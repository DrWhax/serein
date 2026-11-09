// Per-chat drafts (json.draft / draftBodyRanges / draftTimestamp) and the "unread messages"
// divider's query (oldest unread incoming message and the count), against the mock server.

import Foundation
import GRDB
import Testing
@testable import SignalCore

@Suite(.serialized) struct DraftAndUnseenTests {
    @Test func draftIsSavedAndCleared() async throws {
        try await LinkedClient.with { c in
            let aci = c.aliceAci
            let conv = try await c.database.pool.write { try MessageStore.privateConversation($0, serviceId: aci) }
            let ranges = [MessageBodyRange(start: 0, length: 1, kind: .mention(aci: aci)), MessageBodyRange(start: 2, length: 4, kind: .style(1)),
                          MessageBodyRange(start: 40, length: 2, kind: .style(2))]    // outside the body: dropped
            try await c.messenger.saveDraft(conv, body: "\u{FFFC} bold", bodyRanges: ranges)
            let summary = try #require(try await c.database.pool.read { db -> ConversationSummary? in
                let ctx = try ConversationQueries.SummaryContext(db)
                return try Row.fetchOne(db, sql: "SELECT \(ConversationQueries.summaryColumns) FROM conversations WHERE id = ?", arguments: [conv])
                    .map { try ConversationQueries.summary(db, $0, ctx, lastMessage: false) }
            })
            #expect(summary.draft == "\u{FFFC} bold")
            #expect(summary.draftBodyRanges == Array(ranges.prefix(2)))
            #expect(summary.draftTimestamp != nil)

            try await c.messenger.saveDraft(conv, body: "", bodyRanges: [])
            let json = try await c.conversationJSON(serviceId: aci)
            #expect(json["draft"] == nil && json["draftBodyRanges"] == nil && json["draftTimestamp"] == nil)
        }
    }

    @Test func unseenFindsTheOldestUnreadMessage() async throws {
        try await LinkedClient.with { c in
            let (first, _) = try await c.receiveFromAlice("one")
            _ = try await c.receiveFromAlice("two")
            let conv = try #require(try await c.database.pool.read { db in
                try String.fetchOne(db, sql: "SELECT conversationId FROM messages WHERE id = ?", arguments: [first])
            })
            let unseen = try #require(try await c.database.unseen(conversationId: conv))
            #expect(unseen.oldestId == first && unseen.count == 2)
            _ = try await c.messenger.markRead(conversationId: conv)
            #expect(try await c.database.unseen(conversationId: conv) == nil)
        }
    }
}
