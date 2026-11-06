// What a conversation's header and details panel show (upstream's ConversationType fields
// for ConversationHeader / ConversationDetails): mute, timer, block, archive / pin / unread,
// left, the contact's about, the group's state (members with roles and labels, invites,
// requests, bans, access control, link), notify-while-muted, and whether there is media.

import Foundation
import GRDB

public struct ConversationDetailsInfo: Sendable, Equatable {
    public var conversationId: String
    public var isGroup: Bool
    public var serviceId: String?
    public var masterKey: Data?
    public var muteExpiresAt: Int64?
    public var expireTimer: Int?
    public var isBlocked: Bool
    public var isArchived: Bool
    public var isPinned: Bool
    public var markedUnread: Bool
    public var left: Bool
    public var about: String?
    public var aboutEmoji: String?
    public var group: GroupV2State?
    /// `dontNotifyFor…IfMuted` inverted; nil: the account default.
    public var notifyForCallsIfMuted: Bool?
    public var notifyForMentionsIfMuted: Bool?
    public var notifyForRepliesIfMuted: Bool?
    public var hasMedia: Bool
}

extension ConversationQueries {
    public static func details(_ db: Database, conversationId: String) throws -> ConversationDetailsInfo? {
        guard let row = try Row.fetchOne(db, sql: "SELECT type, json, serviceId, groupId FROM conversations WHERE id = ?", arguments: [conversationId])
        else { return nil }
        let json = (try? MessageStore.jsonObject(row["json"] ?? "{}")) ?? [:]
        let isGroup = (row["type"] as String?) == "group"
        let serviceId: String? = row["serviceId"], groupId: String? = row["groupId"]
        var blocked = false
        if let serviceId { blocked = try BlockedList.serviceIds.entries(db).contains { $0.id == serviceId } }
        if let groupId, try BlockedList.groups.entries(db).contains(where: { $0.id == groupId }) { blocked = true }
        let stored = isGroup ? try GroupStore.load(db, conversationId: conversationId) : nil
        let timer = try ConversationState.timer(db, conversationId: conversationId)
        let media = try Int.fetchOne(db, sql: """
            SELECT 1 FROM message_attachments WHERE conversationId = ? AND attachmentType = 'attachment'
              AND (contentType LIKE 'image/%' OR contentType LIKE 'video/%') LIMIT 1
            """, arguments: [conversationId]) != nil
        func flag(_ k: String) -> Bool? { json[k] as? Bool }
        return ConversationDetailsInfo(
            conversationId: conversationId, isGroup: isGroup, serviceId: serviceId, masterKey: stored?.keys.masterKey,
            muteExpiresAt: (json["muteExpiresAt"] as? NSNumber)?.int64Value, expireTimer: timer.seconds.map(Int.init),
            isBlocked: blocked, isArchived: flag("isArchived") ?? false, isPinned: ((try Items.get(db, "pinnedConversationIds") as [String]?) ?? []).contains(conversationId),
            markedUnread: flag("markedUnread") ?? false, left: flag("left") ?? false,
            about: json["about"] as? String, aboutEmoji: json["aboutEmoji"] as? String, group: stored?.state,
            notifyForCallsIfMuted: flag("notifyForCallsIfMuted"), notifyForMentionsIfMuted: flag("notifyForMentionsIfMuted"),
            notifyForRepliesIfMuted: flag("notifyForRepliesIfMuted"), hasMedia: media)
    }
}

extension SignalDatabase {
    public func detailsUpdates(conversationId: String) -> AsyncThrowingStream<ConversationDetailsInfo?, Error> {
        observe { try ConversationQueries.details($0, conversationId: conversationId) }
    }
}

extension Messenger {
    /// ConversationNotificationsSettings: what still notifies while the chat is muted.
    public func setNotifyWhileMuted(_ conversationId: String, calls: Bool, mentions: Bool, replies: Bool) async throws {
        try await changeConversation(conversationId) {
            $0["notifyForCallsIfMuted"] = calls
            $0["notifyForMentionsIfMuted"] = mentions
            $0["notifyForRepliesIfMuted"] = replies
        }
    }
}

/// One entry of a conversation's media gallery (AllMedia): an attachment and its message.
public struct ConversationMediaItem: Sendable, Equatable {
    public var messageId: String
    public var receivedAt: Int64
    public var sentAt: Int64
    public var author: String?
    public var outgoing: Bool
    public var attachment: MessageAttachment
}

extension ConversationQueries {
    /// `getOlderMedia`: the conversation's attachments (not stickers, previews or quotes),
    /// newest first.
    public static func media(_ db: Database, conversationId: String, limit: Int = 500) throws -> [ConversationMediaItem] {
        try Row.fetchAll(db, sql: """
            SELECT a.messageId, a.orderInMessage, m.received_at, m.sent_at, m.sourceServiceId, m.type FROM message_attachments a
            JOIN messages m ON m.id = a.messageId
            WHERE a.conversationId = ? AND a.attachmentType = 'attachment' AND a.editHistoryIndex = -1
              AND coalesce(json_extract(m.json, '$.isViewOnce'), 0) = 0 AND coalesce(json_extract(m.json, '$.deletedForEveryone'), 0) = 0
            ORDER BY m.received_at DESC, a.orderInMessage LIMIT ?
            """, arguments: [conversationId, limit]).compactMap { row in
                let messageId: String = row["messageId"]
                guard let a = try MessageAttachments.fetch(db, .init(messageId: messageId, type: .attachment, order: row["orderInMessage"])) else { return nil }
                let outgoing = (row["type"] as String?) == "outgoing"
                return ConversationMediaItem(messageId: messageId, receivedAt: row["received_at"] ?? 0, sentAt: row["sent_at"] ?? 0,
                                             author: row["sourceServiceId"], outgoing: outgoing, attachment: a)
            }
    }
}

extension SignalDatabase {
    public func mediaUpdates(conversationId: String) -> AsyncThrowingStream<[ConversationMediaItem], Error> {
        observe { try ConversationQueries.media($0, conversationId: conversationId) }
    }
}

extension Messenger {
    /// The 1:1 conversation for an account found by username or number (created if new),
    /// remembering how it was found (`username`, `e164`) until its profile arrives.
    public func directConversation(serviceId: String, username: String? = nil, e164: String? = nil) async throws -> String {
        try await database.pool.write { db in
            let id = try MessageStore.privateConversation(db, serviceId: serviceId)
            if username != nil || e164 != nil {
                try MessageStore.updateConversationJSON(db, conversationId: id) { json in
                    if let username, json["username"] == nil { json["username"] = username }
                    if let e164, json["e164"] == nil { json["e164"] = e164 }
                }
            }
            return id
        }
    }
}
