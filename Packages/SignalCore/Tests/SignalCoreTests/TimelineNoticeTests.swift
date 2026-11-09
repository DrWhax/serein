// The timeline carries the notices a reader must see (safety number changed, verification
// changed, delivery issue, session refreshed) between the messages, in the order they happened.

import Foundation
import GRDB
import LibSignalClient
import Testing
@testable import SignalCore

@Suite struct TimelineNoticeTests {
    @Test func noticesAppearInTheTimelineInOrder() throws {
        let (db, _) = try LinkedClient.temporaryDatabase()
        let contact = UUID().uuidString.lowercased()
        let rows = try db.pool.write { db throws -> [TimelineMessage] in
            let conversationId = try MessageStore.privateConversation(db, serviceId: contact)
            func text(_ body: String) throws {
                try MessageStore.insert(db, .init(conversationId: conversationId, type: "incoming", body: body, sentAt: UInt64(MessageStore.now()),
                                                  source: contact, sourceDevice: 1, serverGuid: nil, serverTimestamp: nil, unidentified: false))
            }
            try text("before")
            try MessageStore.insertKeyChange(db, serviceId: contact)
            try Identity.insertVerifiedChange(db, conversationId: conversationId, verified: true, local: true)
            try Identity.insertVerifiedChange(db, conversationId: conversationId, verified: false, local: false)
            try RetryPlaceholders.insertDeliveryIssue(db, conversationId: conversationId, sender: contact, receivedAt: MessageStore.now())
            try MessageStore.insert(db, .init(conversationId: conversationId, type: "chat-session-refreshed", body: "", sentAt: UInt64(MessageStore.now()),
                                              source: nil, sourceDevice: nil, serverGuid: nil, serverTimestamp: nil, unidentified: false))
            // A type the timeline does not know stays out.
            try MessageStore.insert(db, .init(conversationId: conversationId, type: "profile-change", body: "", sentAt: UInt64(MessageStore.now()),
                                              source: nil, sourceDevice: nil, serverGuid: nil, serverTimestamp: nil, unidentified: false))
            try text("after")
            return try ConversationQueries.messages(db, conversationId: conversationId, limit: 50)
        }
        #expect(rows.map(\.notice) == [
            nil, .keyChange(serviceId: contact), .verifiedChange(verified: true, local: true), .verifiedChange(verified: false, local: false),
            .deliveryIssue(sender: contact), .chatSessionRefreshed, nil,
        ])
        #expect(rows.first?.body == "before" && rows.last?.body == "after")
        // The chat list still previews the last real message, and notices do not count as unread.
        let summary = try #require(try db.pool.read { db in try ConversationQueries.inbox(db).first })
        #expect(summary.lastMessage?.body == "after" && summary.unreadCount == 2)
    }
}
