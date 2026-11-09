// Pre-key refill, rotation and cleanup, held to Signal-Desktop's AccountManager.maybeUpdateKeys
// (its constants and its four _clean passes) and UpdateKeysListener.

import Foundation
import GRDB
import LibSignalClient
import Testing
@testable import SignalCore

/// Stands in for the server: reports key counts and records what is uploaded.
private actor FakeKeyServer {
    var count: Int
    var pqCount: Int
    /// The JSON bodies of the uploads, in order.
    var uploads: [Data] = []
    var failUploads = false
    init(count: Int, pqCount: Int) {
        self.count = count
        self.pqCount = pqCount
    }
    func set(count: Int, pqCount: Int) { (self.count, self.pqCount) = (count, pqCount) }
    func setFailing(_ failing: Bool) { failUploads = failing }
    func handle(_ method: String, _ path: String, _ json: Data?) throws -> Data {
        if method == "GET" { return try JSONSerialization.data(withJSONObject: ["count": count, "pqCount": pqCount]) }
        if failUploads { throw HarnessError(description: "upload refused") }
        uploads.append(json ?? Data())
        return Data("{}".utf8)
    }
    var uploadCount: Int { uploads.count }
    var lastUpload: Data { uploads.last ?? Data("{}".utf8) }
}

/// One uploaded key: its id, public key and (for signed keys) signature, as sent.
private struct UploadedKey: Sendable {
    var id: UInt32
    var publicKey: String
    var signature: Data?
}

private func uploaded(_ body: Data) throws -> [String: [UploadedKey]] {
    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
    return json.mapValues { value in
        let list = (value as? [[String: Any]]) ?? [value as? [String: Any]].compactMap { $0 }
        return list.map { UploadedKey(id: ($0["keyId"] as? NSNumber)?.uint32Value ?? 0, publicKey: $0["publicKey"] as? String ?? "",
                                      signature: ($0["signature"] as? String).flatMap { Data(base64Encoded: $0) }) }
    }
}

@Suite struct PreKeyMaintenanceTests {
    private static let day: Int64 = 86_400_000

    private func maintenance(_ c: LinkedClient, _ server: FakeKeyServer) -> PreKeyMaintenance {
        PreKeyMaintenance(account: c.account, database: c.database) { method, path, json in
            #expect(path == "/v2/keys?identity=aci" || path == "/v2/keys?identity=pni")
            return try await server.handle(method, path, json)
        }
    }

    private func rows(_ c: LinkedClient, _ table: String, lastResort: Bool? = nil) async throws -> [ProtocolStore.KeyRow] {
        try await c.database.pool.read { db in try c.account.aciStore().reusableKeys(db, table: table, lastResort: lastResort) }
    }

    @Test func nothingIsUploadedWhileKeysAreFresh() async throws {
        try await LinkedClient.with { c in
            let server = FakeKeyServer(count: 50, pqCount: 50)
            let report = try await maintenance(c, server).maybeUpdateKeys(.aci)
            #expect(report == PreKeyMaintenance.Report())
            #expect(await server.uploadCount == 0)
        }
    }

    @Test func oneTimeKeysAreRefilledWhenTheServerRunsLow() async throws {
        try await LinkedClient.with { c in
            let server = FakeKeyServer(count: 9, pqCount: 50)   // PRE_KEY_MINIMUM is 10
            let keys = maintenance(c, server)
            let before = Set(try await rows(c, "preKeys").map(\.keyId))
            let report = try await keys.maybeUpdateKeys(.aci)
            #expect(report.preKeys == 100 && report.kyberPreKeys == 0 && report.signedPreKey == nil && report.lastResortKey == nil)
            let first = try uploaded(await server.lastUpload)
            #expect(first.keys.sorted() == ["preKeys"])
            let batch = try #require(first["preKeys"])
            let ids = batch.map(\.id)
            #expect(ids.count == 100 && Set(ids).isDisjoint(with: before))   // no unused key is overwritten
            #expect(ids.allSatisfy { $0 >= 1 && $0 <= 0xFF_FFFF })
            // Each public key offered has its private key in the store.
            try await c.database.pool.read { db throws in
                let store = c.account.aciStore()
                for key in batch {
                    let record = try store.loadPreKey(id: key.id, context: DatabaseStoreContext(db))
                    #expect(try record.publicKey().serialize().base64EncodedString() == key.publicKey)
                }
            }
            // The next batch continues after this one; Kyber keys are counted separately.
            await server.set(count: 50, pqCount: 3)
            let second = try await keys.maybeUpdateKeys(.aci)
            #expect(second.preKeys == 0 && second.kyberPreKeys == 100)
            #expect(try uploaded(await server.lastUpload).keys.sorted() == ["pqPreKeys"])
            await server.set(count: 9, pqCount: 50)
            _ = try await keys.maybeUpdateKeys(.aci)
            let third = try #require(try uploaded(await server.lastUpload)["preKeys"]).map(\.id)
            #expect(Set(third).isDisjoint(with: Set(ids)) && third.first == (ids.last ?? 0) % 0xFF_FFFF + 1)
            // Upstream also regenerates when the server holds more than PRE_KEY_MAX_COUNT.
            await server.set(count: 201, pqCount: 50)
            #expect(try await keys.maybeUpdateKeys(.aci).preKeys == 100)
        }
    }

    @Test func signedAndLastResortKeysRotateAfterADayAndAHalf() async throws {
        try await LinkedClient.with { c in
            let server = FakeKeyServer(count: 50, pqCount: 50)
            let keys = maintenance(c, server)
            let linkedAt = MessageStore.now()
            let original = try #require(try await rows(c, "signedPreKeys").first)

            #expect(try await keys.maybeUpdateKeys(.aci, now: linkedAt + Self.day).signedPreKey == nil)   // one day: not yet
            let report = try await keys.maybeUpdateKeys(.aci, now: linkedAt + 2 * Self.day)
            let signedId = try #require(report.signedPreKey), lastResortId = try #require(report.lastResortKey)
            #expect(report.preKeys == 0 && report.kyberPreKeys == 0)
            let rotated = try uploaded(await server.lastUpload)
            #expect(rotated.keys.sorted() == ["pqLastResortPreKey", "signedPreKey"])

            // Both are signed by our identity key.
            let identity = c.account.aciIdentity.publicKey
            for (field, id) in [("signedPreKey", signedId), ("pqLastResortPreKey", lastResortId)] {
                let key = try #require(rotated[field]?.first)
                #expect(key.id == id)
                let publicKey = try #require(Data(base64Encoded: key.publicKey))
                #expect(try identity.verifySignature(message: publicKey, signature: try #require(key.signature)))
            }
            let signed = try await rows(c, "signedPreKeys")
            #expect(signed.count == 2 && signed.allSatisfy { $0.isConfirmed == true })
            #expect(signed.contains { $0.keyId == original.keyId })   // a message in flight may still use the old one
            #expect(try await rows(c, "kyberPreKeys", lastResort: true).count == 2)
            let updated = try await c.database.pool.read { db in try Items.get(db, "signedKeyUpdateTime", as: Int64.self) }
            #expect(updated == linkedAt + 2 * Self.day)
            // Fresh again: the next check uploads nothing.
            #expect(try await keys.maybeUpdateKeys(.aci, now: linkedAt + 3 * Self.day) == PreKeyMaintenance.Report())
        }
    }

    /// A key the server never accepted does not count as the current one.
    @Test func failedUploadLeavesTheKeyUnconfirmedAndIsRetried() async throws {
        try await LinkedClient.with { c in
            let server = FakeKeyServer(count: 50, pqCount: 50)
            let keys = maintenance(c, server)
            let later = MessageStore.now() + 2 * Self.day
            await server.setFailing(true)
            await #expect(throws: (any Error).self) { try await keys.maybeUpdateKeys(.aci, now: later) }
            let pending = try await rows(c, "signedPreKeys").filter { $0.isConfirmed == false }
            #expect(pending.count == 1)
            #expect(try await c.database.pool.read { db in try Items.get(db, "signedKeyUpdateTime", as: Int64.self) } == nil)

            await server.setFailing(false)
            let report = try await keys.maybeUpdateKeys(.aci, now: later)
            #expect(report.signedPreKey != nil && report.signedPreKey != pending[0].keyId)
        }
    }

    @Test func oldReusableKeysAreRemovedOnlyWhenNoMessageCanNeedThem() async throws {
        try await LinkedClient.with { c in
            let server = FakeKeyServer(count: 50, pqCount: 50)
            let keys = maintenance(c, server)
            let start = MessageStore.now()
            // A rotation every two days for twenty days: eleven keys, all younger than the
            // thirty days a message may wait on the server. None may go.
            for step in 1...10 { _ = try await keys.maybeUpdateKeys(.aci, now: start + Int64(step) * 2 * Self.day) }
            #expect(try await rows(c, "signedPreKeys").count == 11)
            #expect(try await rows(c, "kyberPreKeys", lastResort: true).count == 11)

            // Much later: the newest five stay whatever their age, the rest are past thirty days.
            let report = try await keys.maybeUpdateKeys(.aci, now: start + 100 * Self.day)
            #expect(report.removed == 14)   // 7 signed + 7 last-resort
            let signed = try await rows(c, "signedPreKeys")
            #expect(signed.count == 5 && signed.contains { $0.keyId == report.signedPreKey })
            #expect(try await rows(c, "kyberPreKeys", lastResort: true).count == 5)
            // One-time keys are not touched by this (fewer than 200, and that pass needs 90 days).
            #expect(try await rows(c, "preKeys").isEmpty == false)
        }
    }

    @Test func runsEveryTwoDays() async throws {
        try await LinkedClient.with { c in
            let server = FakeKeyServer(count: 50, pqCount: 50)
            let keys = maintenance(c, server)
            let now = MessageStore.now()
            let first = try await keys.runIfDue(now: now)                     // never ran: due
            let tooSoon = try await keys.runIfDue(now: now + Self.day)
            let second = try await keys.runIfDue(now: now + 2 * Self.day)
            #expect(first && !tooSoon && second)
            #expect(await server.uploadCount == 2)                            // the second run rotated both identities' keys
        }
    }

    /// Upstream refuses to send while our reusable keys are more than two weeks old.
    @Test func sendingWaitsForCurrentKeys() async throws {
        try await LinkedClient.with { c in
            let server = FakeKeyServer(count: 50, pqCount: 50)
            let keys = maintenance(c, server)
            let linkedAt = MessageStore.now()
            // Right after linking nothing is recorded yet: the first check records the key times.
            try await keys.ensureKeysCurrent(now: linkedAt)
            let fresh = try await keys.areKeysOutOfDate(now: linkedAt + 13 * Self.day)
            let stale = try await keys.areKeysOutOfDate(now: linkedAt + 15 * Self.day)
            #expect(!fresh && stale)
            #expect(await server.uploadCount == 0)

            // Too old and the server cannot be reached: no send.
            await server.setFailing(true)
            await #expect(throws: (any Error).self) { try await keys.ensureKeysCurrent(now: linkedAt + 15 * Self.day) }
            // Reachable again: the keys are replaced and sending may go on.
            await server.setFailing(false)
            try await keys.ensureKeysCurrent(now: linkedAt + 15 * Self.day)
            let after = try await keys.areKeysOutOfDate(now: linkedAt + 15 * Self.day)
            #expect(!after)
            #expect(await server.uploadCount == 1)
        }
    }

    /// Against the mock server: after replacing every key, a contact that has never talked to
    /// us fetches a bundle and its first message decrypts.
    @Test func uploadedKeysOpenSessions() async throws {
        try await LinkedClient.with { c in
            let report = try await PreKeyMaintenance(account: c.account, database: c.database, socket: c.socket).maybeUpdateKeys(.aci, force: true)
            #expect(report.preKeys == 100 && report.kyberPreKeys == 100 && report.signedPreKey != nil && report.lastResortKey != nil)
            // Uploaded and acknowledged: the new reusable keys are confirmed.
            let unconfirmed = try await c.database.pool.read { db in
                try c.account.aciStore().reusableKeys(db, table: "signedPreKeys", lastResort: nil).filter { $0.isConfirmed == false }.count
            }
            #expect(unconfirmed == 0)
            struct Counts: Decodable { var count: Int; var pqCount: Int }
            let response = try await c.socket.authenticatedRequest("GET", "/v2/keys?identity=aci")
            let counts = try JSONDecoder().decode(Counts.self, from: response)
            #expect(counts.count == 100 && counts.pqCount == 100)
            _ = try await c.server.json("addAccount", ["name": "bob"])
            let t = TestClock.next()
            try await c.server.call("sendText", ["from": "bob", "text": "hello with your new keys", "timestamp": t])
            _ = try await c.log.waitFor("bob's message") { if case .message(_, _, _, _, t, _, _, _) = $0 { true } else { false } }
            let stored = try await c.database.pool.read { db in try String.fetchOne(db, sql: "SELECT body FROM messages WHERE sent_at = ?", arguments: [Int64(t)]) }
            #expect(stored == "hello with your new keys")
        }
    }
}
