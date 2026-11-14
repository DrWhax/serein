// Video in the service: H.264, HEVC and AV1 tracks of MP4 files. Metadata, the poster frame (first frame,
// rotated, PNG), and playback sessions that keep a decoder per open video and return frames
// in display order. Damaged pictures come out concealed (the decoder's errorCount).

import CodecCore
import ContainerMP4
import EncodePNG
import Foundation
import MediaXPCInterface
import VideoAV1
import VideoH264
import VideoHEVC

/// A decoded frame from either decoder: 8-bit planes and the colour description.
struct DecodedVideoFrame {
    /// The planes' bytes: one per sample, or two (little-endian) when `bitDepth` > 8.
    var picture: YUVPicture
    var bitDepth = 8
    var pts: Int64?
    var fullRange: Bool
    var matrix: Int
    var transfer: Int
}

struct VideoStream {
    enum Backend {
        case avc(H264Decoder, AVCDecoderConfiguration)
        case hevc(HEVCDecoder, HEVCDecoderConfiguration)
        case av1(AV1VideoDecoder, AV1CodecConfiguration)
    }

    let bytes: [UInt8]
    let file: MP4File
    let track: MP4Track
    var backend: Backend
    var next = 0
    var pending: [DecodedVideoFrame] = []
    var flushed = false
    /// 10/12-bit HEVC keeps its precision (playback); otherwise frames are 8-bit.
    let deep: Bool

    init(_ bytes: [UInt8], deep: Bool = false) throws {
        self.deep = deep
        let file = try MP4Demuxer.parse(bytes)
        guard let track = file.videoTracks.first else {
            throw MediaProcessingError.undecodable("no video track (\(file.audioTracks.count) audio)")
        }
        guard !track.samples.isEmpty else { throw MediaProcessingError.undecodable("no samples (fragmented MP4?)") }
        self.bytes = bytes
        self.file = file
        self.track = track
        switch track.sampleEntries.first {
        case .avc(_, _, _, let config)?: backend = .avc(try Self.makeDecoder(config), config)
        case .hevc(_, _, _, let config)?: backend = .hevc(try Self.makeDecoder(config, deep: deep), config)
        case .av1(_, _, let config)?: backend = .av1(try Self.makeDecoder(config), config)
        default:
            // Name what it is (vp09 = VP9, mp4v = MPEG-4 Part 2…).
            let codec = track.sampleEntries.first.map { Self.text($0.fourCC) } ?? "none"
            throw MediaProcessingError.undecodable("unsupported video codec \(codec)")
        }
    }

    /// A FourCC as its four characters (non-printable bytes as "?").
    static func text(_ f: FourCC) -> String {
        String([24, 16, 8, 0].map { shift -> Character in
            let b = UInt8((f >> UInt32(shift)) & 0xFF)
            return (0x20 ... 0x7E).contains(b) ? Character(UnicodeScalar(b)) : "?"
        })
    }

    /// Reconstruction workers: the cores less one for parsing the next picture (which runs
    /// alongside) and one for the rest of the service; 6 on an 8-core Mac.
    static let decodeThreads = max(2, min(16, ProcessInfo.processInfo.activeProcessorCount - 2))

    static func makeDecoder(_ c: AVCDecoderConfiguration) throws -> H264Decoder {
        do {
            var limits = H264Decoder.Limits()
            limits.threads = decodeThreads
            return try H264Decoder(sequenceParameterSets: c.sequenceParameterSets.map { $0.copyBytes() }, pictureParameterSets: c.pictureParameterSets.map { $0.copyBytes() },
                                   limits: limits)
        } catch {
            throw MediaProcessingError.undecodable("\(error)")
        }
    }

    static func makeDecoder(_ c: HEVCDecoderConfiguration, deep: Bool) throws -> HEVCDecoder {
        do {
            let d = try HEVCDecoder(vps: c.videoParameterSets.map { $0.copyBytes() }, sps: c.sequenceParameterSets.map { $0.copyBytes() },
                                    pps: c.pictureParameterSets.map { $0.copyBytes() }, nalLengthSize: c.nalLengthSize)
            d.packedOutput = deep ? .littleEndian16 : .eightBit
            return d
        } catch {
            throw MediaProcessingError.undecodable("\(error)")
        }
    }

    static func makeDecoder(_ c: AV1CodecConfiguration) throws -> AV1VideoDecoder {
        guard !c.monochrome, c.subsamplingX, c.subsamplingY else { throw MediaProcessingError.undecodable("AV1 other than 4:2:0") }
        do { return try AV1VideoDecoder(configOBUs: c.configOBUs) } catch { throw MediaProcessingError.undecodable("\(error)") }
    }

    /// 4:2:0 planes: 8-bit, or (10-bit when `deep`) 16-bit little-endian as HEVC's.
    static func frame(_ f: AV1Frame, deep: Bool) -> DecodedVideoFrame {
        var p = YUVPicture(width: f.width, height: f.height)
        let shift = f.bitDepth - 8
        func reduce(_ a: [UInt16]) -> [UInt8] {
            if shift == 0 { return a.map { UInt8(truncatingIfNeeded: $0) } }
            let round = UInt16(1 << (shift - 1))
            return a.map { UInt8(min(255, ($0 + round) >> UInt16(shift))) }
        }
        func packed(_ a: [UInt16]) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: 2 * a.count)
            for (i, v) in a.enumerated() { out[2 * i] = UInt8(v & 0xFF); out[2 * i + 1] = UInt8(v >> 8) }
            return out
        }
        let two = deep && f.bitDepth > 8
        p.y = two ? packed(f.y) : reduce(f.y)
        p.u = two ? packed(f.u) : reduce(f.u)
        p.v = two ? packed(f.v) : reduce(f.v)
        return DecodedVideoFrame(picture: p, bitDepth: two ? f.bitDepth : 8, pts: f.pts, fullRange: f.fullRange, matrix: f.matrixCoefficients,
                                 transfer: f.transferCharacteristics)
    }

    var info: VideoInfo {
        let duration = file.durationSeconds > 0 ? file.durationSeconds : Double(track.duration) / Double(max(1, track.timescale))
        var w = track.presentationWidth, h = track.presentationHeight
        switch track.sampleEntries.first {
        case .avc(_, let cw, let ch, _)? where w <= 0 || h <= 0: w = cw; h = ch
        case .hevc(_, let cw, let ch, _)? where w <= 0 || h <= 0: w = cw; h = ch
        case .av1(let cw, let ch, _)? where w <= 0 || h <= 0: w = cw; h = ch
        default: break
        }
        if track.rotation % 180 != 0 { swap(&w, &h) }
        return VideoInfo(width: max(1, w), height: max(1, h), rotation: track.rotation, duration: duration,
                         hasAudio: !file.audioTracks.isEmpty, goodForStories: file.storyCheck == .good)
    }

    /// 10 / 12-bit samples rounded to 8 bits (the renderer's textures; HDR stays HLG / PQ coded).
    static func eightBit(_ f: HEVCFrame) -> DecodedVideoFrame {
        var p = YUVPicture(width: f.width, height: f.height)
        if f.packedBytesPerSample > 0 {
            // Packed by the decoder (its reconstruction thread): 8-bit, or 16-bit little-endian.
            let two = f.packedBytesPerSample == 2
            p.y = f.packedY
            if f.chromaFormat == 0 {
                let mid = 1 << (f.bitDepth - 1), n = ((f.width + 1) / 2) * ((f.height + 1) / 2)
                p.u = two ? (0..<(2 * n)).map { UInt8(truncatingIfNeeded: $0 & 1 == 0 ? mid : mid >> 8) } : [UInt8](repeating: 128, count: n)
                p.v = p.u
            } else {
                p.u = f.packedU
                p.v = f.packedV
            }
            return DecodedVideoFrame(picture: p, bitDepth: two ? f.bitDepth : 8, pts: f.pts, fullRange: f.fullRange, matrix: f.matrixCoefficients,
                                     transfer: f.transferCharacteristics)
        }
        let shift = f.bitDepth - 8
        func reduce(_ a: [UInt16]) -> [UInt8] {
            if shift == 0 { return a.map { UInt8(truncatingIfNeeded: $0) } }
            let round = UInt16(1 << (shift - 1))
            return a.map { UInt8(min(255, ($0 + round) >> UInt16(shift))) }
        }
        p.y = reduce(f.y)
        if f.chromaFormat == 0 {
            p.u = [UInt8](repeating: 128, count: ((f.width + 1) / 2) * ((f.height + 1) / 2))
            p.v = p.u
        } else {
            p.u = reduce(f.u)
            p.v = reduce(f.v)
        }
        return DecodedVideoFrame(picture: p, pts: f.pts, fullRange: f.fullRange, matrix: f.matrixCoefficients, transfer: f.transferCharacteristics)
    }

    /// The next frames in display order.
    mutating func frames(_ count: Int) -> [DecodedVideoFrame] {
        while pending.count < count && !flushed {
            if next < track.samples.count {
                let s = track.samples[next]
                next += 1
                guard s.offset >= 0, s.size >= 0, s.offset + s.size <= bytes.count else { continue }
                let sample = ByteSlice(Array(bytes[s.offset ..< s.offset + s.size]))
                switch backend {
                case .avc(var d, let c):
                    let out = d.decode(sample: sample, nalLengthSize: c.nalLengthSize, pts: s.compositionTime)
                    backend = .avc(d, c)
                    pending += out.map { DecodedVideoFrame(picture: $0.picture, pts: $0.pts, fullRange: $0.fullRange, matrix: $0.matrixCoefficients, transfer: 1) }
                case .hevc(let d, _):
                    pending += d.decode(sample: sample, pts: s.compositionTime).map(Self.eightBit)
                case .av1(let d, _):
                    let deep = self.deep
                    pending += d.decode(sample: sample, pts: s.compositionTime).map { Self.frame($0, deep: deep) }
                }
            } else {
                switch backend {
                case .avc(var d, let c):
                    let out = d.flush()
                    backend = .avc(d, c)
                    pending += out.map { DecodedVideoFrame(picture: $0.picture, pts: $0.pts, fullRange: $0.fullRange, matrix: $0.matrixCoefficients, transfer: 1) }
                case .hevc(let d, _): pending += d.flush().map(Self.eightBit)
                case .av1(let d, _):
                    let deep = self.deep
                    pending += d.flush().map { Self.frame($0, deep: deep) }
                }
                flushed = true
            }
        }
        readAhead()
        let out = Array(pending.prefix(count))
        pending.removeFirst(out.count)
        return out
    }

    /// Frames decoded ahead of the caller (memory: a frame each).
    static let readAheadFrames = 6

    /// Keeps the H.264 decoder's pictures in flight between requests: samples are submitted
    /// while it has room (each costs only its headers here; the pictures decode in the
    /// background while these frames travel), up to `readAheadFrames` waiting.
    mutating func readAhead() {
        guard case .avc(var d, let c) = backend else { return }
        while !flushed, next < track.samples.count, pending.count < Self.readAheadFrames, d.picturesInFlight < H264Decoder.maxPicturesInFlight - 1 {
            let s = track.samples[next]
            next += 1
            guard s.offset >= 0, s.size >= 0, s.offset + s.size <= bytes.count else { continue }
            let out = d.decode(sample: ByteSlice(Array(bytes[s.offset ..< s.offset + s.size])), nalLengthSize: c.nalLengthSize, pts: s.compositionTime)
            pending += out.map { DecodedVideoFrame(picture: $0.picture, pts: $0.pts, fullRange: $0.fullRange, matrix: $0.matrixCoefficients, transfer: 1) }
        }
        backend = .avc(d, c)
    }

    func seconds(_ pts: Int64?) -> Double {
        Double((pts ?? 0) - track.presentationOffset) / Double(max(1, track.timescale))
    }

    /// Restarts decoding at the sync sample whose presentation time is at or before `t`.
    mutating func seek(to t: Double) throws {
        let target = Int64(t * Double(track.timescale)) + track.presentationOffset
        var start = 0
        for (i, s) in track.samples.enumerated() where s.isSync && s.compositionTime <= target { start = i }
        switch backend {
        case .avc(_, let c): backend = .avc(try Self.makeDecoder(c), c)
        case .hevc(_, let c): backend = .hevc(try Self.makeDecoder(c, deep: deep), c)
        case .av1(_, let c): backend = .av1(try Self.makeDecoder(c), c)
        }
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
        let (w, h, rgba) = f.transfer == 16 || f.transfer == 18
            ? HDRConvert.rgba(f.picture, fullRange: f.fullRange, pq: f.transfer == 16, rotation: s.track.rotation)
            : YUVConvert.rgba(f.picture, fullRange: f.fullRange, matrix: f.matrix, rotation: s.track.rotation)
        let png = PNGEncoder.encode(PixelBuffer(width: w, height: h, rgba: rgba))
        return VideoPoster(png: Data(png), width: w, height: h, duration: s.info.duration)
    }

    static let videoSessions = VideoSessions()

    public func openVideo(_ bytes: Data) async throws -> (session: UUID, info: VideoInfo) {
        try await Self.videoSessions.open(Array(bytes))
    }

    public func videoFrames(_ session: UUID, count: Int, fit: VideoFit?) async throws -> [VideoFrame] {
        try await Self.videoSessions.frames(session, count: min(max(count, 1), VideoLimits.maxFramesPerRequest), fit: try fit?.validated())
    }

    public func seekVideo(_ session: UUID, to seconds: Double) async throws { try await Self.videoSessions.seek(session, to: seconds) }
    public func closeVideo(_ session: UUID) async { await Self.videoSessions.close(session) }
}

actor VideoSessions {
    var sessions: [UUID: VideoStream] = [:]

    /// The stream (and its decoder) is built inside the actor and never leaves it.
    func open(_ bytes: [UInt8]) throws -> (session: UUID, info: VideoInfo) {
        guard sessions.count < VideoLimits.maxSessions else { throw MediaProcessingError.undecodable("too many open videos") }
        let s: VideoStream
        do { s = try VideoStream(bytes, deep: true) } catch let e as MediaProcessingError { throw e } catch { throw MediaProcessingError.undecodable("\(error)") }
        let id = UUID()
        sessions[id] = s
        return (id, s.info)
    }

    /// The next frames, each scaled down to `fit` when larger than it shows.
    func frames(_ id: UUID, count: Int, fit: VideoFit? = nil) throws -> [VideoFrame] {
        guard var s = sessions[id] else { throw MediaProcessingError.invalidResult }
        let frames = s.frames(count)
        sessions[id] = s
        let rotation = s.track.rotation
        return frames.map { decoded in
            let f = fit.map { decoded.scaled(to: $0, rotation: rotation) } ?? decoded
            return VideoFrame(time: s.seconds(f.pts), width: f.picture.width, height: f.picture.height, y: Data(f.picture.y), u: Data(f.picture.u),
                              v: Data(f.picture.v), fullRange: f.fullRange, matrix: f.matrix, transfer: f.transfer, bitDepth: f.bitDepth,
                              decodedWidth: decoded.picture.width, decodedHeight: decoded.picture.height)
        }
    }

    func seek(_ id: UUID, to t: Double) throws {
        guard var s = sessions[id] else { throw MediaProcessingError.invalidResult }
        try s.seek(to: t)
        sessions[id] = s
    }

    func close(_ id: UUID) { sessions[id] = nil }
}
