// Resource containment around the XPC services. A request on hostile input can hang or crash
// its service. Timing out on the client alone would leave the service burning a core, and
// retrying would hand it the same input again. So:
//
//   * every request has a budget (`MediaRequest.budget`); the client gives up at the budget;
//   * the service cancels a request at its budget (network work stops there) and runs each
//     under a watchdog on its own thread (not a Swift task, which hostile work can starve)
//     that exits the process when one runs past budget + grace, so work that ignores
//     cancellation dies with it; launchd starts a fresh process for the next message;
//   * the service runs a bounded number of requests at once and queues a bounded number
//     more; beyond that it answers "busy" at once instead of piling up work;
//   * the client quarantines inputs that hung or took the service down (`MediaQuarantine`):
//     a timeout quarantines at once; a lost connection counts one strike against each input in
//     flight on it (a crash cannot be pinned on one request: each of them fails once, and
//     strikes its own input), and two strikes quarantine. Verification/Broker proves the count.

import CryptoKit
import Foundation
import Synchronization

/// How a call to a service failed, as opposed to the service answering with an error.
public enum XPCServiceError: Error, Equatable, CustomStringConvertible {
    /// No reply within the budget.
    case timedOut
    /// The connection broke (the service crashed or exited) or could not be made.
    case lost(String)
    /// The service is at its request limit.
    case busy

    public var description: String {
        switch self {
        case .timedOut: return "service timed out"
        case .lost(let why): return "service: \(why)"
        case .busy: return "service busy"
        }
    }
}

// MARK: - Service side

/// Exits the process when a request runs past its deadline. Checks from a dedicated thread.
public final class ServiceWatchdog: Sendable {
    let running = Mutex<[UInt64: ContinuousClock.Instant]>([:])
    let next = Atomic<UInt64>(0)
    let onExpiry: @Sendable () -> Void

    /// `onExpiry` (tests) replaces exiting.
    public init(interval: Duration = .milliseconds(250), onExpiry: (@Sendable () -> Void)? = nil) {
        self.onExpiry = onExpiry ?? {
            FileHandle.standardError.write(Data("watchdog: a request ran past its budget, exiting\n".utf8))
            exit(70)   // EX_SOFTWARE
        }
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        Thread.detachNewThread { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: seconds)
                guard let watchdog = self else { return }
                watchdog.check()
            }
        }
    }

    func check() {
        let now = ContinuousClock.now
        if running.withLock({ $0.values.contains { $0 < now } }) { onExpiry() }
    }

    public func begin(_ budget: Duration) -> UInt64 {
        let id = next.add(1, ordering: .relaxed).newValue
        let deadline = ContinuousClock.now.advanced(by: budget)
        running.withLock { $0[id] = deadline }
        return id
    }

    public func end(_ id: UInt64) { _ = running.withLock { $0.removeValue(forKey: id) } }
}

/// At most `maxRunning` requests at once and `maxWaiting` more queued (first come, first
/// served); any more are refused with `XPCServiceError.busy`. Running requests are watched.
public final class RequestGate: Sendable {
    struct State {
        var running = 0
        var waiting: [CheckedContinuation<Void, Never>] = []
    }
    let state = Mutex(State())
    public let maxRunning: Int
    public let maxWaiting: Int
    let watchdog: ServiceWatchdog
    /// The client gives up at the budget; the service cancels the request `slack` later and
    /// gives up on itself `grace` later, so that the client (which knows which request it was,
    /// and quarantines its input) always times out first.
    public static let slack: Duration = .seconds(1)
    public static let grace: Duration = .seconds(5)

    public init(maxRunning: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 1), maxWaiting: Int = 64,
                watchdog: ServiceWatchdog = ServiceWatchdog()) {
        self.maxRunning = maxRunning
        self.maxWaiting = maxWaiting
        self.watchdog = watchdog
    }

    func acquire() async throws {
        enum Admission { case run, wait, refuse }
        let admission = state.withLock { s -> Admission in
            if s.running < maxRunning { s.running += 1; return .run }
            return s.waiting.count < maxWaiting ? .wait : .refuse
        }
        switch admission {
        case .run: return
        case .refuse: throw XPCServiceError.busy
        case .wait:
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                let admitted = state.withLock { s -> Bool in
                    // A slot may have opened since the first look.
                    if s.running < maxRunning { s.running += 1; return true }
                    s.waiting.append(k)
                    return false
                }
                if admitted { k.resume() }
            }
        }
    }

    func release() {
        let next = state.withLock { s -> CheckedContinuation<Void, Never>? in
            if s.waiting.isEmpty { s.running -= 1; return nil }
            return s.waiting.removeFirst()   // its slot is handed over: `running` stays
        }
        next?.resume()
    }

    /// Runs `body` once admitted. At `budget + slack` it is cancelled and the call fails with
    /// `timedOut` (network work stops there); work that ignores cancellation (a decoder stuck in
    /// a loop) is ended with the process by the watchdog at `budget + grace`.
    public func run<T: Sendable>(budget: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        let id = watchdog.begin(budget + Self.grace)
        defer { watchdog.end(id) }
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: budget + Self.slack)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let result = first else { throw XPCServiceError.timedOut }
            return result
        }
    }
}

// MARK: - Client side

/// Inputs that hung a service or were in flight when it died. In memory, at most `capacity`
/// entries (the oldest forgotten first).
public final class MediaQuarantine: Sendable {
    struct State {
        var strikes: [SHA256Digest: Int] = [:]
        var order: [SHA256Digest] = []
        /// The ended sessions each input was struck for (one strike per session).
        var lostOn: [SHA256Digest: Set<UInt64>] = [:]

        mutating func add(_ key: SHA256Digest, _ count: Int, capacity: Int) {
            if strikes[key] == nil {
                order.append(key)
                if order.count > capacity {
                    let oldest = order.removeFirst()
                    strikes[oldest] = nil
                    lostOn[oldest] = nil
                }
            }
            strikes[key, default: 0] += count
        }
    }
    let state = Mutex(State())
    public let capacity: Int
    public static let strikesToQuarantine = 2

    public init(capacity: Int = 512) { self.capacity = capacity }

    public static func key(_ input: Data) -> SHA256Digest { SHA256.hash(data: input) }

    public func isQuarantined(_ key: SHA256Digest) -> Bool {
        state.withLock { ($0.strikes[key] ?? 0) >= Self.strikesToQuarantine }
    }

    public func strike(_ key: SHA256Digest, _ count: Int = 1) {
        state.withLock { $0.add(key, count, capacity: capacity) }
    }

    /// One strike for `key` because session `session` ended while it was in flight: only the
    /// first time for that session.
    func strike(_ key: SHA256Digest, lostSession session: UInt64) {
        state.withLock { s in
            guard s.lostOn[key, default: []].insert(session).inserted else { return }
            s.add(key, 1, capacity: capacity)
        }
    }
}

extension MediaRequest {
    /// The untrusted bytes this request hands the decoder, if any (what quarantine is keyed by).
    public var input: Data? {
        switch self {
        case .stickerImage(let b), .displayImage(let b, _), .displayAnimation(let b, _), .imageInfo(let b), .thumbnail(let b, _), .scaleForSending(let b, _, _),
             .stripMetadata(let b, _), .convertHEIC(let b), .audioSummary(let b), .decodeAudio(let b, _, _), .videoInfo(let b),
             .posterFrame(let b), .openVideo(let b): return b
        case .startVoiceNote, .appendVoiceNote, .finishVoiceNote, .cancelVoiceNote, .recordVoiceNote, .voiceNoteProgress, .videoFrames, .seekVideo,
             .closeVideo: return nil
        }
    }

    /// How long the request may take: a few times what the largest legitimate input needs.
    public var budget: Duration {
        switch self {
        case .imageInfo, .videoInfo, .openVideo, .startVoiceNote, .appendVoiceNote, .cancelVoiceNote, .voiceNoteProgress, .seekVideo, .closeVideo:
            return .seconds(10)
        // The first time, macOS asks the user for the microphone.
        case .recordVoiceNote:
            return .seconds(120)
        case .displayImage, .thumbnail, .stickerImage, .stripMetadata, .posterFrame, .videoFrames, .decodeAudio:
            return .seconds(15)
        case .scaleForSending, .convertHEIC, .audioSummary, .finishVoiceNote, .displayAnimation:
            return .seconds(30)
        }
    }
}
