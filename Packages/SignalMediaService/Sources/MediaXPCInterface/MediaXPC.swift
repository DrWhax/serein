// The XPC boundary to SignalMediaDecoder.xpc (plan.md "all parsing of incoming media runs in a
// sandboxed XPC service"): each message carries a `MediaRequest` and its reply the result, both
// in the strict wire format (Wire.swift) (or an error string) over XPCTransport.swift. The
// client is `MediaProcessing`, so the app passes it wherever the in-process decoder went in
// tests. A request that fails, times out, or loses the service (a crash) throws; the session is
// then reopened for the next one.

import Foundation
import Synchronization
import XPC

public enum MediaRequest: Codable, Sendable {
    case stickerImage(Data)
    case displayImage(Data, maxDimension: Int)
    case displayAnimation(Data, maxDimension: Int)
    case imageInfo(Data)
    case thumbnail(Data, size: Int)
    case scaleForSending(Data, contentType: String, level: MediaQualityLevel)
    case stripMetadata(Data, contentType: String)
    case convertHEIC(Data)
    case audioSummary(Data)
    case decodeAudio(Data, startFrame: Int, maxFrames: Int)
    case startVoiceNote(sampleRate: Int)
    case appendVoiceNote(UUID, samples: [Float])
    case finishVoiceNote(UUID)
    case cancelVoiceNote(UUID)
    /// Records from the microphone into a new voice note, in the voice-note service (the app
    /// never opens the microphone): asks for permission first if it was never given.
    case recordVoiceNote
    case voiceNoteProgress(UUID)
    case videoInfo(Data)
    case posterFrame(Data)
    case openVideo(Data)
    case videoFrames(UUID, count: Int)
    case seekVideo(UUID, seconds: Double)
    case closeVideo(UUID)
}

public enum VoiceNoteLimits {
    /// The largest request the voice-note service reads (a chunk of recorded samples).
    public static let maxRequestBytes = 16 << 20
}

extension MediaRequest {
    /// Recording requests: served by SignalVoiceNoteEncoder.xpc, never by the decoder.
    public var isVoiceNote: Bool {
        switch self {
        case .startVoiceNote, .appendVoiceNote, .finishVoiceNote, .cancelVoiceNote, .recordVoiceNote, .voiceNoteProgress: return true
        default: return false
        }
    }

    /// The largest request the decoder service reads (attachments are at most 100 MiB upstream).
    public static let maxBytes = 512 << 20
    static let small = 64 << 10

    /// The largest reply this request can have, from the limits its result's `validated` checks.
    public var maxReplyBytes: Int {
        func pixels(_ side: Int) -> Int { let s = min(max(side, 1), 16384); return s * s * 4 }
        switch self {
        case .stickerImage: return StickerImage.maxBytes + pixels(StickerImage.size) + Self.small
        case .displayImage(_, let max): return pixels(min(max, 4096)) + Self.small
        case .displayAnimation(_, let max): return Swift.max(pixels(min(max, 4096)), DisplayAnimation.maxBytes) + Self.small
        case .thumbnail: return (4 << 20) + Self.small
        case .scaleForSending(let b, _, let level): return b.count + pixels(level.data.maxDimensions) + Self.small
        case .stripMetadata(let b, _): return b.count + Self.small
        case .convertHEIC: return (256 << 20) + Self.small
        case .decodeAudio(_, _, let frames): return min(max(frames, 0), AudioLimits.maxChunkFrames) * AudioLimits.maxChannels * 4 + Self.small
        case .finishVoiceNote: return 64 << 20
        case .posterFrame: return pixels(8192) + Self.small
        case .videoFrames: return Int.max   // its own frame format, checked frame by frame (decodeFrames)
        case .voiceNoteProgress: return VoiceNoteProgress.maxLevels * 4 + Self.small
        case .imageInfo, .audioSummary, .videoInfo, .openVideo, .startVoiceNote, .appendVoiceNote, .cancelVoiceNote, .recordVoiceNote, .seekVideo,
             .closeVideo: return Self.small
        }
    }
}

/// `openVideo`'s result over the wire.
public struct OpenedVideo: Codable, Sendable {
    public var session: UUID
    public var info: VideoInfo
    public init(session: UUID, info: VideoInfo) {
        self.session = session
        self.info = info
    }
}

/// A result-less reply.
public struct MediaEmpty: Codable, Sendable { public init() {} }

public enum MediaXPCWire {
    /// Video frames as a flat record (a binary plist hashes every Data it holds, megabytes per
    /// frame): "SSVF", version 2, a count, then per frame its fields and the three planes.
    /// Little-endian; the reader checks every length against what is left.
    static let framesMagic: [UInt8] = [0x53, 0x53, 0x56, 0x46, 2]

    public static func encodeFrames(_ frames: [VideoFrame]) -> Data {
        var out = Data(capacity: 16 + frames.reduce(0) { $0 + 48 + $1.y.count + $1.u.count + $1.v.count })
        func u(_ v: UInt64, _ bytes: Int) { for i in 0..<bytes { out.append(UInt8(truncatingIfNeeded: v >> UInt64(8 * i))) } }
        out.append(contentsOf: framesMagic)
        u(UInt64(frames.count), 4)
        for f in frames {
            u(f.time.bitPattern, 8)
            u(UInt64(f.width), 4)
            u(UInt64(f.height), 4)
            u(f.fullRange ? 1 : 0, 1)
            u(UInt64(UInt16(truncatingIfNeeded: f.matrix)), 2)
            u(UInt64(UInt16(truncatingIfNeeded: f.transfer)), 2)
            u(UInt64(UInt8(truncatingIfNeeded: f.bitDepth)), 1)
            for plane in [f.y, f.u, f.v] {
                u(UInt64(plane.count), 4)
                out.append(plane)
            }
        }
        return out
    }

    public static func decodeFrames(_ data: Data, maxFrames: Int) throws -> [VideoFrame] {
        let bad = MediaProcessingError.invalidResult
        var pos = data.startIndex
        func take(_ n: Int) throws -> Data {
            guard n >= 0, data.endIndex - pos >= n else { throw bad }
            defer { pos += n }
            return data.subdata(in: pos ..< pos + n)
        }
        func u(_ bytes: Int) throws -> UInt64 {
            guard data.endIndex - pos >= bytes else { throw bad }
            var v: UInt64 = 0
            for i in 0..<bytes { v |= UInt64(data[pos + i]) << UInt64(8 * i) }
            pos += bytes
            return v
        }
        guard [UInt8](try take(framesMagic.count)) == framesMagic else { throw bad }
        let count = Int(try u(4))
        guard count <= maxFrames else { throw bad }
        var frames: [VideoFrame] = []
        for _ in 0..<count {
            let time = Double(bitPattern: try u(8))
            let width = Int(try u(4)), height = Int(try u(4))
            let full = try u(1)
            guard full <= 1 else { throw bad }
            let matrix = Int(try u(2)), transfer = Int(try u(2)), bitDepth = Int(try u(1))
            let y = try take(Int(try u(4))), cb = try take(Int(try u(4))), cr = try take(Int(try u(4)))
            frames.append(VideoFrame(time: time, width: width, height: height, y: y, u: cb, v: cr, fullRange: full == 1, matrix: matrix, transfer: transfer,
                                     bitDepth: bitDepth))
        }
        guard pos == data.endIndex else { throw bad }
        return frames
    }

    /// Everything else: the strict wire format (Wire.swift).
    public static func encode<T: Encodable>(_ value: T) throws -> Data { try Wire.encode(value) }
    /// `maxBytes`: the largest message the caller can legitimately get; anything larger is
    /// refused before it is read.
    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data, maxBytes: Int) throws -> T {
        try Wire.decode(type, data, maxBytes: maxBytes)
    }
}

public final class MediaXPCClient: MediaProcessing {
    public static let serviceName = "org.signalsafe.SignalMediaDecoder"
    public static let voiceServiceName = "org.signalsafe.SignalVoiceNoteEncoder"
    let channel: XPCChannel
    /// Voice notes go to their own service (SignalVoiceNoteEncoder.xpc).
    let voice: XPCChannel

    /// The bundled services (only if they are signed as XPCPeer says), or (tests) listeners.
    public init(timeout: Duration = .seconds(30),
                decoder: XPCTarget = .service(MediaXPCClient.serviceName), peer: XPCPeerRequirement? = XPCPeer.requirement(.decoder),
                voice: XPCTarget = .service(MediaXPCClient.voiceServiceName), voicePeer: XPCPeerRequirement? = XPCPeer.requirement(.voice)) {
        channel = XPCChannel(decoder, peer: peer, timeout: timeout)
        // Long enough for the microphone permission prompt (`recordVoiceNote`'s budget).
        self.voice = XPCChannel(voice, peer: voicePeer, timeout: max(timeout, MediaRequest.recordVoiceNote.budget))
    }

    /// Tests: given channels.
    init(channel: XPCChannel, voice: XPCChannel) {
        self.channel = channel
        self.voice = voice
    }

    /// Inputs that hung or crashed the service (shared by every call on this client).
    public let quarantine = MediaQuarantine()
    static let quarantined = "this file stopped the media service before"

    /// `orphan`: what to do with a reply that came after the request ended (it timed out or its
    /// caller was cancelled): a session the service opened for it is closed (`release`).
    func call<T: Decodable & Sendable>(_ request: MediaRequest, _ type: T.Type, orphan: (@Sendable (T) -> Void)? = nil) async throws -> T {
        let maxBytes = request.maxReplyBytes
        var late: (@Sendable (Data) -> Void)? = nil
        if let orphan { late = { bytes in if let v = try? MediaXPCWire.decode(T.self, bytes, maxBytes: maxBytes) { orphan(v) } } }
        return try MediaXPCWire.decode(T.self, try await callData(request, late: late), maxBytes: maxBytes)
    }

    /// The reply's bytes, undecoded. Refused at once for a quarantined input; the request's
    /// budget bounds the wait (Containment.swift).
    func callData(_ request: MediaRequest, late: (@Sendable (Data) -> Void)? = nil) async throws -> Data {
        let payload = try MediaXPCWire.encode(request)
        if request.isVoiceNote { return try await voice.send(payload, timeout: request.budget, maxReply: request.maxReplyBytes, late: late) }
        let key = request.input.map(MediaQuarantine.key)
        if let key, quarantine.isQuarantined(key) { throw MediaProcessingError.undecodable(Self.quarantined) }
        // Every request in flight on a session that ends fails with `lost`, each once: its input
        // takes one strike for that session, however many of its requests were in flight, so one
        // crash quarantines nothing by itself.
        var lost: (@Sendable (UInt64) -> Void)? = nil
        if let key { lost = { [quarantine] session in quarantine.strike(key, lostSession: session) } }
        do {
            return try await channel.send(payload, timeout: request.budget, maxReply: request.maxReplyBytes, late: late, lost: lost)
        } catch XPCServiceError.timedOut {
            if let key { quarantine.strike(key, MediaQuarantine.strikesToQuarantine) }
            throw XPCServiceError.timedOut
        }
    }

    /// Closes a session the service opened for a request nobody is waiting for, or whose answer
    /// was refused (the service would keep it: VideoLimits.maxSessions, VoiceNoteSessions).
    func release(_ request: MediaRequest) {
        Task { _ = try? await self.callData(request) }
    }

    public func stickerImage(_ bytes: Data) async throws -> StickerImage { try await call(.stickerImage(bytes), StickerImage.self).validated() }
    public func displayImage(_ bytes: Data, maxDimension: Int) async throws -> DisplayImage {
        try await call(.displayImage(bytes, maxDimension: maxDimension), DisplayImage.self).validated(maxDimension: maxDimension)
    }
    public func displayAnimation(_ bytes: Data, maxDimension: Int) async throws -> DisplayAnimation {
        guard (1...4096).contains(maxDimension) else { throw MediaProcessingError.undecodable("bad maxDimension") }
        return try await call(.displayAnimation(bytes, maxDimension: maxDimension), DisplayAnimation.self).validated(maxDimension: maxDimension)
    }
    public func imageInfo(_ bytes: Data) async throws -> ImageInfo { try await call(.imageInfo(bytes), ImageInfo.self).validated() }
    public func thumbnail(_ bytes: Data, size: Int) async throws -> Thumbnail { try await call(.thumbnail(bytes, size: size), Thumbnail.self).validated(size: size) }
    public func scaleForSending(_ bytes: Data, contentType: String, level: MediaQualityLevel) async throws -> ScaledImage {
        try await call(.scaleForSending(bytes, contentType: contentType, level: level), ScaledImage.self).validated(maxDimension: 4096)
    }
    public func stripMetadata(_ bytes: Data, contentType: String) async throws -> Data { try await call(.stripMetadata(bytes, contentType: contentType), Data.self) }
    public func convertHEIC(_ bytes: Data) async throws -> ConvertedImage { try await call(.convertHEIC(bytes), ConvertedImage.self).validated() }
    public func audioSummary(_ bytes: Data) async throws -> AudioSummary { try await call(.audioSummary(bytes), AudioSummary.self).validated() }
    public func decodeAudio(_ bytes: Data, startFrame: Int, maxFrames: Int) async throws -> AudioChunk {
        try await call(.decodeAudio(bytes, startFrame: startFrame, maxFrames: maxFrames), AudioChunk.self).validated(requestedStart: startFrame, maxFrames: maxFrames)
    }
    public func startVoiceNote(sampleRate: Int) async throws -> UUID {
        try await call(.startVoiceNote(sampleRate: sampleRate), UUID.self) { [weak self] id in self?.release(.cancelVoiceNote(id)) }
    }
    public func appendVoiceNote(_ session: UUID, samples: [Float]) async throws { _ = try await call(.appendVoiceNote(session, samples: samples), MediaEmpty.self) }
    public func finishVoiceNote(_ session: UUID) async throws -> VoiceNote { try await call(.finishVoiceNote(session), VoiceNote.self).validated() }
    public func cancelVoiceNote(_ session: UUID) async { _ = try? await call(.cancelVoiceNote(session), MediaEmpty.self) }
    /// Starts recording a voice note from the microphone (in the voice-note service). A recording
    /// that starts after its caller stopped waiting (cancelled, or timed out at the permission
    /// prompt) is cancelled at once (Verification/Broker, B4), so the microphone is not left on;
    /// the service also stops one nobody polls (VoiceNoteRecorder.unwatched).
    public func recordVoiceNote() async throws -> UUID {
        try await call(.recordVoiceNote, UUID.self) { [weak self] id in self?.release(.cancelVoiceNote(id)) }
    }
    public func voiceNoteProgress(_ session: UUID) async throws -> VoiceNoteProgress {
        try await call(.voiceNoteProgress(session), VoiceNoteProgress.self).validated()
    }
    public func videoInfo(_ bytes: Data) async throws -> VideoInfo { try await call(.videoInfo(bytes), VideoInfo.self).validated() }
    public func posterFrame(_ bytes: Data) async throws -> VideoPoster { try await call(.posterFrame(bytes), VideoPoster.self).validated() }
    public func openVideo(_ bytes: Data) async throws -> (session: UUID, info: VideoInfo) {
        let o = try await call(.openVideo(bytes), OpenedVideo.self) { [weak self] o in self?.release(.closeVideo(o.session)) }
        do { return (o.session, try o.info.validated()) } catch {
            release(.closeVideo(o.session))
            throw error
        }
    }
    public func videoFrames(_ session: UUID, count: Int) async throws -> [VideoFrame] {
        let frames = try MediaXPCWire.decodeFrames(try await callData(.videoFrames(session, count: count)), maxFrames: VideoLimits.maxFramesPerRequest)
        return try frames.map { try $0.validated() }
    }
    public func seekVideo(_ session: UUID, to seconds: Double) async throws { _ = try await call(.seekVideo(session, seconds: seconds), MediaEmpty.self) }
    public func closeVideo(_ session: UUID) async { _ = try? await call(.closeVideo(session), MediaEmpty.self) }
}
