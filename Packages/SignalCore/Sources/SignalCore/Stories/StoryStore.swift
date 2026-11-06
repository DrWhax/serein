// Stories in the database, as upstream keeps them: `messages` rows of type 'story' (24h
// expiry from the send time, the attachment or text attachment in `attachments`), replies
// pointing at them by `storyId`, distribution lists in `storyDistributions` +
// `storyDistributionMembers` (My Story is the all-zero id), and views in `storyReads`.
//
// Upstream: textsecure/MessageReceiver #handleStoryMessage, messages/handleDataMessage
// (storyContext), util/onStoryRecipientUpdate, sql/Server story queries.

import Foundation
import GRDB
import SignalProtos

public enum StoryStore {
    static let day: Int64 = 86_400_000
    public static let myStoryId = StorageLocal.myStoryId
    public static let textAttachmentContentType = "text/x-signal-plain"

    /// A story as the UI needs it.
    public struct Story: Sendable, Identifiable, Hashable {
        public var id: String
        public var conversationId: String
        public var sourceServiceId: String
        public var sentAt: UInt64
        public var distributionListId: String?
        public var groupId: String?
        public var canReplyToStory: Bool
        public var readStatus: Int
        public var textAttachment: [String: String]?
        public var sendStateByConversationId: [String: String]
    }

    // MARK: text attachments

    /// `TextAttachmentType` (the story's `attachments[0].textAttachment`), as upstream stores it.
    static func textAttachmentJSON(_ t: Signalservice_TextAttachment) -> [String: Any] {
        var out: [String: Any] = ["textStyle": t.textStyle.rawValue]
        if t.hasText { out["text"] = t.text }
        if t.hasTextForegroundColor { out["textForegroundColor"] = t.textForegroundColor }
        if t.hasTextBackgroundColor { out["textBackgroundColor"] = t.textBackgroundColor }
        switch t.background {
        case .color(let c)?: out["color"] = c
        case .gradient(let g)?:
            var gradient: [String: Any] = ["angle": g.angle]
            if g.hasStartColor { gradient["startColor"] = g.startColor }
            if g.hasEndColor { gradient["endColor"] = g.endColor }
            if !g.colors.isEmpty { gradient["colors"] = g.colors }
            if !g.positions.isEmpty { gradient["positions"] = g.positions }
            out["gradient"] = gradient
        case nil: break
        }
        return out
    }

    // MARK: insert

    struct Insert {
        var conversationId: String
        var source: String
        var sourceDevice: UInt32?
        var sentAt: UInt64
        var serverTimestamp: UInt64?
        var serverGuid: String?
        var story: Signalservice_StoryMessage
        var outgoing: Bool
        var distributionListId: String? = nil
        var sendState: [String: Any] = [:]
        var unidentified = false
    }

    /// The story's row (no conversation activity: a story doesn't move its chat up).
    @discardableResult
    static func insert(_ db: Database, _ s: Insert) throws -> String? {
        let story = s.story
        var attachments: [[String: Any]] = []
        var preview: [[String: Any]] = []
        if case .textAttachment(let t)? = story.attachment {
            guard t.hasText || t.hasPreview else { return nil }          // "Text attachments must have text or link preview!"
            var t2 = t
            t2.clearPreview()
            attachments.append(["contentType": textAttachmentContentType, "size": t.text.utf8.count, "textAttachment": textAttachmentJSON(t2)])
            if t.hasPreview {
                var p: [String: Any] = ["url": t.preview.url]
                if t.preview.hasTitle { p["title"] = t.preview.title }
                if t.preview.hasDescription_p { p["description"] = t.preview.description_p }
                preview.append(p)
            }
        }
        let id = UUID().uuidString.lowercased()
        let receivedAt = try MessageStore.nextReceivedAt(db)
        let expirationStart = Int64(min(s.sentAt, s.serverTimestamp.flatMap { $0 > 0 ? $0 : nil } ?? s.sentAt))
        var json: [String: Any] = [
            "id": id, "conversationId": s.conversationId, "type": "story", "body": "", "sent_at": s.sentAt, "timestamp": s.sentAt,
            "received_at": receivedAt, "received_at_ms": MessageStore.now(), "attachments": attachments, "schemaVersion": 14,
            "sourceServiceId": s.source, "canReplyToStory": story.allowsReplies, "expireTimer": 86_400,
            "expirationStartTimestamp": expirationStart,
            "readStatus": (s.outgoing ? ReadStatus.read : .unread).rawValue,
            "seenStatus": (s.outgoing ? SeenStatus.notApplicable : .unseen).rawValue,
        ]
        if !preview.isEmpty { json["preview"] = preview }
        if let d = s.sourceDevice { json["sourceDevice"] = d }
        if let g = s.serverGuid { json["serverGuid"] = g }
        if let t = s.serverTimestamp { json["serverTimestamp"] = t }
        if let l = s.distributionListId { json["storyDistributionListId"] = l }
        if !s.sendState.isEmpty { json["sendStateByConversationId"] = s.sendState }
        if !s.outgoing { json["unidentifiedDeliveryReceived"] = s.unidentified }
        try db.execute(sql: """
            INSERT INTO messages (id, json, readStatus, seenStatus, sent_at, conversationId, received_at, type, body, sourceServiceId, serverGuid,
                                  sourceDevice, expireTimer, expirationStartTimestamp, storyDistributionListId, hasAttachments, hasFileAttachments,
                                  hasVisualMediaAttachments, schemaVersion)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'story', '', ?, ?, ?, 86400, ?, ?, 0, 0, 0, 14)
            """,
            arguments: [id, try MessageStore.jsonString(json), json["readStatus"] as? Int, json["seenStatus"] as? Int, Int64(s.sentAt), s.conversationId,
                        receivedAt, s.source, s.serverGuid, s.sourceDevice.map { Int($0) }, expirationStart, s.distributionListId])
        if case .fileAttachment(let pointer)? = story.attachment {
            try MessageStore.storeIncomingAttachments(db, messageId: id, conversationId: s.conversationId, sentAt: Int64(s.sentAt), attachments: [pointer])
        }
        if !s.outgoing {
            try MessageStore.updateConversationJSON(db, conversationId: s.conversationId) { $0["hasPostedStory"] = true }
        }
        return id
    }

    // MARK: queries

    /// The story `author` sent at `sentAt` (`findStoryMessage`).
    public static func find(_ db: Database, author: String, sentAt: UInt64) throws -> (id: String, conversationId: String, distributionListId: String?)? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT id, conversationId, storyDistributionListId FROM messages WHERE type = 'story' AND sourceServiceId = ? AND sent_at = ? LIMIT 1
            """, arguments: [author, Int64(sentAt)]) else { return nil }
        return (row["id"], row["conversationId"], row["storyDistributionListId"])
    }

    /// Unexpired stories, newest first.
    public static func stories(_ db: Database, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> [Story] {
        try Row.fetchAll(db, sql: """
            SELECT m.id, m.conversationId, m.sourceServiceId, m.sent_at, m.storyDistributionListId, m.readStatus, m.json, c.groupId
            FROM messages m LEFT JOIN conversations c ON c.id = m.conversationId
            WHERE m.type = 'story' AND m.expirationStartTimestamp + 86400000 > ? ORDER BY m.sent_at DESC
            """, arguments: [now]).map { row in
            let json = (try? MessageStore.jsonObject(row["json"])) ?? [:]
            let text = ((json["attachments"] as? [[String: Any]])?.first?["textAttachment"] as? [String: Any])?.compactMapValues { "\($0)" }
            let states = (json["sendStateByConversationId"] as? [String: [String: Any]] ?? [:]).compactMapValues { $0["status"] as? String }
            return Story(id: row["id"], conversationId: row["conversationId"], sourceServiceId: row["sourceServiceId"] ?? "",
                         sentAt: UInt64(row["sent_at"] as Int64), distributionListId: row["storyDistributionListId"], groupId: row["groupId"],
                         canReplyToStory: json["canReplyToStory"] as? Bool ?? false, readStatus: row["readStatus"] ?? 0, textAttachment: text,
                         sendStateByConversationId: states)
        }
    }

    /// Removes stories past their 24 hours (with their replies' story link left dangling, as upstream).
    @discardableResult
    public static func deleteExpired(_ db: Database, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> Int {
        try db.execute(sql: "DELETE FROM messages WHERE type = 'story' AND expirationStartTimestamp + 86400000 <= ?", arguments: [now])
        return db.changesCount
    }

    /// We viewed a story: read + viewed, and a `storyReads` row (`markStoryRead`).
    public static func markViewed(_ db: Database, storyId: String, at date: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT conversationId, sourceServiceId, json FROM messages WHERE id = ? AND type = 'story'",
                                         arguments: [storyId]) else { return }
        var json = try MessageStore.jsonObject(row["json"])
        json["readStatus"] = ReadStatus.viewed.rawValue
        json["seenStatus"] = SeenStatus.seen.rawValue
        try db.execute(sql: "UPDATE messages SET json = ?, readStatus = ?, seenStatus = ? WHERE id = ?",
                       arguments: [try MessageStore.jsonString(json), ReadStatus.viewed.rawValue, SeenStatus.seen.rawValue, storyId])
        try db.execute(sql: "INSERT OR REPLACE INTO storyReads (authorId, conversationId, storyId, storyReadDate) VALUES (?, ?, ?, ?)",
                       arguments: [row["sourceServiceId"] as String? ?? "", row["conversationId"] as String, storyId, date])
    }

    /// Replies (and reactions) to a story, oldest first.
    public static func replies(_ db: Database, storyId: String) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT id FROM messages WHERE storyId = ? ORDER BY received_at", arguments: [storyId])
    }
}

/// Story distribution lists (`StoryDistributionWithMembersType`).
public enum StoryDistributionLists {
    public struct List: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var allowsReplies: Bool
        public var isBlockList: Bool
        public var members: [String]
        public var deletedAt: Int64?
    }

    public static func all(_ db: Database, includeDeleted: Bool = false) throws -> [List] {
        try Row.fetchAll(db, sql: "SELECT * FROM storyDistributions" + (includeDeleted ? "" : " WHERE deletedAtTimestamp IS NULL")).map { row in
            let id: String = row["id"]
            return List(id: id, name: row["name"] ?? "", allowsReplies: (row["allowsReplies"] as Int64? ?? 1) != 0,
                        isBlockList: (row["isBlockList"] as Int64? ?? 0) != 0,
                        members: try String.fetchAll(db, sql: "SELECT serviceId FROM storyDistributionMembers WHERE listId = ?", arguments: [id]),
                        deletedAt: row["deletedAtTimestamp"])
        }
    }

    public static func list(_ db: Database, id: String) throws -> List? { try all(db, includeDeleted: true).first { $0.id == id } }

    /// Creates a custom list (`createNewStoryDistributionList`); returns its id.
    @discardableResult
    public static func create(_ db: Database, name: String, members: [String], allowsReplies: Bool = true) throws -> String {
        let id = UUID().uuidString.lowercased()
        try db.execute(sql: "INSERT INTO storyDistributions (id, name, allowsReplies, isBlockList, senderKeyInfoJson) VALUES (?, ?, ?, 0, NULL)",
                       arguments: [id, name, allowsReplies])
        try setMembers(db, listId: id, members)
        try StorageWriteBack.recordChanged(db, .storyList(id: id))
        return id
    }

    static func setMembers(_ db: Database, listId: String, _ members: [String]) throws {
        try db.execute(sql: "DELETE FROM storyDistributionMembers WHERE listId = ?", arguments: [listId])
        for m in Set(members) {
            try db.execute(sql: "INSERT INTO storyDistributionMembers (listId, serviceId) VALUES (?, ?)", arguments: [listId, m])
        }
    }

    /// `modifyStoryDistributionWithMembers`: viewers added / removed, block list or not.
    public static func update(_ db: Database, listId: String, name: String? = nil, allowsReplies: Bool? = nil, isBlockList: Bool? = nil,
                              members: [String]? = nil) throws {
        if let name { try db.execute(sql: "UPDATE storyDistributions SET name = ? WHERE id = ?", arguments: [name, listId]) }
        if let allowsReplies { try db.execute(sql: "UPDATE storyDistributions SET allowsReplies = ? WHERE id = ?", arguments: [allowsReplies, listId]) }
        if let isBlockList { try db.execute(sql: "UPDATE storyDistributions SET isBlockList = ? WHERE id = ?", arguments: [isBlockList, listId]) }
        if let members { try setMembers(db, listId: listId, members) }
        try StorageWriteBack.recordChanged(db, .storyList(id: listId))
    }

    /// `deleteStoryDistribution`: a tombstone storage keeps for 30 days (My Story can't go).
    public static func delete(_ db: Database, listId: String) throws {
        guard listId != StoryStore.myStoryId else { return }
        try db.execute(sql: "UPDATE storyDistributions SET deletedAtTimestamp = ?, name = '' WHERE id = ?", arguments: [MessageStore.now(), listId])
        try db.execute(sql: "DELETE FROM storyDistributionMembers WHERE listId = ?", arguments: [listId])
        try StorageWriteBack.recordChanged(db, .storyList(id: listId))
    }

    /// Who a story to `list` goes to: its members, or (My Story as a block list) every Signal
    /// connection not excluded (`getListMemberServiceIds`).
    public static func recipients(_ db: Database, list: List, signalConnections: [String]) -> [String] {
        if list.id == StoryStore.myStoryId && list.isBlockList {
            let excluded = Set(list.members)
            return signalConnections.filter { !excluded.contains($0) }
        }
        return list.members
    }

    /// `getSignalConnections`: contacts we share our profile with (profile sharing on, not
    /// blocked or hidden), with an ACI.
    public static func signalConnections(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT serviceId FROM conversations WHERE type = 'private' AND serviceId IS NOT NULL
              AND json ->> '$.profileSharing' = 1 AND IFNULL(json ->> '$.isBlocked', 0) = 0 AND json ->> '$.removalStage' IS NULL
            """)
    }
}
