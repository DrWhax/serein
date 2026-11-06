// Phase 4 step 6a: reactions, delete for everyone, edits, polls, pins, view-once, delete for
// me, and the same changes arriving as syncs from the phone — against the mock server.

import Foundation
import GRDB
import SignalProtos
import Testing
@testable import SignalCore

extension LinkedClient {
    /// Sends `message` (a harness DataMessage spec) from `from`; waits until it is processed.
    func send(_ message: [String: Any], from: String = "alice", timestamp: UInt64 = TestClock.next(), storesMessage: Bool = true) async throws -> UInt64 {
        try await server.callJSON("sendDataMessage", ["from": from, "timestamp": timestamp, "message": message])
        if storesMessage {
            _ = try await log.waitFor("message \(timestamp)") { if case .message(_, _, _, _, let t, _, _, _) = $0 { t == timestamp } else { false } }
        } else {
            _ = try await log.waitFor("modifier \(timestamp)") { if case .other(kind: "modifier:\(timestamp)", _) = $0 { true } else { false } }
        }
        return timestamp
    }

    func messageId(sentAt: UInt64) async throws -> String {
        let id = try await database.pool.read { try String.fetchOne($0, sql: "SELECT id FROM messages WHERE sent_at = ?", arguments: [Int64(sentAt)]) }
        return try #require(id)
    }
}

@Suite(.serialized) struct ModifierTests {
    @Test func reactions() async throws {
        try await LinkedClient.with { c in
            let alice = c.aliceAci
            let t = try await c.send(["body": "tea?"])
            _ = try await c.send(["reaction": ["emoji": "👍", "targetAuthor": "alice", "targetSentTimestamp": t]], storesMessage: false)
            var r = try await c.messageJSON(sentAt: t)["reactions"] as? [[String: Any]]
            #expect(r?.count == 1 && r?.first?["emoji"] as? String == "👍")
            _ = try await c.send(["reaction": ["emoji": "❤️", "targetAuthor": "alice", "targetSentTimestamp": t]], storesMessage: false)
            r = try await c.messageJSON(sentAt: t)["reactions"] as? [[String: Any]]
            #expect(r?.count == 1 && r?.first?["emoji"] as? String == "❤️")
            #expect(try await c.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM reactions") } == 1)
            _ = try await c.send(["reaction": ["emoji": "❤️", "remove": true, "targetAuthor": "alice", "targetSentTimestamp": t]], storesMessage: false)
            #expect((try await c.messageJSON(sentAt: t)["reactions"] as? [Any])?.isEmpty == true)

            // A reaction before its message: kept, applied when the message arrives.
            let later = TestClock.next()
            _ = try await c.send(["reaction": ["emoji": "🫖", "targetAuthor": "alice", "targetSentTimestamp": later]], storesMessage: false)
            _ = try await c.send(["body": "late"], timestamp: later)
            #expect((try await c.messageJSON(sentAt: later)["reactions"] as? [[String: Any]])?.first?["emoji"] as? String == "🫖")

            // Someone outside our 1:1 with alice cannot react in it.
            try await c.server.call("addAccount", ["name": "bob"])
            // A first message from bob opens his session with us.
            let hi = TestClock.next()
            try await c.server.call("sendText", ["from": "bob", "text": "hi", "timestamp": hi])
            _ = try await c.log.waitFor("bob's hello") { if case .message(_, _, _, _, let t, _, _, _) = $0 { t == hi } else { false } }
            _ = try await c.send(["reaction": ["emoji": "💀", "targetAuthor": "alice", "targetSentTimestamp": t]], from: "bob", storesMessage: false)
            #expect((try await c.messageJSON(sentAt: t)["reactions"] as? [Any])?.isEmpty == true)

            // Ours: sent to alice, transcript to the phone, applied here.
            try await c.messenger.react(to: try await c.messageId(sentAt: t), emoji: "🎉")
            let m = try await c.server.json("waitForMessage", ["account": "alice"])
            let reaction = try #require(m["reaction"] as? [String: Any])
            #expect(reaction["emoji"] as? String == "🎉" && reaction["targetSentTimestamp"] as? Int == Int(t) && reaction["targetAuthor"] as? String == alice)
            let sync = try await c.server.json("waitForSyncMessage", ["kind": "sent"])
            #expect((sync["sent"] as? [String: Any])?["destination"] as? String == alice)
            #expect((try await c.messageJSON(sentAt: t)["reactions"] as? [[String: Any]])?.first?["emoji"] as? String == "🎉")

            // The phone reacts (sync): ours is replaced.
            let st = TestClock.next()
            try await c.server.callJSON("phoneSync", ["timestamp": st, "sent": ["timestamp": st, "destination": "alice",
                                                                               "message": ["reaction": ["emoji": "🍪", "targetAuthor": "alice", "targetSentTimestamp": t]]]])
            try await c.eventually("phone reaction") { db in
                try String.fetchOne(db, sql: "SELECT json FROM messages WHERE sent_at = ?", arguments: [Int64(t)])?.contains("🍪") == true
            }
        }
    }

    @Test func deleteForEveryone() async throws {
        try await LinkedClient.with { c in
            let t = try await c.send(["body": "oops"])
            try await c.server.call("addAccount", ["name": "bob"])
            // A first message from bob opens his session with us.
            let hi = TestClock.next()
            try await c.server.call("sendText", ["from": "bob", "text": "hi", "timestamp": hi])
            _ = try await c.log.waitFor("bob's hello") { if case .message(_, _, _, _, let t, _, _, _) = $0 { t == hi } else { false } }
            _ = try await c.send(["delete": ["targetSentTimestamp": t]], from: "bob", storesMessage: false)
            #expect(try await c.messageJSON(sentAt: t)["deletedForEveryone"] == nil)   // not bob's message
            _ = try await c.send(["delete": ["targetSentTimestamp": t]], storesMessage: false)
            let j = try await c.messageJSON(sentAt: t)
            #expect(j["deletedForEveryone"] as? Bool == true && j["body"] == nil)
            // Files left by erased messages go with the orphan cleanup; referenced ones stay.
            let kept = try c.attachmentStore.storeLocally(Data("kept".utf8)).path
            let orphan = try c.attachmentStore.write(Data("orphan".utf8))
            let removed = try await c.database.pool.write { db -> Int in
                try Stickers.savePackMetadata(db, packId: "p", packKey: "k")
                try db.execute(sql: "INSERT INTO stickers (id, packId, path, version, localKey, size) VALUES (1, 'p', ?, 2, 'k', 4)", arguments: [kept])
                return try c.attachmentStore.deleteOrphans(db)
            }
            #expect(removed >= 1 && (try? c.attachmentStore.read(orphan)) == nil && (try? c.attachmentStore.read(kept)) != nil)

            // Too old: outside a day plus the grace day.
            let old = try await c.send(["body": "ancient"])
            let oldId = try await c.messageId(sentAt: old)
            try await c.database.pool.write { db in
                try MessageStore.updateJSON(db, messageId: oldId) { $0["serverTimestamp"] = MessageStore.now() - 3 * 86_400_000 }
            }
            _ = try await c.send(["delete": ["targetSentTimestamp": old]], storesMessage: false)
            #expect(try await c.messageJSON(sentAt: old)["deletedForEveryone"] == nil)

            // Ours.
            let sent = try await c.messenger.sendText("regret", to: c.aliceAci)
            _ = try await c.server.json("waitForMessage", ["account": "alice"])
            try await c.messenger.deleteForEveryone(sent.messageId)
            let m = try await c.server.json("waitForMessage", ["account": "alice"])
            #expect((m["delete"] as? [String: Any])?["targetSentTimestamp"] as? Int == Int(sent.timestamp))
            #expect(try await c.messageJSON(sentAt: sent.timestamp)["deletedForEveryone"] as? Bool == true)
        }
    }

    @Test func edits() async throws {
        try await LinkedClient.with { c in
            let t = try await c.send(["body": "helo"])
            let e1 = TestClock.next()
            try await c.server.callJSON("sendEditMessage", ["timestamp": e1, "targetSentTimestamp": t, "message": ["body": "hello"]])
            try await c.eventually("edit applied") { db in try String.fetchOne(db, sql: "SELECT body FROM messages WHERE sent_at = ?", arguments: [Int64(t)]) == "hello" }
            #expect((try await c.messageJSON(sentAt: t)["editHistory"] as? [Any])?.count == 2)
            // A reaction to the edited version reaches the same message.
            _ = try await c.send(["reaction": ["emoji": "👍", "targetAuthor": "alice", "targetSentTimestamp": e1]], storesMessage: false)
            #expect((try await c.messageJSON(sentAt: t)["reactions"] as? [Any])?.count == 1)

            let sent = try await c.messenger.sendText("typo", to: c.aliceAci)
            _ = try await c.server.json("waitForMessage", ["account": "alice"])
            try await c.messenger.edit(sent.messageId, newBody: "no typo")
            let edit = try await c.server.json("waitForEdit", ["account": "alice"])
            #expect(edit["targetSentTimestamp"] as? Int == Int(sent.timestamp) && edit["body"] as? String == "no typo")
            #expect(try await c.messageJSON(sentAt: sent.timestamp)["body"] as? String == "no typo")
        }
    }

    @Test func polls() async throws {
        try await LinkedClient.with { c in
            let t = try await c.send(["pollCreate": ["question": "Tea or coffee?", "options": ["tea", "coffee", "water"], "allowMultiple": false]])
            #expect((try await c.messageJSON(sentAt: t)["poll"] as? [String: Any])?["question"] as? String == "Tea or coffee?")
            func vote(_ idx: [Int], _ count: Int) async throws {
                _ = try await c.send(["pollVote": ["targetAuthor": "alice", "targetSentTimestamp": t, "optionIndexes": idx, "voteCount": count]], storesMessage: false)
            }
            func votes() async throws -> [[String: Any]] { (try await c.messageJSON(sentAt: t)["poll"] as? [String: Any])?["votes"] as? [[String: Any]] ?? [] }
            try await vote([1], 1)
            #expect(try await votes().first?["optionIndexes"] as? [Int] == [1])
            try await vote([2], 1)                                // not newer
            #expect(try await votes().first?["optionIndexes"] as? [Int] == [1])
            try await vote([0, 2], 2)                             // two options, single choice
            try await vote([7], 3)                                // no such option
            #expect(try await votes().first?["optionIndexes"] as? [Int] == [1])
            try await vote([2], 4)
            #expect(try await votes().first?["optionIndexes"] as? [Int] == [2])

            try await c.messenger.vote(on: try await c.messageId(sentAt: t), optionIndexes: [0])
            let m = try await c.server.json("waitForMessage", ["account": "alice"])
            #expect((m["pollVote"] as? [String: Any])?["voteCount"] as? Int == 1 && (m["pollVote"] as? [String: Any])?["optionIndexes"] as? [Int] == [0])
            #expect(try await votes().count == 2)

            _ = try await c.send(["pollTerminate": ["targetSentTimestamp": t]], storesMessage: false)
            #expect((try await c.messageJSON(sentAt: t)["poll"] as? [String: Any])?["terminatedAt"] != nil)
            try await vote([1], 9)                                // ended
            #expect(try await votes().first { $0["voteCount"] as? Int == 9 } == nil)

            // Ours: a poll goes out as PollCreate.
            let ourPoll = try await c.messenger.createPoll(question: "Biscuits?", options: ["yes", "no"], allowMultiple: false,
                                                           conversationId: try await c.database.pool.write { try MessageStore.privateConversation($0, serviceId: c.aliceAci) })
            let p = try await c.server.json("waitForMessage", ["account": "alice"])
            #expect((p["pollCreate"] as? [String: Any])?["options"] as? [String] == ["yes", "no"])
            _ = ourPoll
        }
    }

    @Test func pins() async throws {
        try await LinkedClient.with { c in
            var ts: [UInt64] = []
            for i in 0..<4 { ts.append(try await c.send(["body": "msg \(i)"])) }
            for t in ts {
                _ = try await c.send(["pinMessage": ["targetAuthor": "alice", "targetSentTimestamp": t]], storesMessage: false)
            }
            let pinned = try await c.database.pool.read { db in
                try Int64.fetchAll(db, sql: "SELECT m.sent_at FROM pinnedMessages p JOIN messages m ON m.id = p.messageId ORDER BY m.sent_at")
            }
            #expect(pinned == ts.suffix(3).map { Int64($0) })   // limit 3, oldest pin dropped
            #expect(try await c.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM messages WHERE type = 'pinned-message-notification'") } == 4)
            _ = try await c.send(["unpinMessage": ["targetAuthor": "alice", "targetSentTimestamp": ts[3]]], storesMessage: false)
            #expect(try await c.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM pinnedMessages") } == 2)
            try await c.messenger.pin(try await c.messageId(sentAt: ts[0]), durationSeconds: 3600)
            let m = try await c.server.json("waitForMessage", ["account": "alice"])
            #expect((m["pinMessage"] as? [String: Any])?["targetSentTimestamp"] as? Int == Int(ts[0]))
            let firstId = try await c.messageId(sentAt: ts[0])
            let exp = try await c.database.pool.read { try Int64.fetchOne($0, sql: "SELECT expiresAt FROM pinnedMessages WHERE messageId = ?", arguments: [firstId]) }
            #expect(exp != nil)
            try await c.database.pool.write { try MessageModifiers.expirePins($0, now: MessageStore.now() + 3_700_000) }
            #expect(try await c.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM pinnedMessages") } == 2)
        }
    }

    @Test func viewOnceAndDeleteForMe() async throws {
        try await LinkedClient.with { c in
            let v1 = try await c.send(["body": "secret", "isViewOnce": true])
            #expect(try await c.messageJSON(sentAt: v1)["isViewOnce"] as? Bool == true)
            try await c.server.callJSON("phoneSync", ["timestamp": TestClock.next(), "viewOnceOpen": ["sender": "alice", "timestamp": v1]])
            try await c.eventually("erased by the phone") { db in
                try String.fetchOne(db, sql: "SELECT json FROM messages WHERE sent_at = ?", arguments: [Int64(v1)])?.contains("\"isErased\":true") == true
            }
            let v2 = try await c.send(["body": "secret 2", "isViewOnce": true])
            try await c.messenger.openViewOnce(try await c.messageId(sentAt: v2))
            #expect(try await c.messageJSON(sentAt: v2)["isErased"] as? Bool == true)
            _ = try await c.server.json("waitForSyncMessage", ["kind": "viewOnceOpen"])

            // Delete for me, both ways.
            let d1 = try await c.send(["body": "forget me"])
            try await c.server.callJSON("phoneSync", ["timestamp": TestClock.next(), "deleteForMe": ["messageDeletes": [
                ["conversation": ["serviceId": "alice"], "messages": [["author": "alice", "sentTimestamp": d1]]]]]])
            try await c.eventually("deleted by the phone") { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE sent_at = ?", arguments: [Int64(d1)]) == 0
            }
            let d2 = try await c.send(["body": "forget me too"])
            try await c.messenger.deleteForMe([try await c.messageId(sentAt: d2)])
            #expect(try await c.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM messages WHERE sent_at = ?", arguments: [Int64(d2)]) } == 0)
            _ = try await c.server.json("waitForSyncMessage", ["kind": "deleteForMe"])
        }
    }
}
