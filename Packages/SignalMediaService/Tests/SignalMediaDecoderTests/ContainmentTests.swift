// Resource containment (MediaXPCInterface/Containment.swift) and the app's side of a hostile
// or broken media service: bounded admission, cancellation at the budget, the watchdog,
// quarantine after a hang or crashes, and replies that break the limits.

import Foundation
@testable import MediaXPCInterface
import Synchronization
import Testing

/// A media service in process that does what `behaviour` says with each request.
final class FakeMediaService: NSObject, MediaXPCProtocol, NSXPCListenerDelegate, @unchecked Sendable {   // the listener is set up once, in init
    enum Behaviour: Sendable { case hang, crash, reply(Data) }
    let behaviour: Behaviour
    let requests = Atomic<Int>(0)
    let listener = NSXPCListener.anonymous()

    init(_ behaviour: Behaviour) {
        self.behaviour = behaviour
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func client(timeout: Duration) -> MediaXPCClient {
        let endpoint = listener.endpoint
        return MediaXPCClient(timeout: timeout, peer: nil) { NSXPCConnection(listenerEndpoint: endpoint) }
    }

    func handle(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        requests.add(1, ordering: .relaxed)
        switch behaviour {
        case .hang: break
        case .crash: NSXPCConnection.current()?.invalidate()
        case .reply(let data): reply(data, nil)
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = NSXPCInterface(with: MediaXPCProtocol.self)
        c.exportedObject = self
        c.resume()
        return true
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
        defer { service.listener.invalidate() }
        let client = service.client(timeout: .milliseconds(300))
        let bad = Data([1, 2, 3, 4])
        await #expect(throws: XPCServiceError.timedOut) { try await client.imageInfo(bad) }
        #expect(client.quarantine.isQuarantined(MediaQuarantine.key(bad)))
        #expect(!client.quarantine.isQuarantined(MediaQuarantine.key(Data([5]))))
        // Refused without asking the service again.
        let before = service.requests.load(ordering: .relaxed)
        await #expect(throws: MediaProcessingError.undecodable("this file stopped the media service before")) { try await client.thumbnail(bad, size: 150) }
        #expect(service.requests.load(ordering: .relaxed) == before)
    }

    @Test func twoCrashesQuarantine() async throws {
        let service = FakeMediaService(.crash)
        defer { service.listener.invalidate() }
        let client = service.client(timeout: .seconds(10))
        let bad = Data([9, 9, 9])
        let key = MediaQuarantine.key(bad)
        await #expect(throws: XPCServiceError.self) { try await client.imageInfo(bad) }
        #expect(!client.quarantine.isQuarantined(key))   // one strike: maybe it was another request
        await #expect(throws: XPCServiceError.self) { try await client.imageInfo(bad) }
        #expect(client.quarantine.isQuarantined(key))
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
            defer { service.listener.invalidate() }
            let client = service.client(timeout: .seconds(10))
            await #expect(throws: MediaProcessingError.invalidResult) {
                if call == "display" { _ = try await client.displayImage(png, maxDimension: 64) } else { _ = try await client.imageInfo(png) }
            }
        }
    }
}
