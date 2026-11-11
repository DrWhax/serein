// Resource containment (MediaXPCInterface/Containment.swift) and the app's side of a hostile
// or broken media service: bounded admission, cancellation at the budget, the watchdog,
// quarantine after a hang or crashes, and replies that break the limits.

import Foundation
@testable import MediaXPCInterface
import Synchronization
import Testing
import XPC

/// A media service in process that does what `behaviour` says with each request (on raw XPC,
/// so it can hang, or end its session as a crash would).
final class FakeMediaService: Sendable {
    enum Behaviour: Sendable { case hang, crash, crashOnce(then: Data), reply(Data) }
    final class Counter: Sendable {
        let value = Atomic<Int>(0)
        /// Requests held unanswered, as a hung service holds them (one dropped unanswered fails
        /// the client at once).
        let held = Mutex<[XPCServer.Received]>([])
    }
    let requests: Counter
    let listener: XPCListener

    struct Peer: XPCPeerHandler {
        let behaviour: Behaviour
        weak let session: XPCSession?
        let requests: Counter

        func handleIncomingRequest(_ message: XPCDictionary) -> XPCDictionary? {
            let n = requests.value.add(1, ordering: .relaxed).newValue
            switch behaviour {
            case .hang: requests.held.withLock { $0.append(XPCServer.Received(message: message)) }
            case .crash: session?.cancel(reason: "crashed")
            case .crashOnce(let data):
                if n == 1 { session?.cancel(reason: "crashed") } else { message.reply(XPCMessage(payload: data).dictionary) }
            case .reply(let data): message.reply(XPCMessage(payload: data).dictionary)
            }
            return nil
        }
    }

    init(_ behaviour: Behaviour) {
        let requests = Counter()
        self.requests = requests
        listener = XPCListener { $0.accept { session in Peer(behaviour: behaviour, session: session, requests: requests) } }
    }

    deinit { listener.cancel() }

    var requestCount: Int { requests.value.load(ordering: .relaxed) }

    func client(timeout: Duration) -> MediaXPCClient {
        MediaXPCClient(timeout: timeout, decoder: .endpoint(listener.endpoint), peer: nil)
    }
}

@Suite struct ContainmentTests {
    @Test func gateAdmitsQueuesAndRefuses() async throws {
        let gate = RequestGate(maxRunning: 2, maxWaiting: 1, watchdog: ServiceWatchdog(onExpiry: {}))
        let started = Atomic<Int>(0)
        let results = await withTaskGroup(of: String.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    do {
                        return try await gate.run(budget: .seconds(10)) {
                            started.add(1, ordering: .relaxed)
                            try await Task.sleep(for: .milliseconds(300))
                            return "ran"
                        }
                    } catch { return "\(error)" }
                }
            }
            var out: [String] = []
            for await r in group { out.append(r) }
            return out.sorted()
        }
        #expect(results == ["ran", "ran", "ran", "service busy"])
        #expect(started.load(ordering: .relaxed) == 3)
    }

    @Test func gateCancelsAtTheBudget() async throws {
        let gate = RequestGate(maxRunning: 1, maxWaiting: 0, watchdog: ServiceWatchdog(onExpiry: {}))
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: XPCServiceError.timedOut) {
            try await gate.run(budget: .milliseconds(100)) { try await Task.sleep(for: .seconds(30)); return 1 }
        }
        #expect(clock.now - start < .seconds(5))
        // The slot is free again.
        #expect(try await gate.run(budget: .seconds(1)) { 2 } == 2)
    }

    @Test func watchdogFiresOnlyPastTheDeadline() async throws {
        let fired = Atomic<Int>(0)
        let watchdog = ServiceWatchdog(interval: .milliseconds(20)) { fired.add(1, ordering: .relaxed) }
        let quick = watchdog.begin(.seconds(10))
        try await Task.sleep(for: .milliseconds(100))
        watchdog.end(quick)
        #expect(fired.load(ordering: .relaxed) == 0)
        _ = watchdog.begin(.milliseconds(30))   // never ended: stuck work
        try await Task.sleep(for: .milliseconds(200))
        #expect(fired.load(ordering: .relaxed) > 0)
    }

    @Test func aHangQuarantinesItsInput() async throws {
        let service = FakeMediaService(.hang)
        let client = service.client(timeout: .milliseconds(300))
        let bad = Data([1, 2, 3, 4])
        await #expect(throws: XPCServiceError.timedOut) { try await client.imageInfo(bad) }
        #expect(client.quarantine.isQuarantined(MediaQuarantine.key(bad)))
        #expect(!client.quarantine.isQuarantined(MediaQuarantine.key(Data([5]))))
        // Refused without asking the service again.
        let before = service.requestCount
        await #expect(throws: MediaProcessingError.undecodable("this file stopped the media service before")) { try await client.thumbnail(bad, size: 150) }
        #expect(service.requestCount == before)
    }

    @Test func twoCrashesQuarantine() async throws {
        let service = FakeMediaService(.crash)
        let client = service.client(timeout: .seconds(10))
        let bad = Data([9, 9, 9])
        let key = MediaQuarantine.key(bad)
        await #expect(throws: XPCServiceError.self) { try await client.imageInfo(bad) }
        #expect(!client.quarantine.isQuarantined(key))   // one strike: maybe it was another request
        await #expect(throws: XPCServiceError.self) { try await client.imageInfo(bad) }
        #expect(client.quarantine.isQuarantined(key))
    }

    /// A crash ends the session; the next request opens a new one and is served.
    @Test func theSessionIsReopenedAfterACrash() async throws {
        let info = ImageInfo(width: 2, height: 3, blurHash: String(repeating: "0", count: 28), isAnimated: false)
        let service = FakeMediaService(.crashOnce(then: try Wire.encode(info)))
        let client = service.client(timeout: .seconds(10))
        await #expect(throws: XPCServiceError.self) { try await client.imageInfo(Data([1])) }
        #expect(try await client.imageInfo(Data([2])) == info)
        #expect(service.requestCount == 2)
    }

    @Test func quarantineIsBounded() {
        let q = MediaQuarantine(capacity: 2)
        let a = MediaQuarantine.key(Data([1])), b = MediaQuarantine.key(Data([2])), c = MediaQuarantine.key(Data([3]))
        q.strike(a, 2)
        q.strike(b, 2)
        q.strike(c, 2)
        #expect(!q.isQuarantined(a) && q.isQuarantined(b) && q.isQuarantined(c))
    }

    /// A compromised decoder: a reply larger than the request allows, of the wrong type, or
    /// out of bounds, is refused.
    @Test func hostileRepliesAreRefused() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let huge = DisplayImage(width: 4000, height: 4000, rgba: Data(count: 4000 * 4000 * 4), originalWidth: 4000, originalHeight: 4000)
        let wrongType = try Wire.encode(PaginatedGifResults(next: nil, gifs: []))
        let outOfBounds = try Wire.encode(ImageInfo(width: 0, height: 99_999, blurHash: "", isAnimated: false))
        for (reply, call) in [(try Wire.encode(huge), "display"), (wrongType, "info"), (outOfBounds, "info")] {
            let service = FakeMediaService(.reply(reply))
                let client = service.client(timeout: .seconds(10))
            await #expect(throws: MediaProcessingError.invalidResult) {
                if call == "display" { _ = try await client.displayImage(png, maxDimension: 64) } else { _ = try await client.imageInfo(png) }
            }
        }
    }
}
