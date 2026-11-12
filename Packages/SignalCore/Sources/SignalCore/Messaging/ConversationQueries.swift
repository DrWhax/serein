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

    /// The message types the timeline shows as notices.
    static let types = ["keychange", "verified-change", "delivery-issue", "chat-session-refreshed"]

    init?(type: String?, json: [String: Any], source: String?) {
        switch type {
        case "keychange": self = .keyChange(serviceId: json["key_changed"] as? String)
        case "verified-change": self = .verifiedChange(verified: json["verified"] as? Bool ?? false, local: json["local"] as? Bool ?? false)
        case "delivery-issue": self = .deliveryIssue(sender: source)
        case "chat-session-refreshed": self = .chatSessionRefreshed
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
    /// `bodyRanges`: mentions and styles of the body.
    public var bodyRanges: [MessageBodyRange] = []
    /// `editHistory`: every version, newest first (the current one included); empty if never edited.
    public var editHistory: [TimelineEdit] = []
    /// Set for an entry that is a notice, not a message (its body is empty).
    public var notice: TimelineNotice?
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
public enum MessageContentKind: Sendable, Equatable {
    case text, gif, photo, video, voiceMessage, audio, file
    case sticker(emoji: String?)

    /// ts/util/GoogleChrome.std.ts isImageTypeSupported / isVideoTypeSupported.
    static let supportedImageTypes: Set<String> = ["image/avif", "image/bmp", "image/gif", "image/jpeg", "image/webp", "image/x-xbitmap",
                                                   "image/vnd.microsoft.icon", "image/ico", "image/icon", "image/x-icon", "image/apng", "image/png"]
    static let supportedVideoTypes: Set<String> = ["video/mp4", "video/ogg", "video/webm"]

    static func of(_ json: [String: Any]) -> MessageContentKind {
        if let sticker = json["sticker"] as? [String: Any] { return .sticker(emoji: sticker["emoji"] as? String) }
        guard let attachments = json["attachments"] as? [[String: Any]], let first = attachments.first else { return .text }
        // Upstream reads the first attachment only.
        let type = (first["contentType"] as? String ?? "").lowercased()
        let flags = first["flags"] as? Int ?? 0
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
}

public enum ConversationQueries {
    static let messageColumns = "id, conversationId, type, body, sent_at, received_at, sourceServiceId, json, hasAttachments"

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
            """, arguments: [id]).map(message) : nil
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
                                         avatar: LocalFile.from(json["profileAvatar"]))
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
                if let q = m.quote {
                    m.quote?.messageId = try quotedMessageId(db, conversationId: conversationId, q)
                    m.quote?.thumbnail = try MessageAttachments.fetch(db, .init(messageId: m.id, type: .quote, order: 0))
                }
                if pinned.contains(m.id) { m.isPinned = true }
                for k in m.reactions.indices { m.reactions[k].fromId = try serviceId(m.reactions[k].fromId) }
                if m.sticker != nil { m.sticker?.attachment = try MessageAttachments.fetch(db, .init(messageId: m.id, type: .sticker, order: 0)) }
                for k in m.previews.indices { m.previews[k].image = try MessageAttachments.fetch(db, .init(messageId: m.id, type: .preview, order: k)) }
                guard m.hasAttachments else { return m }
                m.attachments = try MessageAttachments.fetch(db, messageId: m.id)
                    .filter { $0.0.type == .attachment && $0.0.editHistoryIndex == -1 }
                    .sorted { $0.0.order < $1.0.order }
                    .map { TimelineAttachment(location: $0.0, attachment: $0.1) }
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
                                            body: row["body"] ?? "", content: MessageContentKind.of(json), isViewOnce: json["isViewOnce"] as? Bool ?? false,
                                            pollQuestion: (json["poll"] as? [String: Any])?["question"] as? String, attachment: first)
            }
    }
}

extension SignalDatabase {
    public func pinnedMessagesUpdates(conversationId: String) -> AsyncThrowingStream<[PinnedMessageSummary], Error> {
        observe { try ConversationQueries.pinnedMessages($0, conversationId: conversationId) }
    }
}
