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

    /// `setUnregistered`: the server says the account is gone (first and discovered times).
    static func markUnregistered(_ db: Database, serviceId: String) throws {
        guard let id = try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE serviceId = ?", arguments: [serviceId]) else { return }
        let now = now()
        try updateConversationJSON(db, conversationId: id) { json in
            if json["firstUnregisteredAt"] == nil { json["firstUnregisteredAt"] = now }
            json["discoveredUnregisteredAt"] = now
        }
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
            // Only recipients still pending fail: one that already got it stays Sent (or better).
            let current = ((json["sendStateByConversationId"] as? [String: [String: Any]])?[conversationId]?["status"] as? String)
                .flatMap(SendStatus.init(rawValue:))
            guard current == nil || current == .pending || current == .failed else { return }
            setSendStatus(&json, conversationId: conversationId, .failed, force: true)
            // An identity failure recorded by this attempt says more than the generic error.
            if (json["errors"] as? [[String: Any]])?.contains(where: { $0["name"] as? String == identityKeyErrorName }) == true { return }
            json["errors"] = [["name": "SendError", "message": error]]
        }
    }

    /// A send stopped because these recipients' identity keys are not trusted: failed, with
    /// one upstream `OutgoingIdentityKeyError` per recipient (what the UI offers the safety
    /// number review for).
    static func markFailed(_ db: Database, messageId: String, untrustedIdentities serviceIds: [String]) throws {
        try markFailed(db, messageId: messageId, error: "untrusted identity")
        try updateJSON(db, messageId: messageId) { json in
            guard json["errors"] != nil else { return }
            json["errors"] = serviceIds.map { ["name": identityKeyErrorName, "serviceId": $0, "message": "The identity of \($0) has changed."] }
        }
    }

    static let identityKeyErrorName = "OutgoingIdentityKeyError"

    /// The recipients a failed message is waiting on for identity approval.
    static func untrustedRecipients(_ db: Database, messageId: String) throws -> [String] {
        guard let json = try String.fetchOne(db, sql: "SELECT json FROM messages WHERE id = ?", arguments: [messageId]) else { return [] }
        let errors = try jsonObject(json)["errors"] as? [[String: Any]] ?? []
        return errors.filter { $0["name"] as? String == identityKeyErrorName }.compactMap { $0["serviceId"] as? String }
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

    /// `addKeyChange`: the "safety number changed" notice in the contact's conversation and in
    /// every group we share with them, where the sender key is also reset so the next group
    /// send distributes a new one.
    static func insertKeyChange(_ db: Database, serviceId: String) throws {
        func notice(_ conversationId: String) throws {
            try insert(db, .init(conversationId: conversationId, type: "keychange", body: "", sentAt: UInt64(now()), source: nil, sourceDevice: nil,
                                 serverGuid: nil, serverTimestamp: nil, unidentified: false,
                                 extra: ["key_changed": serviceId, "readStatus": ReadStatus.read.rawValue, "seenStatus": SeenStatus.unseen.rawValue]))
        }
        try notice(try privateConversation(db, serviceId: serviceId))
        let groups = try String.fetchAll(db, sql: """
            SELECT conversations.id FROM conversations, json_each(conversations.json, '$.membersV2') AS m
            WHERE conversations.type = 'group' AND coalesce(json_extract(conversations.json, '$.left'), 0) = 0
              AND json_extract(m.value, '$.aci') = ?
            """, arguments: [serviceId])
        for group in groups {
            try notice(group)
            // Marked, not removed: the group sender needs the distribution id to delete our old key.
            try updateConversationJSON(db, conversationId: group) { json in
                guard var info = json["senderKeyInfo"] as? [String: Any] else { return }
                info["needsReset"] = true
                info["memberDevices"] = [[String: Any]]()
                json["senderKeyInfo"] = info
            }
        }
    }
}

/// Upstream VerifiedStatus (identityKeys.json.verified).
public enum VerifiedStatus: Int, Sendable {
    case `default` = 0, verified = 1, unverified = 2
}

extension ProtocolStore {
    static func verifiedStatus(_ db: Database, serviceId: String) throws -> VerifiedStatus {
        try identityRow(db, serviceId: serviceId)?.verifiedStatus ?? .default
    }

    /// `updateIdentityAfterSync`: a key and verification state our other devices told us about
    /// (Verified sync, ContactRecord). Coming from ourselves it needs no further approval.
    /// The caller adds the key-change notice and archives sessions when the key differs.
    static func setIdentity(_ db: Database, serviceId: String, key: IdentityKeyBytes, verified: VerifiedStatus) throws {
        let existing = try identityRow(db, serviceId: serviceId)
        let keyMatches = existing?.key.map { SignalCrypto.constantTimeEqual($0, key) } == true
        if keyMatches, existing?.verifiedStatus == verified { return }
        try save(db, IdentityRow(id: serviceId, publicKey: key.base64EncodedString(), firstUse: existing == nil, timestamp: MessageStore.now(),
                                 verified: verified.rawValue, nonblockingApproval: true))
    }

    /// `setVerified` (the user's own action): the state of the key on record. Marking it
    /// verified or unverified also counts as having seen the key.
    static func setVerified(_ db: Database, serviceId: String, _ verified: VerifiedStatus) throws {
        guard var row = try identityRow(db, serviceId: serviceId) else { throw ProtocolStoreError.missing("identity \(serviceId)") }
        row.verified = verified.rawValue
        if verified != .default {
            row.firstUse = false
            row.nonblockingApproval = true
        }
        try save(db, row)
    }

    /// `setApproval`: the user has seen the key change and wants to go on.
    static func setApproval(_ db: Database, serviceId: String, _ approved: Bool) throws {
        guard var row = try identityRow(db, serviceId: serviceId) else { throw ProtocolStoreError.missing("identity \(serviceId)") }
        row.nonblockingApproval = approved
        try save(db, row)
    }

    /// `isUntrusted`: the key was replaced within `threshold` and not approved since.
    static func isUntrusted(_ db: Database, serviceId: String, threshold: Int64 = approvalWindow) throws -> Bool {
        try identityRow(db, serviceId: serviceId)?.needsApproval(now: MessageStore.now(), threshold: threshold) ?? false
    }

    /// What `blockSendUntilConversationsAreVerified` stops a send for: unverified, or untrusted.
    static func needsApproval(_ db: Database, serviceId: String, threshold: Int64 = approvalWindow) throws -> Bool {
        guard let row = try identityRow(db, serviceId: serviceId) else { return false }
        return row.verifiedStatus == .unverified || row.needsApproval(now: MessageStore.now(), threshold: threshold)
    }
}

typealias IdentityKeyBytes = Data
