// Changes that target an existing message (ts/messageModifiers/*): reactions, delete for
// everyone (and admin delete), edits, poll votes and terminations, pins, view-once opens.
//
// A modifier names its target by (author ACI, sent timestamp); an edited message also answers
// to the timestamps of its edits (`getMessageSentTimestampSet`). A modifier whose target has
// not arrived yet is kept (upstream keeps it in memory with its envelope in the receive cache;
// here it is persisted, for 48 hours, at most 500) and applied when the target is stored.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos
import SignalText

public enum ModifierSource: String, Codable, Sendable {
    /// Someone else's message.
    case someoneElse
    /// SyncMessage.Sent from another of our devices.
    case sync
    /// Made on this device.
    case thisDevice
}

/// The message carrying a modifier.
struct ModifierContext: Codable, Sendable {
    var sender: String
    var timestamp: UInt64
    var serverTimestamp: UInt64
    /// The conversation the modifier was sent in (a group, or the 1:1 with the sender / the
    /// sync's destination).
    var conversationId: String
    var source: ModifierSource
}

struct PendingModifier: Codable, Sendable {
    enum Kind: String, Codable { case reaction, delete, adminDelete, edit, pollVote, pollTerminate, pin, unpin, viewOnceOpen }
    var kind: Kind
    var targetAuthor: String
    var targetSentAt: UInt64
    var context: ModifierContext
    /// The modifier's proto (Reaction, EditMessage, …), serialized.
    var payload: Data
    var storedAt: Int64
}

enum MessageModifiers {
    static let pendingKey = "pendingMessageModifiers"
    static let pendingLimit = 500
    static let pendingMaxAge: Int64 = 48 * 3_600_000

    struct Target {
        var id: String
        var conversationId: String
        var type: String
        var sentAt: Int64
        var serverTimestamp: Int64?
        var json: [String: Any]
        var deletedForEveryone: Bool { json["deletedForEveryone"] as? Bool ?? false }
    }

    /// `findMessageModifierTarget`: by author and any of the message's sent timestamps.
    static func target(_ db: Database, author: String, sentAt: UInt64) throws -> Target? {
        let row = try Row.fetchOne(db, sql: """
            SELECT id, conversationId, type, sent_at, json FROM messages WHERE sourceServiceId = ? AND sent_at = ?
            UNION ALL
            SELECT m.id, m.conversationId, m.type, m.sent_at, m.json FROM edited_messages e JOIN messages m ON m.id = e.messageId
            WHERE m.sourceServiceId = ? AND e.sentAt = ?
            LIMIT 1
            """, arguments: [author, Int64(sentAt), author, Int64(sentAt)])
        guard let row else { return nil }
        let json = try MessageStore.jsonObject(row["json"])
        return Target(id: row["id"], conversationId: row["conversationId"], type: row["type"], sentAt: row["sent_at"],
                      serverTimestamp: (json["serverTimestamp"] as? NSNumber)?.int64Value, json: json)
    }

    // MARK: pending

    static func keep(_ db: Database, _ p: PendingModifier) throws {
        var list = try Items.get(db, pendingKey, as: [PendingModifier].self) ?? []
        let now = MessageStore.now()
        list.removeAll { now - $0.storedAt > pendingMaxAge }
        list.append(p)
        if list.count > pendingLimit { list.removeFirst(list.count - pendingLimit) }
        try Items.set(db, pendingKey, list)
    }

    /// Applies the modifiers that were waiting for this message (author, sent_at).
    static func applyPending(_ db: Database, author: String, sentAt: UInt64, ourAci: String) throws {
        guard var list = try Items.get(db, pendingKey, as: [PendingModifier].self), !list.isEmpty else { return }
        let matching = list.filter { $0.targetAuthor == author && $0.targetSentAt == sentAt }
        guard !matching.isEmpty else { return }
        list.removeAll { $0.targetAuthor == author && $0.targetSentAt == sentAt }
        try Items.set(db, pendingKey, list)
        for p in matching.sorted(by: { $0.context.timestamp < $1.context.timestamp }) {
            _ = try apply(db, p, ourAci: ourAci, keepIfMissing: false)
        }
    }

    /// Runs a modifier now, or keeps it until its target arrives. Returns the target's id.
    @discardableResult
    static func apply(_ db: Database, _ p: PendingModifier, ourAci: String, keepIfMissing: Bool = true) throws -> String? {
        guard let t = try target(db, author: p.targetAuthor, sentAt: p.targetSentAt) else {
            if keepIfMissing { try keep(db, p) }
            return nil
        }
        let ok: Bool
        switch p.kind {
        case .reaction: ok = try applyReaction(db, t, try Signalservice_DataMessage.Reaction(serializedBytes: p.payload), p.context, ourAci: ourAci)
        case .delete: ok = try applyDelete(db, t, p.context, admin: false, ourAci: ourAci)
        case .adminDelete: ok = try applyDelete(db, t, p.context, admin: true, ourAci: ourAci)
        case .edit: ok = try applyEdit(db, t, try Signalservice_EditMessage(serializedBytes: p.payload), p.context, ourAci: ourAci)
        case .pollVote: ok = try applyPollVote(db, t, try Signalservice_DataMessage.PollVote(serializedBytes: p.payload), p.context, ourAci: ourAci)
        case .pollTerminate: ok = try applyPollTerminate(db, t, p.context, ourAci: ourAci)
        case .pin: ok = try applyPin(db, t, try Signalservice_DataMessage.PinMessage(serializedBytes: p.payload), p.context, ourAci: ourAci)
        case .unpin: ok = try applyUnpin(db, t, p.context, ourAci: ourAci)
        case .viewOnceOpen: ok = try eraseViewOnce(db, t)
        }
        return ok ? t.id : nil
    }

    // MARK: checks

    /// `isValidSenderAciForConversation`: a contact can only act in our 1:1 with them, a group
    /// member in their group; we can act anywhere.
    static func senderBelongs(_ db: Database, sender: String, conversationId: String, ourAci: String) throws -> Bool {
        if sender == ourAci { return true }
        if let g = try GroupStore.load(db, conversationId: conversationId) { return g.state?.isMember(sender) ?? false }
        return try String.fetchOne(db, sql: "SELECT serviceId FROM conversations WHERE id = ?", arguments: [conversationId]) == sender
    }

    static func isBlocked(_ db: Database, conversationId: String, sender: String) throws -> Bool {
        if try BlockedList.serviceIds.blockedAt(db, sender).blocked { return true }
        guard let row = try Row.fetchOne(db, sql: "SELECT type, serviceId, groupId FROM conversations WHERE id = ?", arguments: [conversationId]) else { return false }
        if let g: String = row["groupId"] { return try BlockedList.groups.blockedAt(db, g).blocked }
        if let s: String = row["serviceId"] { return try BlockedList.serviceIds.blockedAt(db, s).blocked }
        return false
    }

    /// For our outgoing target: the reacting contact must have been sent it (`isSent`).
    static func wasSent(_ t: Target, to conversationId: String) -> Bool {
        let states = t.json["sendStateByConversationId"] as? [String: [String: Any]] ?? [:]
        guard let status = states[conversationId]?["status"] as? String else { return false }
        return ["Sent", "Delivered", "Read", "Viewed"].contains(status)
    }

    static func conversationOf(_ db: Database, sender: String) throws -> String { try MessageStore.privateConversation(db, serviceId: sender) }

    // MARK: reactions (Reactions.preload.ts handleReaction)

    static func applyReaction(_ db: Database, _ t: Target, _ r: Signalservice_DataMessage.Reaction, _ c: ModifierContext, ourAci: String) throws -> Bool {
        guard !t.deletedForEveryone, !(t.json["isViewOnce"] as? Bool ?? false) else { return false }
        if c.sender != ourAci {
            guard t.conversationId == c.conversationId, try senderBelongs(db, sender: c.sender, conversationId: t.conversationId, ourAci: ourAci),
                  try !isBlocked(db, conversationId: t.conversationId, sender: c.sender) else { return false }
            if t.type == "outgoing", !wasSent(t, to: try conversationOf(db, sender: c.sender)) { return false }
        }
        let fromId = try conversationOf(db, sender: c.sender)
        var reactions = t.json["reactions"] as? [[String: Any]] ?? []
        let previous = reactions.first { $0["fromId"] as? String == fromId }
        // A sync never replaces a newer reaction of ours.
        if c.source == .sync, let prev = previous, (prev["timestamp"] as? NSNumber)?.uint64Value ?? 0 > c.timestamp { return false }
        reactions.removeAll { $0["fromId"] as? String == fromId }
        if !r.remove {
            reactions.append(["emoji": r.emoji, "fromId": fromId, "targetAuthorAci": t.json["sourceServiceId"] ?? "", "targetTimestamp": t.sentAt,
                              "timestamp": c.timestamp])
        }
        try MessageStore.updateJSON(db, messageId: t.id) { $0["reactions"] = reactions }
        try db.execute(sql: "DELETE FROM reactions WHERE messageId = ? AND fromId = ?", arguments: [t.id, fromId])
        if !r.remove {
            let receivedAt = try Int64.fetchOne(db, sql: "SELECT received_at FROM messages WHERE id = ?", arguments: [t.id]) ?? 0
            // Unread: someone else reacting to one of our messages (notifications).
            let unread = c.sender != ourAci && t.type == "outgoing"
            try db.execute(sql: """
                INSERT INTO reactions (conversationId, emoji, fromId, messageReceivedAt, targetAuthorAci, targetTimestamp, unread, messageId, timestamp)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [t.conversationId, r.emoji, fromId, receivedAt, t.json["sourceServiceId"] as? String, t.sentAt, unread ? 1 : 0, t.id,
                                 Int64(c.timestamp)])
        }
        return true
    }

    // MARK: delete for everyone (canReceiveDeleteForEveryone + applyDeleteForEveryone)

    static let deleteGracePeriod: Int64 = 86_400_000

    static func deleteMaxAge(_ db: Database, admin: Bool) throws -> Int64 {
        let key = admin ? "global.adminDeleteMaxAgeInSeconds" : "global.normalDeleteMaxAgeInSeconds"
        if let s = try RemoteConfig.int(db, key), s > 0 { return Int64(s) * 1000 }
        return 86_400_000
    }

    static func applyDelete(_ db: Database, _ t: Target, _ c: ModifierContext, admin: Bool, ourAci: String) throws -> Bool {
        guard !t.deletedForEveryone, t.conversationId == c.conversationId || c.source != .someoneElse else { return false }
        if try String.fetchOne(db, sql: "SELECT serviceId FROM conversations WHERE id = ?", arguments: [t.conversationId]) == ourAci { return false }
        let age = abs(Int64(c.serverTimestamp) - (t.serverTimestamp ?? t.sentAt))
        if admin {
            guard let g = try GroupStore.load(db, conversationId: t.conversationId), g.state?.isAdmin(c.sender) == true else { return false }
        } else {
            guard t.json["sourceServiceId"] as? String == c.sender else { return false }
        }
        guard age <= (try deleteMaxAge(db, admin: admin)) + deleteGracePeriod else { return false }
        try erase(db, t.id) { json in
            json["deletedForEveryone"] = true
            json["reactions"] = []
            if admin { json["deletedForEveryoneByAdminAci"] = c.sender }
        }
        return true
    }

    /// `eraseMessageContents`: body, attachments, previews, quote, sticker, poll, edit history.
    static func erase(_ db: Database, _ id: String, _ extra: (inout [String: Any]) -> Void = { _ in }) throws {
        try MessageStore.updateJSON(db, messageId: id) { json in
            for k in ["body", "attachments", "preview", "quote", "sticker", "contact", "poll", "editHistory", "bodyRanges", "giftBadge"] { json[k] = nil }
            json["isErased"] = true
            extra(&json)
        }
        try db.execute(sql: "UPDATE messages SET body = NULL, hasAttachments = 0, hasFileAttachments = 0, hasVisualMediaAttachments = 0 WHERE id = ?",
                       arguments: [id])
        for table in ["message_attachments", "attachment_downloads", "reactions", "edited_messages", "mentions", "sticker_references"] {
            try db.execute(sql: "DELETE FROM \(table) WHERE messageId = ?", arguments: [id])
        }
        try db.execute(sql: "DELETE FROM pinnedMessages WHERE messageId = ?", arguments: [id])
    }

    // MARK: edits (handleEditMessage)

    static let maxEditAge: Int64 = 2 * 86_400_000

    static func applyEdit(_ db: Database, _ t: Target, _ edit: Signalservice_EditMessage, _ c: ModifierContext, ourAci: String) throws -> Bool {
        guard !t.deletedForEveryone, t.json["sourceServiceId"] as? String == c.sender,
              abs(Int64(c.serverTimestamp == 0 ? c.timestamp : c.serverTimestamp) - (t.serverTimestamp ?? t.sentAt)) <= maxEditAge
                || c.source != .someoneElse
        else { return false }
        let m = edit.dataMessage
        // Older edits arriving late are ignored.
        if let current = (t.json["editMessageTimestamp"] as? NSNumber)?.uint64Value, current >= m.timestamp { return false }
        guard try MessageStore.applyEdit(db, author: c.sender, targetSentAt: UInt64(t.sentAt), newBody: m.body, editSentAt: m.timestamp) != nil else { return false }
        try MessageStore.updateJSON(db, messageId: t.id) { json in
            json["preview"] = nil
            if c.source != .someoneElse { json["readStatus"] = ReadStatus.read.rawValue }
        }
        if !m.preview.isEmpty {
            try db.execute(sql: "DELETE FROM message_attachments WHERE messageId = ? AND attachmentType = 'preview'", arguments: [t.id])
            try MessageStore.storePreviews(db, messageId: t.id, conversationId: t.conversationId, sentAt: t.sentAt, messageType: t.type, body: m.body, m.preview)
        }
        return true
    }

    // MARK: polls (Polls.preload.ts)

    static func applyPollVote(_ db: Database, _ t: Target, _ v: Signalservice_DataMessage.PollVote, _ c: ModifierContext, ourAci: String) throws -> Bool {
        guard !t.deletedForEveryone, var poll = t.json["poll"] as? [String: Any], poll["terminatedAt"] == nil,
              try senderBelongs(db, sender: c.sender, conversationId: t.conversationId, ourAci: ourAci) else { return false }
        let options = (poll["options"] as? [String])?.count ?? 0
        let indexes = Array(Set(v.optionIndexes.map(Int.init))).sorted()
        guard indexes.allSatisfy({ $0 < options }), (poll["allowMultiple"] as? Bool ?? false) || indexes.count <= 1 else { return false }
        let fromId = try conversationOf(db, sender: c.sender)
        var votes = poll["votes"] as? [[String: Any]] ?? []
        if let existing = votes.first(where: { $0["fromConversationId"] as? String == fromId }),
           (existing["voteCount"] as? NSNumber)?.uint32Value ?? 0 >= v.voteCount { return false }
        votes.removeAll { $0["fromConversationId"] as? String == fromId }
        if !indexes.isEmpty {
            votes.append(["fromConversationId": fromId, "optionIndexes": indexes, "voteCount": v.voteCount, "timestamp": c.timestamp])
        } else {
            // An empty vote retracts, but its count still orders later votes.
            votes.append(["fromConversationId": fromId, "optionIndexes": [Int](), "voteCount": v.voteCount, "timestamp": c.timestamp])
        }
        poll["votes"] = votes
        try MessageStore.updateJSON(db, messageId: t.id) { $0["poll"] = poll }
        return true
    }

    static func applyPollTerminate(_ db: Database, _ t: Target, _ c: ModifierContext, ourAci: String) throws -> Bool {
        guard var poll = t.json["poll"] as? [String: Any], poll["terminatedAt"] == nil, t.json["sourceServiceId"] as? String == c.sender else { return false }
        poll["terminatedAt"] = c.timestamp
        try MessageStore.updateJSON(db, messageId: t.id) { $0["poll"] = poll }
        return true
    }

    // MARK: pins (PinnedMessages.preload.ts)

    static func pinLimit(_ db: Database) throws -> Int { try RemoteConfig.int(db, "global.pinnedMessageLimit") ?? 3 }

    static func applyPin(_ db: Database, _ t: Target, _ p: Signalservice_DataMessage.PinMessage, _ c: ModifierContext, ourAci: String) throws -> Bool {
        guard !t.deletedForEveryone, t.json["giftBadge"] == nil, try !isBlocked(db, conversationId: t.conversationId, sender: c.sender),
              try senderBelongs(db, sender: c.sender, conversationId: t.conversationId, ourAci: ourAci) else { return false }
        if let g = try GroupStore.load(db, conversationId: t.conversationId), let state = g.state,
           state.accessControl.attributes == GroupAccess.administrator, !state.isAdmin(c.sender) { return false }
        let pinnedAt = MessageStore.now()
        let expiresAt: Int64? = p.pinDurationForever || p.pinDurationSeconds == 0 ? nil : pinnedAt + Int64(p.pinDurationSeconds) * 1000
        let existed = try Int.fetchOne(db, sql: "SELECT 1 FROM pinnedMessages WHERE conversationId = ? AND messageId = ?", arguments: [t.conversationId, t.id]) != nil
        try db.execute(sql: """
            INSERT INTO pinnedMessages (conversationId, messageId, pinnedAt, expiresAt) VALUES (?, ?, ?, ?)
            ON CONFLICT(conversationId, messageId) DO UPDATE SET pinnedAt = excluded.pinnedAt, expiresAt = excluded.expiresAt
            """, arguments: [t.conversationId, t.id, pinnedAt, expiresAt])
        // `appendPinnedMessage(limit)`: the oldest pins beyond the limit go.
        try db.execute(sql: """
            DELETE FROM pinnedMessages WHERE conversationId = ? AND id NOT IN
              (SELECT id FROM pinnedMessages WHERE conversationId = ? ORDER BY pinnedAt DESC, id DESC LIMIT ?)
            """, arguments: [t.conversationId, t.conversationId, try pinLimit(db)])
        if !existed {
            try MessageStore.insert(db, .init(conversationId: t.conversationId, type: "pinned-message-notification", body: "", sentAt: c.timestamp,
                                              source: c.sender, sourceDevice: nil, serverGuid: nil, serverTimestamp: nil, unidentified: false,
                                              extra: ["pinMessage": ["targetSentTimestamp": t.sentAt, "targetAuthorAci": t.json["sourceServiceId"] ?? ""],
                                                      "readStatus": ReadStatus.read.rawValue, "seenStatus": SeenStatus.unseen.rawValue]))
        }
        return true
    }

    static func applyUnpin(_ db: Database, _ t: Target, _ c: ModifierContext, ourAci: String) throws -> Bool {
        guard try senderBelongs(db, sender: c.sender, conversationId: t.conversationId, ourAci: ourAci) else { return false }
        try db.execute(sql: "DELETE FROM pinnedMessages WHERE conversationId = ? AND messageId = ?", arguments: [t.conversationId, t.id])
        return db.changesCount > 0
    }

    /// Pins past their expiry (`pinnedMessagesCleanupService`).
    static func expirePins(_ db: Database, now: Int64 = MessageStore.now()) throws {
        try db.execute(sql: "DELETE FROM pinnedMessages WHERE expiresAt IS NOT NULL AND expiresAt <= ?", arguments: [now])
    }

    // MARK: view-once (ViewOnceOpenSyncs + markViewOnceMessageViewed)

    static func eraseViewOnce(_ db: Database, _ t: Target) throws -> Bool {
        guard t.json["isViewOnce"] as? Bool == true, t.json["isErased"] as? Bool != true else { return false }
        try erase(db, t.id) { json in
            json["readStatus"] = ReadStatus.viewed.rawValue
            json["seenStatus"] = SeenStatus.seen.rawValue
        }
        try db.execute(sql: "UPDATE messages SET readStatus = ?, seenStatus = ? WHERE id = ?", arguments: [ReadStatus.viewed.rawValue, SeenStatus.seen.rawValue, t.id])
        return true
    }

    // MARK: building modifiers from a DataMessage

    static func aci(_ binary: Data, _ string: String = "") -> String? { StorageLocal.aci(binary: binary, string: string) }

    /// The modifiers a DataMessage carries (it then has no content of its own).
    static func modifiers(of m: Signalservice_DataMessage, context c: ModifierContext) throws -> [PendingModifier] {
        let now = MessageStore.now()
        var out: [PendingModifier] = []
        func add(_ kind: PendingModifier.Kind, _ author: String?, _ sentAt: UInt64, _ payload: Data = Data()) {
            guard let author, sentAt > 0 else { return }
            out.append(PendingModifier(kind: kind, targetAuthor: author, targetSentAt: sentAt, context: c, payload: payload, storedAt: now))
        }
        if m.hasReaction, !m.reaction.emoji.isEmpty || m.reaction.remove {
            add(.reaction, aci(m.reaction.targetAuthorAciBinary, m.reaction.targetAuthorAci), m.reaction.targetSentTimestamp, try m.reaction.serializedBytes())
        }
        if m.hasDelete { add(.delete, c.sender, m.delete.targetSentTimestamp) }
        if m.hasAdminDelete { add(.adminDelete, aci(m.adminDelete.targetAuthorAciBinary), m.adminDelete.targetSentTimestamp) }
        if m.hasPollVote { add(.pollVote, aci(m.pollVote.targetAuthorAciBinary), m.pollVote.targetSentTimestamp, try m.pollVote.serializedBytes()) }
        if m.hasPollTerminate { add(.pollTerminate, c.sender, m.pollTerminate.targetSentTimestamp) }
        if m.hasPinMessage { add(.pin, aci(m.pinMessage.targetAuthorAciBinary), m.pinMessage.targetSentTimestamp, try m.pinMessage.serializedBytes()) }
        if m.hasUnpinMessage { add(.unpin, aci(m.unpinMessage.targetAuthorAciBinary), m.unpinMessage.targetSentTimestamp) }
        return out
    }

    /// `PollCreate` on a new message: its `poll` attribute (2–10 options, non-empty question).
    static func pollJSON(_ p: Signalservice_DataMessage.PollCreate) -> [String: Any]? {
        let options = p.options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !p.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (2...10).contains(options.count), options.allSatisfy({ !$0.isEmpty })
        else { return nil }
        return ["question": p.question, "options": options, "allowMultiple": p.allowMultiple, "votes": [[String: Any]]()]
    }
}
