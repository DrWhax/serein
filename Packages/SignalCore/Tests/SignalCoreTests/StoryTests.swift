// Integration: stories in and out (StoryStore, StoryReceiver, Messenger+Stories) against the
// mock server — a contact's text story (kept only with profile sharing), viewing it, a group
// story, sending to a custom list and to My Story, our phone's transcript, and replies.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos
import Testing
@testable import SignalCore

struct ReceivedStory: Decodable {
    var text: String?
    var color: UInt32?
    var allowsReplies: Bool
    var hasGroup: Bool
    var hasFile: Bool
    var envelopeType: String
    var source: String?
}

struct StorySyncSummary: Decodable {
    struct Recipient: Decodable { var serviceId: String?; var lists: [String]; var isAllowedToReply: Bool }
    struct Sent: Decodable { var timestamp: UInt64; var storyText: String?; var storyRecipients: [Recipient]; var storyContext: UInt64? }
    var kind: String
    var sent: Sent?
}

extension LinkedClient {
    func receiveStory(from: String = "alice", text: String, groupId: String? = nil) async throws -> (storyId: String, timestamp: UInt64) {
        let t = TestClock.next()
        if let groupId {
            try await server.call("sendStory", ["from": from, "text": text, "timestamp": t, "groupId": groupId])
        } else {
            try await server.call("sendStory", ["from": from, "text": text, "timestamp": t])
        }
        let e = try await log.waitFor("story \(t)") { if case .story(_, _, _, t) = $0 { true } else { false } }
        guard case .story(let id, _, _, _) = e else { throw HarnessError(description: "unexpected \(e)") }
        return (id, t)
    }
    func waitForStory(_ account: String = "alice") async throws -> ReceivedStory {
        try await server.decode(ReceivedStory.self, "waitForStory", ["account": account])
    }
    func waitForStorySync(_ kind: String = "sent") async throws -> StorySyncSummary {
        try await server.decode(StorySyncSummary.self, "waitForSyncMessage", ["account": "phone", "kind": kind])
    }
    struct StoryRow: Sendable, Equatable {
        var type: String
        var expireTimer: Int?
        var expirationStartTimestamp: Int64?
        var json: String
        var conversationId: String
        var storyDistributionListId: String?
        var storyId: String?
        var body: String?
        var sentAt: Int64
    }
    func storyRow(_ id: String) async throws -> StoryRow? {
        try await database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM messages WHERE id = ?", arguments: [id]).map { r in
                StoryRow(type: r["type"], expireTimer: r["expireTimer"], expirationStartTimestamp: r["expirationStartTimestamp"], json: r["json"],
                         conversationId: r["conversationId"], storyDistributionListId: r["storyDistributionListId"], storyId: r["storyId"],
                         body: r["body"], sentAt: r["sent_at"])
            }
        }
    }
    static func text(_ s: String, color: UInt32 = 4_285_041_620) -> Signalservice_TextAttachment {
        var t = Signalservice_TextAttachment()
        t.text = s
        t.textStyle = .regular
        t.color = color
        return t
    }
}

@Suite(.serialized) struct StoryTests {
    @Test func receivesAContactsStoryAndViewsIt() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("hi", withProfileKey: true)
            try await c.acceptAlice()
            let (storyId, t) = try await c.receiveStory(text: "look at this")
            let row = try #require(try await c.storyRow(storyId))
            #expect(row.type == "story" && row.expireTimer == 86_400 && (row.expirationStartTimestamp ?? .max) <= Int64(t))
            let json = try MessageStore.jsonObject(row.json)
            let attachment = try #require((json["attachments"] as? [[String: Any]])?.first)
            #expect(attachment["contentType"] as? String == StoryStore.textAttachmentContentType)
            #expect((attachment["textAttachment"] as? [String: Any])?["text"] as? String == "look at this")
            #expect(json["canReplyToStory"] as? Bool == true)
            let listed = try await c.database.pool.read { db in try StoryStore.stories(db) }
            #expect(listed.map(\.id) == [storyId] && listed[0].sourceServiceId == c.aliceAci)

            // Viewing it: viewed state, a viewed sync, and (story view receipts on) a viewed receipt.
            try await c.database.pool.write { db in try Items.set(db, "storyViewReceiptsEnabled", true) }
            _ = try await c.waitForReceipt(to: "alice")      // the story's delivery receipt
            try await c.messenger.markStoryViewed(storyId: storyId)
            let sync = try await c.waitForSync("viewed")
            #expect(sync.viewed?.first?.timestamp == t && sync.viewed?.first?.senderAci == c.aliceAci)
            let receipt = try await c.waitForReceipt(to: "alice")
            #expect(receipt.type == "viewed" && receipt.timestamps == [t])
            let reads = try await c.database.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM storyReads WHERE storyId = ?", arguments: [storyId]) }
            #expect(reads == 1)
        }
    }

    @Test func dropsAStoryWithoutProfileSharing() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("hi")
            let t = TestClock.next()
            try await c.server.call("sendStory", ["from": "alice", "text": "not for you", "timestamp": t])
            // Processed in order: the next message arrives after the story was handled.
            try await c.receiveFromAlice("after")
            let stories = try await c.database.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE type = 'story'") }
            #expect(stories == 0)
        }
    }

    @Test func receivesAGroupStory() async throws {
        try await LinkedClient.with { c in
            let g = try await c.server.json("createGroup", ["title": "Story club"])
            let groupId = try #require(g["id"] as? String), masterKey = try #require(Data(base64Encoded: g["masterKey"] as! String))
            let (storyId, _) = try await c.receiveStory(text: "group news", groupId: groupId)
            let row = try #require(try await c.storyRow(storyId))
            let groupConversation = try await c.database.pool.write { db in try MessageStore.groupConversation(db, masterKey: masterKey).id }
            #expect(row.conversationId == groupConversation)
            let listed = try await c.database.pool.read { db in try StoryStore.stories(db) }
            #expect(listed.first?.groupId != nil)
        }
    }

    @Test func sendsToACustomListWithTranscript() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("hi", withProfileKey: true)
            let aci = c.aliceAci
            let listId = try await c.database.pool.write { db in try StoryDistributionLists.create(db, name: "Close friends", members: [aci]) }
            let ids = try await c.messenger.sendStory(.text(LinkedClient.text("hello list")), listIds: [listId])
            #expect(ids.count == 1)
            let received = try await c.waitForStory()
            #expect(received.text == "hello list"); #expect(received.allowsReplies); #expect(!received.hasGroup)   // sent on the unauthenticated socket (story=true): sealed by construction
            let sync = try await c.waitForStorySync()
            #expect(sync.sent?.storyText == "hello list")
            #expect(sync.sent?.storyRecipients.map(\.serviceId) == [aci] && sync.sent?.storyRecipients.first?.lists == [listId])
            let row = try #require(try await c.storyRow(ids[0]))
            #expect(row.storyDistributionListId == listId)
            let states = try MessageStore.jsonObject(row.json)["sendStateByConversationId"] as? [String: [String: Any]]
            #expect(states?.values.map { $0["status"] as? String } == ["Sent"])
            // The list is queued for storage.
            let needsSync = try await c.database.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT storageNeedsSync FROM storyDistributions WHERE id = ?", arguments: [listId])
            }
            #expect(needsSync == 1)
        }
    }

    @Test func myStoryGoesToSignalConnectionsAndTakesReplies() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("hi", withProfileKey: true)
            try await c.acceptAlice()
            let ids = try await c.messenger.sendStory(.text(LinkedClient.text("for everyone")), listIds: [StoryStore.myStoryId])
            let storyId = try #require(ids.first)
            let received = try await c.waitForStory()
            #expect(received.text == "for everyone")
            let sentAt = try #require(try await c.storyRow(storyId)).sentAt

            // alice replies, then reacts.
            let t1 = TestClock.next()
            try await c.server.call("sendStoryReply", ["from": "alice", "storyAuthor": c.account.aci, "storyTimestamp": sentAt, "text": "nice!", "timestamp": t1])
            let reply = try await c.log.waitFor("reply") { if case .storyReply(_, storyId, _, _) = $0 { true } else { false } }
            guard case .storyReply(let replyId, _, _, _) = reply else { return }
            let replyRow = try #require(try await c.storyRow(replyId))
            #expect(replyRow.storyId == storyId && replyRow.body == "nice!")
            let t2 = TestClock.next()
            try await c.server.call("sendStoryReply", ["from": "alice", "storyAuthor": c.account.aci, "storyTimestamp": sentAt, "emoji": "❤️", "timestamp": t2])
            try await c.eventually("reaction") { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE storyId = ? AND json ->> '$.storyReaction.emoji' = '❤️'",
                                 arguments: [storyId]) == 1
            }
        }
    }

    @Test func repliesToAContactsStory() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("hi", withProfileKey: true)
            try await c.acceptAlice()
            let (storyId, t) = try await c.receiveStory(text: "reply to me")
            let replyId = try await c.messenger.sendStoryReply(storyId: storyId, body: "love it")
            let sync = try await c.waitForStorySync()
            #expect(sync.sent?.storyContext == t)
            let row = try #require(try await c.storyRow(replyId))
            #expect(row.storyId == storyId)
        }
    }

    @Test func recipientUpdateDropsAStoryWithNobodyLeft() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("hi", withProfileKey: true)
            let aci = c.aliceAci
            let listId = try await c.database.pool.write { db in try StoryDistributionLists.create(db, name: "One", members: [aci]) }
            let ids = try await c.messenger.sendStory(.text(LinkedClient.text("soon gone")), listIds: [listId])
            _ = try await c.waitForStory()
            let sentAt = try #require(try await c.storyRow(ids[0])).sentAt
            try await c.database.pool.write { db in
                try c.receiver.applyStoryRecipientUpdate(db, timestamp: UInt64(sentAt), recipients: [])
            }
            #expect(try await c.storyRow(ids[0]) == nil)
        }
    }
}
