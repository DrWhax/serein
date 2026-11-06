// Local changes that storage must hear about (upstream `captureChange` +
// `runStorageServiceUploadJob`, and the `storageNeedsSync = 1` the SQL layer sets on the
// record tables). Each call marks the record and queues one upload in the caller's
// transaction; poke the JobQueue after the commit.

import Foundation
import GRDB

public enum StorageWriteBack {
    /// A contact's or group's synced state changed (archive, mute, pin, block, profile
    /// sharing, nickname/note, …).
    public static func conversationChanged(_ db: Database, conversationId: String) throws {
        try MessageStore.updateConversationJSON(db, conversationId: conversationId) { $0["needsStorageServiceSync"] = true }
        try StorageService.scheduleUpload(db)
    }

    /// AccountRecord state changed (settings items, Note to Self, pins, profile).
    public static func accountChanged(_ db: Database, account: Account) throws {
        try conversationChanged(db, conversationId: try StorageLocal.ourConversation(db, account: account))
    }

    public enum Table: Sendable {
        case storyList(id: String)
        case chatFolder(id: String)
        case notificationProfile(id: String)
        case installedStickerPack(id: String)
        case uninstalledStickerPack(id: String)
        case favoriteSticker(packId: String, stickerId: Int)
        case callLink(roomId: String)
        case defunctCallLink(roomId: String)
    }

    /// A row of one of the record tables changed.
    public static func recordChanged(_ db: Database, _ record: Table) throws {
        switch record {
        case .storyList(let id): try db.execute(sql: "UPDATE storyDistributions SET storageNeedsSync = 1 WHERE id = ?", arguments: [id])
        case .chatFolder(let id): try db.execute(sql: "UPDATE chatFolders SET storageNeedsSync = 1 WHERE id = ?", arguments: [id])
        case .notificationProfile(let id): try db.execute(sql: "UPDATE notificationProfiles SET storageNeedsSync = 1 WHERE id = ?", arguments: [id])
        case .installedStickerPack(let id): try db.execute(sql: "UPDATE sticker_packs SET storageNeedsSync = 1 WHERE id = ?", arguments: [id])
        case .uninstalledStickerPack(let id): try db.execute(sql: "UPDATE uninstalled_sticker_packs SET storageNeedsSync = 1 WHERE id = ?", arguments: [id])
        case .favoriteSticker(let packId, let stickerId):
            try db.execute(sql: "UPDATE favorite_stickers SET storageNeedsSync = 1 WHERE packId = ? AND stickerId = ?", arguments: [packId, stickerId])
        case .callLink(let roomId): try db.execute(sql: "UPDATE callLinks SET storageNeedsSync = 1 WHERE roomId = ?", arguments: [roomId])
        case .defunctCallLink(let roomId): try db.execute(sql: "UPDATE defunctCallLinks SET storageNeedsSync = 1 WHERE roomId = ?", arguments: [roomId])
        }
        try StorageService.scheduleUpload(db)
    }

    /// A conversation storage has never seen (`ConversationController` "new conversation").
    static func conversationCreated(_ db: Database, conversationId: String) throws {
        let storageID = try String.fetchOne(db, sql: "SELECT json ->> '$.storageID' FROM conversations WHERE id = ?", arguments: [conversationId])
        if storageID == nil { try StorageService.scheduleUpload(db) }
    }
}
