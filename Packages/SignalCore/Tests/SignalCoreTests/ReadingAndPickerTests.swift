// Reading as messages scroll into view (markConversationRead up to a message), the Timeline's
// unread counts and oldest unread mention, notices seen on their own, recent GIFs, the saved
// reaction emoji, and retrying a delete for everyone that did not go out.

import Foundation
import GRDB
import LibSignalClient
import Testing
@testable import SignalCore

@Suite struct ReadingAndPickerTests {
    /// Three unread messages, the middle one mentioning us; reading up to the second leaves the
    /// third unread (and the chat's unreadCount at 1).
    @Test func readingUpToAMessage() throws {
        let (db, _) = try LinkedClient.temporaryDatabase()
        let contact = UUID().uuidString.lowercased()
        let (chat, ids) = try db.pool.write { db throws -> (String, [String]) in
            let c = try MessageStore.privateConversation(db, serviceId: contact)
            var ids: [String] = []
            for i in 0..<3 {
                let id = try MessageStore.insert(db, .init(conversationId: c, type: "incoming", body: "m\(i)", sentAt: UInt64(1_000 + i), source: contact,
                                                           sourceDevice: 1, serverGuid: nil, serverTimestamp: nil, unidentified: false))
                if i == 1 { try db.execute(sql: "UPDATE messages SET mentionsMe = 1 WHERE id = ?", arguments: [id]) }
                ids.append(id)
            }
            return (c, ids)
        }
        #expect(try db.pool.read { try ConversationQueries.unreadCounts($0, conversationId: chat) } == .init(unread: 3, mentions: 1))
        #expect(try db.pool.read { try ConversationQueries.oldestUnreadMention($0, conversationId: chat) } == ids[1])

        let second = try db.pool.read { try Int64.fetchOne($0, sql: "SELECT received_at FROM messages WHERE id = ?", arguments: [ids[1]]) ?? 0 }
        let targets = try db.pool.write { try MessageStore.markRead($0, conversationId: chat, upTo: second) }
        #expect(targets.map(\.messageId) == [ids[0], ids[1]])
        #expect(try db.pool.read { try ConversationQueries.unreadCounts($0, conversationId: chat) } == .init(unread: 1, mentions: 0))
        #expect(try db.pool.read { try ConversationQueries.oldestUnreadMention($0, conversationId: chat) } == nil)
        let unreadCount = try db.pool.read { db in
            (try MessageStore.jsonObject(try String.fetchOne(db, sql: "SELECT json FROM conversations WHERE id = ?", arguments: [chat]) ?? "{}"))["unreadCount"]
                as? Int
        }
        #expect(unreadCount == 1)
        _ = try db.pool.write { try MessageStore.markRead($0, conversationId: chat) }
        #expect(try db.pool.read { try ConversationQueries.unreadCounts($0, conversationId: chat) } == .init(unread: 0, mentions: 0))
    }

    /// The most recent first, at most 64; removing one drops it.
    @Test func recentGifs() throws {
        let (db, _) = try LinkedClient.temporaryDatabase()
        func gif(_ i: Int) -> RecentGif {
            RecentGif(id: "g\(i)", title: "t\(i)", description: "d\(i)", previewMedia: .init(url: "https://media/p\(i).mp4", width: 100, height: 80),
                      attachmentMedia: .init(url: "https://media/a\(i).mp4", width: 400, height: 320))
        }
        try db.pool.write { db in
            for i in 0..<70 { try RecentGifs.add(db, gif(i), at: Int64(1_000 + i)) }
            try RecentGifs.add(db, gif(3), at: 5_000)          // used again: first
        }
        let all = try db.pool.read { try RecentGifs.all($0) }
        #expect(all.count == RecentGifs.limit && all.first == gif(3) && all[1] == gif(69))
        #expect(!all.contains(gif(0)))
        #expect(try db.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM recentGifs") } == RecentGifs.limit)   // the rest are gone
        try db.pool.write { try RecentGifs.remove($0, id: "g3") }
        #expect(try db.pool.read { try RecentGifs.all($0) }.first == gif(69))
    }

    /// Notices become seen without reading messages; the reaction emoji are saved (six, or
    /// refused) and synced to storage.
    @Test func noticesSeenAndReactions() async throws {
        try await LinkedClient.with { c in
            let t = try await c.send(["body": "unread"])
            let chat = try await c.database.pool.read { try String.fetchOne($0, sql: "SELECT conversationId FROM messages WHERE sent_at = ?", arguments: [Int64(t)]) ?? "" }
            try await c.database.pool.write { db in
                try ChatEventNotices.insert(db, conversationId: chat, type: "change-number-notification", sentAt: MessageStore.now(), seenStatus: .unseen)
            }
            try await c.messenger.markNoticesSeen(conversationId: chat)
            let rows = try await c.database.pool.read { try ConversationQueries.messages($0, conversationId: chat, limit: 50) }
            #expect(rows.first { $0.notice != nil }?.isUnseen == false)
            #expect(rows.first { $0.notice == nil }?.isUnseen == true)
            #expect(try await c.database.pool.read { try ConversationQueries.unreadCounts($0, conversationId: chat) }.unread == 1)

            try await c.messenger.setPreferredReactions(["👍", "❤️", "😂", "😮", "😢", "🎉"])
            #expect(try await c.database.pool.read { try Items.get($0, "preferredReactionEmoji", as: [String].self) } == ["👍", "❤️", "😂", "😮", "😢", "🎉"])
            await #expect(throws: (any Error).self) { try await c.messenger.setPreferredReactions(Array(repeating: "👍", count: 7)) }
        }
    }

    /// A delete for everyone marked as failed goes out again on retry, and the mark is cleared;
    /// with nothing failed there is nothing to retry.
    @Test func retryingAFailedDelete() async throws {
        try await LinkedClient.with { c in
            let conversation = try await c.database.pool.write { try MessageStore.privateConversation($0, serviceId: c.aliceAci) }
            let sent = try await c.messenger.sendMessage("oops", attachments: [], to: c.aliceAci)
            _ = try await c.server.json("waitForMessage", ["account": "alice"])
            try await c.messenger.deleteForEveryone(sent.messageId)
            _ = try await c.server.json("waitForMessage", ["account": "alice"])
            await #expect(throws: (any Error).self) { try await c.messenger.retryDeleteForEveryone(sent.messageId) }

            try await c.database.pool.write { try MessageStore.updateJSON($0, messageId: sent.messageId) { $0["deletedForEveryoneFailed"] = true } }
            #expect(try await c.database.pool.read { try ConversationQueries.messages($0, conversationId: conversation, limit: 50) }
                .first { $0.id == sent.messageId }?.isDeleteForEveryoneFailed == true)
            try await c.messenger.retryDeleteForEveryone(sent.messageId)
            let again = try await c.server.json("waitForMessage", ["account": "alice"])
            #expect((again["delete"] as? [String: Any])?["targetSentTimestamp"] as? Int == Int(sent.timestamp))
            #expect(try await c.database.pool.read { try ConversationQueries.messages($0, conversationId: conversation, limit: 50) }
                .first { $0.id == sent.messageId }?.isDeleteForEveryoneFailed == false)
        }
    }

    /// Reservation errors carry upstream's reasons (`reserveUsername`'s libsignal mapping), so
    /// the editor can say what is wrong.
    @Test func usernameReservationErrors() {
        let cases: [(SignalError, ReserveUsernameError)] = [
            (.nicknameTooShort(""), .notEnoughCharacters), (.nicknameCannotBeEmpty(""), .notEnoughCharacters),
            (.nicknameTooLong(""), .tooManyCharacters), (.nicknameCannotStartWithDigit(""), .checkStartingCharacter),
            (.badNicknameCharacter(""), .checkCharacters), (.usernameDiscriminatorCannotBeZero(""), .allZeroDiscriminator),
            (.usernameDiscriminatorCannotHaveLeadingZeros(""), .leadingZeroDiscriminator),
            (.usernameDiscriminatorCannotBeSingleDigit(""), .notEnoughDiscriminator), (.usernameDiscriminatorTooLarge(""), .notEnoughDiscriminator),
            (.usernameNotAvailable(""), .conflict), (.rateLimitedError(retryAfter: 1, message: ""), .tooManyAttempts),
        ]
        for (error, expected) in cases { #expect(ReserveUsernameError.from(error) == expected, "\(error)") }
        #expect(ReserveUsernameError.from(SignalError.invalidState("")) == nil)
        #expect(throws: UsernameError.reserve(.checkStartingCharacter)) {
            do { _ = try Username(nickname: "1abc", discriminator: "01", withValidLengthWithin: 3...32) } catch {
                throw ReserveUsernameError.from(error).map(UsernameError.reserve) ?? error
            }
        }
    }
}
