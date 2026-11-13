// The upstream send log (sendLogPayloads / sendLogRecipients / sendLogMessageIds,
// ts/sql/Server.node.ts insertSentProto & getSentProtoByRecipient): every sent Content
// is kept for a day together with the devices it went to, so a DecryptionErrorMessage
// from one of those devices can be answered by re-sending the exact payload.

import Foundation
import GRDB
import SignalProtos
import Synchronization

public struct SentProto: Sendable, Equatable {
    public var id: Int64
    public var timestamp: UInt64
    public var contentHint: UInt32
    public var proto: Data
    public var urgent: Bool
    public var messageIds: [String]
    /// Nil for legacy records whose original authorization context was not retained.
    public var groupId: Data? = nil
    public var story: Bool = false

    func payload(for requester: String, device: UInt32) throws -> OutgoingPayload {
        guard let groupId else { throw JobError.permanent("resend authorization context missing") }
        var payload = OutgoingPayload(content: try Signalservice_Content(serializedBytes: proto), timestamp: timestamp,
                                      contentHint: ContentHint(rawValue: contentHint), urgent: urgent, story: story)
        payload.groupId = groupId
        payload.resendAuthorization = .init(payloadId: id, requester: requester, device: device, timestamp: timestamp)
        return payload
    }
}

public enum SendLog {
    struct Authorization: Sendable {
        let payloadId: Int64
        let requester: String
        let device: UInt32
        let timestamp: UInt64
    }

    /// Repeat the lookup at submission: receipts, retention and story-list changes can occur
    /// while the resend fetches keys or encrypts. Group authorization additionally checks membership.
    static func authorize(_ db: Database, _ snapshot: Authorization, ourAci: String) throws {
        guard try !MessageSender.isBlocked(db, serviceId: snapshot.requester) else {
            throw JobError.permanent("recipient blocked")
        }
        guard case .resend(let current) = try answer(db, requester: snapshot.requester, deviceId: snapshot.device,
            timestamp: snapshot.timestamp, answered: 0, ourAci: ourAci), current.id == snapshot.payloadId else {
            throw JobError.permanent("resend no longer authorized")
        }
    }

    /// Upstream MAX_SENT_PROTO_AGE: one day.
    public static let maxAge: Int64 = 24 * 60 * 60 * 1000

    /// Records that `proto` (sent at `timestamp`) reached `devices` of `recipient`.
    /// The same Content sent to several recipients shares one payload row.
    @discardableResult
    public static func record(_ db: Database, timestamp: UInt64, contentHint: UInt32, proto: Data, urgent: Bool, hasPniSignature: Bool = false,
                              recipient: String, devices: [UInt32], messageIds: [String], now: Int64? = nil, groupId: Data = Data(), story: Bool = false) throws -> Int64 {
        let payloadId: Int64
        if let existing = try Int64.fetchOne(db, sql: "SELECT p.id FROM sendLogPayloads p JOIN serein_sendLogAuthorization a ON a.payloadId = p.id WHERE p.timestamp = ? AND p.proto = ? AND a.groupId = ? AND a.story = ?",
                                             arguments: [Int64(timestamp), proto, groupId, story]) {
            payloadId = existing
        } else {
            try db.execute(sql: "INSERT INTO sendLogPayloads (timestamp, contentHint, proto, urgent, hasPniSignatureMessage) VALUES (?, ?, ?, ?, ?)",
                           arguments: [Int64(timestamp), Int(contentHint), proto, urgent, hasPniSignature])
            payloadId = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO serein_sendLogAuthorization (payloadId, groupId, story) VALUES (?, ?, ?)",
                           arguments: [payloadId, groupId, story])
        }
        for d in devices {
            try db.execute(sql: "INSERT OR IGNORE INTO sendLogRecipients (payloadId, recipientServiceId, deviceId) VALUES (?, ?, ?)",
                           arguments: [payloadId, recipient, Int(d)])
        }
        for m in messageIds {
            try db.execute(sql: "INSERT OR IGNORE INTO sendLogMessageIds (payloadId, messageId) VALUES (?, ?)", arguments: [payloadId, m])
        }
        try prune(db, now: now ?? MessageStore.now())
        return payloadId
    }

    /// The payload sent at `timestamp` to `recipient`'s `deviceId`, if still logged and no older
    /// than a day (upstream `getSentProtoByRecipient` prunes first); the oldest if several.
    public static func find(_ db: Database, recipient: String, deviceId: UInt32, timestamp: UInt64,
                            now: Int64? = nil) throws -> SentProto? {
        let now = now ?? MessageStore.now()
        guard let row = try Row.fetchOne(db, sql: """
            SELECT p.id, p.timestamp, p.contentHint, p.proto, p.urgent, a.groupId, a.story FROM sendLogPayloads p
            JOIN sendLogRecipients r ON r.payloadId = p.id
            LEFT JOIN serein_sendLogAuthorization a ON a.payloadId = p.id
            WHERE p.timestamp = ? AND r.recipientServiceId = ? AND r.deviceId = ? AND p.timestamp >= ?
            ORDER BY p.id LIMIT 1
            """, arguments: [Int64(timestamp), recipient, Int(deviceId), now - maxAge]) else { return nil }
        let id: Int64 = row["id"]
        let ids = try String.fetchAll(db, sql: "SELECT messageId FROM sendLogMessageIds WHERE payloadId = ?", arguments: [id])
        return SentProto(id: id, timestamp: UInt64(row["timestamp"] as Int64), contentHint: UInt32(row["contentHint"] as Int),
                         proto: row["proto"], urgent: (row["urgent"] as Bool?) ?? true, messageIds: ids, groupId: row["groupId"], story: (row["story"] as Bool?) ?? false)
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

    // MARK: answering a retry request (upstream `onRetryRequest`)

    /// Upstream RETRY_LIMIT: one (requester, device, timestamp) is answered at most this often.
    public static let retryLimit = 5

    public enum ResendAnswer: Equatable, Sendable {
        /// Send this logged payload again, to the requester only (and still through
        /// `MessageSender.authorization`: not to a blocked contact, nothing naming a removed message).
        case resend(SentProto)
        /// Nothing logged for that device and time (or no longer): a NullMessage, which carries
        /// nothing, starts the new session.
        case nullMessage
        /// Answered too often already, or a story the requester may no longer see: nothing.
        case nothing
    }

    /// The decision for a DecryptionErrorMessage from `requester`'s `deviceId` about our message
    /// sent at `timestamp`, asked `answered` times before. **The send log is the boundary**: only
    /// a payload logged as delivered to that very device at that timestamp, within a day, goes
    /// back, and only to the requester; a story only while the requester is still in a list it
    /// was sent to.
    public static func answer(_ db: Database, requester: String, deviceId: UInt32, timestamp: UInt64, answered: Int, ourAci: String,
                              now: Int64? = nil) throws -> ResendAnswer {
        guard answered < retryLimit else { return .nothing }
        guard let logged = try find(db, recipient: requester, deviceId: deviceId, timestamp: timestamp, now: now) else { return .nullMessage }
        // Old log rows cannot distinguish a direct send from a group-key distribution.
        // Keep them for receipt/pruning bookkeeping, but never resend without their context.
        guard logged.groupId != nil else { return .nothing }
        // A story to distribution lists (a group's story goes to its members like a group message).
        if case .storyMessage(let story)? = (try? Signalservice_Content(serializedBytes: logged.proto))?.content, !story.hasGroup,
           try !storyListed(db, requester: requester, timestamp: timestamp, ourAci: ourAci) {
            return .nothing
        }
        return .resend(logged)
    }

    /// `checkDistributionListAndAddSKDM`: one of our stories sent at `timestamp` went to a list
    /// that still has `requester` as a member. (Stricter for My Story as a block list, whose
    /// members are the excluded: never.)
    static func storyListed(_ db: Database, requester: String, timestamp: UInt64, ourAci: String) throws -> Bool {
        let lists = try String.fetchAll(db, sql: """
            SELECT storyDistributionListId FROM messages WHERE type = 'story' AND sourceServiceId = ? AND sent_at = ? AND storyDistributionListId IS NOT NULL
            """, arguments: [ourAci, Int64(timestamp)])
        return try lists.contains { id in
            guard let list = try StoryDistributionLists.list(db, id: id) else { return false }
            return !list.isBlockList && list.deletedAt == nil && list.members.contains(requester)
        }
    }

    static func prune(_ db: Database, now: Int64) throws {
        try db.execute(sql: "DELETE FROM sendLogPayloads WHERE timestamp < ?", arguments: [now - maxAge])
    }
}

/// How often each (requester, device, timestamp) has asked for a resend (upstream keeps this in
/// memory too: `retryRecord`).
public final class RetryLimiter: Sendable {
    let counts = Mutex<[String: Int]>([:])

    public init() {}

    /// The number of earlier requests; counts this one.
    public func count(requester: String, deviceId: UInt32, timestamp: UInt64) -> Int {
        counts.withLock { c in
            let key = "\(requester).\(deviceId):\(timestamp)"
            let n = c[key, default: 0]
            c[key] = n + 1
            return n
        }
    }
}
