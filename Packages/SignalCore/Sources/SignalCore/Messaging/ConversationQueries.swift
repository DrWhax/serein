// What the app shows: the inbox (upstream getAllConversations + the left pane's last-message
// preview) and a conversation's timeline (getOlderMessagesByConversation), read straight from
// the upstream tables, and observed live (GRDB ValueObservation: a fresh value after every
// commit that touches the tables read).

import Foundation
import CryptoKit
import GRDB
import SignalText
import LibSignalClient

public struct ConversationSummary: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case `private`, group }
    public var id: String
    public var kind: Kind
    public var title: String
    /// Avatar colour (A100…A210).
    public var color: String
    public var serviceId: String?
    public var e164: String?
    /// GroupsV2 master key (base64 decoded), for group sends.
    public var masterKey: Data?
    public var activeAt: Int64?
    public var unreadCount: Int
    public var isArchived: Bool
    public var isPinned: Bool
    /// Message request accepted (or ours to begin with): upstream isConversationAccepted.
    public var isAccepted: Bool
    public var lastMessage: TimelineMessage?
    /// Groups: current members (json.membersV2).
    public var membersCount: Int = 0
    /// The downloaded avatar (profileAvatar for contacts, avatar for groups).
    public var avatar: LocalFile?
    /// What chat folders test (mute, unread, mentions, marked unread).
    public var folderProps: ChatFolderConversation = ChatFolderConversation(id: "", isGroup: false)
    /// The unsent composer text (`json.draft`, mentions as U+FFFC), its ranges and when it was saved.
    public var draft: String?
    public var draftBodyRanges: [MessageBodyRange] = []
    public var draftTimestamp: Int64?
    /// Groups: whether the group is in the story send list ("Always" / "Never" / nil: default).
    public var storySendMode: String?
}

/// Where the "unread messages" divider goes when a chat opens (upstream getOldestUnseenMessage-
/// ForConversation / getTotalUnseenForConversation).
public struct UnseenSummary: Sendable, Equatable {
    public var oldestId: String
    public var count: Int
}

/// A message a notice points at, by author and sent time; `messageId` once found.
public struct TimelineMessageRef: Sendable, Equatable {
    public var author: String?
    public var sentAt: Int64
    public var messageId: String?
}

/// A timeline entry that is not a chat message but something the reader has to be told
/// (upstream's notification message types).
public enum TimelineNotice: Sendable, Equatable {
    /// `keychange`: this contact's safety number changed.
    case keyChange(serviceId: String?)
    /// `verified-change`: marked verified or not, here (`local`) or on another device.
    case verifiedChange(verified: Bool, local: Bool)
    /// `delivery-issue`: a message from `sender` could not be decrypted.
    case deliveryIssue(sender: String?)
    /// `chat-session-refreshed`: the session was reset after a decryption error.
    case chatSessionRefreshed
    /// `call-history`: a call in this chat, with its call history row (looked up by `callId`
    /// when the timeline is read; nil if it is missing).
    case call(callId: String?, details: CallHistoryDetails?)
    /// `group-v2-change`: upstream's `groupV2Change` (`from` and `details`) as JSON, for the
    /// UI's own model of it.
    case groupChange(json: Data)
    /// `timer-notification`: the disappearing timer was set (`seconds`, 0: off) by `source`
    /// (nil: a group change with no author), or by a sync from another of our devices.
    case timerChange(seconds: Int, source: String?, fromSync: Bool)
    /// `pinned-message-notification`: `source` pinned a message (looked up when the timeline is
    /// read; nil once it is gone).
    case pinnedMessage(source: String?, target: TimelineMessageRef)
    /// `poll-terminate`: `source` ended the poll `question` (the poll looked up like a pin's).
    case pollTerminate(source: String?, question: String, poll: TimelineMessageRef)
    /// `profile-change`: the contact of chat `changedConversationId` changed their profile name.
    case profileChange(changedConversationId: String?, oldName: String, newName: String)
    /// `change-number-notification`: `source` changed their phone number.
    case changeNumber(source: String?)
    /// `joined-signal-notification`
    case joinedSignal
    /// `title-transition-notification`: the chat was known as `oldTitle` (getTitle of its render
    /// info) before it learned the contact's name.
    case titleTransition(oldTitle: String?)
    /// `conversation-merge`: an older chat with this contact, known as `obsoleteTitle` or by
    /// `obsoleteNumber`, was merged into this one.
    case conversationMerge(obsoleteTitle: String?, obsoleteNumber: String?)
    /// `phone-number-discovery`: the chat's number (`e164`) now belongs to this account.
    case phoneNumberDiscovery(e164: String)
    /// `message-request-response-event`: ACCEPT, BLOCK, UNBLOCK or SPAM.
    case messageRequestResponse(event: String)

    /// The message types the timeline shows as notices.
    static let types = ["keychange", "verified-change", "delivery-issue", "chat-session-refreshed",
                        "call-history", "group-v2-change", "timer-notification", "pinned-message-notification", "poll-terminate",
                        "profile-change", "change-number-notification", "joined-signal-notification", "title-transition-notification",
                        "conversation-merge", "phone-number-discovery", "message-request-response-event"]

    /// getTitleNoDefault of a stored render info (`renderInfo`).
    static func title(_ renderInfo: [String: Any]?) -> String? {
        guard let info = renderInfo else { return nil }
        return ConversationQueries.titleNoDefault(Row(), json: info, kind: info["type"] as? String == "group" ? .group : .private)
    }

    init?(type: String?, json: [String: Any], source: String?) {
        switch type {
        case "keychange": self = .keyChange(serviceId: json["key_changed"] as? String)
        case "verified-change": self = .verifiedChange(verified: json["verified"] as? Bool ?? false, local: json["local"] as? Bool ?? false)
        case "delivery-issue": self = .deliveryIssue(sender: source)
        case "chat-session-refreshed": self = .chatSessionRefreshed
        case "call-history": self = .call(callId: json["callId"] as? String, details: nil)
        case "group-v2-change":
            guard let change = json["groupV2Change"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: change, options: .sortedKeys) else { return nil }
            self = .groupChange(json: data)
        case "timer-notification":
            let update = json["expirationTimerUpdate"] as? [String: Any] ?? [:]
            self = .timerChange(seconds: (update["expireTimer"] as? NSNumber)?.intValue ?? 0,
                                source: update["sourceServiceId"] as? String ?? update["source"] as? String,
                                fromSync: update["fromSync"] as? Bool ?? false)
        case "pinned-message-notification":
            let pin = json["pinMessage"] as? [String: Any] ?? [:]
            self = .pinnedMessage(source: source, target: TimelineMessageRef(author: pin["targetAuthorAci"] as? String,
                                                                             sentAt: (pin["targetSentTimestamp"] as? NSNumber)?.int64Value ?? 0))
        case "poll-terminate":
            let p = json["pollTerminateNotification"] as? [String: Any] ?? [:]
            self = .pollTerminate(source: source, question: p["question"] as? String ?? "",
                                  poll: TimelineMessageRef(author: source, sentAt: (p["pollTimestamp"] as? NSNumber)?.int64Value ?? 0))
        case "profile-change":
            let change = json["profileChange"] as? [String: Any] ?? [:]
            self = .profileChange(changedConversationId: json["changedId"] as? String, oldName: change["oldName"] as? String ?? "",
                                  newName: change["newName"] as? String ?? "")
        case "change-number-notification": self = .changeNumber(source: source)
        case "joined-signal-notification": self = .joinedSignal
        case "title-transition-notification":
            self = .titleTransition(oldTitle: Self.title((json["titleTransition"] as? [String: Any])?["renderInfo"] as? [String: Any]))
        case "conversation-merge":
            let info = (json["conversationMerge"] as? [String: Any])?["renderInfo"] as? [String: Any]
            self = .conversationMerge(obsoleteTitle: Self.title(info), obsoleteNumber: info?["e164"] as? String)
        case "phone-number-discovery":
            self = .phoneNumberDiscovery(e164: (json["phoneNumberDiscovery"] as? [String: Any])?["e164"] as? String ?? "")
        case "message-request-response-event":
            guard let event = json["messageRequestResponseEvent"] as? String else { return nil }
            self = .messageRequestResponse(event: event)
        default: return nil
        }
    }
}

public struct TimelineMessage: Sendable, Equatable, Identifiable {
    public enum Direction: String, Sendable { case incoming, outgoing }
    public enum Status: String, Sendable { case pending = "Pending", sent = "Sent", delivered = "Delivered", read = "Read", viewed = "Viewed", failed = "Failed" }
    public var id: String
    public var conversationId: String
    public var direction: Direction
    public var body: String
    public var sentAt: Int64
    public var receivedAt: Int64
    public var author: String?
    public var status: Status?
    public var hasAttachments: Bool
    public var isDeleted: Bool
    /// What the message carries besides text (the left-pane / notification preview).
    public var content: MessageContentKind
    /// The message's attachments (message_attachments rows), in order.
    public var attachments: [TimelineAttachment] = []
    /// One per sender (`json.reactions`), oldest first.
    public var reactions: [TimelineReaction] = []
    public var quote: TimelineQuote?
    /// Pinned in the conversation (and not expired).
    public var isPinned = false
    public var isEdited = false
    /// The disappearing timer (seconds) and when it started, if any.
    public var expireTimer: Int?
    public var expirationStartTimestamp: Int64?
    /// `bodyRanges` (styles and mentions), as stored.
    public var hasBodyRanges = false
    /// A sticker message's sticker.
    public var sticker: TimelineSticker?
    /// The message's link previews (`preview`), their images the `preview` attachments.
    public var previews: [TimelinePreview] = []
    /// `readStatus` is Viewed (a played voice note, an opened view-once).
    public var isViewed = false
    /// View-once media (`isTapToView`: `isViewOnce`, or an old `messageTimer`), and whether it was
    /// erased (opened here or on another device: its attachments are gone).
    public var isViewOnce = false
    public var isErased = false
    /// A poll (`poll`): its question, options and votes.
    public var poll: TimelinePoll?
    /// A shared contact (`contact`, the first), its avatar the `contact` attachment.
    public var contact: SharedContactInfo?
    /// `bodyRanges`: mentions and styles of the body.
    public var bodyRanges: [MessageBodyRange] = []
    /// `editHistory`: every version, newest first (the current one included); empty if never edited.
    public var editHistory: [TimelineEdit] = []
    /// Set for an entry that is a notice, not a message (its body is empty).
    public var notice: TimelineNotice?
    /// `seenStatus` is Unseen: not yet shown in an open chat (upstream's collapse sets keep
    /// such entries out of their fold).
    public var isUnseen = false
    /// Deleted for everyone, but the delete did not go out (`deletedForEveryoneFailed`: retryable).
    public var isDeleteForEveryoneFailed = false
}

public struct TimelineSticker: Sendable, Equatable {
    public var packId: String
    public var stickerId: Int
    public var emoji: String?
    /// The sticker attachment (ours, or downloaded); its pixels may instead come from the
    /// installed pack.
    public var attachment: MessageAttachment?
}

public struct TimelineReaction: Sendable, Equatable {
    public var emoji: String
    /// The reactor's service id (ours for our reaction).
    public var fromId: String
    public var timestamp: Int64
}

/// A reply's reference to the message it quotes.
public struct TimelineQuote: Sendable, Equatable {
    /// The quoted message's sent timestamp and author.
    public var sentAt: Int64
    public var authorAci: String
    public var text: String?
    public var attachmentContentType: String?
    public var attachmentFileName: String?
    public var isGiftBadge: Bool
    /// The quoted message here, when it is (tapping the quote scrolls to it).
    public var messageId: String?
    /// The quote's own thumbnail (sent with it), once downloaded or ours.
    public var thumbnail: MessageAttachment?

    public init(sentAt: Int64, authorAci: String, text: String?, attachmentContentType: String? = nil, attachmentFileName: String? = nil,
                isGiftBadge: Bool, messageId: String? = nil) {
        self.sentAt = sentAt
        self.authorAci = authorAci
        self.text = text
        self.attachmentContentType = attachmentContentType
        self.attachmentFileName = attachmentFileName
        self.isGiftBadge = isGiftBadge
        self.messageId = messageId
    }
}

/// A poll as stored on its message (votes by voter conversation; an empty vote is a retraction).
public struct TimelinePoll: Sendable, Equatable {
    public struct Vote: Sendable, Equatable {
        public var fromConversationId: String
        public var optionIndexes: [Int]
    }
    public var question: String
    public var options: [String]
    public var allowMultiple: Bool
    public var terminated: Bool
    public var votes: [Vote]
}

/// One version of an edited message.
public struct TimelineEdit: Sendable, Equatable {
    public var body: String
    /// Its send time (ms).
    public var timestamp: Int64
}

/// A link preview as stored on a message (`LinkPreviewType`).
public struct TimelinePreview: Sendable, Equatable {
    public var url: String
    public var title: String?
    public var description: String?
    public var date: Int64?
    public var domain: String?
    public var isStickerPack: Bool
    public var isCallLink: Bool
    public var image: MessageAttachment?
}

public struct TimelineAttachment: Sendable, Equatable {
    public var location: MessageAttachments.Location
    public var attachment: MessageAttachment
}

/// getNotificationDataForMessage's attachment and sticker cases (ts/util/…preload.ts).
public enum MessageContentKind: Sendable, Hashable {
    case text, gif, photo, video, voiceMessage, audio, file
    case sticker(emoji: String?)

    /// ts/util/GoogleChrome.std.ts isImageTypeSupported / isVideoTypeSupported.
    static let supportedImageTypes: Set<String> = ["image/avif", "image/bmp", "image/gif", "image/jpeg", "image/webp", "image/x-xbitmap",
                                                   "image/vnd.microsoft.icon", "image/ico", "image/icon", "image/x-icon", "image/apng", "image/png"]
    static let supportedVideoTypes: Set<String> = ["video/mp4", "video/ogg", "video/webm"]

    /// From the message JSON alone (attachments inlined there, as in older rows).
    static func of(_ json: [String: Any]) -> MessageContentKind {
        let first = (json["attachments"] as? [[String: Any]])?.first
        return of(json, firstAttachment: first.map { ($0["contentType"] as? String ?? "", $0["flags"] as? Int ?? 0) })
    }

    /// The message's kind, its attachments read from message_attachments (where they are
    /// kept; the JSON has none), else from the JSON.
    static func of(_ db: Database, messageId: String, json: [String: Any]) throws -> MessageContentKind {
        let row = try Row.fetchOne(db, sql: """
            SELECT contentType, flags FROM message_attachments
            WHERE messageId = ? AND editHistoryIndex = -1 AND attachmentType = 'attachment' ORDER BY orderInMessage LIMIT 1
            """, arguments: [messageId])
        guard let row else { return of(json) }
        return of(json, firstAttachment: (row["contentType"] ?? "", row["flags"] ?? 0))
    }

    /// Upstream reads the first attachment only.
    static func of(_ json: [String: Any], firstAttachment: (contentType: String, flags: Int)?) -> MessageContentKind {
        if let sticker = json["sticker"] as? [String: Any] { return .sticker(emoji: sticker["emoji"] as? String) }
        guard let first = firstAttachment else { return .text }
        let type = first.contentType.lowercased()
        let flags = first.flags
        // Attachment flags: VOICE_MESSAGE = 1, GIF = 8.
        if type == "image/gif" || flags & 8 != 0 { return .gif }
        if supportedImageTypes.contains(type) { return .photo }
        if supportedVideoTypes.contains(type) { return .video }
        if flags & 1 != 0 { return .voiceMessage }
        if type.hasPrefix("audio/") { return .audio }
        return .file
    }
}

public struct ContactInfo: Sendable, Equatable {
    public var title: String
    public var color: String
    public var avatar: LocalFile?
    /// Their profile has a photo (`remoteAvatarUrl`), downloaded or not (a message request's is
    /// only downloaded on a click).
    public var hasRemoteAvatar = false
}

public enum ConversationQueries {
    static let messageColumns = "id, conversationId, type, body, sent_at, received_at, sourceServiceId, json, hasAttachments, seenStatus"

    static let summaryColumns = "id, type, json, serviceId, e164, groupId, name, profileFullName, profileName, profileFamilyName, active_at"

    struct SummaryContext {
        var pinned: Set<String>
        var ourAci: String
        init(_ db: Database) throws {
            pinned = Set((try Items.get(db, "pinnedConversationIds") as [String]?) ?? [])
            ourAci = ((try Items.get(db, "uuid_id") as String?) ?? "").split(separator: ".").first.map(String.init) ?? ""
        }
    }

    static func summary(_ db: Database, _ row: Row, _ ctx: SummaryContext, lastMessage: Bool) throws -> ConversationSummary {
        let id: String = row["id"]
        let json = (try? MessageStore.jsonObject(row["json"] ?? "{}")) ?? [:]
        let kind: ConversationSummary.Kind = (row["type"] as String?) == "group" ? .group : .private
        let last = lastMessage ? try Row.fetchOne(db, sql: """
            SELECT \(messageColumns) FROM messages WHERE conversationId = ? AND type IN ('incoming', 'outgoing')
            ORDER BY received_at DESC, sent_at DESC LIMIT 1
            """, arguments: [id]).map { row in
                var m = message(row)
                if m.hasAttachments {
                    m.content = try MessageContentKind.of(db, messageId: m.id, json: (try? MessageStore.jsonObject(row["json"] ?? "{}")) ?? [:])
                }
                return m
            } : nil
        return ConversationSummary(
            id: id, kind: kind, title: title(row, json: json, kind: kind),
            color: json["color"] as? String ?? avatarColor(serviceId: row["serviceId"], e164: row["e164"], groupId: row["groupId"]), serviceId: row["serviceId"],
            e164: row["e164"], masterKey: (json["masterKey"] as? String).flatMap { Data(base64Encoded: $0) }, activeAt: row["active_at"],
            unreadCount: json["unreadCount"] as? Int ?? 0, isArchived: json["isArchived"] as? Bool ?? false,
            isPinned: ctx.pinned.contains(id), isAccepted: try ConversationState.isAccepted(db, conversationId: id, ourAci: ctx.ourAci),
            lastMessage: last, membersCount: (json["membersV2"] as? [Any])?.count ?? 0,
            avatar: LocalFile.from(kind == .group ? json["avatar"] : json["profileAvatar"]),
            folderProps: ChatFolderConversation(id: id, isGroup: kind == .group, muteExpiresAt: (json["muteExpiresAt"] as? NSNumber)?.int64Value ?? 0,
                                                unreadCount: (json["unreadCount"] as? NSNumber)?.intValue ?? 0,
                                                unreadMentionsCount: (json["unreadMentionsCount"] as? NSNumber)?.intValue ?? 0,
                                                markedUnread: json["markedUnread"] as? Bool ?? false),
            draft: (json["draft"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            draftBodyRanges: (json["draftBodyRanges"] as? [[String: Any]] ?? []).compactMap(MessageBodyRange.from),
            draftTimestamp: (json["draftTimestamp"] as? NSNumber)?.int64Value, storySendMode: json["storySendMode"] as? String)
    }

    /// The oldest unread incoming message and how many there are (nil: none).
    public static func unseen(_ db: Database, conversationId: String) throws -> UnseenSummary? {
        guard let oldest = try String.fetchOne(db, sql: """
            SELECT id FROM messages WHERE conversationId = ? AND type = 'incoming' AND readStatus = ?
            ORDER BY received_at, sent_at LIMIT 1
            """, arguments: [conversationId, ReadStatus.unread.rawValue]) else { return nil }
        let count = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM messages WHERE conversationId = ? AND type = 'incoming' AND readStatus = ?
            """, arguments: [conversationId, ReadStatus.unread.rawValue]) ?? 0
        return UnseenSummary(oldestId: oldest, count: count)
    }

    /// The open chat's unread messages and unread mentions of us (the Timeline's scroll-down
    /// buttons: `unreadCount`, `getTotalUnreadMentionsOfMeForConversation`).
    public struct UnreadCounts: Sendable, Equatable {
        public var unread: Int
        public var mentions: Int
        public init(unread: Int, mentions: Int) {
            self.unread = unread
            self.mentions = mentions
        }
    }

    public static func unreadCounts(_ db: Database, conversationId: String) throws -> UnreadCounts {
        let row = try Row.fetchOne(db, sql: """
            SELECT count(*) AS unread, coalesce(sum(mentionsMe), 0) AS mentions FROM messages
            WHERE conversationId = ? AND type = 'incoming' AND readStatus = ?
            """, arguments: [conversationId, ReadStatus.unread.rawValue])
        return UnreadCounts(unread: row?["unread"] ?? 0, mentions: row?["mentions"] ?? 0)
    }

    /// `getOldestUnreadMentionOfMeForConversation`: the message to scroll to.
    public static func oldestUnreadMention(_ db: Database, conversationId: String) throws -> String? {
        try String.fetchOne(db, sql: """
            SELECT id FROM messages WHERE conversationId = ? AND type = 'incoming' AND readStatus = ? AND mentionsMe = 1
            ORDER BY received_at, sent_at LIMIT 1
            """, arguments: [conversationId, ReadStatus.unread.rawValue])
    }

    public static func inbox(_ db: Database) throws -> [ConversationSummary] {
        let ctx = try SummaryContext(db)
        return try Row.fetchAll(db, sql: """
            SELECT \(summaryColumns) FROM conversations WHERE active_at IS NOT NULL AND active_at > 0 ORDER BY active_at DESC
            """).map { try summary(db, $0, ctx, lastMessage: true) }
    }

    /// One conversation, whether or not it is in the inbox (opening a contact from compose).
    public static func conversation(_ db: Database, id: String) throws -> ConversationSummary? {
        let ctx = try SummaryContext(db)
        return try Row.fetchOne(db, sql: "SELECT \(summaryColumns) FROM conversations WHERE id = ?", arguments: [id])
            .map { try summary(db, $0, ctx, lastMessage: true) }
    }

    /// The compose list (upstream getComposableContacts / getComposableGroups with
    /// canComposeConversation): ourselves (Note to Self) and trusted direct contacts with a
    /// display name — profile sharing, a system-contact name, or a group in common — that are
    /// not blocked or removed; and the groups we have not left. Sorted by title.
    public static func composable(_ db: Database) throws -> [ConversationSummary] {
        let ctx = try SummaryContext(db)
        let rows = try Row.fetchAll(db, sql: "SELECT \(summaryColumns) FROM conversations WHERE type IN ('private', 'group')")
        let blocked = Set(try BlockedList.serviceIds.entries(db).map(\.id))
        var inGroups = Set<String>()
        for row in rows where (row["type"] as String?) == "group" {
            let json = (try? MessageStore.jsonObject(row["json"] ?? "{}")) ?? [:]
            if json["left"] as? Bool == true { continue }
            for m in json["membersV2"] as? [[String: Any]] ?? [] { if let a = m["aci"] as? String { inGroups.insert(a) } }
        }
        var out: [ConversationSummary] = []
        for row in rows {
            let json = (try? MessageStore.jsonObject(row["json"] ?? "{}")) ?? [:]
            if json["removalStage"] != nil || json["terminated"] as? Bool == true { continue }
            if (row["type"] as String?) == "group" {
                guard json["left"] as? Bool != true, let name = json["name"] as? String, !name.isEmpty else { continue }
            } else {
                guard let serviceId: String = row["serviceId"], !blocked.contains(serviceId),
                      json["discoveredUnregisteredAt"] == nil else { continue }
                let isMe = serviceId == ctx.ourAci
                // isInSystemContacts: a system name from the primary (storage service / contact sync).
                let named = ["systemGivenName", "systemFamilyName", "systemNickname"].contains { ((json[$0] as? String) ?? "").isEmpty == false }
                    || ((row["name"] as String?) ?? "").isEmpty == false
                let trusted = isMe || json["profileSharing"] as? Bool == true || named || inGroups.contains(serviceId)
                let displayable = isMe || titleNoDefault(row, json: json, kind: .private) != nil
                guard trusted, displayable else { continue }
            }
            out.append(try summary(db, row, ctx, lastMessage: false))
        }
        return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Every known contact by service id (titles and colours for message authors).
    public static func contacts(_ db: Database) throws -> [String: ContactInfo] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT json, serviceId, e164, name, profileFullName, profileName, profileFamilyName FROM conversations WHERE type = 'private' AND serviceId IS NOT NULL
            """)
        var out: [String: ContactInfo] = [:]
        for row in rows {
            let json = (try? MessageStore.jsonObject(row["json"] ?? "{}")) ?? [:]
            let serviceId: String = row["serviceId"]
            out[serviceId] = ContactInfo(title: title(row, json: json, kind: .private),
                                         color: json["color"] as? String ?? avatarColor(serviceId: serviceId, e164: row["e164"], groupId: nil),
                                         avatar: LocalFile.from(json["profileAvatar"]), hasRemoteAvatar: json["remoteAvatarUrl"] is String)
        }
        return out
    }

    /// Up to `limit` messages before (`received_at` <) `before`, oldest first.
    public static func messages(_ db: Database, conversationId: String, limit: Int = 100, before: Int64 = .max) throws -> [TimelineMessage] {
        let pinned = Set(try String.fetchAll(db, sql: """
            SELECT messageId FROM pinnedMessages WHERE conversationId = ? AND (expiresAt IS NULL OR expiresAt > ?)
            """, arguments: [conversationId, MessageStore.now()]))
        // Reactions name the reactor's conversation (upstream fromId); the timeline wants the service id.
        var serviceIds: [String: String] = [:]
        func serviceId(_ conversationId: String) throws -> String {
            if let s = serviceIds[conversationId] { return s }
            let s = try String.fetchOne(db, sql: "SELECT serviceId FROM conversations WHERE id = ?", arguments: [conversationId]) ?? conversationId
            serviceIds[conversationId] = s
            return s
        }
        return try Row.fetchAll(db, sql: """
            SELECT \(messageColumns) FROM messages
            WHERE conversationId = ? AND type IN ('incoming', 'outgoing', \(TimelineNotice.types.map { "'\($0)'" }.joined(separator: ", "))) AND received_at < ?
            ORDER BY received_at DESC, sent_at DESC LIMIT ?
            """, arguments: [conversationId, before, limit]).map(message).reversed().map { m in
                var m = m
                switch m.notice {
                case .call(let callId?, nil): m.notice = .call(callId: callId, details: try CallHistoryStore.get(db, callId: callId))
                case .pinnedMessage(let source, var target):
                    target.messageId = try target.author.flatMap { try MessageStore.find(db, author: $0, sentAt: UInt64(max(0, target.sentAt))) }
                    m.notice = .pinnedMessage(source: source, target: target)
                case .pollTerminate(let source, let question, var poll):
                    poll.messageId = try poll.author.flatMap { try MessageStore.find(db, author: $0, sentAt: UInt64(max(0, poll.sentAt))) }
                    m.notice = .pollTerminate(source: source, question: question, poll: poll)
                default: break
                }
                if let q = m.quote {
                    m.quote?.messageId = try quotedMessageId(db, conversationId: conversationId, q)
                    m.quote?.thumbnail = try MessageAttachments.fetch(db, .init(messageId: m.id, type: .quote, order: 0))
                }
                if pinned.contains(m.id) { m.isPinned = true }
                for k in m.reactions.indices { m.reactions[k].fromId = try serviceId(m.reactions[k].fromId) }
                if m.sticker != nil { m.sticker?.attachment = try MessageAttachments.fetch(db, .init(messageId: m.id, type: .sticker, order: 0)) }
                for k in m.previews.indices { m.previews[k].image = try MessageAttachments.fetch(db, .init(messageId: m.id, type: .preview, order: k)) }
                if let c = m.contact {
                    m.contact?.avatar = try MessageAttachments.fetch(db, .init(messageId: m.id, type: .contact, order: 0))
                    m.contact?.resolution = try SharedContacts.resolve(db, c)
                }
                guard m.hasAttachments else { return m }
                m.attachments = try MessageAttachments.fetch(db, messageId: m.id)
                    .filter { $0.0.type == .attachment && $0.0.editHistoryIndex == -1 }
                    .sorted { $0.0.order < $1.0.order }
                    .map { TimelineAttachment(location: $0.0, attachment: $0.1) }
                if let first = m.attachments.first?.attachment, m.sticker == nil {
                    m.content = MessageContentKind.of([:], firstAttachment: (first.contentType, first.flags ?? 0))
                }
                return m
            }
    }

    /// The local message a quote refers to (its timestamp and author), if present.
    static func quotedMessageId(_ db: Database, conversationId: String, _ q: TimelineQuote) throws -> String? {
        try String.fetchOne(db, sql: "SELECT id FROM messages WHERE conversationId = ? AND sent_at = ? AND sourceServiceId = ? LIMIT 1",
                            arguments: [conversationId, q.sentAt, q.authorAci])
    }

    /// Upstream getTitle (ts/util/getTitle.preload.ts).
    static func title(_ row: Row, json: [String: Any], kind: ConversationSummary.Kind) -> String {
        titleNoDefault(row, json: json, kind: kind) ?? (kind == .group ? "Group" : "Unknown contact")
    }

    /// getTitleNoDefault: groups their name; direct chats the nickname, the system contact
    /// name, the profile name, the number, the username, then a shared contact's name.
    static func titleNoDefault(_ row: Row, json: [String: Any], kind: ConversationSummary.Kind) -> String? {
        func text(_ key: String) -> String? {
            let v = (json[key] as? String) ?? (row.hasColumn(key) ? row[key] as String? : nil)
            return v.flatMap { $0.isEmpty ? nil : $0 }
        }
        func combine(_ given: String?, _ family: String?) -> String? {
            let parts = [given, family].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        if kind == .group { return text("name") }
        return combine(text("nicknameGivenName"), text("nicknameFamilyName"))
            ?? text("systemNickname") ?? combine(text("systemGivenName"), text("systemFamilyName"))
            ?? combine(text("profileName"), text("profileFamilyName"))
            ?? text("e164")
            ?? text("username")
            ?? combine(text("sharedGivenName"), text("sharedFamilyName"))
            ?? text("name")    // contact-sync name, before the storage service has the system name
    }

    /// generateAvatarColor (ts/Crypto.node.ts): AvatarColors[sha256(identifier)[0] % 12].
    public static func avatarColor(serviceId: String?, e164: String?, groupId: String?) -> String {
        let colors = StorageLocal.avatarColors
        var identifier: Data?
        if let serviceId, let id = try? ServiceId.parseFrom(serviceIdString: serviceId) { identifier = Data(id.serviceIdBinary) }
        else if let e164 { identifier = Data(e164.utf8) }
        else if let groupId { identifier = Data(base64Encoded: groupId) }
        guard let identifier else { return colors[0] }
        return colors[Int(Array(SHA256.hash(data: identifier))[0]) % colors.count]
    }

    static func message(_ row: Row) -> TimelineMessage {
        let json = (try? MessageStore.jsonObject(row["json"] ?? "{}")) ?? [:]
        let conversationId: String = row["conversationId"]
        let outgoing = (row["type"] as String?) == "outgoing"
        var status: TimelineMessage.Status?
        if outgoing {
            let states = json["sendStateByConversationId"] as? [String: [String: Any]] ?? [:]
            // Best state across recipients, failed only when every recipient failed (upstream getMessagePropStatus).
            let all = states.values.compactMap { ($0["status"] as? String).flatMap(SendStatus.init(rawValue:)) }
            if let best = all.max(by: { $0.rank < $1.rank }) { status = TimelineMessage.Status(rawValue: best.rawValue) }
            // No one else to send to (a group with only us): upstream's `isMessageJustForMe`,
            // sent — not "sending" forever.
            else if states.isEmpty { status = .sent }
            else { status = .pending }
        }
        var m = TimelineMessage(id: row["id"], conversationId: conversationId, direction: outgoing ? .outgoing : .incoming,
                                body: row["body"] ?? "", sentAt: row["sent_at"] ?? 0, receivedAt: row["received_at"] ?? 0,
                                author: row["sourceServiceId"], status: status, hasAttachments: (row["hasAttachments"] as Int?) == 1,
                                isDeleted: json["deletedForEveryone"] as? Bool ?? false, content: MessageContentKind.of(json))
        m.notice = TimelineNotice(type: row["type"], json: json, source: row["sourceServiceId"])
        m.isUnseen = (row["seenStatus"] as Int?) == SeenStatus.unseen.rawValue
        m.isDeleteForEveryoneFailed = json["deletedForEveryoneFailed"] as? Bool ?? false
        func int64(_ v: Any?) -> Int64? { (v as? NSNumber)?.int64Value }
        m.reactions = (json["reactions"] as? [[String: Any]] ?? []).compactMap { r in
            guard let emoji = r["emoji"] as? String, let from = r["fromId"] as? String else { return nil }
            return TimelineReaction(emoji: emoji, fromId: from, timestamp: int64(r["timestamp"]) ?? 0)
        }
        if let q = json["quote"] as? [String: Any], let author = q["authorAci"] as? String, let id = int64(q["id"]) {
            let first = (q["attachments"] as? [[String: Any]])?.first
            m.quote = TimelineQuote(sentAt: id, authorAci: author, text: q["text"] as? String, attachmentContentType: first?["contentType"] as? String,
                                    attachmentFileName: first?["fileName"] as? String, isGiftBadge: q["isGiftBadge"] as? Bool ?? false)
        }
        m.isEdited = json["editMessageTimestamp"] != nil || !((json["editHistory"] as? [Any])?.isEmpty ?? true)
        m.expireTimer = (json["expireTimer"] as? NSNumber)?.intValue
        m.expirationStartTimestamp = int64(json["expirationStartTimestamp"])
        m.hasBodyRanges = !((json["bodyRanges"] as? [Any])?.isEmpty ?? true)
        m.bodyRanges = (json["bodyRanges"] as? [[String: Any]] ?? []).compactMap(MessageBodyRange.from)
        if let p = json["poll"] as? [String: Any], let question = p["question"] as? String, let options = p["options"] as? [String] {
            let votes = (p["votes"] as? [[String: Any]] ?? []).compactMap { v -> TimelinePoll.Vote? in
                guard let from = v["fromConversationId"] as? String else { return nil }
                return TimelinePoll.Vote(fromConversationId: from, optionIndexes: (v["optionIndexes"] as? [NSNumber] ?? []).map(\.intValue))
            }
            m.poll = TimelinePoll(question: question, options: options, allowMultiple: p["allowMultiple"] as? Bool ?? false,
                                  terminated: p["terminatedAt"] != nil, votes: votes)
        }
        if let c = (json["contact"] as? [[String: Any]])?.first { m.contact = SharedContacts.info(c) }
        if let s = json["sticker"] as? [String: Any], let packId = s["packId"] as? String, let stickerId = (s["stickerId"] as? NSNumber)?.intValue {
            m.sticker = TimelineSticker(packId: packId, stickerId: stickerId, emoji: s["emoji"] as? String)
        }
        m.editHistory = (json["editHistory"] as? [[String: Any]] ?? []).map { e in
            TimelineEdit(body: e["body"] as? String ?? "", timestamp: int64(e["timestamp"]) ?? 0)
        }
        m.isViewed = (json["readStatus"] as? NSNumber).flatMap { ReadStatus(rawValue: $0.intValue) } == .viewed
        m.isViewOnce = json["isViewOnce"] as? Bool == true || json["messageTimer"] != nil
        m.isErased = json["isErased"] as? Bool == true
        m.previews = (json["preview"] as? [[String: Any]] ?? []).compactMap { p in
            guard let url = p["url"] as? String else { return nil }
            return TimelinePreview(url: url, title: p["title"] as? String, description: p["description"] as? String, date: int64(p["date"]),
                                   domain: p["domain"] as? String ?? LinkPreviewRules.domain(url), isStickerPack: p["isStickerPack"] as? Bool ?? false,
                                   isCallLink: p["isCallLink"] as? Bool ?? false)
        }
        return m
    }
}

extension SignalDatabase {
    /// `fetch` now and after every commit that changes what it read, until the consumer stops.
    public func observe<T: Sendable & Equatable>(_ fetch: @escaping @Sendable (Database) throws -> T) -> AsyncThrowingStream<T, Error> {
        let values = ValueObservation.tracking(fetch).removeDuplicates().values(in: pool)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in values { continuation.yield(value) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func inboxUpdates() -> AsyncThrowingStream<[ConversationSummary], Error> { observe(ConversationQueries.inbox) }

    public func contactUpdates() -> AsyncThrowingStream<[String: ContactInfo], Error> { observe(ConversationQueries.contacts) }

    public func chatFolderUpdates() -> AsyncThrowingStream<[ChatFolder], Error> { observe { try ChatFolderStore.current($0) } }

    public func composableUpdates() -> AsyncThrowingStream<[ConversationSummary], Error> { observe(ConversationQueries.composable) }

    public func unseen(conversationId: String) async throws -> UnseenSummary? {
        try await pool.read { try ConversationQueries.unseen($0, conversationId: conversationId) }
    }

    public func timelineUpdates(conversationId: String, limit: Int = 100) -> AsyncThrowingStream<[TimelineMessage], Error> {
        observe { try ConversationQueries.messages($0, conversationId: conversationId, limit: limit) }
    }

    public func unreadCountUpdates(conversationId: String) -> AsyncThrowingStream<ConversationQueries.UnreadCounts, Error> {
        observe { try ConversationQueries.unreadCounts($0, conversationId: conversationId) }
    }

    /// The saved reaction emoji (`preferredReactionEmoji`; empty: the defaults).
    public func preferredReactionUpdates() -> AsyncThrowingStream<[String], Error> {
        observe { try Items.get($0, "preferredReactionEmoji", as: [String].self) ?? [] }
    }

    public func oldestUnreadMention(conversationId: String) async throws -> String? {
        try await pool.read { try ConversationQueries.oldestUnreadMention($0, conversationId: conversationId) }
    }
}

/// Message details (upstream MessageDetail): per recipient, the send state and when it changed.
public struct MessageDeliveryDetail: Sendable, Equatable {
    public struct Recipient: Sendable, Equatable {
        public var conversationId: String
        public var serviceId: String?
        /// "Pending", "Sent", "Delivered", "Read", "Viewed" or "Failed".
        public var status: String
        public var updatedAt: Int64?
        /// Sent with sealed sender.
        public var unidentified: Bool
    }
    public var sentAt: Int64
    public var receivedAt: Int64
    public var recipients: [Recipient]
    /// Incoming: received with sealed sender.
    public var unidentifiedDeliveryReceived: Bool
    public var errors: [String]
}

extension ConversationQueries {
    public static func deliveryDetail(_ db: Database, messageId: String) throws -> MessageDeliveryDetail? {
        guard let row = try Row.fetchOne(db, sql: "SELECT sent_at, received_at, json FROM messages WHERE id = ?", arguments: [messageId]) else { return nil }
        let json = (try? MessageStore.jsonObject(row["json"] ?? "{}")) ?? [:]
        let states = json["sendStateByConversationId"] as? [String: [String: Any]] ?? [:]
        let sealed = Set(json["unidentifiedDeliveries"] as? [String] ?? [])
        var recipients: [MessageDeliveryDetail.Recipient] = []
        for (conversationId, state) in states.sorted(by: { $0.key < $1.key }) {
            let serviceId = try String.fetchOne(db, sql: "SELECT serviceId FROM conversations WHERE id = ?", arguments: [conversationId])
            recipients.append(.init(conversationId: conversationId, serviceId: serviceId, status: state["status"] as? String ?? "Pending",
                                    updatedAt: (state["updatedAt"] as? NSNumber)?.int64Value, unidentified: serviceId.map(sealed.contains) ?? false))
        }
        let errors = (json["errors"] as? [[String: Any]] ?? []).compactMap { $0["message"] as? String }
        return MessageDeliveryDetail(sentAt: row["sent_at"] ?? 0, receivedAt: row["received_at"] ?? 0, recipients: recipients,
                                     unidentifiedDeliveryReceived: json["unidentifiedDeliveryReceived"] as? Bool ?? false, errors: errors)
    }
}

extension SignalDatabase {
    public func deliveryDetailUpdates(messageId: String) -> AsyncThrowingStream<MessageDeliveryDetail?, Error> {
        observe { try ConversationQueries.deliveryDetail($0, messageId: messageId) }
    }
}

/// A conversation's pinned message (upstream PinnedMessagesBar's `Pin`), newest pin first.
public struct PinnedMessageSummary: Sendable, Equatable {
    public var pinId: Int
    public var messageId: String
    public var outgoing: Bool
    /// The message's author (nil for ours).
    public var author: String?
    public var body: String
    public var content: MessageContentKind
    public var isViewOnce: Bool
    public var pollQuestion: String?
    /// The first attachment, for the thumbnail.
    public var attachment: MessageAttachment?
}

extension ConversationQueries {
    public static func pinnedMessages(_ db: Database, conversationId: String) throws -> [PinnedMessageSummary] {
        try Row.fetchAll(db, sql: """
            SELECT p.id AS pinId, m.id, m.type, m.sourceServiceId, m.body, m.json FROM pinnedMessages p JOIN messages m ON m.id = p.messageId
            WHERE p.conversationId = ? AND (p.expiresAt IS NULL OR p.expiresAt > ?) ORDER BY p.pinnedAt DESC, p.id DESC
            """, arguments: [conversationId, MessageStore.now()]).map { row in
                let json = (try? MessageStore.jsonObject(row["json"] ?? "{}")) ?? [:]
                let id: String = row["id"]
                let first = try MessageAttachments.fetch(db, messageId: id)
                    .filter { $0.0.type == .attachment && $0.0.editHistoryIndex == -1 }
                    .min { $0.0.order < $1.0.order }?.1
                let outgoing = (row["type"] as String?) == "outgoing"
                return PinnedMessageSummary(pinId: row["pinId"], messageId: id, outgoing: outgoing, author: outgoing ? nil : row["sourceServiceId"],
                                            body: row["body"] ?? "", content: MessageContentKind.of(json, firstAttachment: first.map { ($0.contentType, $0.flags ?? 0) }),
                                            isViewOnce: json["isViewOnce"] as? Bool ?? false, pollQuestion: (json["poll"] as? [String: Any])?["question"] as? String, attachment: first)
            }
    }
}

extension SignalDatabase {
    public func pinnedMessagesUpdates(conversationId: String) -> AsyncThrowingStream<[PinnedMessageSummary], Error> {
        observe { try ConversationQueries.pinnedMessages($0, conversationId: conversationId) }
    }
}
