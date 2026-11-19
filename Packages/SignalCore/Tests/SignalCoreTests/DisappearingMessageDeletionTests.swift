// A disappearing message leaves the local database when its timer runs out: the row, its
// full-text index entry, attachment rows and reactions, and (on the orphan pass) its file.

import Foundation
import GRDB
import Testing
@testable import SignalCore

@Suite struct DisappearingMessageDeletionTests {
    @Test func expiredMessageIsGoneFromTheDatabaseAndDisk() async throws {
        let (database, url) = try LinkedClient.temporaryDatabase()
        let root = url.appendingPathExtension("attachments")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentStore(root: root)
        let stored = try store.storeLocally(Data("photo bytes".utf8))
        let fileURL = try store.url(stored.path)

        let (id, keep) = try await database.pool.write { db -> (String, String) in
            let peer = UUID().uuidString.lowercased()
            let conversation = try MessageStore.privateConversation(db, serviceId: peer)
            func insert(_ body: String, sentAt: UInt64) throws -> String {
                try MessageStore.insert(db, .init(conversationId: conversation, type: "incoming", body: body, sentAt: sentAt,
                                                  source: peer, sourceDevice: 1, serverGuid: nil, serverTimestamp: nil, unidentified: false))
            }
            let id = try insert("meet at the old lighthouse", sentAt: 100)
            let keep = try insert("lighthouse photos later", sentAt: 200)     // no timer: stays
            // 60 s, read at 1000: expiresAt (derived by the schema) is 61000.
            try db.execute(sql: "UPDATE messages SET expireTimer = 60, expirationStartTimestamp = 1000 WHERE id = ?", arguments: [id])
            var a = MessageAttachment(contentType: "image/jpeg", size: 11)
            a.path = stored.path
            a.localKey = stored.localKey.base64EncodedString()
            try MessageAttachments.upsert(db, .init(messageId: id, type: .attachment, order: 0), conversationId: conversation,
                                          sentAt: 100, receivedAt: 100, messageType: "incoming", a)
            try db.execute(sql: "INSERT INTO reactions (conversationId, emoji, fromId, messageId, timestamp) VALUES (?, '❤️', ?, ?, 1)",
                           arguments: [conversation, peer, id])
            return (id, keep)
        }

        func count(_ sql: String, _ args: StatementArguments = []) async throws -> Int {
            try await database.pool.read { try Int.fetchOne($0, sql: sql, arguments: args) ?? 0 }
        }
        func traces() async throws -> [String: Int] {
            [
                "messages": try await count("SELECT count(*) FROM messages WHERE id = ?", [id]),
                "fts": try await count("SELECT count(*) FROM messages_fts WHERE messages_fts MATCH 'meet'"),
                "attachments": try await count("SELECT count(*) FROM message_attachments WHERE messageId = ?", [id]),
                "reactions": try await count("SELECT count(*) FROM reactions WHERE messageId = ?", [id]),
            ]
        }

        let maintenance = Maintenance(database: database, store: store, keyTransparency: nil)
        // Before the timer runs out, everything is there.
        #expect(try await maintenance.runOnce(now: 60_999, cleanOrphans: false).expiredMessages == 0)
        #expect(try await traces() == ["messages": 1, "fts": 1, "attachments": 1, "reactions": 1])

        // The periodic pass: the message and everything referring to it go.
        #expect(try await maintenance.runOnce(now: 61_000, cleanOrphans: false).expiredMessages == 1)
        #expect(try await traces() == ["messages": 0, "fts": 0, "attachments": 0, "reactions": 0])
        #expect(try await count("SELECT count(*) FROM messages WHERE body LIKE '%old lighthouse%' OR json LIKE '%old lighthouse%'") == 0)
        // The other message in the chat is untouched (and still searchable).
        #expect(try await count("SELECT count(*) FROM messages WHERE id = ?", [keep]) == 1)
        #expect(try await count("SELECT count(*) FROM messages_fts WHERE messages_fts MATCH 'photos'") == 1)

        // Its attachment file goes on the orphan pass (run at startup).
        #expect(try await maintenance.cleanOrphans() == 1)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }
}
