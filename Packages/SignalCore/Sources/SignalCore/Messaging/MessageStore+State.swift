// Message/conversation state transitions for the send side and for read/viewed state
// (upstream sendStateByConversationId, readStatus/seenStatus, keychange notifications).

import Foundation
import GRDB

/// Upstream SendStatus order (ts/messages/MessageSendState.std.ts).
enum SendStatus: String {
    case failed = "Failed", pending = "Pending", sent = "Sent", delivered = "Delivered", read = "Read", viewed = "Viewed"
    var rank: Int {
        switch self {
        case .failed: 0
        case .pending: 1
        case .sent: 2
        case .delivered: 3
        case .read: 4
        case .viewed: 5
        }
    }
}

extension MessageStore {
    static func updateJSON(_ db: Database, messageId: String, _ change: (inout [String: Any]) throws -> Void) throws {
        guard let s = try String.fetchOne(db, sql: "SELECT json FROM messages WHERE id = ?", arguments: [messageId]) else { return }
        var json = try jsonObject(s)
        try change(&json)
        try db.execute(sql: "UPDATE messages SET json = ? WHERE id = ?", arguments: [try jsonString(json), messageId])
    }

    static func updateConversationJSON(_ db: Database, conversationId: String, _ change: (inout [String: Any]) throws -> Void) throws {
        guard let s = try String.fetchOne(db, sql: "SELECT json FROM conversations WHERE id = ?", arguments: [conversationId]) else { return }
        var json = try jsonObject(s)
        try change(&json)
        try db.execute(sql: "UPDATE conversations SET json = ? WHERE id = ?", arguments: [try jsonString(json), conversationId])
    }

    static func setSendStatus(_ json: inout [String: Any], conversationId: String, _ status: SendStatus, force: Bool = false) {
        var states = json["sendStateByConversationId"] as? [String: [String: Any]] ?? [:]
        var state = states[conversationId] ?? [:]
        let old = (state["status"] as? String).flatMap(SendStatus.init(rawValue:))
        if !force, let old, old.rank >= status.rank { return }
        state["status"] = status.rawValue
        state["updatedAt"] = now()
        states[conversationId] = state
        json["sendStateByConversationId"] = states
    }

    /// (body, sent_at, recipient service id) of an outgoing 1:1 message.
    static func outgoingText(_ db: Database, messageId: String) throws -> (String, UInt64, String)? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT m.body, m.sent_at, c.serviceId FROM messages m JOIN conversations c ON c.id = m.conversationId
            WHERE m.id = ? AND m.type = 'outgoing' AND c.type = 'private'
            """, arguments: [messageId]), let serviceId: String = row["serviceId"] else { return nil }
        return ((row["body"] as String?) ?? "", UInt64(row["sent_at"] as Int64), serviceId)
    }

    static func markSent(_ db: Database, messageId: String, conversationId: String, unidentified: [String]) throws {
        try updateJSON(db, messageId: messageId) { json in
            setSendStatus(&json, conversationId: conversationId, .sent)
            json["unidentifiedDeliveries"] = unidentified
            json["errors"] = nil
        }
    }

    static func markFailed(_ db: Database, messageId: String, error: String) throws {
        try updateJSON(db, messageId: messageId) { json in
            guard let conversationId = json["conversationId"] as? String else { return }
            setSendStatus(&json, conversationId: conversationId, .failed, force: true)
            json["errors"] = [["name": "SendError", "message": error]]
        }
    }

    /// Marks unread incoming messages read and seen; returns them as receipt targets.
    static func markRead(_ db: Database, conversationId: String) throws -> [ReceiptTarget] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, sourceServiceId, sent_at FROM messages
            WHERE conversationId = ? AND type = 'incoming' AND readStatus = ? ORDER BY received_at
            """, arguments: [conversationId, ReadStatus.unread.rawValue])
        var targets: [ReceiptTarget] = []
        try ConversationState.startTimers(db, messageIds: rows.map { $0["id"] }, at: now())
        for row in rows {
            let id: String = row["id"]
            try setRead(db, messageId: id, .read)
            if let sender: String = row["sourceServiceId"] {
                targets.append(ReceiptTarget(messageId: id, conversationId: conversationId, senderAci: sender, timestamp: UInt64(row["sent_at"] as Int64)))
            }
        }
        try updateConversationJSON(db, conversationId: conversationId) { $0["unreadCount"] = 0 }
        return targets
    }

    static func markViewed(_ db: Database, messageId: String) throws -> ReceiptTarget? {
        guard let row = try Row.fetchOne(db, sql: "SELECT conversationId, sourceServiceId, sent_at, type FROM messages WHERE id = ?", arguments: [messageId]),
              row["type"] as String? == "incoming", let sender: String = row["sourceServiceId"] else { return nil }
        try setRead(db, messageId: messageId, .viewed)
        return ReceiptTarget(messageId: messageId, conversationId: row["conversationId"], senderAci: sender, timestamp: UInt64(row["sent_at"] as Int64))
    }

    static func setRead(_ db: Database, messageId: String, _ status: ReadStatus) throws {
        try updateJSON(db, messageId: messageId) { json in
            json["readStatus"] = status.rawValue
            json["seenStatus"] = SeenStatus.seen.rawValue
        }
        try db.execute(sql: "UPDATE messages SET readStatus = ?, seenStatus = ? WHERE id = ?",
                       arguments: [status.rawValue, SeenStatus.seen.rawValue, messageId])
    }

    /// Applies a read or viewed sync from another of our devices (no receipts are sent).
    static func applyReadSync(_ db: Database, sender: String, timestamp: UInt64, viewed: Bool) throws -> String? {
        guard let id = try find(db, author: sender, sentAt: timestamp) else { return nil }
        try setRead(db, messageId: id, viewed ? .viewed : .read)
        try ConversationState.startTimers(db, messageIds: [id], at: now())
        if let conversationId = try String.fetchOne(db, sql: "SELECT conversationId FROM messages WHERE id = ?", arguments: [id]) {
            let unread = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE conversationId = ? AND type = 'incoming' AND readStatus = ?",
                                          arguments: [conversationId, ReadStatus.unread.rawValue]) ?? 0
            try updateConversationJSON(db, conversationId: conversationId) { $0["unreadCount"] = unread }
        }
        return id
    }

    /// `enableProfileSharing` (not via storage sync): a change is captured for storage.
    static func setProfileSharing(_ db: Database, conversationId: String) throws {
        var changed = false
        try updateConversationJSON(db, conversationId: conversationId) { json in
            changed = json["profileSharing"] as? Bool != true
            json["profileSharing"] = true
        }
        if changed { try StorageWriteBack.conversationChanged(db, conversationId: conversationId) }
    }

    /// Stores a contact's profile key (DataMessage.profileKey, contact/storage sync).
    /// A new key resets the sealed-sender state, as upstream setProfileKey does.
    @discardableResult
    static func setProfileKey(_ db: Database, serviceId: String, _ key: Data) throws -> Bool {
        guard key.count == 32 else { return false }
        let conversationId = try privateConversation(db, serviceId: serviceId)
        var changed = false
        try updateConversationJSON(db, conversationId: conversationId) { json in
            let b64 = key.base64EncodedString()
            guard json["profileKey"] as? String != b64 else { return }
            json["profileKey"] = b64
            json["sealedSender"] = SealedSenderMode.unknown.rawValue
            json["profileKeyCredential"] = nil
            changed = true
        }
        return changed
    }

    /// "Safety number changed" notification (upstream message type `keychange`).
    static func insertKeyChange(_ db: Database, serviceId: String) throws {
        let conversationId = try privateConversation(db, serviceId: serviceId)
        try insert(db, .init(conversationId: conversationId, type: "keychange", body: "", sentAt: UInt64(now()), source: nil, sourceDevice: nil,
                             serverGuid: nil, serverTimestamp: nil, unidentified: false, extra: ["key_changed": serviceId]))
    }
}

/// Upstream VerifiedStatus (identityKeys.json.verified).
public enum VerifiedStatus: Int, Sendable {
    case `default` = 0, verified = 1, unverified = 2
}

extension ProtocolStore {
    static func verifiedStatus(_ db: Database, serviceId: String) throws -> VerifiedStatus {
        guard let json = try String.fetchOne(db, sql: "SELECT json FROM identityKeys WHERE id = ?", arguments: [serviceId]) else { return .default }
        return VerifiedStatus(rawValue: try MessageStore.jsonObject(json)["verified"] as? Int ?? 0) ?? .default
    }

    /// Records an identity key with a verification state (ContactRecord.identityKey/identityState).
    static func setIdentity(_ db: Database, serviceId: String, key: IdentityKeyBytes, verified: VerifiedStatus) throws {
        let existing = try String.fetchOne(db, sql: "SELECT json FROM identityKeys WHERE id = ?", arguments: [serviceId]).map { try MessageStore.jsonObject($0) }
        let sameKey = existing?["publicKey"] as? String == key.base64EncodedString()
        let json: [String: Any] = [
            "id": serviceId, "publicKey": key.base64EncodedString(), "firstUse": existing == nil,
            "timestamp": sameKey ? (existing?["timestamp"] ?? MessageStore.now()) : MessageStore.now(),
            "verified": verified.rawValue, "nonblockingApproval": existing?["nonblockingApproval"] ?? false,
        ]
        try db.execute(sql: "INSERT INTO identityKeys (id, json) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json",
                       arguments: [serviceId, try MessageStore.jsonString(json)])
    }
}

typealias IdentityKeyBytes = Data
