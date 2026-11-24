// The timeline carries the notices a reader must see (safety number changed, verification
// changed, delivery issue, session refreshed, calls, group and timer changes) between the
// messages, in the order they happened.

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
            try MessageStore.insert(db, .init(conversationId: conversationId, type: "group-v1-migration", body: "", sentAt: UInt64(MessageStore.now()),
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

    /// Calls (with their call history), group changes (upstream's JSON) and timer changes are
    /// notices too; each starts unseen, and reading the chat makes every one of them seen.
    @Test func callsGroupAndTimerChangesAreNoticesSeenOnRead() throws {
        let (db, _) = try LinkedClient.temporaryDatabase()
        let contact = UUID().uuidString.lowercased()
        let conversationId = try db.pool.write { db throws -> String in
            let conversationId = try MessageStore.privateConversation(db, serviceId: contact)
            let call = CallDetails(callId: "123456789", peerId: contact, ringerId: contact, startedById: nil, mode: .direct, type: .video,
                                   direction: .incoming, timestamp: MessageStore.now())
            try CallHistoryStore.apply(db, CallEventDetails(details: call, event: .local(.missed), eventSource: "local", eventTimestamp: MessageStore.now()))
            var add = GroupChangeDetail("member-add")
            add.aci = contact
            _ = try GroupStore.appendChangeMessages(db, conversationId: conversationId,
                                                   [GroupChangeMessage(from: contact, details: [GroupChangeDetail("title"), add], read: false, timer: nil),
                                                    GroupChangeMessage(from: nil, details: [], read: false, timer: 3600)],
                                                   timestamp: UInt64(MessageStore.now()))
            try ConversationState.insertTimerNotification(db, conversationId: conversationId, seconds: 0, from: contact, sentAt: UInt64(MessageStore.now()))
            return conversationId
        }
        let rows = try db.pool.read { try ConversationQueries.messages($0, conversationId: conversationId, limit: 50) }
        #expect(rows.count == 4 && rows.allSatisfy(\.isUnseen))
        guard case .call(let callId, let details)? = rows.first?.notice else { Issue.record("not a call: \(String(describing: rows.first?.notice))"); return }
        #expect(callId == "123456789" && details?.status == .missed && details?.details.type == .video && details?.details.direction == .incoming)
        guard case .groupChange(let json)? = rows[1].notice else { Issue.record("not a group change"); return }
        let change = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(change["from"] as? String == contact)
        #expect((change["details"] as? [[String: Any]])?.compactMap { $0["type"] as? String } == ["title", "member-add"])
        #expect(rows[2].notice == .timerChange(seconds: 3600, source: nil, fromSync: false))
        #expect(rows[3].notice == .timerChange(seconds: 0, source: contact, fromSync: false))

        _ = try db.pool.write { try MessageStore.markRead($0, conversationId: conversationId) }
        let read = try db.pool.read { try ConversationQueries.messages($0, conversationId: conversationId, limit: 50) }
        #expect(read.count == 4 && read.allSatisfy { !$0.isUnseen })
    }
}
