// Audio attachments in the service: MP3 and AAC (ADTS, or the first AAC track of an MP4 /
// M4A), sniffed from the bytes. Each stream becomes a timeline of codec frames with the
// presentation trim players apply (MP3: the LAME/Xing delay + the decoder's 529 and the
// padding; MP4: the edit list's start and length; ADTS: none), so chunks can be decoded from
// any point: decoding starts a few frames early (the MP3 bit reservoir, the IMDCT overlap)
// and the warm-up output is dropped. (AAC noise substitution draws from a generator that runs
// through the stream, so a chunk's noise bands differ from a decode from the start.)

import AudioAAC
import AudioMP3
import CodecCore
import ContainerMP4
import Foundation
import MediaXPCInterface

struct AudioTimeline {
    enum Source {
        case mp3(MP3Stream)
        case aac(frames: [ByteSlice], config: AACConfig)
    }

    let source: Source
    let sampleRate: Int
    let channels: Int
    let samplesPerUnit: Int
    let units: Int
    /// Decoder-output samples before the presentation starts.
    let skip: Int
    /// Presentation length in frames.
    let totalFrames: Int

    static func sniff(_ b: [UInt8]) -> Bool {
        if b.count >= 8, Array(b[4 ..< 8]) == Array("ftyp".utf8) { return true }
        if b.count >= 3, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 { return true }   // ID3 (MP3 or ADTS)
        return b.count >= 2 && b[0] == 0xFF && b[1] & 0xE0 == 0xE0
    }

    init(_ bytes: [UInt8]) throws {
        if bytes.count >= 8, Array(bytes[4 ..< 8]) == Array("ftyp".utf8) {
            let file = try MP4Demuxer.parse(bytes)
            guard let track = file.audioTracks.first(where: { if case .aac = $0.sampleEntries.first { return true } else { return false } }),
                  case .aac(_, _, let entry) = track.sampleEntries[0] else { throw MediaProcessingError.unsupportedFormat }
            let config = try AACConfig.parse(entry.audioSpecificConfig)
            let all = ByteSlice(bytes)
            var frames: [ByteSlice] = []
            frames.reserveCapacity(track.samples.count)
            for s in track.samples {
                var c = all.cursor()
                try c.skip(s.offset, "mp4.sample")
                frames.append(try c.bytes(s.size, "mp4.sample"))
            }
            source = .aac(frames: frames, config: config)
            sampleRate = config.sampleRate
            channels = config.channels
            samplesPerUnit = 1024
            units = frames.count
            // Edit list times are in the media timescale (the output rate for HE-AAC; we decode
            // only its core) and the movie timescale.
            let scale = Double(config.sampleRate) / Double(max(1, track.timescale))
            skip = Int((Double(track.presentationOffset) * scale).rounded())
            let decoded = units * 1024 - skip
            if let edit = track.editList.first(where: { $0.mediaTime >= 0 }), file.movieTimescale > 0, edit.segmentDuration > 0 {
                let frames = Int((Double(edit.segmentDuration) / Double(file.movieTimescale) * Double(config.sampleRate)).rounded())
                totalFrames = max(0, min(decoded, frames))
            } else {
                totalFrames = max(0, decoded)
            }
            return
        }
        // ADTS or MP3 (both may start with ID3).
        var start = 0
        while bytes.count - start >= 10, bytes[start] == 0x49, bytes[start + 1] == 0x44, bytes[start + 2] == 0x33 {
            let size = Int(bytes[start + 6] & 0x7F) << 21 | Int(bytes[start + 7] & 0x7F) << 14 | Int(bytes[start + 8] & 0x7F) << 7 | Int(bytes[start + 9] & 0x7F)
            start += 10 + size + (bytes[start + 5] & 0x10 != 0 ? 10 : 0)
        }
        if start + 2 <= bytes.count, bytes[start] == 0xFF, bytes[start + 1] & 0xF6 == 0xF0 {
            let frames = try ADTS.frames(bytes)
            guard let first = frames.first, frames.allSatisfy({ $0.rawDataBlocks == 1 && $0.config == first.config }) else { throw MediaProcessingError.unsupportedFormat }
            source = .aac(frames: frames.map(\.payload), config: first.config)
            sampleRate = first.config.sampleRate
            channels = first.config.channels
            samplesPerUnit = 1024
            units = frames.count
            skip = 0
            totalFrames = units * 1024
            return
        }
        let stream = try MP3Stream.parse(bytes)
        source = .mp3(stream)
        sampleRate = stream.sampleRate
        channels = stream.channels
        samplesPerUnit = stream.samplesPerFrame
        units = stream.frames.count
        if let delay = stream.info?.encoderDelay {
            skip = delay + MP3Decoder.decoderDelay
            totalFrames = max(0, units * samplesPerUnit - delay - (stream.info?.encoderPadding ?? 0))
        } else {
            skip = 0
            totalFrames = units * samplesPerUnit
        }
    }

    /// Units to decode before `unit` so that its output is exact.
    func warmUp(before unit: Int) -> Int {
        switch source {
        case .aac: return min(unit, 1)
        case .mp3(let s):
            // Back far enough for the reservoir (≤ 511 bytes of earlier frames' main data), plus
            // one frame for the overlap.
            var bytes = 0, k = 0
            while unit - k > 0 && bytes < 512 {
                k += 1
                let h = s.frames[unit - k].header
                bytes += max(0, s.frames[unit - k].bytes.count - 4 - (h.hasCRC ? 2 : 0) - h.sideInfoLength)
            }
            return min(unit, k + 1)
        }
    }

    /// Calls `body` with each decoded unit's interleaved samples, from `first` up to `end`.
    func decodeUnits(_ first: Int, _ end: Int, _ body: (Int, [Float]) -> Void) throws {
        switch source {
        case .mp3(let s):
            var dec = MP3Decoder(for: s)
            for u in first ..< end {
                let pcm = (try? dec.decode(s.frames[u], channels: channels)) ?? Array(repeating: [Float](repeating: 0, count: samplesPerUnit), count: channels)
                body(u, Self.interleave(pcm))
            }
        case .aac(let frames, let config):
            var dec = AACDecoder(config: config)
            for u in first ..< end {
                // A damaged frame decodes as silence, as players conceal it.
                let pcm = (try? dec.decode(frames[u])) ?? Array(repeating: [Float](repeating: 0, count: 1024), count: channels)
                body(u, Self.interleave(pcm))
            }
        }
    }

    static func interleave(_ pcm: [[Float]]) -> [Float] {
        guard pcm.count > 1 else { return pcm.first ?? [] }
        var out = [Float](repeating: 0, count: pcm[0].count * pcm.count)
        for i in 0 ..< pcm[0].count { for c in pcm.indices { out[i * pcm.count + c] = pcm[c][i] } }
        return out
    }

    /// Presentation frames [start, start + count).
    func decode(start: Int, count: Int) throws -> [Float] {
        let start = max(0, min(start, totalFrames)), count = max(0, min(count, totalFrames - start))
        guard count > 0, samplesPerUnit > 0 else { return [] }
        let rawStart = start + skip, rawEnd = rawStart + count
        let firstUnit = rawStart / samplesPerUnit
        let lastUnit = min(units, (rawEnd + samplesPerUnit - 1) / samplesPerUnit)
        let from = firstUnit - warmUp(before: firstUnit)
        var out: [Float] = []
        out.reserveCapacity(count * channels)
        try decodeUnits(from, lastUnit) { u, samples in
            guard u >= firstUnit else { return }
            let unitStart = u * samplesPerUnit
            let lo = max(rawStart, unitStart) - unitStart, hi = min(rawEnd, unitStart + samplesPerUnit) - unitStart
            if hi > lo { out += samples[lo * channels ..< hi * channels] }
        }
        return out
    }
}

extension MediaDecoder {
    public func audioSummary(_ bytes: Data) async throws -> AudioSummary {
        let b = Array(bytes)
        guard AudioTimeline.sniff(b) else { throw MediaProcessingError.unsupportedFormat }
        let t: AudioTimeline
        do { t = try AudioTimeline(b) } catch let e as MediaProcessingError { throw e } catch { throw MediaProcessingError.undecodable("\(error)") }
        let duration = Double(t.totalFrames) / Double(max(1, t.sampleRate))
        guard AudioLimits.sampleRates.contains(t.sampleRate), (1 ... AudioLimits.maxChannels).contains(t.channels) else { throw MediaProcessingError.unsupportedFormat }
        if duration > AudioLimits.maxWaveformDuration {
            return AudioSummary(waveform: [], duration: duration, sampleRate: t.sampleRate, channels: t.channels)
        }
        var builder = WaveformBuilder()
        let rawEnd = t.skip + t.totalFrames
        try t.decodeUnits(0, t.units) { u, samples in
            let unitStart = u * t.samplesPerUnit
            let lo = max(t.skip, unitStart) - unitStart, hi = min(rawEnd, unitStart + t.samplesPerUnit) - unitStart
            guard hi > lo else { return }
            for s in samples[lo * t.channels ..< hi * t.channels] { builder.push(s) }
        }
        return AudioSummary(waveform: builder.collect(), duration: duration, sampleRate: t.sampleRate, channels: t.channels)
    }

    public func decodeAudio(_ bytes: Data, startFrame: Int, maxFrames: Int) async throws -> AudioChunk {
        let b = Array(bytes)
        guard AudioTimeline.sniff(b) else { throw MediaProcessingError.unsupportedFormat }
        let t: AudioTimeline
        do { t = try AudioTimeline(b) } catch let e as MediaProcessingError { throw e } catch { throw MediaProcessingError.undecodable("\(error)") }
        guard AudioLimits.sampleRates.contains(t.sampleRate), (1 ... AudioLimits.maxChannels).contains(t.channels) else { throw MediaProcessingError.unsupportedFormat }
        let start = max(0, min(startFrame, t.totalFrames))
        let samples = try t.decode(start: start, count: min(maxFrames, AudioLimits.maxChunkFrames))
        var data = Data(capacity: samples.count * 4)
        for s in samples {
            let v = s.bitPattern
            data.append(contentsOf: [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)])
        }
        return AudioChunk(sampleRate: t.sampleRate, channels: t.channels, totalFrames: t.totalFrames, startFrame: start, samples: data)
    }
}

// MARK: voice notes

/// Recording sessions (upstream's mp3Encoder worklet: the encoder plus the waveform of the
/// input samples).
actor VoiceNoteSessions {
    struct Session {
        var encoder: MP3Encoder
        var waveform = WaveformBuilder()
        var bytes: [UInt8] = []
        var samples = 0
        let sampleRate: Int
    }
    var sessions: [UUID: Session] = [:]
    static let maxSessions = 4

    func start(sampleRate: Int) throws -> UUID {
        guard sessions.count < Self.maxSessions else { throw MediaProcessingError.undecodable("too many recordings") }
        guard let encoder = try? MP3Encoder(inputSampleRate: sampleRate) else { throw MediaProcessingError.unsupportedFormat }
        let id = UUID()
        sessions[id] = Session(encoder: encoder, sampleRate: sampleRate)
        return id
    }

    func append(_ id: UUID, _ samples: [Float]) throws {
        guard var s = sessions[id] else { throw MediaProcessingError.invalidResult }
        let clean = samples.map { $0.isFinite ? min(max($0, -1), 1) : 0 }
        for v in clean { s.waveform.push(v) }
        s.samples += clean.count
        s.bytes += s.encoder.encode(clean)
        sessions[id] = s
    }

    func finish(_ id: UUID) throws -> VoiceNote {
        guard var s = sessions.removeValue(forKey: id) else { throw MediaProcessingError.invalidResult }
        s.bytes += s.encoder.flush()
        let tag = s.encoder.tagFrame()
        for (i, b) in tag.enumerated() where i < s.bytes.count { s.bytes[i] = b }
        return VoiceNote(data: Data(s.bytes), waveform: s.waveform.collect(), duration: Double(s.samples) / Double(s.sampleRate))
    }

    func cancel(_ id: UUID) { sessions[id] = nil }
}

extension MediaDecoder {
    static let voiceNotes = VoiceNoteSessions()

    public func startVoiceNote(sampleRate: Int) async throws -> UUID { try await Self.voiceNotes.start(sampleRate: sampleRate) }
    public func appendVoiceNote(_ session: UUID, samples: [Float]) async throws { try await Self.voiceNotes.append(session, samples) }
    public func finishVoiceNote(_ session: UUID) async throws -> VoiceNote { try await Self.voiceNotes.finish(session) }
    public func cancelVoiceNote(_ session: UUID) async { await Self.voiceNotes.cancel(session) }
}
