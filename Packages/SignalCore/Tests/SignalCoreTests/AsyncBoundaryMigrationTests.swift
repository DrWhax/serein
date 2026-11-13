import Foundation
import GRDB
import Testing
@testable import SignalCore

@Suite struct AsyncBoundaryMigrationTests {
    @Test func existingHistorySurvivesAndOldJobsReceiveStableLeases() throws {
        let queue = try DatabaseQueue()
        try SignalDatabase.migrator.migrate(queue, upTo: "upstream-1870")
        let message = try queue.write { db in
            let conversation = try MessageStore.privateConversation(db, serviceId: "peer")
            let id = try MessageStore.insert(db, .init(conversationId: conversation, type: "incoming", body: "keep history", sentAt: 1,
                source: "peer", sourceDevice: 1, serverGuid: nil, serverTimestamp: nil, unidentified: false))
            var a = MessageAttachment(contentType: "application/octet-stream", size: 3); a.pending = true
            let json = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
            try db.execute(sql: """
                INSERT INTO attachment_downloads
                  (messageId, attachmentType, attachmentSignature, receivedAt, sentAt, contentType, size, attachmentJson, active, attempts)
                VALUES (?, 'attachment', '.', 1, 1, 'application/octet-stream', 3, ?, 0, 0)
                """, arguments: [id, json])
            try db.execute(sql: "INSERT INTO sendLogPayloads (id, timestamp, contentHint, proto, urgent) VALUES (1, 1, 0, ?, 1)", arguments: [Data([1])])
            try db.execute(sql: "INSERT INTO sendLogRecipients (payloadId, recipientServiceId, deviceId) VALUES (1, 'peer', 1)")
            return id
        }
        try SignalDatabase.migrator.migrate(queue)
        let lease = try queue.read { db in
            #expect(try String.fetchOne(db, sql: "SELECT body FROM messages WHERE id = ?", arguments: [message]) == "keep history")
            #expect(try SendLog.answer(db, requester: "peer", deviceId: 1, timestamp: 1, answered: 0, ourAci: "me", now: 1) == .nothing)
            let job = try #require(try AttachmentDownloads.next(db, limit: 1, prioritize: [], now: 1).first)
            return try #require(job.leaseId)
        }
        #expect(!lease.isEmpty)
        try SignalDatabase.migrator.migrate(queue)
        try queue.write { db in
            #expect(try String.fetchOne(db, sql: "SELECT leaseId FROM attachment_downloads WHERE messageId = ?", arguments: [message]) == lease)
            let id = try SendLog.record(db, timestamp: 2, contentHint: 0, proto: Data([2]), urgent: false,
                recipient: "peer", devices: [1], messageIds: [], now: 2, groupId: Data([7]))
            try db.execute(sql: "DELETE FROM sendLogPayloads WHERE id = ?", arguments: [id])
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM serein_sendLogAuthorization WHERE payloadId = ?", arguments: [id]) == 0)
        }
    }
}
