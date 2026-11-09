// Story actions against the mock server: delete for everyone (the delete reaches the viewer
// as a story send, our phone gets the recipient update, the story goes here), hiding a
// contact's stories, and the story settings.

import Foundation
import GRDB
import Testing
@testable import SignalCore

@Suite(.serialized) struct StoryActionTests {
    struct DeleteMessage: Decodable {
        struct Target: Decodable { var targetSentTimestamp: UInt64 }
        var delete: Target?
        var envelopeType: String
    }

    @Test func deleteForEveryone() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("hi", withProfileKey: true)
            let aci = c.aliceAci
            let listId = try await c.database.pool.write { db in try StoryDistributionLists.create(db, name: "Close friends", members: [aci]) }
            let ids = try await c.messenger.sendStory(.text(LinkedClient.text("oops")), listIds: [listId])
            _ = try await c.waitForStory()
            let sentAt = try #require(try await c.storyRow(ids[0])).sentAt
            _ = try await c.waitForStorySync()

            try await c.messenger.deleteStoryForEveryone(storyId: ids[0])
            let deleted = try await c.server.decode(DeleteMessage.self, "waitForMessage", ["account": "alice"])
            #expect(deleted.delete?.targetSentTimestamp == UInt64(sentAt))
            let update = try await c.waitForStorySync()
            #expect(update.sent?.timestamp == UInt64(sentAt) && update.sent?.storyText == nil)
            #expect(update.sent?.storyRecipients.map(\.serviceId) == [aci] && update.sent?.storyRecipients.first?.lists == [])
            #expect(try await c.storyRow(ids[0]) == nil)
            #expect(try await c.database.pool.read { try StoryFeed.items($0) }.isEmpty)
        }
    }

    /// A list member who is no longer on Signal is dropped from the story, not counted as a
    /// failed send (upstream sendStory), and marked unregistered so My Story skips them.
    @Test func unregisteredRecipientIsDroppedNotFailed() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("hi", withProfileKey: true)
            let aci = c.aliceAci
            let gone = UUID().uuidString.lowercased()
            let listId = try await c.database.pool.write { db in
                _ = try MessageStore.privateConversation(db, serviceId: gone)
                return try StoryDistributionLists.create(db, name: "Friends", members: [aci, gone])
            }
            let ids = try await c.messenger.sendStory(.text(LinkedClient.text("still here?")), listIds: [listId])
            _ = try await c.waitForStory()
            let row = try #require(try await c.storyRow(ids[0]))
            let states = try MessageStore.jsonObject(row.json)["sendStateByConversationId"] as? [String: [String: Any]] ?? [:]
            #expect(states.count == 1 && states.values.first?["status"] as? String == "Sent")
            let item = try #require(try await c.database.pool.read { try StoryFeed.items($0) }.first { $0.id == ids[0] })
            #expect(item.sendStatuses == ["Sent"])
            #expect(try await c.database.pool.read { try StoryDistributionLists.everUnregistered($0, serviceId: gone) })
        }
    }

    @Test func hidingAContactsStories() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("hi", withProfileKey: true)
            try await c.acceptAlice()
            let (storyId, _) = try await c.receiveStory(text: "hide me")
            let conv = try #require(try await c.storyRow(storyId)).conversationId
            func hidden() async throws -> Bool? { try await c.database.pool.read { try StoryFeed.items($0) }.first { $0.id == storyId }?.isHidden }
            #expect(try await hidden() == false)
            try await c.messenger.setHideStories(conv, true)
            #expect(try await hidden() == true)
            #expect(try await c.conversationJSON(serviceId: c.aliceAci)["hideStory"] as? Bool == true)
            try await c.messenger.setHideStories(conv, false)
            #expect(try await hidden() == false)
        }
    }

    @Test func storySettings() async throws {
        try await LinkedClient.with { c in
            try await c.messenger.setStorySettings(viewReceipts: true, storiesDisabled: true)
            var s = try await c.database.pool.read { try AccountSettings.load($0) }
            #expect(s.storyViewReceipts && s.storiesDisabled)
            try await c.messenger.setStorySettings(viewReceipts: false, storiesDisabled: false)
            s = try await c.database.pool.read { try AccountSettings.load($0) }
            #expect(!s.storyViewReceipts && !s.storiesDisabled)
        }
    }
}
