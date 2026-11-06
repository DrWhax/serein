// Chat folders (ts/types/ChatFolder.std.ts + sql/server/chatFolders.std.ts): the "All chats"
// folder and custom ones (which chats they include / exclude, unread only, muted or not), in
// order; deleted folders keep a tombstone (position 2^32−1) for storage until the message
// queue time passes. Every local change is queued for the storage service.

import Foundation
import GRDB

public struct ChatFolder: Sendable, Hashable, Identifiable {
    public enum FolderType: Int, Sendable { case unknown = 0, all = 1, custom = 2 }
    public var id: String
    public var folderType: FolderType
    public var name: String
    public var position: Int64
    public var showOnlyUnread: Bool
    public var showMutedChats: Bool
    public var includeAllIndividualChats: Bool
    public var includeAllGroupChats: Bool
    public var includedConversationIds: [String]
    public var excludedConversationIds: [String]
    public var deletedAtTimestampMs: Int64

    public init(id: String = UUID().uuidString.lowercased(), folderType: FolderType = .custom, name: String, position: Int64 = 0,
                showOnlyUnread: Bool = false, showMutedChats: Bool = true, includeAllIndividualChats: Bool = false,
                includeAllGroupChats: Bool = false, includedConversationIds: [String] = [], excludedConversationIds: [String] = [],
                deletedAtTimestampMs: Int64 = 0) {
        self.id = id
        self.folderType = folderType
        self.name = name
        self.position = position
        self.showOnlyUnread = showOnlyUnread
        self.showMutedChats = showMutedChats
        self.includeAllIndividualChats = includeAllIndividualChats
        self.includeAllGroupChats = includeAllGroupChats
        self.includedConversationIds = includedConversationIds
        self.excludedConversationIds = excludedConversationIds
        self.deletedAtTimestampMs = deletedAtTimestampMs
    }

    public static let nameMaxLength = 32
    public static let deletedPosition: Int64 = 4_294_967_295
}

/// What a chat-folder test needs of a conversation (`ConversationPropsForChatFolder`).
public struct ChatFolderConversation: Sendable, Hashable {
    public var id: String
    public var isGroup: Bool
    public var muteExpiresAt: Int64
    public var unreadCount: Int
    public var unreadMentionsCount: Int
    public var markedUnread: Bool
    public init(id: String, isGroup: Bool, muteExpiresAt: Int64 = 0, unreadCount: Int = 0, unreadMentionsCount: Int = 0, markedUnread: Bool = false) {
        self.id = id
        self.isGroup = isGroup
        self.muteExpiresAt = muteExpiresAt
        self.unreadCount = unreadCount
        self.unreadMentionsCount = unreadMentionsCount
        self.markedUnread = markedUnread
    }
}

public enum ChatFolderStore {
    /// `isConversationInChatFolder`
    public static func contains(_ folder: ChatFolder, _ c: ChatFolderConversation, ignoreShowOnlyUnread: Bool = false,
                                ignoreShowMutedChats: Bool = false) -> Bool {
        if folder.folderType == .all { return true }
        let included = (folder.includeAllIndividualChats && !c.isGroup) || (folder.includeAllGroupChats && c.isGroup)
            || folder.includedConversationIds.contains(c.id)
        guard included else { return false }
        if !ignoreShowOnlyUnread, folder.showOnlyUnread, !(c.unreadCount > 0 || c.unreadMentionsCount > 0 || c.markedUnread) { return false }
        if !ignoreShowMutedChats, !folder.showMutedChats, c.muteExpiresAt > 0 { return false }
        return !folder.excludedConversationIds.contains(c.id)
    }

    static func folder(_ row: Row) -> ChatFolder {
        func ids(_ s: String?) -> [String] { (try? JSONDecoder().decode([String].self, from: Data((s ?? "[]").utf8))) ?? [] }
        return ChatFolder(id: row["id"], folderType: ChatFolder.FolderType(rawValue: row["folderType"]) ?? .unknown, name: row["name"],
                          position: row["position"], showOnlyUnread: (row["showOnlyUnread"] as Int64) == 1, showMutedChats: (row["showMutedChats"] as Int64) == 1,
                          includeAllIndividualChats: (row["includeAllIndividualChats"] as Int64) == 1,
                          includeAllGroupChats: (row["includeAllGroupChats"] as Int64) == 1,
                          includedConversationIds: ids(row["includedConversationIds"]), excludedConversationIds: ids(row["excludedConversationIds"]),
                          deletedAtTimestampMs: row["deletedAtTimestampMs"])
    }

    static func json(_ ids: [String]) throws -> String { String(decoding: try JSONEncoder().encode(ids), as: UTF8.self) }

    /// `getCurrentChatFolders`: known types, not deleted, in order.
    public static func current(_ db: Database) throws -> [ChatFolder] {
        try Row.fetchAll(db, sql: "SELECT * FROM chatFolders WHERE folderType IS NOT 0 AND deletedAtTimestampMs IS 0 ORDER BY position ASC").map(folder)
    }

    public static func get(_ db: Database, id: String) throws -> ChatFolder? {
        try Row.fetchOne(db, sql: "SELECT * FROM chatFolders WHERE id = ?", arguments: [id]).map(folder)
    }

    static func insert(_ db: Database, _ f: ChatFolder) throws {
        try db.execute(sql: """
            INSERT INTO chatFolders (id, folderType, name, position, showOnlyUnread, showMutedChats, includeAllIndividualChats, includeAllGroupChats,
                                     includedConversationIds, excludedConversationIds, deletedAtTimestampMs, storageNeedsSync)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
            """, arguments: [f.id, f.folderType.rawValue, f.name, f.position, f.showOnlyUnread, f.showMutedChats, f.includeAllIndividualChats,
                             f.includeAllGroupChats, try json(f.includedConversationIds), try json(f.excludedConversationIds), f.deletedAtTimestampMs])
        try StorageWriteBack.recordChanged(db, .chatFolder(id: f.id))
    }

    /// `createChatFolder`: a custom folder at the end.
    @discardableResult
    public static func create(_ db: Database, _ params: ChatFolder) throws -> ChatFolder {
        var f = params
        f.name = String(f.name.prefix(ChatFolder.nameMaxLength))
        f.folderType = .custom
        f.position = (try Int64.fetchOne(db, sql: "SELECT MAX(position) FROM chatFolders WHERE deletedAtTimestampMs IS 0") ?? -1) + 1
        f.deletedAtTimestampMs = 0
        try insert(db, f)
        return f
    }

    /// `createAllChatsChatFolder`: "All chats" first, the others moved one along.
    @discardableResult
    public static func ensureAllChats(_ db: Database) throws -> ChatFolder {
        if let existing = try current(db).first(where: { $0.folderType == .all }) { return existing }
        try resetPositions(db, offset: 1)
        let f = ChatFolder(folderType: .all, name: "", position: 0, includeAllIndividualChats: true, includeAllGroupChats: true)
        try insert(db, f)
        return f
    }

    /// `updateChatFolder`
    public static func update(_ db: Database, _ f: ChatFolder) throws {
        try db.execute(sql: """
            UPDATE chatFolders SET folderType = ?, name = ?, position = ?, showOnlyUnread = ?, showMutedChats = ?, includeAllIndividualChats = ?,
              includeAllGroupChats = ?, includedConversationIds = ?, excludedConversationIds = ?, deletedAtTimestampMs = ?, storageNeedsSync = 1
            WHERE id = ?
            """, arguments: [f.folderType.rawValue, String(f.name.prefix(ChatFolder.nameMaxLength)), f.position, f.showOnlyUnread, f.showMutedChats,
                             f.includeAllIndividualChats, f.includeAllGroupChats, try json(f.includedConversationIds), try json(f.excludedConversationIds),
                             f.deletedAtTimestampMs, f.id])
        try StorageWriteBack.recordChanged(db, .chatFolder(id: f.id))
    }

    /// `updateChatFolderToggleChat`: "Add to folder" / "Remove from folder".
    public static func toggle(_ db: Database, folderId: String, conversationId: String, included: Bool) throws {
        guard var f = try get(db, id: folderId) else { return }
        var inc = Set(f.includedConversationIds), exc = Set(f.excludedConversationIds)
        if included { inc.insert(conversationId); exc.remove(conversationId) } else { inc.remove(conversationId); exc.insert(conversationId) }
        f.includedConversationIds = inc.sorted()
        f.excludedConversationIds = exc.sorted()
        try update(db, f)
    }

    /// `markChatFolderDeleted`: a tombstone; the rest close the gap.
    public static func delete(_ db: Database, id: String, at timestamp: Int64) throws {
        try db.execute(sql: """
            UPDATE chatFolders SET position = ?, deletedAtTimestampMs = ?, storageNeedsSync = 1, includedConversationIds = '[]',
              excludedConversationIds = '[]' WHERE id = ?
            """, arguments: [ChatFolder.deletedPosition, timestamp, id])
        try resetPositions(db, offset: 0)
        try StorageWriteBack.recordChanged(db, .chatFolder(id: id))
    }

    /// `updateChatFolderPositions`: the folders in this order.
    public static func reorder(_ db: Database, ids: [String]) throws {
        for (i, id) in ids.enumerated() {
            try db.execute(sql: "UPDATE chatFolders SET position = ?, storageNeedsSync = 1 WHERE id = ?", arguments: [i, id])
        }
        try StorageService.scheduleUpload(db)
    }

    static func resetPositions(_ db: Database, offset: Int64) throws {
        let ids = try String.fetchAll(db, sql: "SELECT id FROM chatFolders WHERE deletedAtTimestampMs IS 0 ORDER BY position ASC")
        for (i, id) in ids.enumerated() {
            try db.execute(sql: "UPDATE chatFolders SET position = ?, storageNeedsSync = 1 WHERE id = ?", arguments: [offset + Int64(i), id])
        }
    }

    /// `deleteExpiredChatFolders`: tombstones older than the message queue time go.
    @discardableResult
    public static func deleteExpired(_ db: Database, messageQueueTime: Int64, now: Int64) throws -> [String] {
        let ids = try String.fetchAll(db, sql: "SELECT id FROM chatFolders WHERE deletedAtTimestampMs > 0 AND deletedAtTimestampMs < ?",
                                      arguments: [now - messageQueueTime])
        try db.execute(sql: "DELETE FROM chatFolders WHERE deletedAtTimestampMs > 0 AND deletedAtTimestampMs < ?", arguments: [now - messageQueueTime])
        return ids
    }

    /// The conversations as chat-folder tests see them.
    public static func conversations(_ db: Database) throws -> [ChatFolderConversation] {
        try Row.fetchAll(db, sql: "SELECT id, type, json FROM conversations WHERE active_at > 0").map { row in
            let j = try MessageStore.jsonObject(row["json"])
            return ChatFolderConversation(id: row["id"], isGroup: (row["type"] as String) == "group",
                                          muteExpiresAt: (j["muteExpiresAt"] as? NSNumber)?.int64Value ?? 0,
                                          unreadCount: (j["unreadCount"] as? NSNumber)?.intValue ?? 0,
                                          unreadMentionsCount: (j["unreadMentionsCount"] as? NSNumber)?.intValue ?? 0,
                                          markedUnread: j["markedUnread"] as? Bool ?? false)
        }
    }
}
