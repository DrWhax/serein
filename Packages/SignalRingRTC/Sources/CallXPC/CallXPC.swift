// ringrtc in SignalCalling.xpc, as the app sees it: the requests (in the wire format,
// MediaXPCInterface/Wire.swift) and `RemoteCallEndpoint`, the RingRTCEndpoint that sends them.
//
// The service runs WebRTC: it reads what remote peers send (RTP, ICE, call signalling) and
// holds the network and the microphone, but no keys, messages or files. The app treats its
// replies as hostile: every reply has a size limit, frames are checked against what was asked
// for, and RingRTC checks what the events ask the app to do (RingRTC.swift).
//
// Commands are synchronous (RingRTC's API is: a call id comes back from `createOutgoingCall`),
// each bounded by a timeout after which the session, and with it the service's endpoints, is
// ended. The service exits when its session ends, so a stuck or crashed service leaves no call
// state behind: the endpoint is lost, its generation moves on, the event wait reports it once,
// and the next command starts a fresh service and endpoint (replaying `setSelfUuid` and the
// assets). Video frames are fetched by a thread of their own and handed out from a cache, so the
// display link never waits on the service.

import Foundation
import MediaXPCInterface
import SignalRingRTC
import Synchronization

/// One request to the calling service.
public enum CallRequest: Codable, Sendable {
    /// A new endpoint with ringrtc's field-trial string; replies its id (UInt64).
    case create(fieldTrials: String)
    case destroy(endpoint: UInt64)
    /// A ringrtc command as JSON; replies the result's JSON.
    case command(endpoint: UInt64, json: Data)
    /// Waits up to `timeoutMs` for events; replies their JSON array.
    case waitEvents(endpoint: UInt64, timeoutMs: Int)
    /// A local video frame (camera or screen); replies Bool.
    case sendFrame(endpoint: UInt64, width: Int, height: Int, format: Int, data: Data)
    /// The newest remote frame of each wanted stream, where there is a new one; replies [ReceivedFrame].
    case receiveFrames(endpoint: UInt64, wants: [FrameWant])
}

public struct FrameWant: Codable, Sendable, Equatable {
    public var demuxId: UInt32
    public var maxWidth: Int
    public var maxHeight: Int
    public init(demuxId: UInt32, maxWidth: Int, maxHeight: Int) {
        self.demuxId = demuxId
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
    }
}

public struct ReceivedFrame: Codable, Sendable, Equatable {
    public var demuxId: UInt32
    public var width: Int
    public var height: Int
    public var rgba: Data
    public init(demuxId: UInt32, width: Int, height: Int, rgba: Data) {
        self.demuxId = demuxId
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    /// Fits what was asked for: `want`'s size in either orientation, exactly width×height RGBA.
    public func fits(_ want: FrameWant) -> Bool {
        let (fs, fl) = (min(width, height), max(width, height)), (ms, ml) = (min(want.maxWidth, want.maxHeight), max(want.maxWidth, want.maxHeight))
        return demuxId == want.demuxId && width >= 1 && height >= 1 && fs <= ms && fl <= ml && rgba.count == width * height * 4
    }
}

public enum CallXPCLimits {
    /// The largest frame sent (2880×1800 RGBA screen shares and more; NV12 camera frames are
    /// far smaller): a larger one is refused by the app before it is sent.
    public static let maxRequestBytes = 48 << 20
    public static let maxCommandReply = 4 << 20
    public static let maxEventsReply = 16 << 20
    /// Streams asked for at once, and the frames handed back in one reply.
    public static let maxWants = 32
    public static let maxFramesReply = 64 << 20
    public static let maxWaitMs = 1000
    /// The largest frame asked for (CallVideoConstants.maxFrame), in either orientation.
    public static let maxWantedSide = 4096
}

public enum CallServiceError: Error, Equatable, CustomStringConvertible {
    case unknownEndpoint
    case tooManyEndpoints
    case badRequest

    public var description: String {
        switch self {
        case .unknownEndpoint: "no such endpoint"
        case .tooManyEndpoints: "too many endpoints"
        case .badRequest: "bad request"
        }
    }
}

/// ringrtc's endpoint in the calling service.
public final class RemoteCallEndpoint: RingRTCEndpoint {
    public static let serviceName = "org.signalsafe.SignalCalling"

    let channel: XPCChannel
    let fieldTrials: String

    struct Frame {
        var seq: UInt64
        var generation: UInt64
        var width: Int, height: Int
        var rgba: Data
    }
    struct Want {
        var want: FrameWant
        var asked: ContinuousClock.Instant
    }
    struct State {
        /// The service's endpoint, while it lives.
        var id: UInt64?
        var generation: UInt64 = 0
        /// The last generation whose loss the event wait reported.
        var reported: UInt64 = 0
        /// `setSelfUuid` and `addAsset`, replayed on a new endpoint (by command and asset group).
        var config: [(key: String, name: String, fields: [String: JSONValue])] = []
        var closed = false
        var wants: [UInt32: Want] = [:]
        var frames: [UInt32: Frame] = [:]
        var handedOut: [UInt32: UInt64] = [:]
        var seq: UInt64 = 0
        var fetching = false
        var framesInFlight = 0
    }
    let state = Mutex(State())
    let frameQueue = DispatchQueue(label: "signalsafe.calling.frames-out")

    static let createTimeout: Duration = .seconds(20)
    static let commandTimeout: Duration = .seconds(10)
    static let frameTimeout: Duration = .seconds(3)
    static let configCommands: Set<String> = ["setSelfUuid", "addAsset"]
    /// A stream not asked for this long is no longer fetched.
    static let wantLifetime: Duration = .seconds(1)

    /// An endpoint in the bundled service (or, in tests, a listener's).
    public init(fieldTrials: String, channel: XPCChannel) throws {
        self.channel = channel
        self.fieldTrials = fieldTrials
        let id = try create()
        state.withLock { $0.id = id }
    }

    /// RingRTC on the bundled calling service, signed as XPCPeer says (`timeout` bounds each
    /// session's requests; the service's own limits are in CallXPCLimits).
    public static func factory(_ target: XPCTarget = .service(serviceName), peer: XPCPeerRequirement? = XPCPeer.requirement(.calling)) -> RingRTCEndpointFactory {
        let channel = XPCChannel(target, peer: peer, timeout: createTimeout)
        return { trials in try RemoteCallEndpoint(fieldTrials: trials, channel: channel) }
    }

    deinit { close() }

    func call<T: Decodable>(_ request: CallRequest, _ type: T.Type, timeout: Duration, maxReply: Int) throws -> T {
        let reply = try channel.sendSync(try Wire.encode(request), timeout: timeout, maxReply: maxReply)
        return try Wire.decode(T.self, reply, maxBytes: maxReply)
    }

    func create() throws -> UInt64 {
        do { return try call(.create(fieldTrials: fieldTrials), UInt64.self, timeout: Self.createTimeout, maxReply: 64) } catch {
            throw RingRTCError.noEndpoint
        }
    }

    /// Endpoint `id` is gone, or answered as no endpoint should: the generation moves on
    /// (once), and the session ends, so the service exits with everything it ran (a call left
    /// running there would keep the microphone and the network).
    func lost(_ id: UInt64) {
        let current = state.withLock { s -> Bool in
            guard s.id == id else { return false }
            s.id = nil
            s.generation += 1
            s.frames = [:]
            return true
        }
        if current { channel.reset() }
    }

    static func isLoss(_ error: any Error) -> Bool {
        if let e = error as? XPCServiceError { return e == .timedOut || { if case .lost = e { true } else { false } }() }
        return false
    }

    public var generation: UInt64 { state.withLock { $0.generation } }

    /// The live endpoint, or a new one with the configuration replayed. Nil after `close`.
    func live() throws -> UInt64 {
        if let id = state.withLock({ $0.closed ? nil : $0.id }) { return id }
        guard !state.withLock({ $0.closed }) else { throw RingRTCError.lost }
        let id = try create()
        let config = state.withLock { $0.config }
        for c in config { _ = try? run(id, c.name, c.fields) }
        let winner = state.withLock { s -> UInt64? in
            if let other = s.id { return other }
            s.id = id
            return nil
        }
        if let winner {
            _ = try? call(.destroy(endpoint: id), Bool.self, timeout: Self.commandTimeout, maxReply: 64)
            return winner
        }
        return id
    }

    func run(_ id: UInt64, _ name: String, _ fields: [String: JSONValue]) throws -> JSONValue {
        let json = Data(try JSONValue.command(name, fields))
        let reply: Data
        do { reply = try call(.command(endpoint: id, json: json), Data.self, timeout: Self.commandTimeout, maxReply: CallXPCLimits.maxCommandReply) } catch {
            if Self.isLoss(error) {
                lost(id)
                throw RingRTCError.lost
            }
            throw RingRTCError.native(String(describing: error))
        }
        do { return try JSONDecoder().decode(JSONValue.self, from: reply) } catch { throw RingRTCError.invalidResponse }
    }

    public func command(_ name: String, _ fields: [String: JSONValue], generation: UInt64?) throws -> JSONValue {
        if let generation, generation != self.generation { throw RingRTCError.lost }
        // Recorded first, so that an endpoint made after this command fails still gets it.
        if Self.configCommands.contains(name) {
            let key = name + (fields["assetGroup"]?.string ?? "")
            state.withLock { s in
                s.config.removeAll { $0.key == key }
                s.config.append((key, name, fields))
            }
        }
        let id = try live()
        return try run(id, name, fields)
    }

    public func waitEvents(timeoutMs: UInt32) -> EndpointEvents {
        let (id, report) = state.withLock { s -> (UInt64?, UInt64?) in
            if s.reported < s.generation {
                s.reported = s.generation
                return (nil, s.generation - 1)
            }
            return (s.closed ? nil : s.id, nil)
        }
        if let report { return .lost(generation: report) }
        guard let id else {
            Thread.sleep(forTimeInterval: Double(timeoutMs) / 1000)
            return .events([])
        }
        let wait = min(Int(timeoutMs), CallXPCLimits.maxWaitMs)
        do {
            let bytes = try call(.waitEvents(endpoint: id, timeoutMs: wait), Data.self, timeout: Self.commandTimeout + .milliseconds(wait),
                                 maxReply: CallXPCLimits.maxEventsReply)
            return .events((try? JSONDecoder().decode([JSONValue].self, from: bytes)) ?? [])
        } catch {
            // A lost session or an endpoint the service no longer has: either way it is gone.
            lost(id)
            return .events([])
        }
    }

    @discardableResult
    public func sendVideoFrame(width: Int, height: Int, format: VideoPixelFormat, data: [UInt8], generation: UInt64?) -> Bool {
        guard format.frameSize(width: width, height: height) == data.count, data.count + 4096 <= CallXPCLimits.maxRequestBytes else { return false }
        // At most two frames on their way; later ones are dropped (as the camera drops late frames).
        let id = state.withLock { s -> UInt64? in
            guard !s.closed, let id = s.id, generation == nil || generation == s.generation, s.framesInFlight < 2 else { return nil }
            s.framesInFlight += 1
            return id
        }
        guard let id else { return false }
        let request = CallRequest.sendFrame(endpoint: id, width: width, height: height, format: Int(format.rawValue), data: Data(data))
        frameQueue.async { [self] in
            do { _ = try call(request, Bool.self, timeout: Self.frameTimeout, maxReply: 64) } catch {
                if Self.isLoss(error) { lost(id) }
            }
            state.withLock { $0.framesInFlight -= 1 }
        }
        return true
    }

    public func receiveVideoFrame(demuxId: UInt32, maxWidth: Int, maxHeight: Int, into buffer: inout [UInt8], generation: UInt64?)
        -> (width: Int, height: Int)?
    {
        let want = FrameWant(demuxId: demuxId, maxWidth: min(max(1, maxWidth), CallXPCLimits.maxWantedSide),
                             maxHeight: min(max(1, maxHeight), CallXPCLimits.maxWantedSide))
        let (frame, startFetching) = state.withLock { s -> (Frame?, Bool) in
            guard !s.closed, generation == nil || generation == s.generation else { return (nil, false) }
            if s.wants[demuxId] != nil || s.wants.count < CallXPCLimits.maxWants { s.wants[demuxId] = Want(want: want, asked: .now) }
            let start = !s.fetching
            s.fetching = true
            guard let f = s.frames[demuxId], f.seq > s.handedOut[demuxId] ?? 0, f.generation == s.generation,
                  ReceivedFrame(demuxId: demuxId, width: f.width, height: f.height, rgba: f.rgba).fits(want), f.rgba.count <= buffer.count else { return (nil, start) }
            s.handedOut[demuxId] = f.seq
            return (f, start)
        }
        if startFetching { startFetcher() }
        guard let frame else { return nil }
        buffer.replaceSubrange(0..<frame.rgba.count, with: frame.rgba)
        return (frame.width, frame.height)
    }

    /// Fetches the wanted streams' frames until none is wanted any more.
    func startFetcher() {
        let thread = Thread { [weak self] in
            while let self, self.fetchOnce() {}
        }
        thread.name = "signalsafe.calling.frames-in"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// One round; false when nothing is wanted (the fetcher stops).
    func fetchOnce() -> Bool {
        let now = ContinuousClock.now
        let (id, wants) = state.withLock { s -> (UInt64?, [FrameWant]?) in
            s.wants = s.wants.filter { now - $0.value.asked < Self.wantLifetime }
            guard !s.closed, !s.wants.isEmpty else {
                s.fetching = false
                return (nil, nil)
            }
            return (s.id, s.wants.values.map(\.want))
        }
        guard let wants else { return false }
        guard let id else {
            Thread.sleep(forTimeInterval: 0.05)
            return true
        }
        do {
            let frames = try call(.receiveFrames(endpoint: id, wants: wants), [ReceivedFrame].self, timeout: Self.frameTimeout,
                                  maxReply: CallXPCLimits.maxFramesReply)
            let byDemux = Dictionary(wants.map { ($0.demuxId, $0) }, uniquingKeysWith: { a, _ in a })
            state.withLock { s in
                guard s.id == id else { return }
                for f in frames {
                    guard let want = byDemux[f.demuxId], f.fits(want) else { continue }
                    s.seq += 1
                    s.frames[f.demuxId] = Frame(seq: s.seq, generation: s.generation, width: f.width, height: f.height, rgba: f.rgba)
                }
            }
            Thread.sleep(forTimeInterval: frames.isEmpty ? 0.012 : 0.004)
        } catch {
            if Self.isLoss(error) { lost(id) } else { Thread.sleep(forTimeInterval: 0.05) }
        }
        return true
    }

    public func close() {
        let id = state.withLock { s -> UInt64? in
            defer {
                s.closed = true
                s.id = nil
            }
            return s.closed ? nil : s.id
        }
        guard let id else { return }
        let request = CallRequest.destroy(endpoint: id)
        frameQueue.async { [channel] in _ = try? channel.sendSync(try Wire.encode(request), timeout: Self.commandTimeout, maxReply: 64) }
    }
}
