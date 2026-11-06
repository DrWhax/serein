// Phase 4 step 6b: disappearing messages, message requests, blocking, archive / mute / pin /
// nickname / note (with storage write-back), against the mock server.

import Foundation
import GRDB
import SignalProtos
import Testing
@testable import SignalCore

@Suite(.serialized) struct ConversationStateTests {
    func aliceConversation(_ c: LinkedClient) async throws -> String {
        let aci = c.aliceAci
        return try await c.database.pool.write { try MessageStore.privateConversation($0, serviceId: aci) }
    }

    @Test func disappearingMessages() async throws {
        try await LinkedClient.with { c in
            try await c.acceptAlice()
            let conv = try await aliceConversation(c)
            func timer() async throws -> ConversationState.Timer { try await c.database.pool.read { try ConversationState.timer($0, conversationId: conv) } }
            // Timer updates from alice: applied when their version is newer.
            let u1 = TestClock.next()
            try await c.server.callJSON("sendDataMessage", ["timestamp": u1, "message": ["flags": 2, "expireTimer": 60, "expireTimerVersion": 2]])
            _ = try await c.log.waitFor("timer \(u1)") { if case .other(kind: "timerUpdate:\(u1)", _) = $0 { true } else { false } }
            let t1 = try await timer()
            #expect(t1.seconds == 60 && t1.version == 2)
            let u2 = TestClock.next()
            try await c.server.callJSON("sendDataMessage", ["timestamp": u2, "message": ["flags": 2, "expireTimer": 5, "expireTimerVersion": 2]])
            _ = try await c.log.waitFor("timer \(u2)") { if case .other(kind: "timerUpdate:\(u2)", _) = $0 { true } else { false } }
            #expect(try await timer().seconds == 60)   // same version: ignored
            #expect(try await c.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM messages WHERE type = 'timer-notification'") } == 1)

            // A disappearing message starts counting when read, then goes.
            let t = try await c.send(["body": "poof", "expireTimer": 60, "expireTimerVersion": 2])
            #expect(try await c.messageJSON(sentAt: t)["expirationStartTimestamp"] == nil)
            _ = try await c.messenger.markRead(conversationId: conv)
            let started = try #require(try await c.messageJSON(sentAt: t)["expirationStartTimestamp"] as? Int64)
            let maintenance = Maintenance(database: c.database, store: c.attachmentStore, keyTransparency: nil)
            #expect(try await maintenance.runOnce(now: started + 59_000).expiredMessages == 0)
            #expect(try await maintenance.runOnce(now: started + 61_000).expiredMessages == 1)

            // Ours: the next version goes out, and our messages carry the timer.
            try await c.messenger.setDisappearingTimer(conv, seconds: 30)
            let update = try await c.server.json("waitForMessage", ["account": "alice"])
            #expect(update["flags"] as? Int == 2 && update["expireTimer"] as? Int == 30 && update["expireTimerVersion"] as? Int == 3)
            let sent = try await c.messenger.sendText("short-lived", to: c.aliceAci)
            let m = try await c.server.json("waitForMessage", ["account": "alice"])
            #expect(m["expireTimer"] as? Int == 30)
            #expect(try await c.messageJSON(sentAt: sent.timestamp)["expirationStartTimestamp"] != nil)

            // A new chat starts with the universal timer.
            try await c.database.pool.write { try Items.set($0, "universalExpireTimer", 3600) }
            let bob = try await c.server.json("addAccount", ["name": "bob"])
            _ = try await c.messenger.sendText("hello bob", to: try #require(bob["aci"] as? String).lowercased())
            let toBob = try await c.server.json("waitForMessage", ["account": "bob"])
            #expect(toBob["expireTimer"] as? Int == 3600)
        }
    }

    @Test func messageRequestsAndBlocking() async throws {
        try await LinkedClient.with { c in
            let bob = try await c.server.json("addAccount", ["name": "bob"])
            let bobAci = try #require(bob["aci"] as? String).lowercased()
            // A stranger's media waits for the request to be accepted.
            let t = TestClock.next()
            _ = try await c.server.json("sendAttachment", ["from": "bob", "data": AttachmentFlowTests.png().base64EncodedString(), "contentType": "image/png", "timestamp": t])
            _ = try await c.log.waitFor("bob's photo") { if case .message(_, _, _, _, let ts, _, _, _) = $0 { ts == t } else { false } }
            let bobConv = try await c.database.pool.write { try MessageStore.privateConversation($0, serviceId: bobAci) }
            #expect(try await c.messenger.isAccepted(bobConv) == false)
            #expect(try await c.database.pool.read { try AttachmentDownloads.count($0) } == 0)

            try await c.messenger.respondToMessageRequest(conversationId: bobConv, .accept)
            #expect(try await c.messenger.isAccepted(bobConv))
            // The photo that waited is downloaded now.
            #expect(try await c.database.pool.read { try AttachmentDownloads.count($0) } == 1)
            let sync = try await c.server.json("waitForSyncMessage", ["kind": "messageRequestResponse"])
            #expect(sync["kind"] as? String == "messageRequestResponse")
            let pk = try await c.server.json("waitForMessage", ["account": "bob"])
            #expect(pk["flags"] as? Int == 4 && pk["profileKey"] as? String != nil)

            // The phone blocks bob: his messages stop arriving.
            try await c.server.callJSON("phoneSync", ["timestamp": TestClock.next(), "messageRequestResponse": ["thread": "bob", "type": "BLOCK"]])
            try await c.eventually("bob blocked") { db in try BlockedList.serviceIds.blockedAt(db, bobAci).blocked }
            let dropped = TestClock.next()
            try await c.server.call("sendText", ["from": "bob", "text": "let me in", "timestamp": dropped])
            let later = TestClock.next()
            try await c.server.call("sendText", ["from": "alice", "text": "marker", "timestamp": later])
            _ = try await c.log.waitFor("alice marker") { if case .message(_, _, _, _, let ts, _, _, _) = $0 { ts == later } else { false } }
            #expect(try await c.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM messages WHERE sent_at = ?", arguments: [Int64(dropped)]) } == 0)

            // We block alice: our devices get the whole list.
            let aliceConv = try await aliceConversation(c)
            try await c.messenger.setBlocked(aliceConv, true)
            let blocked = try await c.server.json("waitForSyncMessage", ["kind": "blocked"])
            #expect(blocked["kind"] as? String == "blocked")
            #expect(try await c.database.pool.read { try BlockedList.serviceIds.entries($0).map(\.id) }.contains(c.aliceAci))
            try await c.messenger.setBlocked(aliceConv, false)
            #expect(try await c.database.pool.read { try BlockedList.serviceIds.blockedAt($0, c.aliceAci).blocked } == false)
        }
    }

    @Test func chatSettingsGoToStorage() async throws {
        try await LinkedClient.with { c in
            try await c.server.call("setStorageState")
            try await c.storage.sync()
            let conv = try await aliceConversation(c)
            try await c.messenger.setArchived(conv, true)
            try await c.messenger.setMuted(conv, until: 4_102_444_800_000)
            try await c.messenger.setNickname(conv, given: "Ally", family: "L.")
            try await c.messenger.setNote(conv, "likes tea")
            try await c.messenger.setMarkedUnread(conv, false)
            let aliceRaw = StorageLocal.uuidBytes(c.aliceAci)!.base64EncodedString()
            let deadline = ContinuousClock.now + .seconds(20)
            var contact: [String: Any]? = nil
            var after = -1
            while ContinuousClock.now < deadline {
                let r = try await c.server.json("storageRecords", ["after": after, "timeout": 5000])
                after = r["version"] as? Int ?? after
                let records = r["records"] as? [[String: Any]] ?? []
                contact = records.compactMap { ($0["record"] as? [String: Any])?["contact"] as? [String: Any] }.first { $0["aciBinary"] as? String == aliceRaw }
                if contact?["note"] as? String == "likes tea", contact?["archived"] as? Bool == true { break }
            }
            let a = try #require(contact)
            #expect(a["archived"] as? Bool == true && a["markedUnread"] as? Bool != true && a["note"] as? String == "likes tea")
            #expect((a["nickname"] as? [String: Any])?["given"] as? String == "Ally" && a["mutedUntilTimestamp"] as? Int == 4_102_444_800_000)

            // Pins: at most 4, pinning unarchives, archiving unpins.
            try await c.messenger.setPinned(conv, true)
            #expect(try await c.conversationJSON(serviceId: c.aliceAci)["isArchived"] as? Bool == false)
            try await c.messenger.setArchived(conv, true)
            #expect(try await c.database.pool.read { try Items.get($0, "pinnedConversationIds", as: [String].self) }?.contains(conv) == false)
            var ids: [String] = []
            for i in 0..<4 {
                let bob = try await c.server.json("addAccount", ["name": "p\(i)"])
                let aci = try #require(bob["aci"] as? String).lowercased()
                let id = try await c.database.pool.write { try MessageStore.privateConversation($0, serviceId: aci) }
                ids.append(id)
            }
            // setStorageState pinned alice and the group already; two more fit.
            let existing = try await c.database.pool.read { try Items.get($0, "pinnedConversationIds", as: [String].self) ?? [] }
            for id in ids.prefix(4 - existing.count) { try await c.messenger.setPinned(id, true) }
            await #expect(throws: ModifierError.self) { try await c.messenger.setPinned(ids[3], true) }
        }
    }
}
