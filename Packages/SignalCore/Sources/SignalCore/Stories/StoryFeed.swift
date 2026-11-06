// What the Stories tab shows (upstream getStories / getStoriesState): every story still in its
// 24 hours, newest first, with its text attachment as upstream stores it, its media
// attachment, read and send state — observed live.

import Foundation
import GRDB

public struct StoryText: Sendable, Equatable {
    public var text: String?
    public var textStyle: Int
    public var textForegroundColor: UInt32?
    public var textBackgroundColor: UInt32?
    public var color: UInt32?
    public var gradientAngle: Int?
    public var gradientColors: [UInt32] = []
    public var gradientPositions: [Float] = []
    public init(text: String? = nil, textStyle: Int = 0, textForegroundColor: UInt32? = nil, textBackgroundColor: UInt32? = nil,
                color: UInt32? = nil, gradientAngle: Int? = nil, gradientColors: [UInt32] = [], gradientPositions: [Float] = []) {
        self.text = text
        self.textStyle = textStyle
        self.textForegroundColor = textForegroundColor
        self.textBackgroundColor = textBackgroundColor
        self.color = color
        self.gradientAngle = gradientAngle
        self.gradientColors = gradientColors
        self.gradientPositions = gradientPositions
    }
}

public struct StoryFeedItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var conversationId: String
    public var author: String
    public var sentAt: Int64
    public var isOutgoing: Bool
    public var isUnread: Bool
    public var distributionListId: String?
    public var groupConversationId: String?
    public var canReply: Bool
    public var text: StoryText?
    public var media: MessageAttachment?
    public var mediaLocation: MessageAttachments.Location?
    /// Outgoing: Pending / Sent / Failed… per recipient; views = recipients that viewed it.
    public var sendStatuses: [String]
    public var views: Int
}

public enum StoryFeed {
    public static func items(_ db: Database, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> [StoryFeedItem] {
        let ourAci = ((try Items.get(db, "uuid_id") as String?) ?? "").split(separator: ".").first.map(String.init) ?? ""
        return try Row.fetchAll(db, sql: """
            SELECT m.id, m.conversationId, m.sourceServiceId, m.sent_at, m.storyDistributionListId, m.readStatus, m.json, c.type AS ctype
            FROM messages m LEFT JOIN conversations c ON c.id = m.conversationId
            WHERE m.type = 'story' AND coalesce(m.expirationStartTimestamp, m.sent_at) + 86400000 > ? ORDER BY m.sent_at DESC
            """, arguments: [now]).map { row in
            let id: String = row["id"]
            let json = (try? MessageStore.jsonObject(row["json"])) ?? [:]
            let author: String = row["sourceServiceId"] ?? ourAci
            let states = (json["sendStateByConversationId"] as? [String: [String: Any]] ?? [:]).compactMap { $0.value["status"] as? String }
            var item = StoryFeedItem(
                id: id, conversationId: row["conversationId"], author: author, sentAt: row["sent_at"], isOutgoing: author == ourAci,
                isUnread: (row["readStatus"] as Int?) == ReadStatus.unread.rawValue, distributionListId: row["storyDistributionListId"],
                groupConversationId: (row["ctype"] as String?) == "group" ? row["conversationId"] : nil,
                canReply: json["canReplyToStory"] as? Bool ?? false, text: nil, media: nil, mediaLocation: nil, sendStatuses: states,
                views: states.filter { $0 == "Viewed" }.count)
            if let t = (json["attachments"] as? [[String: Any]])?.first?["textAttachment"] as? [String: Any] {
                item.text = text(t)
            } else if let (loc, a) = try MessageAttachments.fetch(db, messageId: id).first(where: { $0.0.type == .attachment }) {
                item.media = a
                item.mediaLocation = loc
            }
            return item
        }
    }

    static func number(_ v: Any?) -> Int64? { (v as? Int64) ?? (v as? Int).map(Int64.init) ?? (v as? NSNumber)?.int64Value }

    static func text(_ t: [String: Any]) -> StoryText {
        var s = StoryText(text: t["text"] as? String, textStyle: Int(number(t["textStyle"]) ?? 0))
        s.textForegroundColor = number(t["textForegroundColor"]).map { UInt32(truncatingIfNeeded: $0) }
        s.textBackgroundColor = number(t["textBackgroundColor"]).map { UInt32(truncatingIfNeeded: $0) }
        s.color = number(t["color"]).map { UInt32(truncatingIfNeeded: $0) }
        if let g = t["gradient"] as? [String: Any] {
            s.gradientAngle = number(g["angle"]).map(Int.init)
            var colors = (g["colors"] as? [Any] ?? []).compactMap { number($0).map { UInt32(truncatingIfNeeded: $0) } }
            if colors.isEmpty { colors = [number(g["startColor"]), number(g["endColor"])].compactMap { $0.map { UInt32(truncatingIfNeeded: $0) } } }
            s.gradientColors = colors
            s.gradientPositions = (g["positions"] as? [Any] ?? []).compactMap { ($0 as? Double).map(Float.init) ?? ($0 as? NSNumber)?.floatValue }
        }
        return s
    }
}

extension SignalDatabase {
    public func storyListUpdates() -> AsyncThrowingStream<[StoryDistributionLists.List], Error> { observe { try StoryDistributionLists.all($0) } }

    public func storyUpdates() -> AsyncThrowingStream<[StoryFeedItem], Error> { observe { try StoryFeed.items($0) } }
}
