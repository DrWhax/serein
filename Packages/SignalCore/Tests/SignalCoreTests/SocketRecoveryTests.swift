// Sending after a chat connection drops (sleep, a network change, the server closing it):
// the next send reconnects instead of failing until the app restarts.

import Foundation
import Synchronization
import Testing
import LibSignalClient
@testable import SignalCore

@Suite(.serialized) struct SocketRecoveryTests {
    @Test func sealedSendAfterTheUnauthenticatedSocketDrops() async throws {
        try await LinkedClient.with { c in
            let alice = c.aliceAci
            _ = try await c.send(["body": "hi"])   // alice writes first: her profile key, so ours go sealed
            _ = try await c.messenger.sendMessage("one", attachments: [], quoting: nil, to: alice)
            #expect(try await c.server.json("waitForMessage", ["account": "alice"])["body"] as? String == "one")
            #expect(await c.socket.unauthenticated != nil, "the send went sealed, over the unauthenticated socket")

            // The socket drops.
            try? await c.socket.unauthenticated?.disconnect()

            _ = try await c.messenger.sendMessage("two", attachments: [], quoting: nil, to: alice)
            #expect(try await c.server.json("waitForMessage", ["account": "alice"])["body"] as? String == "two")
        }
    }
}

/// A listener for a socket that never connects.
final class SilentChatListener: ChatConnectionListener, Sendable {
    func chatConnection(_ chat: AuthenticatedChatConnection, didReceiveIncomingMessage envelope: Data, serverDeliveryTimestamp: UInt64,
                        sendAck: sending @escaping () throws -> Void) {}
    func chatConnectionDidReceiveQueueEmpty(_ chat: AuthenticatedChatConnection) {}
    func chatConnection(_ chat: AuthenticatedChatConnection, didReceiveAlerts alerts: [String]) {}
    func connectionWasInterrupted(_ service: AuthenticatedChatConnection, error: Error?) {}
}

@Suite struct SocketReconnectTests {
    /// A first connection that fails (offline at launch) leaves the manager retrying.
    @Test func aFailedFirstConnectKeepsReconnecting() async throws {
        let manager = SocketManager(net: Net(env: .staging, userAgent: "test", buildVariant: .production))   // no credentials: fails at once
        let listener = SilentChatListener()
        await #expect(throws: (any Error).self) { try await manager.connect(listener: listener) }
        #expect(await manager.reconnectTask != nil)
        await manager.disconnect()
        #expect(await manager.reconnectTask == nil)
    }
}

@Suite struct JobQueueCancellationTests {
    /// A handler's own cancellation error (the queue still running) is retried with backoff, and
    /// later jobs still run; before, the job re-ran at once, forever.
    @Test func aStrayCancellationErrorIsAnOrdinaryFailure() async throws {
        let (database, _) = try LinkedClient.temporaryDatabase()
        let queue = JobQueue(database: database, policy: RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(200), maxDelay: .seconds(1)))
        let calls = Mutex<[String]>([])
        await queue.register("t") { job in
            let payload = try job.decode(String.self)
            let n = calls.withLock { $0.append(payload); return $0.filter { $0 == payload }.count }
            if payload == "first" && n == 1 { throw CancellationError() }
        }
        _ = try await queue.enqueue(queueType: "t", payload: "first")
        _ = try await queue.enqueue(queueType: "t", payload: "second")
        let start = ContinuousClock.now
        await queue.start()
        var succeeded: [String] = []
        for await e in queue.events {
            if case .succeeded(let j) = e { succeeded.append(try j.decode(String.self)) }
            if succeeded.count == 2 { break }
        }
        #expect(Set(succeeded) == ["first", "second"])
        #expect(calls.withLock { $0.filter { $0 == "first" }.count } == 2, "one failure, one retry — not a loop")
        #expect(ContinuousClock.now - start >= .milliseconds(150), "the retry waited for its backoff")
        await queue.stop()
    }
}
