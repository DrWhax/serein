// CDSI: request assembly (e164 validation, ACI + access-key pairs from known profile
// keys), merging of results into conversations, and the real Net.cdsiLookup path.

import Foundation
import GRDB
import LibSignalClient
import Synchronization
import Testing
@testable import SignalCore

@Suite struct ContactDiscoveryTests {
    @Test func requestAndMerge() async throws {
        let (db, _) = try LinkedClient.temporaryDatabase()
        let known = UUID().uuidString.lowercased(), discovered = UUID().uuidString.lowercased(), pniOnly = UUID().uuidString.lowercased()
        let profileKey = Data(repeating: 5, count: 32)
        try await db.pool.write { db in
            try MessageStore.setProfileKey(db, serviceId: known, profileKey)
            // A conversation known only by number (e.g. typed in by the user) is adopted by the discovered ACI.
            try db.execute(sql: "INSERT INTO conversations (id, json, type, e164) VALUES ('c-e164', '{\"id\":\"c-e164\",\"type\":\"private\"}', 'private', '+15550001111')")
        }
        let captured = Mutex<CdsiQuery?>(nil)
        let discovery = ContactDiscovery(database: db, auth: { Auth(username: "u", password: "p") }) { auth, query in
            #expect(auth.username == "u")
            captured.withLock { $0 = query }
            return [CdsiEntry(e164: "+15550001111", aci: discovered, pni: "PNI:\(pniOnly)"),
                    CdsiEntry(e164: "+15550002222", aci: nil, pni: "PNI:\(pniOnly)")]
        }
        let entries = try await discovery.lookup(e164s: ["+15550001111", "+15550002222", "not-a-number", "+1"])
        #expect(entries.count == 2)
        let query = try #require(captured.withLock { $0 })
        #expect(query.e164s == ["+15550001111", "+15550002222"])
        #expect(query.acisAndAccessKeys.map { $0.aci.serviceIdString.lowercased() } == [known])
        let expectedAccessKey = try ProfileKey(contents: profileKey).deriveAccessKey()
        #expect(query.acisAndAccessKeys.first?.accessKey == expectedAccessKey)

        try await db.pool.read { db throws in
            let adopted = try #require(try Row.fetchOne(db, sql: "SELECT serviceId, e164, json FROM conversations WHERE id = 'c-e164'"))
            #expect(adopted["serviceId"] as String? == discovered && adopted["e164"] as String? == "+15550001111")
            #expect(try MessageStore.jsonObject(adopted["json"])["pni"] as? String == "PNI:\(pniOnly)")
            // PNI-only result: conversation keyed by the PNI service id.
            #expect(try String.fetchOne(db, sql: "SELECT e164 FROM conversations WHERE serviceId = ?", arguments: ["PNI:\(pniOnly)"]) == "+15550002222")
        }
        // Nothing valid to look up: no request at all.
        captured.withLock { $0 = nil }
        #expect(try await discovery.lookup(e164s: ["12345"]).isEmpty)
        #expect(captured.withLock { $0 } == nil)
    }

    /// The production lookup goes through libsignal-net's attested CDSI connection; the mock
    /// server has no enclave, so against the local test environment it must fail cleanly
    /// with a libsignal network error (and never touch the database).
    @Test func netCdsiLookupIsWired() async throws {
        let (db, _) = try LinkedClient.temporaryDatabase()
        let net = Net.localTestServer(userAgent: "SignalSafe-Tests", chatPort: 9, rootCertificateDer: Data())
        let discovery = ContactDiscovery(database: db, auth: { Auth(username: "u", password: "p") }, lookup: ContactDiscovery.netLookup(net))
        await #expect(throws: SignalError.self) { try await discovery.lookup(e164s: ["+15550001111"]) }
        #expect(try await db.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM conversations") } == 0)
    }
}

@Suite struct JobQueueTests {
    struct Payload: Codable, Sendable { var n: Int }

    @Test func persistedJobsRunAfterRestart() async throws {
        let (db, _) = try LinkedClient.temporaryDatabase()
        // First "run": jobs are committed but the process dies before running them.
        let first = JobQueue(database: db)
        try await first.enqueue(queueType: "test", payload: Payload(n: 1))
        try await first.enqueue(queueType: "test", payload: Payload(n: 2))
        #expect(try await first.pendingCount() == 2)

        let seen = Mutex<[Int]>([])
        let second = JobQueue(database: db)
        await second.register("test") { job in
            let p = try job.decode(Payload.self)
            seen.withLock { $0.append(p.n) }
        }
        await second.start()
        try await second.waitUntilIdle()
        #expect(seen.withLock { $0 } == [1, 2])
        #expect(try await second.pendingCount() == 0)
        await second.stop()
    }

    @Test func retriesWithBackoffThenSucceeds() async throws {
        struct Flaky: Error {}
        let (db, _) = try LinkedClient.temporaryDatabase()
        let attempts = Mutex(0)
        let queue = JobQueue(database: db, policy: RetryPolicy(maxAttempts: 5, baseDelay: .milliseconds(10), maxDelay: .milliseconds(50)))
        await queue.register("flaky") { _ in
            let n = attempts.withLock { $0 += 1; return $0 }
            if n < 3 { throw Flaky() }
        }
        await queue.start()
        try await queue.enqueue(queueType: "flaky", payload: Payload(n: 0))
        let deadline = ContinuousClock.now + .seconds(5)
        while try await queue.pendingCount() > 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(attempts.withLock { $0 } == 3)
        #expect(try await queue.pendingCount() == 0)
        await queue.stop()
    }

    @Test func permanentFailureCallsFailureHandler() async throws {
        let (db, _) = try LinkedClient.temporaryDatabase()
        let failed = Mutex<String?>(nil)
        let queue = JobQueue(database: db)
        await queue.register("doomed", handler: { _ in throw JobError.permanent("nope") }, onFailure: { _, error in
            failed.withLock { $0 = "\(error)" }
        })
        await queue.start()
        try await queue.enqueue(queueType: "doomed", payload: Payload(n: 0))
        try await queue.waitUntilIdle()
        #expect(failed.withLock { $0 }?.contains("nope") == true)
        #expect(try await queue.pendingCount() == 0)
        await queue.stop()
    }

    @Test func messagePadding() throws {
        // Desktop padMessage: (n + 2) rounded up to a multiple of 80, minus 1.
        for (n, expected) in [(0, 79), (77, 79), (78, 79), (79, 159), (158, 159), (159, 239)] {
            let padded = MessageSender.pad(Data(repeating: 0x41, count: n))
            #expect(padded.count == expected)
            #expect(padded[n] == 0x80 && padded[(n + 1)...].allSatisfy { $0 == 0 })
            #expect(try MessageReceiver.unpad(padded) == Data(repeating: 0x41, count: n))
        }
    }
}
