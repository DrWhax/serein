// The XPC boundary to SignalMediaDecoder.xpc (plan.md "all parsing of incoming media runs in a
// sandboxed XPC service"): one Objective-C method carrying a `MediaRequest` and returning its result,
// both in the strict wire format (Wire.swift) (or an error string). The client is `MediaProcessing`, so
// the app passes it wherever the in-process decoder went in tests. A request that fails, times
// out, or loses the service (a crash) throws; the connection is then rebuilt for the next one.

import Foundation
import Synchronization

@objc public protocol MediaXPCProtocol {
    func handle(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
}

public enum MediaRequest: Codable, Sendable {
    case stickerImage(Data)
    case displayImage(Data, maxDimension: Int)
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
        case .startVoiceNote, .appendVoiceNote, .finishVoiceNote, .cancelVoiceNote: return true
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
        case .thumbnail: return (4 << 20) + Self.small
        case .scaleForSending(let b, _, let level): return b.count + pixels(level.data.maxDimensions) + Self.small
        case .stripMetadata(let b, _): return b.count + Self.small
        case .convertHEIC: return (256 << 20) + Self.small
        case .decodeAudio(_, _, let frames): return min(max(frames, 0), AudioLimits.maxChunkFrames) * AudioLimits.maxChannels * 4 + Self.small
        case .finishVoiceNote: return 64 << 20
        case .posterFrame: return pixels(8192) + Self.small
        case .videoFrames: return Int.max   // its own frame format, checked frame by frame (decodeFrames)
        case .imageInfo, .audioSummary, .videoInfo, .openVideo, .startVoiceNote, .appendVoiceNote, .cancelVoiceNote, .seekVideo,
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

/// One XPC service's connection: rebuilt after an invalidation or interruption (a crash), each
/// request bounded by a watchdog. Shared by the media decoder, the link-preview parser and the
/// fetcher. With a peer requirement (XPCPeer) the connection only talks to a process signed
/// that way: anything else is invalidated by the system before a message is exchanged.
public final class XPCChannel: Sendable {
    let makeConnection: @Sendable () -> NSXPCConnection
    let connection = Mutex<NSXPCConnection?>(nil)
    let timeout: Duration
    let peerRequirement: String?
    let remoteInterface: @Sendable () -> NSXPCInterface

    public init(timeout: Duration, peer: String? = nil,
                remoteInterface: @escaping @Sendable () -> NSXPCInterface = { NSXPCInterface(with: MediaXPCProtocol.self) },
                makeConnection: @escaping @Sendable () -> NSXPCConnection) {
        self.timeout = timeout
        self.makeConnection = makeConnection
        self.peerRequirement = peer
        self.remoteInterface = remoteInterface
    }

    func current() -> NSXPCConnection {
        connection.withLock { c in
            if let c { return c }
            let fresh = makeConnection()
            if let req = peerRequirement { fresh.setCodeSigningRequirement(req) }
            fresh.remoteObjectInterface = remoteInterface()
            let weakSelf = WeakBox(self)
            fresh.invalidationHandler = { weakSelf.value?.connection.withLock { $0 = nil } }
            fresh.interruptionHandler = { weakSelf.value?.connection.withLock { $0 = nil } }
            fresh.resume()
            c = fresh
            return fresh
        }
    }

    /// The reply's bytes, undecoded. `timeout` (at most the channel's) bounds this call.
    func send(_ payload: Data, timeout: Duration? = nil) async throws -> Data {
        try await invoke(timeout: timeout) { proxy, finish in
            guard let service = proxy as? MediaXPCProtocol else { return finish(.failure(MediaProcessingError.invalidResult)) }
            service.handle(payload) { data, error in
                if let data { finish(.success(data)) } else { finish(.failure(MediaProcessingError.undecodable(String((error ?? "no reply").prefix(512))))) }
            }
        }
    }

    /// One call on the remote object, bounded by the timeout and failing with the connection
    /// (XPCServiceError).
    func invoke<T: Sendable>(timeout: Duration? = nil, _ body: @escaping (AnyObject, @escaping @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let conn = current()
        let timeout = min(timeout ?? self.timeout, self.timeout)
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<T, Error>) in
            let once = OnceFlag()
            let watchdog = Mutex<Task<Void, Never>?>(nil)
            let finish: @Sendable (Result<T, Error>) -> Void = { r in
                if once.claim() {
                    watchdog.withLock { $0?.cancel() }
                    k.resume(with: r)
                }
            }
            watchdog.withLock { w in
                w = Task {
                    try? await Task.sleep(for: timeout)
                    finish(.failure(XPCServiceError.timedOut))
                }
            }
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                finish(.failure(XPCServiceError.lost(String(String(describing: error).prefix(512)))))
            }
            body(proxy as AnyObject, finish)
        }
    }
}

public final class MediaXPCClient: MediaProcessing {
    public static let serviceName = "org.signalsafe.SignalMediaDecoder"
    public static let voiceServiceName = "org.signalsafe.SignalVoiceNoteEncoder"
    let channel: XPCChannel
    /// Voice notes go to their own service (SignalVoiceNoteEncoder.xpc).
    let voice: XPCChannel

    /// The bundled service (only if it is signed as XPCPeer says), or (tests) any connection.
    public init(timeout: Duration = .seconds(30), peer: String? = XPCPeer.requirement(.decoder),
                voicePeer: String? = XPCPeer.requirement(.voice),
                makeConnection: @escaping @Sendable () -> NSXPCConnection = { NSXPCConnection(serviceName: MediaXPCClient.serviceName) },
                makeVoiceConnection: @escaping @Sendable () -> NSXPCConnection = { NSXPCConnection(serviceName: MediaXPCClient.voiceServiceName) }) {
        channel = XPCChannel(timeout: timeout, peer: peer, makeConnection: makeConnection)
        voice = XPCChannel(timeout: timeout, peer: voicePeer, makeConnection: makeVoiceConnection)
    }

    /// Inputs that hung or crashed the service (shared by every call on this client).
    public let quarantine = MediaQuarantine()
    let inFlight = InFlight()

    func call<T: Decodable & Sendable>(_ request: MediaRequest, _ type: T.Type) async throws -> T {
        try MediaXPCWire.decode(T.self, try await callData(request), maxBytes: request.maxReplyBytes)
    }

    /// The reply's bytes, undecoded. Refused at once for a quarantined input; the request's
    /// budget bounds the wait (Containment.swift).
    func callData(_ request: MediaRequest) async throws -> Data {
        if request.isVoiceNote { return try await voice.send(try MediaXPCWire.encode(request), timeout: request.budget) }
        let key = request.input.map(MediaQuarantine.key)
        if let key, quarantine.isQuarantined(key) { throw MediaProcessingError.undecodable("this file stopped the media service before") }
        let flight = key.map(inFlight.add)
        defer { flight.map(inFlight.remove) }
        do {
            return try await channel.send(try MediaXPCWire.encode(request), timeout: request.budget)
        } catch XPCServiceError.timedOut {
            if let key { quarantine.strike(key, MediaQuarantine.strikesToQuarantine) }
            throw XPCServiceError.timedOut
        } catch let XPCServiceError.lost(why) {
            for k in inFlight.all() { quarantine.strike(k) }
            throw XPCServiceError.lost(why)
        }
    }

    public func stickerImage(_ bytes: Data) async throws -> StickerImage { try await call(.stickerImage(bytes), StickerImage.self).validated() }
    public func displayImage(_ bytes: Data, maxDimension: Int) async throws -> DisplayImage {
        try await call(.displayImage(bytes, maxDimension: maxDimension), DisplayImage.self).validated(maxDimension: maxDimension)
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
    public func startVoiceNote(sampleRate: Int) async throws -> UUID { try await call(.startVoiceNote(sampleRate: sampleRate), UUID.self) }
    public func appendVoiceNote(_ session: UUID, samples: [Float]) async throws { _ = try await call(.appendVoiceNote(session, samples: samples), MediaEmpty.self) }
    public func finishVoiceNote(_ session: UUID) async throws -> VoiceNote { try await call(.finishVoiceNote(session), VoiceNote.self).validated() }
    public func cancelVoiceNote(_ session: UUID) async { _ = try? await call(.cancelVoiceNote(session), MediaEmpty.self) }
    public func videoInfo(_ bytes: Data) async throws -> VideoInfo { try await call(.videoInfo(bytes), VideoInfo.self).validated() }
    public func posterFrame(_ bytes: Data) async throws -> VideoPoster { try await call(.posterFrame(bytes), VideoPoster.self).validated() }
    public func openVideo(_ bytes: Data) async throws -> (session: UUID, info: VideoInfo) {
        let o = try await call(.openVideo(bytes), OpenedVideo.self)
        return (o.session, try o.info.validated())
    }
    public func videoFrames(_ session: UUID, count: Int) async throws -> [VideoFrame] {
        let frames = try MediaXPCWire.decodeFrames(try await callData(.videoFrames(session, count: count)), maxFrames: VideoLimits.maxFramesPerRequest)
        return try frames.map { try $0.validated() }
    }
    public func seekVideo(_ session: UUID, to seconds: Double) async throws { _ = try await call(.seekVideo(session, seconds: seconds), MediaEmpty.self) }
    public func closeVideo(_ session: UUID) async { _ = try? await call(.closeVideo(session), MediaEmpty.self) }
}

/// True for the first `claim()` only.
final class OnceFlag: Sendable {
    let flag = Mutex(false)
    func claim() -> Bool { flag.withLock { done in let first = !done; done = true; return first } }
}

final class WeakBox<T: AnyObject>: Sendable where T: Sendable {
    weak let value: T?
    init(_ value: T) { self.value = value }
}
