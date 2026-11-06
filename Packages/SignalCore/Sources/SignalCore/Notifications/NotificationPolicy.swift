// Whether a received message notifies, and with what (upstream messages/maybeNotify,
// util/shouldStoryReplyNotifyUser, util/notifyWhileMuted, services/notifications'
// settings), and the dock badge (util/countUnreadStats, ConversationController
// updateUnreadCount). The text shown for each `notification-setting` is the app's
// (NotificationContent), from what this returns.

import Foundation
import GRDB

/// `NotificationSetting` (`notification-setting`).
public enum NotificationSetting: String, Sendable, CaseIterable {
    case off, count, name, message
}

/// The notification and badge settings (StorageKeys).
public struct NotificationSettings: Sendable, Hashable {
    public var setting: NotificationSetting = .message
    public var playSound = true
    public var drawAttention = false
    public var reactions = true
    public var notifyForCallsIfMuted = false
    public var notifyForMentionsIfMuted = true
    public var notifyForRepliesIfMuted = true
    public var badgeCountMutedConversations = false
    /// `unreadCountBadgeType`: "unread-messages" or "unread-chats".
    public var badgeCountsChats = false

    public init() {}

    public static func load(_ db: Database) throws -> NotificationSettings {
        var s = NotificationSettings()
        if let v = try Items.get(db, "notification-setting", as: String.self) { s.setting = NotificationSetting(rawValue: v) ?? .message }
        s.playSound = try Items.get(db, "audio-notification", as: Bool.self) ?? true
        s.drawAttention = try Items.get(db, "notification-draw-attention", as: Bool.self) ?? false
        s.reactions = try Items.get(db, "reaction-notification", as: Bool.self) ?? true
        s.notifyForCallsIfMuted = try Items.get(db, "notifyForCallsIfMuted", as: Bool.self) ?? false
        s.notifyForMentionsIfMuted = try Items.get(db, "notifyForMentionsIfMuted", as: Bool.self) ?? true
        s.notifyForRepliesIfMuted = try Items.get(db, "notifyForRepliesIfMuted", as: Bool.self) ?? true
        s.badgeCountMutedConversations = try Items.get(db, "badge-count-muted-conversations", as: Bool.self) ?? false
        s.badgeCountsChats = try Items.get(db, "unreadCountBadgeType", as: String.self) == "unread-chats"
        return s
    }

    /// Writes the settings back to their items (Settings → Notifications).
    public func save(_ db: Database) throws {
        try Items.set(db, "notification-setting", setting.rawValue)
        try Items.set(db, "audio-notification", playSound)
        try Items.set(db, "notification-draw-attention", drawAttention)
        try Items.set(db, "reaction-notification", reactions)
        try Items.set(db, "notifyForCallsIfMuted", notifyForCallsIfMuted)
        try Items.set(db, "notifyForMentionsIfMuted", notifyForMentionsIfMuted)
        try Items.set(db, "notifyForRepliesIfMuted", notifyForRepliesIfMuted)
        try Items.set(db, "badge-count-muted-conversations", badgeCountMutedConversations)
        try Items.set(db, "unreadCountBadgeType", badgeCountsChats ? "unread-chats" : "unread-messages")
    }
}

extension SignalDatabase {
    public func notificationSettingsUpdates() -> AsyncThrowingStream<NotificationSettings, Error> { observe { try NotificationSettings.load($0) } }

    /// Blocked contacts and groups (Settings → Privacy → Blocked): their conversation ids.
    public func blockedUpdates() -> AsyncThrowingStream<[String], Error> {
        observe { db in
            let ids = Set(try BlockedList.serviceIds.entries(db).map(\.id))
            let groups = Set(try BlockedList.groups.entries(db).map(\.id))
            return try Row.fetchAll(db, sql: "SELECT id, serviceId, groupId FROM conversations").compactMap { row -> String? in
                if let s: String = row["serviceId"], ids.contains(s) { return row["id"] }
                if let g: String = row["groupId"], groups.contains(g) { return row["id"] }
                return nil
            }
        }
    }
}

/// A notification to show (before the setting's redaction).
public struct PendingNotification: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case message, reaction(emoji: String) }
    public var kind: Kind
    public var conversationId: String
    public var messageId: String
    /// The story a group reply belongs to (clicking opens it).
    public var storyId: String?
    public var senderName: String?
    /// Set for a group: "sender in group".
    public var groupTitle: String?
    public var body: String
    public var isExpiringMessage: Bool
    public var sentAt: UInt64

    public init(kind: Kind, conversationId: String, messageId: String, storyId: String? = nil, senderName: String?, groupTitle: String? = nil,
                body: String, isExpiringMessage: Bool = false, sentAt: UInt64) {
        self.kind = kind
        self.conversationId = conversationId
        self.messageId = messageId
        self.storyId = storyId
        self.senderName = senderName
        self.groupTitle = groupTitle
        self.body = body
        self.isExpiringMessage = isExpiringMessage
        self.sentAt = sentAt
    }
}

public enum NotificationPolicy {
    /// `getTitle` for a contact: nickname, system name, profile name, username, number.
    public static func title(_ json: [String: Any]) -> String? {
        func s(_ k: String) -> String? { (json[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        if let given = s("nicknameGivenName") { return [given, s("nicknameFamilyName")].compactMap { $0 }.joined(separator: " ") }
        if let name = s("name") { return name }
        if let given = s("systemGivenName") { return [given, s("systemFamilyName")].compactMap { $0 }.joined(separator: " ") }
        if let profile = s("profileName") { return [profile, s("profileFamilyName")].compactMap { $0 }.joined(separator: " ") }
        if let username = s("username") { return username }
        return s("e164")
    }

    static func conversation(_ db: Database, id: String) throws -> (type: String, json: [String: Any])? {
        guard let row = try Row.fetchOne(db, sql: "SELECT type, json FROM conversations WHERE id = ?", arguments: [id]) else { return nil }
        return (row["type"], try MessageStore.jsonObject(row["json"]))
    }

    static func isMuted(_ json: [String: Any], now: Int64) -> Bool {
        ((json["muteExpiresAt"] as? NSNumber)?.int64Value ?? 0) > now
    }

    /// `maybeNotify` for a received message: nil when it shouldn't notify.
    public static func pending(_ db: Database, messageId: String, ourAci: String, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
                               calendar: Calendar = .current) throws -> PendingNotification? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT conversationId, type, readStatus, sourceServiceId, sent_at, storyId, mentionsMe, expireTimer, json FROM messages WHERE id = ?
            """, arguments: [messageId]) else { return nil }
        // doesMessageWarrantNotification: incoming, unread.
        guard row["type"] as String? == "incoming", (row["readStatus"] as Int?) == ReadStatus.unread.rawValue else { return nil }
        let conversationId: String = row["conversationId"]
        guard let conv = try conversation(db, id: conversationId) else { return nil }
        let isGroup = conv.type == "group"
        let json = try MessageStore.jsonObject(row["json"])
        let storyId: String? = row["storyId"]
        if let storyId, isGroup, !(try storyReplyNotifies(db, storyId: storyId, ourAci: ourAci)) { return nil }
        let mention = (row["mentionsMe"] as Int? ?? 0) != 0
        let reply = ((json["quote"] as? [String: Any])?["authorAci"] as? String) == ourAci
        // isAllowedByConversation: muted chats only for mentions / replies to us, in groups.
        let settings = try NotificationSettings.load(db)
        if isMuted(conv.json, now: now) {
            guard isGroup else { return nil }
            let mentions = conv.json["notifyForMentionsIfMuted"] as? Bool ?? settings.notifyForMentionsIfMuted
            let replies = conv.json["notifyForRepliesIfMuted"] as? Bool ?? settings.notifyForRepliesIfMuted
            guard (mentions && mention) || (replies && reply) else { return nil }
        }
        let profile = try NotificationProfiles.active(db, time: now, calendar: calendar)
        guard NotificationProfiles.shouldNotify(isCall: false, isMentionOrReply: mention || reply, conversationId: conversationId, activeProfile: profile)
        else { return nil }
        let sender: String? = try (row["sourceServiceId"] as String?).flatMap { aci in
            try Row.fetchOne(db, sql: "SELECT json FROM conversations WHERE serviceId = ?", arguments: [aci]).flatMap { try title(MessageStore.jsonObject($0["json"])) }
        }
        return PendingNotification(kind: .message, conversationId: conversationId, messageId: messageId, storyId: isGroup ? storyId : nil,
                                   senderName: sender, groupTitle: isGroup ? (conv.json["name"] as? String) : nil,
                                   body: notificationText(json), isExpiringMessage: (row["expireTimer"] as Int? ?? 0) > 0,
                                   sentAt: UInt64(row["sent_at"] as Int64))
    }

    /// `shouldStoryReplyNotifyUser` (groups): replies to our story, or one we replied to.
    static func storyReplyNotifies(_ db: Database, storyId: String, ourAci: String) throws -> Bool {
        guard let author = try String.fetchOne(db, sql: "SELECT sourceServiceId FROM messages WHERE id = ? AND type = 'story'", arguments: [storyId])
        else { return false }
        if author == ourAci { return true }
        return try Int.fetchOne(db, sql: "SELECT 1 FROM messages WHERE storyId = ? AND type = 'outgoing' LIMIT 1", arguments: [storyId]) != nil
    }

    /// `getNotificationTextForMessage`, the simple cases: the body, else what it carries.
    static func notificationText(_ json: [String: Any]) -> String {
        if let body = json["body"] as? String, !body.isEmpty { return body }
        if let reaction = json["storyReaction"] as? [String: Any], let emoji = reaction["emoji"] as? String { return emoji }
        if json["sticker"] != nil { return "Sticker" }
        if let attachments = json["attachments"] as? [[String: Any]], let first = attachments.first {
            let type = first["contentType"] as? String ?? ""
            return type.hasPrefix("image/") ? "📷 Photo" : type.hasPrefix("video/") ? "🎥 Video" : type.hasPrefix("audio/") ? "🎤 Voice message" : "📎 File"
        }
        return ""
    }

    /// The dock badge: unread messages (or chats) in countable chats, marked-unread chats as 1
    /// (`countAllConversationsUnreadStats` + `getUnreadCountForBadge`).
    public static func badgeCount(_ db: Database, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000), calendar: Calendar = .current) throws -> Int {
        let settings = try NotificationSettings.load(db)
        let profile = try NotificationProfiles.active(db, time: now, calendar: calendar)
        var unread = 0, chats = 0, marked = 0
        for row in try Row.fetchAll(db, sql: "SELECT id, json FROM conversations WHERE active_at > 0") {
            let id: String = row["id"]
            let j = try MessageStore.jsonObject(row["json"])
            if j["isArchived"] as? Bool == true || j["left"] as? Bool == true { continue }
            if !settings.badgeCountMutedConversations, isMuted(j, now: now) || (profile.map { !$0.allowedMembers.contains(id) } ?? false) { continue }
            let count = (j["unreadCount"] as? NSNumber)?.intValue ?? 0
            let mentions = (j["unreadMentionsCount"] as? NSNumber)?.intValue ?? 0
            if count > 0 || mentions > 0 {
                unread += count
                chats += 1
            } else if j["markedUnread"] as? Bool == true {
                marked += 1
            }
        }
        return (settings.badgeCountsChats ? chats : unread) + marked
    }
}
