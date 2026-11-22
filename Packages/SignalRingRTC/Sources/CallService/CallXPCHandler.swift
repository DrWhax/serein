// SignalCalling.xpc's work: calling endpoints, run for the app (CallXPC.swift has the
// requests). Only the app may connect (XPCPeer), and the service ends with that session, so
// no call outlives the app's connection and a reconnecting app always starts clean.
//
// ringrtc's calls block (an event wait for up to its timeout), so each kind of request runs on
// a dispatch queue of its own, never on Swift's cooperative threads: commands in order on one,
// event waits on another, frames out and frames in on one each.

import CallXPC
import Foundation
import MediaXPCInterface
import SignalRingRTC
import Synchronization

public final class CallXPCHandler: XPCMessageHandler {
    private struct Session {
        var generation: UInt64 = 0
        var endpoints: [UInt64: any LocalCallEndpoint] = [:]
    }
    private let session = Mutex(Session())
    var endpointCount: Int { session.withLock { $0.endpoints.count } }
    let makeEndpoint: LocalCallEndpointFactory
    let next = Atomic<UInt64>(1)
    let onSessionEnd: @Sendable () -> Void
    let commands = DispatchQueue(label: "signalsafe.calling.commands")
    let events = DispatchQueue(label: "signalsafe.calling.events", attributes: .concurrent)
    let framesOut = DispatchQueue(label: "signalsafe.calling.frames-out")
    let framesIn = DispatchQueue(label: "signalsafe.calling.frames-in")
    /// Endpoints at once (RingRTC uses one; `setConfig` briefly two).
    static let maxEndpoints = 4

    /// `onSessionEnd`: what happens once the app's session ends (the service exits; tests
    /// only drop the endpoints).
    public init(makeEndpoint: @escaping LocalCallEndpointFactory,
                onSessionEnd: @escaping @Sendable () -> Void = {}) {
        self.makeEndpoint = makeEndpoint
        self.onSessionEnd = onSessionEnd
    }

    public var maxRequestBytes: Int { CallXPCLimits.maxRequestBytes }

    public func sessionEnded() {
        let endpoints = session.withLock {
            $0.generation += 1
            let endpoints = $0.endpoints
            $0.endpoints = [:]
            return endpoints
        }
        for endpoint in endpoints.values { endpoint.close() }
        onSessionEnd()
    }

    func endpoint(_ id: UInt64) throws -> any LocalCallEndpoint {
        guard let e = session.withLock({ $0.endpoints[id] }) else { throw CallServiceError.unknownEndpoint }
        return e
    }

    func on<T: Sendable>(_ queue: DispatchQueue, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { k in queue.async { k.resume(with: Result { try work() }) } }
    }

    public func reply(to request: XPCMessage) async throws -> XPCMessage {
        let r = try Wire.decode(CallRequest.self, try request.requirePayload(), maxBytes: maxRequestBytes)
        return XPCMessage(payload: try await run(r))
    }

    func run(_ request: CallRequest) async throws -> Data {
        switch request {
        case .create(let trials), .createSwiftVoice(let trials):
            let generation = session.withLock { $0.generation }
            return try await on(commands) { [self] in
                try session.withLock {
                    guard $0.generation == generation else { throw CallServiceError.unknownEndpoint }
                    guard $0.endpoints.count < Self.maxEndpoints else { throw CallServiceError.tooManyEndpoints }
                }
                let made = try makeEndpoint(trials)
                let id = next.add(1, ordering: .relaxed).oldValue
                let registered = session.withLock {
                    guard $0.generation == generation else { return false }
                    $0.endpoints[id] = made
                    return true
                }
                guard registered else { made.close(); throw CallServiceError.unknownEndpoint }
                return try Wire.encode(id)
            }
        case .destroy(let id):
            let gone = session.withLock { $0.endpoints.removeValue(forKey: id) }
            // A blocked event wait can still own this endpoint. Stop its devices explicitly.
            gone?.close()
            commands.async { withExtendedLifetime(gone) {} }
            return try Wire.encode(gone != nil)
        case .command(let id, let json):
            let e = try endpoint(id)
            let out = try await on(commands) { try e.commandJSON([UInt8](json)) }
            guard out.count <= CallXPCLimits.maxCommandReply else { throw CallServiceError.badRequest }
            return try Wire.encode(Data(out))
        case .waitEvents(let id, let ms):
            guard (0...CallXPCLimits.maxWaitMs).contains(ms) else { throw CallServiceError.badRequest }
            let e = try endpoint(id)
            let out = try await on(events) { e.waitEventsJSON(timeoutMs: UInt32(ms)) }
            guard e.isLive, out.count <= CallXPCLimits.maxEventsReply - 64 else {
                e.close()
                throw CallServiceError.unknownEndpoint
            }
            return try Wire.encode(Data(out))
        case .sendFrame(let id, let width, let height, let format, let data):
            let e = try endpoint(id)
            guard let f = Int32(exactly: format).flatMap(VideoPixelFormat.init(rawValue:)) else { throw CallServiceError.badRequest }
            let ok = try await on(framesOut) { e.sendVideoFrame(width: width, height: height, format: f, data: [UInt8](data), generation: nil) }
            return try Wire.encode(ok)
        case .receiveFrames(let id, let wants):
            guard wants.count <= CallXPCLimits.maxWants,
                  wants.allSatisfy({ (1...CallXPCLimits.maxWantedSide).contains($0.maxWidth) && (1...CallXPCLimits.maxWantedSide).contains($0.maxHeight) })
            else { throw CallServiceError.badRequest }
            let e = try endpoint(id)
            let frames = try await on(framesIn) { Self.frames(e, wants) }
            return try Wire.encode(frames)
        }
    }

    /// The new frame of each wanted stream, while the reply stays within its limit (the rest
    /// come on the next request).
    static func frames(_ e: any LocalCallEndpoint, _ wants: [FrameWant]) -> [ReceivedFrame] {
        var out: [ReceivedFrame] = [], total = 0
        for w in wants {
            let size = w.maxWidth * w.maxHeight * 4
            guard total + size + 64 <= CallXPCLimits.maxFramesReply else { break }
            var buffer = [UInt8](repeating: 0, count: size)
            guard let f = e.receiveVideoFrame(demuxId: w.demuxId, maxWidth: w.maxWidth, maxHeight: w.maxHeight, into: &buffer, generation: nil) else { continue }
            guard min(f.width, f.height) > 0, min(f.width, f.height) <= min(w.maxWidth, w.maxHeight),
                  max(f.width, f.height) <= max(w.maxWidth, w.maxHeight) else { continue }
            let n = f.width * f.height * 4
            guard n <= buffer.count else { continue }
            out.append(ReceivedFrame(demuxId: w.demuxId, width: f.width, height: f.height, rgba: Data(buffer[0..<n])))
            total += n + 64
        }
        return out
    }
}
