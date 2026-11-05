// Message/conversation persistence in the upstream tables, with upstream JSON
// shapes (ts/model-types.d.ts MessageAttributesType / ConversationAttributesType).

import Foundation
import GRDB
import LibSignalClient
import SignalProtos

/// Upstream ReadStatus / SeenStatus (ts/messages/MessageReadStatus.std.ts, MessageSeenStatus.std.ts).
enum ReadStatus: Int { case read = 0, unread = 1, viewed = 2 }
enum SeenStatus: Int { case notApplicable = 0, unseen = 1, seen = 2 }

enum MessageStore {
    static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    static func jsonString(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    static func jsonObject(_ s: String) throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) ?? [:]
    }

    // MARK: conversations

    /// Finds or creates the private conversation for `serviceId`.
    static func privateConversation(_ db: Database, serviceId: String) throws -> String {
        if let id = try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE serviceId = ? AND type = 'private'", arguments: [serviceId]) {
            return id
        }
        let id = UUID().uuidString.lowercased()
        let json: [String: Any] = ["id": id, "type": "private", "serviceId": serviceId, "version": 2, "inbox_position": 0,
                                   "unreadCount": 0, "verified": 0, "messageCount": 0, "sentMessageCount": 0, "expireTimerVersion": 1]
        try db.execute(sql: "INSERT INTO conversations (id, json, type, serviceId, active_at) VALUES (?, ?, 'private', ?, NULL)",
                       arguments: [id, try jsonString(json), serviceId])
        return id
    }

    /// Finds or creates the group conversation for a GroupsV2 master key.
    static func groupConversation(_ db: Database, masterKey: Data) throws -> (id: String, groupId: Data) {
        let params = try GroupSecretParams.deriveFromMasterKey(groupMasterKey: GroupMasterKey(contents: masterKey))
        let groupId = try params.getPublicParams().getGroupIdentifier().serialize()
        let b64 = groupId.base64EncodedString()
        if let id = try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE groupId = ?", arguments: [b64]) { return (id, groupId) }
        let id = UUID().uuidString.lowercased()
        let json: [String: Any] = ["id": id, "type": "group", "groupId": b64, "groupVersion": 2, "masterKey": masterKey.base64EncodedString(),
                                   "secretParams": params.serialize().base64EncodedString(), "version": 2, "unreadCount": 0,
                                   "messageCount": 0, "sentMessageCount": 0, "expireTimerVersion": 1]
        try db.execute(sql: "INSERT INTO conversations (id, json, type, groupId) VALUES (?, ?, 'group', ?)", arguments: [id, try jsonString(json), b64])
        return (id, groupId)
    }

    static func touch(_ db: Database, conversationId: String, at timestamp: Int64, unread: Bool) throws {
        try db.execute(sql: "UPDATE conversations SET active_at = max(ifnull(active_at, 0), ?) WHERE id = ?", arguments: [timestamp, conversationId])
        if unread {
            try db.execute(sql: "UPDATE conversations SET json = json_set(json, '$.unreadCount', ifnull(json_extract(json, '$.unreadCount'), 0) + 1) WHERE id = ?",
                           arguments: [conversationId])
        }
    }

    static func nextReceivedAt(_ db: Database) throws -> Int64 {
        let current: Int64 = try Items.get(db, "receivedAtCounter") ?? 0
        let next = max(current + 1, now())
        try Items.set(db, "receivedAtCounter", next)
        return next
    }

    // MARK: messages

    struct Insert {
        var conversationId: String
        var type: String               // "incoming" | "outgoing"
        var body: String
        var sentAt: UInt64
        var source: String?
        var sourceDevice: UInt32?
        var serverGuid: String?
        var serverTimestamp: UInt64?
        var unidentified: Bool
        var extra: [String: Any] = [:]
    }

    @discardableResult
    static func insert(_ db: Database, _ m: Insert) throws -> String {
        let id = UUID().uuidString.lowercased()
        let receivedAt = try nextReceivedAt(db)
        let incoming = m.type == "incoming"
        var json: [String: Any] = [
            "id": id, "conversationId": m.conversationId, "type": m.type, "body": m.body, "sent_at": m.sentAt, "timestamp": m.sentAt,
            "received_at": receivedAt, "received_at_ms": now(), "attachments": [], "schemaVersion": 14,
            "readStatus": (incoming ? ReadStatus.unread : .read).rawValue, "seenStatus": (incoming ? SeenStatus.unseen : .notApplicable).rawValue,
        ]
        if let s = m.source { json["sourceServiceId"] = s }
        if let d = m.sourceDevice { json["sourceDevice"] = d }
        if let g = m.serverGuid { json["serverGuid"] = g }
        if let t = m.serverTimestamp { json["serverTimestamp"] = t }
        if incoming { json["unidentifiedDeliveryReceived"] = m.unidentified }
        json.merge(m.extra) { _, new in new }
        try db.execute(
            sql: """
                INSERT INTO messages (id, json, readStatus, seenStatus, sent_at, conversationId, received_at, type, body, sourceServiceId,
                                      serverGuid, sourceDevice, hasAttachments, hasFileAttachments, hasVisualMediaAttachments, schemaVersion)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0, 14)
                """,
            arguments: [id, try jsonString(json), json["readStatus"] as? Int, json["seenStatus"] as? Int, Int64(m.sentAt), m.conversationId,
                        receivedAt, m.type, m.body, m.source, m.serverGuid, m.sourceDevice.map { Int($0) }])
        try touch(db, conversationId: m.conversationId, at: Int64(m.sentAt), unread: incoming)
        return id
    }

    /// Duplicate detection (upstream getMessageBySender): same author + sent_at.
    static func find(_ db: Database, author: String, sentAt: UInt64) throws -> String? {
        try String.fetchOne(db, sql: "SELECT id FROM messages WHERE sourceServiceId = ? AND sent_at = ? LIMIT 1", arguments: [author, Int64(sentAt)])
    }

    /// Applies an EditMessage: the previous version moves to `editHistory`, the body is replaced,
    /// and an edited_messages row records the edit (upstream handleEditMessage).
    static func applyEdit(_ db: Database, author: String, targetSentAt: UInt64, newBody: String, editSentAt: UInt64) throws -> String? {
        guard let row = try Row.fetchOne(db, sql: "SELECT id, json, conversationId FROM messages WHERE sourceServiceId = ? AND sent_at = ?",
                                         arguments: [author, Int64(targetSentAt)]) else { return nil }
        let id: String = row["id"]
        let conversationId: String = row["conversationId"]
        var json = try jsonObject(row["json"])
        var history = json["editHistory"] as? [[String: Any]] ?? [[
            "body": json["body"] ?? "", "timestamp": json["sent_at"] ?? targetSentAt, "received_at": json["received_at"] ?? 0,
        ]]
        history.insert(["body": newBody, "timestamp": editSentAt, "received_at": try nextReceivedAt(db)], at: 0)
        json["editHistory"] = history
        json["body"] = newBody
        json["editMessageTimestamp"] = editSentAt
        json["editMessageReceivedAt"] = history[0]["received_at"]
        json["readStatus"] = ReadStatus.unread.rawValue
        try db.execute(sql: "UPDATE messages SET json = ?, body = ?, readStatus = ? WHERE id = ?",
                       arguments: [try jsonString(json), newBody, ReadStatus.unread.rawValue, id])
        try db.execute(sql: "INSERT INTO edited_messages (messageId, sentAt, readStatus, conversationId) VALUES (?, ?, ?, ?)",
                       arguments: [id, Int64(editSentAt), ReadStatus.unread.rawValue, conversationId])
        return id
    }

    /// Marks our outgoing messages to `from` as delivered/read/viewed (upstream MessageReceipts).
    static func applyReceipt(_ db: Database, kind: ReceiptKind, from: String, timestamps: [UInt64]) throws -> Int {
        let conversationId = try privateConversation(db, serviceId: from)
        let status = ["delivery": "Delivered", "read": "Read", "viewed": "Viewed"][kind.rawValue]!
        let rank = ["Delivered": 1, "Read": 2, "Viewed": 3]
        var updated = 0
        for t in timestamps {
            let rows = try Row.fetchAll(db, sql: "SELECT id, json FROM messages WHERE type = 'outgoing' AND sent_at = ?", arguments: [Int64(t)])
            for row in rows {
                var json = try jsonObject(row["json"])
                var states = json["sendStateByConversationId"] as? [String: [String: Any]] ?? [:]
                guard var state = states[conversationId] else { continue }
                if let old = state["status"] as? String, (rank[old] ?? 0) >= rank[status]! { continue }
                state["status"] = status
                state["updatedAt"] = now()
                states[conversationId] = state
                json["sendStateByConversationId"] = states
                try db.execute(sql: "UPDATE messages SET json = ? WHERE id = ?", arguments: [try jsonString(json), row["id"] as String])
                updated += 1
            }
        }
        return updated
    }
}
