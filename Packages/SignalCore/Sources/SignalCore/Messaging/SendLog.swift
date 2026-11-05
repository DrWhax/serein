// The upstream send log (sendLogPayloads / sendLogRecipients / sendLogMessageIds,
// ts/sql/Server.node.ts insertSentProto & getSentProtoByRecipient): every sent Content
// is kept for a day together with the devices it went to, so a DecryptionErrorMessage
// from one of those devices can be answered by re-sending the exact payload.

import Foundation
import GRDB

public struct SentProto: Sendable, Equatable {
    public var id: Int64
    public var timestamp: UInt64
    public var contentHint: UInt32
    public var proto: Data
    public var urgent: Bool
    public var messageIds: [String]
}

public enum SendLog {
    /// Upstream MAX_SENT_PROTO_AGE: one day.
    public static let maxAge: Int64 = 24 * 60 * 60 * 1000

    /// Records that `proto` (sent at `timestamp`) reached `devices` of `recipient`.
    /// The same Content sent to several recipients shares one payload row.
    @discardableResult
    public static func record(_ db: Database, timestamp: UInt64, contentHint: UInt32, proto: Data, urgent: Bool, hasPniSignature: Bool = false,
                              recipient: String, devices: [UInt32], messageIds: [String]) throws -> Int64 {
        let payloadId: Int64
        if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM sendLogPayloads WHERE timestamp = ? AND proto = ?",
                                             arguments: [Int64(timestamp), proto]) {
            payloadId = existing
        } else {
            try db.execute(sql: "INSERT INTO sendLogPayloads (timestamp, contentHint, proto, urgent, hasPniSignatureMessage) VALUES (?, ?, ?, ?, ?)",
                           arguments: [Int64(timestamp), Int(contentHint), proto, urgent, hasPniSignature])
            payloadId = db.lastInsertedRowID
        }
        for d in devices {
            try db.execute(sql: "INSERT OR IGNORE INTO sendLogRecipients (payloadId, recipientServiceId, deviceId) VALUES (?, ?, ?)",
                           arguments: [payloadId, recipient, Int(d)])
        }
        for m in messageIds {
            try db.execute(sql: "INSERT OR IGNORE INTO sendLogMessageIds (payloadId, messageId) VALUES (?, ?)", arguments: [payloadId, m])
        }
        try prune(db, now: MessageStore.now())
        return payloadId
    }

    /// The payload sent at `timestamp` to `recipient`'s `deviceId`, if still logged.
    public static func find(_ db: Database, recipient: String, deviceId: UInt32, timestamp: UInt64) throws -> SentProto? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT p.id, p.timestamp, p.contentHint, p.proto, p.urgent FROM sendLogPayloads p
            JOIN sendLogRecipients r ON r.payloadId = p.id
            WHERE p.timestamp = ? AND r.recipientServiceId = ? AND r.deviceId = ?
            """, arguments: [Int64(timestamp), recipient, Int(deviceId)]) else { return nil }
        let id: Int64 = row["id"]
        let ids = try String.fetchAll(db, sql: "SELECT messageId FROM sendLogMessageIds WHERE payloadId = ?", arguments: [id])
        return SentProto(id: id, timestamp: UInt64(row["timestamp"] as Int64), contentHint: UInt32(row["contentHint"] as Int),
                         proto: row["proto"], urgent: (row["urgent"] as Bool?) ?? true, messageIds: ids)
    }

    /// Removes one recipient device after it confirmed (delivery receipt) or after a resend.
    public static func deleteRecipient(_ db: Database, recipient: String, deviceId: UInt32, timestamp: UInt64) throws {
        try db.execute(sql: """
            DELETE FROM sendLogRecipients WHERE recipientServiceId = ? AND deviceId = ?
              AND payloadId IN (SELECT id FROM sendLogPayloads WHERE timestamp = ?)
            """, arguments: [recipient, Int(deviceId), Int64(timestamp)])
        try db.execute(sql: "DELETE FROM sendLogPayloads WHERE timestamp = ? AND id NOT IN (SELECT payloadId FROM sendLogRecipients)",
                       arguments: [Int64(timestamp)])
    }

    static func prune(_ db: Database, now: Int64) throws {
        try db.execute(sql: "DELETE FROM sendLogPayloads WHERE timestamp < ?", arguments: [now - maxAge])
    }
}
