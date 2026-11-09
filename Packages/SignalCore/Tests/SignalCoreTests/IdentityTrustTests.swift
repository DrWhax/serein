// Identity-key trust, held to Signal-Desktop's SignalProtocolStore (saveIdentity,
// isTrustedIdentity, isTrustedForSending, setApproval, updateIdentityKey) and to what its
// send path does with an untrusted identity: nothing goes out until the user has approved.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos
import Testing
@testable import SignalCore

// MARK: the identity store

@Suite struct IdentityStoreTests {
    let db: SignalDatabase
    let ourAci = UUID().uuidString.lowercased()
    let ourPni = "PNI:" + UUID().uuidString.lowercased()
    let ourIdentity = IdentityKeyPair.generate()
    let ourPniIdentity = IdentityKeyPair.generate()
    let store: ProtocolStore
    let contact = UUID().uuidString.lowercased()
    let first = IdentityKeyPair.generate()
    let second = IdentityKeyPair.generate()

    init() throws {
        (db, _) = try LinkedClient.temporaryDatabase()
        store = ProtocolStore(ourServiceId: ourAci, identity: ourIdentity, registrationId: 1,
                              ownIdentities: [ourAci: ourIdentity.identityKey, ourPni: ourPniIdentity.identityKey])
    }

    func address(_ device: UInt32 = 1) throws -> ProtocolAddress { try ProtocolAddress(name: contact, deviceId: device) }

    func row(_ db: Database, _ id: String? = nil) throws -> ProtocolStore.IdentityRow? { try ProtocolStore.identityRow(db, serviceId: id ?? contact) }

    func trusted(_ db: Database, _ key: IdentityKeyPair, _ direction: Direction = .sending) throws -> Bool {
        try store.isTrustedIdentity(key.identityKey, for: try address(), direction: direction, context: DatabaseStoreContext(db))
    }

    /// Moves the record's timestamp into the past (the approval window is wall-clock time).
    func age(_ db: Database, by ms: Int64) throws {
        try db.execute(sql: "UPDATE identityKeys SET json = json_set(json, '$.timestamp', json_extract(json, '$.timestamp') - ?) WHERE id = ?",
                       arguments: [ms, contact])
    }

    func keyChanges(_ db: Database, conversationId: String? = nil) throws -> Int {
        let id = try conversationId ?? MessageStore.privateConversation(db, serviceId: contact)
        return try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE type = 'keychange' AND conversationId = ? AND json ->> '$.key_changed' = ?",
                                arguments: [id, contact]) ?? 0
    }

    /// A session with `device` of the contact under `identity`, started from a pre-key bundle.
    func startSession(_ db: Database, _ identity: IdentityKeyPair, device: UInt32) throws {
        let signed = PrivateKey.generate(), kyber = KEMKeyPair.generate()
        let bundle = try PreKeyBundle(
            registrationId: 5, deviceId: device, signedPrekeyId: 1, signedPrekey: signed.publicKey,
            signedPrekeySignature: identity.privateKey.generateSignature(message: signed.publicKey.serialize()), identity: identity.identityKey,
            kyberPrekeyId: 1, kyberPrekey: kyber.publicKey, kyberPrekeySignature: identity.privateKey.generateSignature(message: kyber.publicKey.serialize()))
        try processPreKeyBundle(bundle, for: try address(device), ourAddress: try ProtocolAddress(name: ourAci, deviceId: 2),
                                sessionStore: store, identityStore: store, context: DatabaseStoreContext(db))
    }

    func liveSessions(_ db: Database) throws -> [Int] {
        try Row.fetchAll(db, sql: "SELECT deviceId, record FROM sessions WHERE serviceId = ? ORDER BY deviceId", arguments: [contact])
            .filter { try SessionRecord(bytes: $0["record"] as Data).hasCurrentState }.map { $0["deviceId"] }
    }

    @Test func firstKeyIsTrustedOnFirstUse() throws {
        try db.pool.write { db throws in
            #expect(try trusted(db, first))   // nothing on record yet
            #expect(try store.saveIdentity(db, first.identityKey, for: try address()) == .newOrUnchanged)
            let r = try #require(try row(db))
            #expect(r.firstUse && r.verifiedStatus == .default && !r.nonblockingApproval)
            #expect(try trusted(db, first))
            #expect(try !trusted(db, second))
            #expect(try keyChanges(db) == 0)
            // Saving it again changes nothing.
            #expect(try store.saveIdentity(db, first.identityKey, for: try address()) == .newOrUnchanged)
            #expect(try row(db)?.firstUse == true)
        }
    }

    @Test func changedKeyBlocksSendingUntilApprovedOrTheWindowPasses() throws {
        try db.pool.write { db throws in
            for device in [1, 2, 3] as [UInt32] { try startSession(db, first, device: device) }
            #expect(try liveSessions(db) == [1, 2, 3])

            // The new key arrives the way libsignal delivers it while decrypting from device 2.
            #expect(try trusted(db, second, .receiving))
            #expect(try store.saveIdentity(second.identityKey, for: try address(2), context: DatabaseStoreContext(db)) == .replacedExisting)
            let r = try #require(try row(db))
            #expect(r.key == second.identityKey.serialize() && !r.firstUse && !r.nonblockingApproval && r.verifiedStatus == .default)
            #expect(try keyChanges(db) == 1)
            #expect(try liveSessions(db) == [2])   // the other devices' sessions are archived

            #expect(try !trusted(db, first))    // the old key is gone
            #expect(try !trusted(db, second))   // the new one is not approved yet
            #expect(try ProtocolStore.isUntrusted(db, serviceId: contact) && ProtocolStore.needsApproval(db, serviceId: contact))

            // Upstream TIMESTAMP_THRESHOLD: a never-verified contact unblocks after five seconds…
            try age(db, by: ProtocolStore.approvalWindow + 1)
            #expect(try trusted(db, second))
            #expect(try !ProtocolStore.needsApproval(db, serviceId: contact))
            // …but a longer review threshold (as the send dialog may use) still lists them.
            #expect(try ProtocolStore.isUntrusted(db, serviceId: contact, threshold: 60_000))
        }
    }

    @Test func approvalUnblocksImmediately() throws {
        try db.pool.write { db throws in
            try store.saveIdentity(db, first.identityKey, for: try address())
            try store.saveIdentity(db, second.identityKey, for: try address())
            #expect(try !trusted(db, second))
            try ProtocolStore.setApproval(db, serviceId: contact, true)
            #expect(try trusted(db, second))
            #expect(try !ProtocolStore.needsApproval(db, serviceId: contact))
        }
    }

    @Test func verifiedContactBecomesUnverifiedAndStaysBlocked() throws {
        try db.pool.write { db throws in
            try store.saveIdentity(db, first.identityKey, for: try address())
            try ProtocolStore.setVerified(db, serviceId: contact, .verified)
            #expect(try trusted(db, first))

            #expect(try store.saveIdentity(db, second.identityKey, for: try address()) == .replacedExisting)
            #expect(try row(db)?.verifiedStatus == .unverified)
            // No amount of waiting helps: the user has to decide.
            try age(db, by: 24 * 3600 * 1000)
            #expect(try !trusted(db, second))
            #expect(try ProtocolStore.needsApproval(db, serviceId: contact))
            // Approval alone does not clear "unverified"…
            try ProtocolStore.setApproval(db, serviceId: contact, true)
            #expect(try !trusted(db, second))
            // …going back to the default state does (what "send anyway" does first).
            try ProtocolStore.setVerified(db, serviceId: contact, .default)
            #expect(try trusted(db, second))

            // Unverified stays unverified across a further change.
            try ProtocolStore.setVerified(db, serviceId: contact, .unverified)
            try store.saveIdentity(db, first.identityKey, for: try address())
            #expect(try row(db)?.verifiedStatus == .unverified)
            #expect(try keyChanges(db) == 2)
        }
    }

    @Test func markingVerifiedCountsAsHavingSeenTheKey() throws {
        try db.pool.write { db throws in
            try store.saveIdentity(db, first.identityKey, for: try address())
            try store.saveIdentity(db, second.identityKey, for: try address())
            #expect(try !trusted(db, second))
            try ProtocolStore.setVerified(db, serviceId: contact, .verified)
            let r = try #require(try row(db))
            #expect(r.nonblockingApproval && !r.firstUse)
            #expect(try trusted(db, second))
        }
    }

    @Test func ourOwnIdentityIsNeverReplaced() throws {
        try db.pool.write { db throws in
            let ctx = DatabaseStoreContext(db)
            for (id, ours) in [(ourAci, ourIdentity), (ourPni, ourPniIdentity)] {
                let me = try ProtocolAddress(name: id, deviceId: 1)
                // Another key for our own id is refused in both directions and never stored.
                for direction in [Direction.sending, .receiving] {
                    #expect(try !store.isTrustedIdentity(second.identityKey, for: me, direction: direction, context: ctx))
                    #expect(try store.isTrustedIdentity(ours.identityKey, for: me, direction: direction, context: ctx))
                }
                #expect(try store.saveIdentity(second.identityKey, for: me, context: ctx) == .newOrUnchanged)
                #expect(try row(db, id) == nil)
                #expect(try store.saveIdentity(ours.identityKey, for: me, context: ctx) == .newOrUnchanged)
                #expect(try store.saveIdentity(second.identityKey, for: me, context: ctx) == .newOrUnchanged)
                #expect(try row(db, id)?.key == ours.identityKey.serialize())
            }
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE type = 'keychange'") == 0)
        }
    }

    @Test func noOverwriteKeepsTheKeyOnRecord() throws {
        try db.pool.write { db throws in
            #expect(try !store.updateIdentityKey(db, first.identityKey, serviceId: contact, noOverwrite: true))
            #expect(try row(db)?.key == first.identityKey.serialize())   // nothing there before: stored
            #expect(try !store.updateIdentityKey(db, second.identityKey, serviceId: contact, noOverwrite: true))
            #expect(try row(db)?.key == first.identityKey.serialize())
            #expect(try keyChanges(db) == 0)
        }
    }

    /// `updateIdentityKey` (profile fetch, pre-key bundle): unlike a key seen while decrypting,
    /// no device's session survives.
    @Test func serverReportedKeyChangeClosesEverySession() throws {
        try db.pool.write { db throws in
            for device in [1, 2] as [UInt32] { try startSession(db, first, device: device) }
            #expect(try !store.updateIdentityKey(db, first.identityKey, serviceId: contact))
            #expect(try liveSessions(db) == [1, 2])
            #expect(try store.updateIdentityKey(db, second.identityKey, serviceId: contact))
            #expect(try liveSessions(db).isEmpty)
            #expect(try keyChanges(db) == 1)
            #expect(try !trusted(db, second))
        }
    }

    /// libsignal asks the store before it encrypts or starts a session: the block is enforced
    /// below anything the app does.
    @Test func libsignalRefusesToUseAnUntrustedIdentity() throws {
        try db.pool.write { db throws in
            let ctx = DatabaseStoreContext(db)
            let local = try ProtocolAddress(name: ourAci, deviceId: 2)
            try startSession(db, first, device: 1)
            _ = try signalEncrypt(message: Data("ok".utf8), for: try address(), localAddress: local, sessionStore: store, identityStore: store, context: ctx)

            // A bundle under another identity does not start a session.
            #expect(throws: SignalError.self) { try startSession(db, second, device: 1) }
            #expect(try row(db)?.key == first.identityKey.serialize())

            // Marked unverified: the existing session no longer encrypts.
            try ProtocolStore.setVerified(db, serviceId: contact, .unverified)
            do {
                _ = try signalEncrypt(message: Data("no".utf8), for: try address(), localAddress: local, sessionStore: store, identityStore: store, context: ctx)
                Issue.record("encrypted to an unverified identity")
            } catch SignalError.untrustedIdentity {}

            // A replaced key inside the approval window: neither does a session under the new key.
            try ProtocolStore.setVerified(db, serviceId: contact, .default)
            try store.updateIdentityKey(db, second.identityKey, serviceId: contact)
            do {
                try startSession(db, second, device: 1)
                Issue.record("started a session with an unapproved identity")
            } catch SignalError.untrustedIdentity {}
            try ProtocolStore.setApproval(db, serviceId: contact, true)
            try startSession(db, second, device: 1)
            #expect(try liveSessions(db) == [1])
        }
    }

    @Test func keyChangeReachesSharedGroupsAndResetsTheirSenderKeys() throws {
        try db.pool.write { db throws in
            func group(_ id: String, members: [String], left: Bool = false) throws {
                let json: [String: Any] = ["id": id, "membersV2": members.map { ["aci": $0] }, "left": left,
                                           "senderKeyInfo": ["createdAtDate": 1, "distributionId": UUID().uuidString, "memberDevices": [[String: Any]]()]]
                try db.execute(sql: "INSERT INTO conversations (id, json, type, groupId) VALUES (?, ?, 'group', ?)",
                               arguments: [id, try MessageStore.jsonString(json), id])
            }
            try group("shared", members: [ourAci, contact])
            try group("other", members: [ourAci, UUID().uuidString.lowercased()])
            try group("left", members: [ourAci, contact], left: true)
            try store.saveIdentity(db, first.identityKey, for: try address())
            try store.saveIdentity(db, second.identityKey, for: try address())

            #expect(try keyChanges(db) == 1)
            #expect(try keyChanges(db, conversationId: "shared") == 1)
            #expect(try keyChanges(db, conversationId: "other") == 0)
            #expect(try keyChanges(db, conversationId: "left") == 0)
            func markedForReset(_ id: String) throws -> Bool {
                try Bool.fetchOne(db, sql: "SELECT coalesce(json_extract(json, '$.senderKeyInfo.needsReset'), 0) FROM conversations WHERE id = ?",
                                  arguments: [id]) ?? false
            }
            #expect(try markedForReset("shared"))
            #expect(try !markedForReset("other"))
            // The notice is unseen but not unread (upstream ReadStatus.Read / SeenStatus.Unseen).
            let notice = try #require(try String.fetchOne(db, sql: "SELECT json FROM messages WHERE type = 'keychange' AND conversationId = 'shared'"))
            let json = try MessageStore.jsonObject(notice)
            #expect(json["readStatus"] as? Int == ReadStatus.read.rawValue && json["seenStatus"] as? Int == SeenStatus.unseen.rawValue)
        }
    }

    /// A key our own devices told us about (Verified sync, storage service) needs no approval.
    @Test func syncedIdentityIsPreApproved() throws {
        try db.pool.write { db throws in
            try store.saveIdentity(db, first.identityKey, for: try address())
            try ProtocolStore.setIdentity(db, serviceId: contact, key: second.identityKey.serialize(), verified: .default)
            let r = try #require(try row(db))
            #expect(r.nonblockingApproval && !r.firstUse)
            #expect(try trusted(db, second))
            try ProtocolStore.setIdentity(db, serviceId: contact, key: second.identityKey.serialize(), verified: .unverified)
            #expect(try !trusted(db, second))
        }
    }
}

// MARK: sending and receiving against the mock server

@Suite struct IdentityTrustFlowTests {
    private func identity(_ c: LinkedClient) async throws -> ProtocolStore.IdentityRow {
        try #require(try await c.database.pool.read { db in try ProtocolStore.identityRow(db, serviceId: c.aliceAci) })
    }

    private func errorNames(_ c: LinkedClient, _ sentAt: UInt64) async throws -> [String] {
        ((try await c.messageJSON(sentAt: sentAt))["errors"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    private func keyChanges(_ c: LinkedClient) async throws -> Int {
        try await c.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE type = 'keychange' AND json ->> '$.key_changed' = ?", arguments: [c.aliceAci]) ?? 0
        }
    }

    private func waitForFailure(_ c: LinkedClient, _ sentAt: UInt64) async throws {
        try await c.eventually("send failure") { db in
            try String.fetchOne(db, sql: "SELECT json ->> '$.errors[0].name' FROM messages WHERE sent_at = ?", arguments: [Int64(sentAt)]) != nil
        }
        try await c.jobs.waitUntilIdle()
    }

    /// The contact re-installed. Upstream: the send fails, the new key goes on record with its
    /// notice, and the message only goes out once the user has approved.
    @Test func reinstalledContactIsNotSentToBeforeApproval() async throws {
        try await LinkedClient.with { c in
            try await c.messenger.sendText("before reinstall", to: c.aliceAci)
            _ = try await c.waitForMessage(to: "alice")
            try await c.jobs.waitUntilIdle()
            let conversationId = try await c.database.pool.write { db in try MessageStore.privateConversation(db, serviceId: c.aliceAci) }
            #expect(try await c.messenger.identitiesNeedingApproval(conversationId: conversationId).isEmpty)

            let fresh = try await c.server.json("reregister", ["account": "alice"])
            let stops = Task { () -> IdentityStop? in
                for await stop in c.messenger.identityStops { return stop }
                return nil
            }
            let (messageId, t) = try await c.messenger.sendText("after reinstall", to: c.aliceAci)
            try await waitForFailure(c, t)

            #expect(try await c.sendStatus(t, conversationWith: c.aliceAci) == "Failed")
            #expect(try await errorNames(c, t) == ["OutgoingIdentityKeyError"])
            #expect(try await c.messenger.identitiesBlocking(messageId: messageId) == [c.aliceAci])
            #expect(await stops.value == IdentityStop(conversationId: conversationId, messageId: messageId, serviceIds: [c.aliceAci]))
            // The new key is on record, unapproved, with the safety-number notice…
            let row = try await identity(c)
            #expect(row.publicKey == fresh["identityKey"] as? String && !row.firstUse && !row.nonblockingApproval)
            #expect(try await keyChanges(c) == 1)
            #expect(try await c.messenger.identitiesNeedingApproval(conversationId: conversationId) == [c.aliceAci])
            // …and alice's new installation has received nothing.
            #expect((try await c.server.json("pendingMessages", ["account": "alice"]))["count"] as? Int == 0)

            try await c.messenger.approveIdentities([c.aliceAci])
            #expect(try await c.messenger.identitiesNeedingApproval(conversationId: conversationId).isEmpty)
            try await c.messenger.retrySend(messageId: messageId)
            // (The probe used above does see a delivered message before anyone waits for it.)
            var delivered = 0
            for _ in 0..<100 where delivered == 0 {
                delivered = (try await c.server.json("pendingMessages", ["account": "alice", "settle": 50]))["count"] as? Int ?? 0
            }
            #expect(delivered == 1)
            let got = try await c.waitForMessage(to: "alice")
            #expect(got.body == "after reinstall" && got.timestamp == t && got.envelopeType == "PreKey")
            try await c.jobs.waitUntilIdle()
            #expect(try await c.sendStatus(t, conversationWith: c.aliceAci) == "Sent")
            #expect(try await errorNames(c, t).isEmpty)
            #expect(try await keyChanges(c) == 1)
        }
    }

    @Test func verifiedContactWithNewIdentityStaysBlockedUntilTheUserDecides() async throws {
        try await LinkedClient.with { c in
            try await c.messenger.sendText("before", to: c.aliceAci)
            _ = try await c.waitForMessage(to: "alice")
            try await c.jobs.waitUntilIdle()
            try await c.messenger.setVerified(c.aliceAci, true)
            try await c.jobs.waitUntilIdle()

            try await c.server.call("reregister", ["account": "alice"])
            let (messageId, t) = try await c.messenger.sendText("must not be sent yet", to: c.aliceAci)
            try await waitForFailure(c, t)
            #expect(try await errorNames(c, t) == ["OutgoingIdentityKeyError"])
            #expect(try await identity(c).verifiedStatus == .unverified)

            // Waiting out the approval window does not help a contact that was verified.
            try await c.database.pool.write { db in
                try db.execute(sql: "UPDATE identityKeys SET json = json_set(json, '$.timestamp', 1) WHERE id = ?", arguments: [c.aliceAci])
            }
            try await c.messenger.retrySend(messageId: messageId)
            try await waitForFailure(c, t)
            #expect(try await c.sendStatus(t, conversationWith: c.aliceAci) == "Failed")
            #expect((try await c.server.json("pendingMessages", ["account": "alice"]))["count"] as? Int == 0)

            try await c.messenger.approveIdentities([c.aliceAci])
            let row = try await identity(c)
            #expect(row.verifiedStatus == .default && row.nonblockingApproval)
            try await c.messenger.retrySend(messageId: messageId)
            let got = try await c.waitForMessage(to: "alice")
            #expect(got.body == "must not be sent yet" && got.timestamp == t)
        }
    }

    /// The new identity writes to us first. Upstream accepts the message, and that is exactly
    /// when the key change has to be recorded: notice, unverified, and no reply without approval.
    @Test func keyChangeSeenOnAnIncomingMessageBlocksTheReply() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("hello")
            try await c.messenger.setVerified(c.aliceAci, true)
            try await c.jobs.waitUntilIdle()
            let old = try await identity(c)

            let fresh = try await c.server.json("reregister", ["account": "alice", "openSession": true])
            try await c.receiveFromAlice("it is me again, new phone")   // received and stored
            let row = try await identity(c)
            #expect(row.publicKey == fresh["identityKey"] as? String && row.publicKey != old.publicKey)
            #expect(row.verifiedStatus == .unverified && !row.firstUse && !row.nonblockingApproval)
            #expect(try await keyChanges(c) == 1)

            let (messageId, t) = try await c.messenger.sendText("who is this?", to: c.aliceAci)
            try await waitForFailure(c, t)
            #expect(try await errorNames(c, t) == ["OutgoingIdentityKeyError"])
            #expect((try await c.server.json("pendingMessages", ["account": "alice"]))["count"] as? Int == 0)

            try await c.messenger.approveIdentities([c.aliceAci])
            try await c.messenger.retrySend(messageId: messageId)
            let got = try await c.waitForMessage(to: "alice")
            #expect(got.body == "who is this?" && got.timestamp == t)
            #expect(try await keyChanges(c) == 1)
        }
    }

    /// A never-verified contact: the same key change only holds sending for the approval window.
    @Test func unverifiedContactUnblocksAfterTheWindow() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("hello")
            try await c.server.call("reregister", ["account": "alice", "openSession": true])
            try await c.receiveFromAlice("new phone")
            #expect(try await identity(c).verifiedStatus == .default)
            #expect(try await keyChanges(c) == 1)

            let (first, t1) = try await c.messenger.sendText("too soon", to: c.aliceAci)
            try await waitForFailure(c, t1)
            #expect(try await errorNames(c, t1) == ["OutgoingIdentityKeyError"])

            try await c.database.pool.write { db in
                try db.execute(sql: "UPDATE identityKeys SET json = json_set(json, '$.timestamp', json_extract(json, '$.timestamp') - 6000) WHERE id = ?",
                               arguments: [c.aliceAci])
            }
            try await c.messenger.retrySend(messageId: first)
            #expect(try await c.waitForMessage(to: "alice").body == "too soon")
        }
    }

    @Test func groupSendWaitsForAnUntrustedMember() async throws {
        try await LinkedClient.with { c in
            _ = try await c.server.json("addAccount", ["name": "bob"])
            let g = try await c.server.json("createGroup", ["title": "Three", "members": ["alice", "phone", "bob"]])
            let groupId = try #require(g["id"] as? String), masterKey = try #require(Data(base64Encoded: g["masterKey"] as! String))
            _ = try await c.server.json("sendGroupText", ["groupId": groupId, "text": "welcome", "timestamp": TestClock.next()])
            _ = try await c.log.waitFor("group update") { if case .other("groupUpdated", _) = $0 { return true } else { return false } }
            let (_, t0) = try await c.messenger.sendGroupMessage("hello both", masterKey: masterKey)
            for name in ["alice", "bob"] { _ = try await c.server.json("waitForMessage", ["account": name]) }
            try await c.jobs.waitUntilIdle()
            _ = t0

            try await c.database.pool.write { db in try ProtocolStore.setVerified(db, serviceId: c.aliceAci, .unverified) }
            let conversationId = try #require(try await c.database.pool.read { db in try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE type = 'group'") })
            #expect(try await c.messenger.identitiesNeedingApproval(conversationId: conversationId) == [c.aliceAci])

            let (messageId, t) = try await c.messenger.sendGroupMessage("not yet", masterKey: masterKey)
            try await waitForFailure(c, t)
            #expect(try await c.messenger.identitiesBlocking(messageId: messageId) == [c.aliceAci])
            // Nobody got it, bob included: the user decides before anything is sent.
            for name in ["alice", "bob"] { #expect((try await c.server.json("pendingMessages", ["account": name]))["count"] as? Int == 0) }

            try await c.messenger.approveIdentities([c.aliceAci])
            try await c.messenger.retrySend(messageId: messageId)
            for name in ["alice", "bob"] {
                let m = try await c.server.json("waitForMessage", ["account": name])
                #expect(m["body"] as? String == "not yet")
            }
        }
    }
}
