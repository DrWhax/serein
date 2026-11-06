// Video in the service: H.264 tracks of MP4 files. Metadata, the poster frame (first frame,
// rotated, PNG), and playback sessions that keep a decoder per open video and return frames
// in display order. Damaged pictures come out concealed (the decoder's errorCount).

import CodecCore
import ContainerMP4
import EncodePNG
import Foundation
import MediaXPCInterface
import VideoH264

struct VideoStream {
    let bytes: [UInt8]
    let file: MP4File
    let track: MP4Track
    let config: AVCDecoderConfiguration
    var decoder: H264Decoder
    var next = 0
    var pending: [H264Frame] = []
    var flushed = false

    init(_ bytes: [UInt8]) throws {
        let file = try MP4Demuxer.parse(bytes)
        guard let track = file.videoTracks.first, case .avc(_, _, _, let config)? = track.sampleEntries.first else {
            throw MediaProcessingError.unsupportedFormat
        }
        self.bytes = bytes
        self.file = file
        self.track = track
        self.config = config
        decoder = try Self.makeDecoder(config)
    }

    static func makeDecoder(_ c: AVCDecoderConfiguration) throws -> H264Decoder {
        do {
            return try H264Decoder(sequenceParameterSets: c.sequenceParameterSets.map { $0.copyBytes() }, pictureParameterSets: c.pictureParameterSets.map { $0.copyBytes() })
        } catch {
            throw MediaProcessingError.undecodable("\(error)")
        }
    }

    var info: VideoInfo {
        let duration = file.durationSeconds > 0 ? file.durationSeconds : Double(track.duration) / Double(max(1, track.timescale))
        var w = track.presentationWidth, h = track.presentationHeight
        if case .avc(_, let cw, let ch, _)? = track.sampleEntries.first, w <= 0 || h <= 0 { w = cw; h = ch }
        if track.rotation % 180 != 0 { swap(&w, &h) }
        return VideoInfo(width: max(1, w), height: max(1, h), rotation: track.rotation, duration: duration,
                         hasAudio: !file.audioTracks.isEmpty, goodForStories: file.storyCheck == .good)
    }

    /// The next frames in display order.
    mutating func frames(_ count: Int) -> [H264Frame] {
        while pending.count < count && !flushed {
            if next < track.samples.count {
                let s = track.samples[next]
                next += 1
                guard s.offset >= 0, s.size >= 0, s.offset + s.size <= bytes.count else { continue }
                pending += decoder.decode(sample: ByteSlice(Array(bytes[s.offset ..< s.offset + s.size])), nalLengthSize: config.nalLengthSize, pts: s.compositionTime)
            } else {
                pending += decoder.flush()
                flushed = true
            }
        }
        let out = Array(pending.prefix(count))
        pending.removeFirst(out.count)
        return out
    }

    func seconds(_ pts: Int64?) -> Double {
        Double((pts ?? 0) - track.presentationOffset) / Double(max(1, track.timescale))
    }

    /// Restarts decoding at the sync sample whose presentation time is at or before `t`.
    mutating func seek(to t: Double) throws {
        let target = Int64(t * Double(track.timescale)) + track.presentationOffset
        var start = 0
        for (i, s) in track.samples.enumerated() where s.isSync && s.compositionTime <= target { start = i }
        decoder = try Self.makeDecoder(config)
        next = start
        pending = []
        flushed = false
    }
}

extension MediaDecoder {
    func stream(_ bytes: Data) throws -> VideoStream {
        do { return try VideoStream(Array(bytes)) } catch let e as MediaProcessingError { throw e } catch { throw MediaProcessingError.undecodable("\(error)") }
    }

    public func videoInfo(_ bytes: Data) async throws -> VideoInfo { try stream(bytes).info }

    public func posterFrame(_ bytes: Data) async throws -> VideoPoster {
        var s = try stream(bytes)
        guard let f = s.frames(1).first else { throw MediaProcessingError.undecodable("no frame") }
        let (w, h, rgba) = YUVConvert.rgba(f.picture, fullRange: f.fullRange, matrix: f.matrixCoefficients, rotation: s.track.rotation)
        let png = PNGEncoder.encode(PixelBuffer(width: w, height: h, rgba: rgba))
        return VideoPoster(png: Data(png), width: w, height: h, duration: s.info.duration)
    }

    static let videoSessions = VideoSessions()

    public func openVideo(_ bytes: Data) async throws -> (session: UUID, info: VideoInfo) {
        let s = try stream(bytes)
        return (try await Self.videoSessions.open(s), s.info)
    }

    public func videoFrames(_ session: UUID, count: Int) async throws -> [VideoFrame] {
        try await Self.videoSessions.frames(session, count: min(max(count, 1), VideoLimits.maxFramesPerRequest))
    }

    public func seekVideo(_ session: UUID, to seconds: Double) async throws { try await Self.videoSessions.seek(session, to: seconds) }
    public func closeVideo(_ session: UUID) async { await Self.videoSessions.close(session) }
}

actor VideoSessions {
    var sessions: [UUID: VideoStream] = [:]

    func open(_ s: VideoStream) throws -> UUID {
        guard sessions.count < VideoLimits.maxSessions else { throw MediaProcessingError.undecodable("too many open videos") }
        let id = UUID()
        sessions[id] = s
        return id
    }

    func frames(_ id: UUID, count: Int) throws -> [VideoFrame] {
        guard var s = sessions[id] else { throw MediaProcessingError.invalidResult }
        let frames = s.frames(count)
        sessions[id] = s
        return frames.map { f in
            VideoFrame(time: s.seconds(f.pts), width: f.picture.width, height: f.picture.height, y: Data(f.picture.y), u: Data(f.picture.u), v: Data(f.picture.v),
                       fullRange: f.fullRange, matrix: f.matrixCoefficients)
        }
    }

    func seek(_ id: UUID, to t: Double) throws {
        guard var s = sessions[id] else { throw MediaProcessingError.invalidResult }
        try s.seek(to: t)
        sessions[id] = s
    }

    func close(_ id: UUID) { sessions[id] = nil }
}
