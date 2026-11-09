// Records kept in their own tables: StoryDistributionListRecord (storyDistributions +
// storyDistributionMembers), InstalledStickerPackRecord (sticker_packs /
// uninstalled_sticker_packs), FavoriteStickerRecord (favorite_stickers), CallLinkRecord
// (callLinks / defunctCallLinks / pending refresh jobs), ChatFolderRecord (chatFolders) and
// NotificationProfile (notificationProfiles). Ports of the matching to*/merge* functions in
// ts/services/storageRecordOps.preload.ts and the SQL they call in ts/sql.
//
// Sticker downloads (step 4) and call-link refreshes (Phase 6) are queued as jobs here
// ("sticker pack download", "call link refresh") for those services to run.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos

/// Where a local storage record lives, for writing its new storageID after an upload or
/// handling its absence from the remote manifest.
enum StorageOwner: Hashable, Sendable {
    case conversation(String)
    case account(String)
    case storyList(String)
    case installedPack(String)
    case uninstalledPack(String)
    case favoriteSticker(packId: String, stickerId: Int)
    case callLink(roomId: String)
    case defunctCallLink(roomId: String)
    case pendingCallLink(jobId: String)
    case chatFolder(String)
    case notificationProfile(String)
}

/// One local record for `generateManifest`.
struct StorageLocalEntry {
    var type: Signalservice_ManifestRecord.Identifier.TypeEnum
    var owner: StorageOwner
    var storageID: String?
    var storageVersion: UInt64?
    var needsSync: Bool
    var record: Signalservice_StorageRecord
    /// An expired tombstone: its key is deleted and the local row removed.
    var drop = false
}

struct CallLinkRefreshJob: Codable, Sendable {
    static let queueType = "call link refresh"
    var rootKey: String
    var adminKey: String?
    var storageID: String?
    var storageVersion: UInt64?
    var storageUnknownFields: String?
    var storageNeedsSync: Bool?
    var source: String
}

struct StickerPackDownloadJob: Codable, Sendable {
    static let queueType = "sticker pack download"
    var packId: String
    var packKey: String
    var finalStatus: String
    var position: Int?
    var favoriteStickerIds: [Int]? = nil
    var actionSource: String
}

/// A StickerPackOperation from another of our devices.
struct StickerPackOperationJob: Codable, Sendable {
    static let queueType = "sticker pack operation"
    var packId: String
    var packKey: String
    var install: Bool
}

extension StorageRecords {
    static func record(_ r: Signalservice_StorageRecord.OneOf_Record) -> Signalservice_StorageRecord {
        var s = Signalservice_StorageRecord()
        s.record = r
        return s
    }

    static func u64(_ row: Row, _ col: String) -> UInt64? { (row[col] as Int64?).map { UInt64(max(0, $0)) } }

    // MARK: story distribution lists

    static func storyEntries(_ db: Database, ctx: StorageMergeContext) throws -> [StorageLocalEntry] {
        try Row.fetchAll(db, sql: "SELECT * FROM storyDistributions ORDER BY id").map { row in
            let id: String = row["id"]
            let members = try String.fetchAll(db, sql: "SELECT serviceId FROM storyDistributionMembers WHERE listId = ? ORDER BY serviceId", arguments: [id])
            var r = Signalservice_StoryDistributionListRecord()
            r.identifier = StorageLocal.uuidBytes(id) ?? Data()
            r.name = row["name"] ?? ""
            let deletedAt: Int64? = row["deletedAtTimestamp"]
            r.deletedAtTimestamp = UInt64(max(0, deletedAt ?? 0))
            r.allowsReplies = (row["allowsReplies"] as Int64? ?? 0) != 0
            r.isBlockList = (row["isBlockList"] as Int64? ?? 0) != 0
            if ctx.binaryServiceIds { r.recipientServiceIdsBinary = members.compactMap(StorageLocal.serviceIdBinary) } else { r.recipientServiceIds = members }
            try StorageLocal.attach(row["storageUnknownFields"], to: &r)
            let expired = deletedAt.map { $0 > 0 && StorageLocal.isOlderThan($0, ctx.messageQueueTime, now: ctx.now) } ?? false
            return StorageLocalEntry(type: .storyDistributionList, owner: .storyList(id), storageID: row["storageID"], storageVersion: u64(row, "storageVersion"),
                                     needsSync: (row["storageNeedsSync"] as Int64? ?? 0) != 0, record: record(.storyDistributionList(r)), drop: expired)
        }
    }

    /// `mergeStoryDistributionListRecord`
    static func mergeStoryList(_ db: Database, _ r: Signalservice_StoryDistributionListRecord, storageID: String,
                               ctx: StorageMergeContext) throws -> StorageMergeResult {
        guard !r.identifier.isEmpty else { throw StorageServiceError.recordTypeMismatch("story list without identifier") }
        let isMyStory = r.identifier == Data(count: 16)
        guard let listId = isMyStory ? StorageLocal.myStoryId : StorageLocal.uuidString(r.identifier) else {
            throw StorageServiceError.recordTypeMismatch("story list identifier")
        }
        let local = try Row.fetchOne(db, sql: "SELECT * FROM storyDistributions WHERE id = ?", arguments: [listId])
        var remoteMembers: [String]
        if !r.recipientServiceIdsBinary.isEmpty {
            remoteMembers = r.recipientServiceIdsBinary.compactMap { StorageLocal.serviceId(binary: $0, string: "") }
        } else {
            remoteMembers = r.recipientServiceIds.compactMap { StorageLocal.serviceId(binary: Data(), string: $0) }
        }
        let deletedAt: Int64? = r.deletedAtTimestamp > 0 ? Int64(r.deletedAtTimestamp) : nil
        var senderKeyInfo: String? = local?["senderKeyInfoJson"]
        if let json = senderKeyInfo, deletedAt != nil,
           let distributionId = (try? MessageStore.jsonObject(json))?["distributionId"] as? String {
            let sender = "\(ctx.account.aci).\(ctx.account.deviceId)"
            try db.execute(sql: "DELETE FROM senderKeys WHERE senderId = ? AND distributionId = ?", arguments: [sender, distributionId.lowercased()])
            senderKeyInfo = nil
        }
        var name = r.name
        if local != nil, deletedAt == nil, name.isEmpty {
            // isBadRemoteData: keep the local name and members.
            name = local?["name"] ?? ""
            remoteMembers = try String.fetchAll(db, sql: "SELECT serviceId FROM storyDistributionMembers WHERE listId = ?", arguments: [listId])
        }
        try db.execute(sql: """
            INSERT INTO storyDistributions (id, name, senderKeyInfoJson, deletedAtTimestamp, allowsReplies, isBlockList, storageID, storageVersion,
              storageUnknownFields, storageNeedsSync) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, senderKeyInfoJson = excluded.senderKeyInfoJson,
              deletedAtTimestamp = excluded.deletedAtTimestamp, allowsReplies = excluded.allowsReplies, isBlockList = excluded.isBlockList,
              storageID = excluded.storageID, storageVersion = excluded.storageVersion, storageUnknownFields = excluded.storageUnknownFields,
              storageNeedsSync = 0
            """, arguments: [listId, name, senderKeyInfo, isMyStory ? nil : deletedAt, r.allowsReplies ? 1 : 0, r.isBlockList ? 1 : 0, storageID,
                             Int64(ctx.version), StorageLocal.unknownFields(r)])
        try db.execute(sql: "DELETE FROM storyDistributionMembers WHERE listId = ?", arguments: [listId])
        for m in Set(remoteMembers) {
            try db.execute(sql: "INSERT INTO storyDistributionMembers (listId, serviceId) VALUES (?, ?)", arguments: [listId, m])
        }
        return StorageMergeResult()
    }

    /// processManifest: My Stories always exists (created as needing sync).
    static func ensureMyStory(_ db: Database) throws {
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM storyDistributions WHERE id = ?", arguments: [StorageLocal.myStoryId]) == nil else { return }
        try db.execute(sql: """
            INSERT INTO storyDistributions (id, name, allowsReplies, isBlockList, storageNeedsSync) VALUES (?, ?, 1, 1, 1)
            """, arguments: [StorageLocal.myStoryId, StorageLocal.myStoryId])
    }

    // MARK: sticker packs

    static func stickerPackEntries(_ db: Database, ctx: StorageMergeContext) throws -> [StorageLocalEntry] {
        var out: [StorageLocalEntry] = []
        var uninstalledIds = Set<String>()
        for row in try Row.fetchAll(db, sql: "SELECT * FROM uninstalled_sticker_packs ORDER BY id") {
            let id: String = row["id"]
            uninstalledIds.insert(id)
            let at: Int64 = row["uninstalledAt"] ?? 0
            var r = Signalservice_InstalledStickerPackRecord()
            r.packID = Data(hex: id) ?? Data()
            r.deletedAtTimestamp = UInt64(max(0, at))
            try StorageLocal.attach(row["storageUnknownFields"], to: &r)
            out.append(StorageLocalEntry(type: .stickerPack, owner: .uninstalledPack(id), storageID: row["storageID"], storageVersion: u64(row, "storageVersion"),
                                         needsSync: (row["storageNeedsSync"] as Int64? ?? 0) != 0, record: record(.installedStickerPack(r)),
                                         drop: at != 0 && StorageLocal.isOlderThan(at, ctx.messageQueueTime, now: ctx.now)))
        }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM sticker_packs WHERE status IS 'installed' OR storageID IS NOT NULL ORDER BY id") {
            let id: String = row["id"]
            if uninstalledIds.contains(id) {
                // Both installed and uninstalled: uninstall wins (`uninstallStickerPack`).
                try db.execute(sql: """
                    UPDATE sticker_packs SET status = 'downloaded', storageID = NULL, storageVersion = NULL, storageUnknownFields = NULL,
                      storageNeedsSync = 0 WHERE id = ?
                    """, arguments: [id])
                continue
            }
            var r = Signalservice_InstalledStickerPackRecord()
            r.packID = Data(hex: id) ?? Data()
            r.packKey = Data(base64Encoded: row["key"] as String? ?? "") ?? Data()
            r.position = UInt32(clamping: row["position"] as Int64? ?? 0)
            try StorageLocal.attach(row["storageUnknownFields"], to: &r)
            out.append(StorageLocalEntry(type: .stickerPack, owner: .installedPack(id), storageID: row["storageID"], storageVersion: u64(row, "storageVersion"),
                                         needsSync: (row["storageNeedsSync"] as Int64? ?? 0) != 0, record: record(.installedStickerPack(r))))
        }
        return out
    }

    /// `mergeInstalledStickerPackRecord`
    static func mergeStickerPack(_ db: Database, _ r: Signalservice_InstalledStickerPackRecord, storageID: String,
                                 ctx: StorageMergeContext) throws -> StorageMergeResult {
        guard !r.packID.isEmpty else { throw StorageServiceError.recordTypeMismatch("sticker pack without packId") }
        let id = r.packID.hexString
        let uninstalled = try Row.fetchOne(db, sql: "SELECT * FROM uninstalled_sticker_packs WHERE id = ?", arguments: [id])
        let installed = uninstalled == nil ? try Row.fetchOne(db, sql: "SELECT * FROM sticker_packs WHERE id = ?", arguments: [id]) : nil
        let remoteDeletedAt = Int64(clamping: r.deletedAtTimestamp)
        let unknown = StorageLocal.unknownFields(r)
        let wasUninstalled = uninstalled != nil
        let localExists = uninstalled != nil || installed != nil
        let version = Int64(ctx.version)

        if remoteDeletedAt > 0 {
            if !wasUninstalled {
                if installed != nil {
                    try db.execute(sql: """
                        UPDATE sticker_packs SET status = CASE WHEN status = 'installed' THEN 'downloaded' ELSE status END,
                          storageID = NULL, storageVersion = NULL, storageUnknownFields = NULL, storageNeedsSync = 0 WHERE id = ?
                        """, arguments: [id])
                }
                try db.execute(sql: """
                    INSERT OR REPLACE INTO uninstalled_sticker_packs (id, uninstalledAt, storageID, storageVersion, storageUnknownFields, storageNeedsSync)
                    VALUES (?, ?, ?, ?, ?, 0)
                    """, arguments: [id, remoteDeletedAt, storageID, version, unknown])
            } else {
                try db.execute(sql: """
                    UPDATE uninstalled_sticker_packs SET storageID = ?, storageVersion = ?, storageUnknownFields = ?, storageNeedsSync = 0 WHERE id = ?
                    """, arguments: [storageID, version, unknown, id])
            }
        } else {
            guard !r.packKey.isEmpty else { throw StorageServiceError.recordTypeMismatch("installed sticker pack without packKey") }
            let key = r.packKey.base64EncodedString()
            let position = Int64(r.position)
            if !localExists || wasUninstalled {
                try db.execute(sql: "DELETE FROM uninstalled_sticker_packs WHERE id = ?", arguments: [id])
                let status: String? = try String.fetchOne(db, sql: "SELECT status FROM sticker_packs WHERE id = ?", arguments: [id])
                if status == "downloaded" || status == "installed" {
                    try db.execute(sql: "UPDATE sticker_packs SET status = 'installed', installedAt = ? WHERE id = ?", arguments: [ctx.now, id])
                } else {
                    try db.execute(sql: """
                        INSERT INTO sticker_packs (id, key, status, attemptedStatus, position, createdAt, downloadAttempts) VALUES (?, ?, 'pending', 'installed', ?, ?, 0)
                        ON CONFLICT(id) DO UPDATE SET key = excluded.key, attemptedStatus = 'installed'
                        """, arguments: [id, key, position, ctx.now])
                    try JobQueue.insert(db, queueType: StickerPackDownloadJob.queueType,
                                        payload: StickerPackDownloadJob(packId: id, packKey: key, finalStatus: "installed", position: Int(position),
                                                                        actionSource: "storageService"))
                }
            }
            try db.execute(sql: """
                UPDATE sticker_packs SET storageID = ?, storageVersion = ?, storageUnknownFields = ?, storageNeedsSync = 0, position = ? WHERE id = ?
                """, arguments: [storageID, version, unknown, position, id])
        }
        var result = StorageMergeResult()
        result.shouldDrop = remoteDeletedAt > 0 && StorageLocal.isOlderThan(remoteDeletedAt, ctx.messageQueueTime, now: ctx.now)
        return result
    }

    // MARK: favourite stickers

    static func favoriteStickerEntries(_ db: Database, ctx: StorageMergeContext) throws -> [StorageLocalEntry] {
        try Row.fetchAll(db, sql: "SELECT * FROM favorite_stickers ORDER BY packId, stickerId").map { row in
            let packId: String = row["packId"], stickerId: Int = row["stickerId"]
            let deletedAt: Int64? = row["deletedAtTimestampMs"]
            var r = Signalservice_FavoriteStickerRecord()
            r.packID = Data(hex: packId) ?? Data()
            r.stickerID = UInt32(clamping: stickerId)
            if let deletedAt {
                r.deletedAtTimestamp = UInt64(max(0, deletedAt))
            } else {
                r.packKey = (row["packKey"] as String?).flatMap { Data(base64Encoded: $0) } ?? Data()
                r.favoritedAtTimestamp = UInt64(max(0, row["favoritedAtTimestampMs"] as Int64? ?? 0))
            }
            try StorageLocal.attach(row["storageUnknownFields"], to: &r)
            let expired = deletedAt.map { $0 != 0 && StorageLocal.isOlderThan($0, ctx.messageQueueTime, now: ctx.now) } ?? false
            return StorageLocalEntry(type: .favoriteStickerPack, owner: .favoriteSticker(packId: packId, stickerId: stickerId), storageID: row["storageID"],
                                     storageVersion: u64(row, "storageVersion"), needsSync: (row["storageNeedsSync"] as Int64? ?? 0) != 0,
                                     record: record(.sticker(r)), drop: expired)
        }
    }

    /// `mergeFavoriteStickerRecord`
    static func mergeFavoriteSticker(_ db: Database, _ r: Signalservice_FavoriteStickerRecord, storageID: String,
                                     ctx: StorageMergeContext) throws -> StorageMergeResult {
        guard !r.packID.isEmpty else { throw StorageServiceError.recordTypeMismatch("favourite sticker without packId") }
        let packId = r.packID.hexString, stickerId = Int(r.stickerID)
        let deletedAt = Int64(clamping: r.deletedAtTimestamp)
        let local = try Row.fetchOne(db, sql: "SELECT * FROM favorite_stickers WHERE packId = ? AND stickerId = ?", arguments: [packId, stickerId])
        let isDeleted = deletedAt > 0
        let shouldDrop = isDeleted && StorageLocal.isOlderThan(deletedAt, ctx.messageQueueTime, now: ctx.now)
        if shouldDrop {
            try db.execute(sql: "DELETE FROM favorite_stickers WHERE packId = ? AND stickerId = ?", arguments: [packId, stickerId])
        } else {
            let packKey: String?, favoritedAt: Int64?, status: String
            if isDeleted {
                (packKey, favoritedAt, status) = (nil, nil, "deleted")
            } else {
                guard !r.packKey.isEmpty else { throw StorageServiceError.recordTypeMismatch("favourite sticker without packKey") }
                let localStatus: String? = local?["status"]
                (packKey, favoritedAt, status) = (r.packKey.base64EncodedString(), Int64(clamping: r.favoritedAtTimestamp),
                                                  localStatus == "installed" ? "installed" : "known")
            }
            if !isDeleted, status != "installed", let packKey {
                // installFavoriteSticker: the pack becomes known and that sticker is fetched.
                try Stickers.savePackMetadata(db, packId: packId, packKey: packKey, resetDownloadAttempts: true)
                try JobQueue.insert(db, queueType: StickerPackDownloadJob.queueType,
                                    payload: StickerPackDownloadJob(packId: packId, packKey: packKey, finalStatus: "known", position: nil,
                                                                    favoriteStickerIds: [stickerId], actionSource: "storageService"))
            }
            try db.execute(sql: """
                INSERT INTO favorite_stickers (packId, stickerId, packKey, favoritedAtTimestampMs, deletedAtTimestampMs, status, storageID, storageVersion,
                  storageUnknownFields, storageNeedsSync) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT(packId, stickerId) DO UPDATE SET packKey = excluded.packKey, favoritedAtTimestampMs = excluded.favoritedAtTimestampMs,
                  deletedAtTimestampMs = excluded.deletedAtTimestampMs, status = excluded.status, storageID = excluded.storageID,
                  storageVersion = excluded.storageVersion, storageUnknownFields = excluded.storageUnknownFields, storageNeedsSync = 0
                """, arguments: [packId, stickerId, packKey, favoritedAt, isDeleted ? deletedAt : nil, status, storageID, Int64(ctx.version),
                                 StorageLocal.unknownFields(r)])
        }
        return StorageMergeResult(shouldDrop: shouldDrop)
    }

    // MARK: call links

    /// ringrtc `CallLinkRootKey::derive_room_id`: HKDF-SHA256 over the first 16 bytes, hex.
    static func roomId(rootKey: Data) throws -> String {
        try SignalCrypto.hkdf(32, ikm: rootKey.prefix(16), info: Data("20230501-Signal-CallLinkRootKey-RoomId".utf8)).hexString
    }

    static func callLinkEntries(_ db: Database, ctx: StorageMergeContext) throws -> [StorageLocalEntry] {
        var out: [StorageLocalEntry] = []
        var rooms = Set<String>()
        for row in try Row.fetchAll(db, sql: "SELECT * FROM callLinks ORDER BY roomId") {
            guard let rootKey: Data = row["rootKey"], let adminKey: Data = row["adminKey"] else { continue }
            let roomId: String = row["roomId"]
            rooms.insert(roomId)
            var r = Signalservice_CallLinkRecord()
            r.rootKey = rootKey
            if (row["deleted"] as Int64? ?? 0) == 1 {
                let at: Int64? = row["deletedAt"]
                r.deletedAtTimestampMs = UInt64(max(0, (at ?? 0) > 0 ? at! : ctx.now))
            } else {
                r.adminPasskey = adminKey
            }
            try StorageLocal.attach(row["storageUnknownFields"], to: &r)
            out.append(StorageLocalEntry(type: .callLink, owner: .callLink(roomId: roomId), storageID: row["storageID"], storageVersion: u64(row, "storageVersion"),
                                         needsSync: (row["storageNeedsSync"] as Int64? ?? 0) != 0, record: record(.callLink(r))))
        }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM defunctCallLinks ORDER BY roomId") {
            let roomId: String = row["roomId"]
            rooms.insert(roomId)
            var r = Signalservice_CallLinkRecord()
            r.rootKey = row["rootKey"] ?? Data()
            r.deletedAtTimestampMs = UInt64(max(0, row["addedAt"] as Int64? ?? 0))
            try StorageLocal.attach(row["storageUnknownFields"], to: &r)
            out.append(StorageLocalEntry(type: .callLink, owner: .defunctCallLink(roomId: roomId), storageID: row["storageID"],
                                         storageVersion: u64(row, "storageVersion"), needsSync: (row["storageNeedsSync"] as Int64? ?? 0) != 0,
                                         record: record(.callLink(r))))
        }
        for (jobId, job) in try pendingCallLinks(db) {
            guard let rootKey = Data(base64Encoded: job.rootKey), let adminKey = job.adminKey.flatMap({ Data(base64Encoded: $0) }),
                  !rooms.contains(try roomId(rootKey: rootKey)) else { continue }
            var r = Signalservice_CallLinkRecord()
            r.rootKey = rootKey
            r.adminPasskey = adminKey
            try StorageLocal.attach(job.storageUnknownFields.flatMap { Data(base64Encoded: $0) }, to: &r)
            out.append(StorageLocalEntry(type: .callLink, owner: .pendingCallLink(jobId: jobId), storageID: job.storageID, storageVersion: job.storageVersion,
                                         needsSync: job.storageNeedsSync ?? false, record: record(.callLink(r))))
        }
        return out
    }

    /// `callLinkRefreshJobQueue.getPendingAdminCallLinks`
    static func pendingCallLinks(_ db: Database) throws -> [(String, CallLinkRefreshJob)] {
        try Row.fetchAll(db, sql: "SELECT id, data FROM jobs WHERE queueType = ? ORDER BY timestamp", arguments: [CallLinkRefreshJob.queueType]).compactMap { row in
            guard let data = (row["data"] as String?)?.data(using: .utf8), let job = try? JSONDecoder().decode(CallLinkRefreshJob.self, from: data) else {
                return nil
            }
            return (row["id"], job)
        }
    }

    static func updatePendingCallLink(_ db: Database, jobId: String, _ change: (inout CallLinkRefreshJob) -> Void) throws {
        guard let data = try String.fetchOne(db, sql: "SELECT data FROM jobs WHERE id = ?", arguments: [jobId])?.data(using: .utf8),
              var job = try? JSONDecoder().decode(CallLinkRefreshJob.self, from: data) else { return }
        change(&job)
        try db.execute(sql: "UPDATE jobs SET data = ? WHERE id = ?", arguments: [String(decoding: try JSONEncoder().encode(job), as: UTF8.self), jobId])
    }

    /// `mergeCallLinkRecord`
    static func mergeCallLink(_ db: Database, _ r: Signalservice_CallLinkRecord, storageID: String, ctx: StorageMergeContext) throws -> StorageMergeResult {
        guard !r.rootKey.isEmpty else { return .drop("no rootKey") }
        let roomId = try roomId(rootKey: r.rootKey)
        let local = try Row.fetchOne(db, sql: "SELECT * FROM callLinks WHERE roomId = ?", arguments: [roomId])
        let defunct = try Row.fetchOne(db, sql: "SELECT * FROM defunctCallLinks WHERE roomId = ?", arguments: [roomId])
        let candidates = [Int64(clamping: r.deletedAtTimestampMs), local?["deletedAt"] as Int64? ?? 0, defunct?["addedAt"] as Int64? ?? 0].filter { $0 > 0 }
        let deletedAt = candidates.min()
        let shouldDrop = deletedAt.map { StorageLocal.isOlderThan($0, ctx.messageQueueTime, now: ctx.now) } ?? false
        let unknown = StorageLocal.unknownFields(r)
        let version = Int64(ctx.version)
        let adminKey: Data? = r.adminPasskey.isEmpty ? nil : r.adminPasskey

        guard let local else {
            if let deletedAt {
                try db.execute(sql: """
                    INSERT INTO defunctCallLinks (roomId, rootKey, adminKey, addedAt, storageID, storageVersion, storageUnknownFields, storageNeedsSync)
                    VALUES (?, ?, NULL, ?, ?, ?, ?, 0)
                    ON CONFLICT(roomId) DO UPDATE SET rootKey = excluded.rootKey, adminKey = NULL, addedAt = excluded.addedAt, storageID = excluded.storageID,
                      storageVersion = excluded.storageVersion, storageUnknownFields = excluded.storageUnknownFields, storageNeedsSync = 0
                    """, arguments: [roomId, r.rootKey, deletedAt, storageID, version, unknown])
            } else if let (jobId, _) = try pendingCallLinks(db).first(where: { Data(base64Encoded: $0.1.rootKey) == r.rootKey }) {
                try updatePendingCallLink(db, jobId: jobId) { job in
                    job.storageID = storageID
                    job.storageVersion = ctx.version
                    job.storageUnknownFields = unknown?.base64EncodedString()
                    job.storageNeedsSync = false
                }
            } else {
                try JobQueue.insert(db, queueType: CallLinkRefreshJob.queueType,
                                    payload: CallLinkRefreshJob(rootKey: r.rootKey.base64EncodedString(), adminKey: adminKey?.base64EncodedString(),
                                                                storageID: storageID, storageVersion: ctx.version,
                                                                storageUnknownFields: unknown?.base64EncodedString(), storageNeedsSync: false,
                                                                source: "storage.mergeCallLinkRecord"))
            }
            return StorageMergeResult(shouldDrop: shouldDrop)
        }
        _ = local
        try db.execute(sql: """
            UPDATE callLinks SET rootKey = ?, adminKey = ?, deleted = ?, deletedAt = ?, storageID = ?, storageVersion = ?, storageUnknownFields = ?,
              storageNeedsSync = 0 WHERE roomId = ?
            """, arguments: [r.rootKey, adminKey, deletedAt != nil ? 1 : 0, deletedAt, storageID, version, unknown, roomId])
        return StorageMergeResult(shouldDrop: shouldDrop)
    }

    // MARK: chat folders

    static func jsonArray(_ s: String?) -> [String] {
        guard let s, let a = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String] else { return [] }
        return a
    }

    static func chatFolderEntries(_ db: Database, ctx: StorageMergeContext) throws -> [StorageLocalEntry] {
        try Row.fetchAll(db, sql: "SELECT * FROM chatFolders ORDER BY id").map { row in
            let id: String = row["id"]
            var r = Signalservice_ChatFolderRecord()
            r.id = StorageLocal.uuidBytes(id) ?? Data()
            r.name = row["name"] ?? ""
            r.position = UInt32(clamping: row["position"] as Int64? ?? 0)
            r.showOnlyUnread = (row["showOnlyUnread"] as Int64? ?? 0) != 0
            r.showMutedChats = (row["showMutedChats"] as Int64? ?? 0) != 0
            r.includeAllIndividualChats = (row["includeAllIndividualChats"] as Int64? ?? 0) != 0
            r.includeAllGroupChats = (row["includeAllGroupChats"] as Int64? ?? 0) != 0
            switch row["folderType"] as Int64? ?? 0 {
            case 1: r.folderType = .all
            case 2: r.folderType = .custom
            default: r.folderType = .unknown
            }
            r.includedRecipients = try StorageLocal.recipients(db, jsonArray(row["includedConversationIds"]))
            r.excludedRecipients = try StorageLocal.recipients(db, jsonArray(row["excludedConversationIds"]))
            r.deletedAtTimestampMs = UInt64(max(0, row["deletedAtTimestampMs"] as Int64? ?? 0))
            try StorageLocal.attach(row["storageUnknownFields"], to: &r)
            return StorageLocalEntry(type: .chatFolder, owner: .chatFolder(id), storageID: row["storageID"], storageVersion: u64(row, "storageVersion"),
                                     needsSync: (row["storageNeedsSync"] as Int64? ?? 0) != 0, record: record(.chatFolder(r)))
        }
    }

    /// `mergeChatFolderRecord`
    static func mergeChatFolder(_ db: Database, _ r: Signalservice_ChatFolderRecord, storageID: String, ctx: StorageMergeContext) throws -> StorageMergeResult {
        guard let id = StorageLocal.uuidString(r.id) else { return .drop("no id") }
        let local = try Row.fetchOne(db, sql: "SELECT * FROM chatFolders WHERE id = ?", arguments: [id])
        let localDeletedAt: Int64 = local?["deletedAtTimestampMs"] ?? 0
        let deletedAt = [Int64(clamping: r.deletedAtTimestampMs), localDeletedAt].filter { $0 > 0 }.min() ?? 0
        let folderType: Int64 = r.folderType == .all ? 1 : r.folderType == .custom ? 2 : 0
        let included = try MessageStore.jsonString(try StorageLocal.conversationIds(db, r.includedRecipients))
        let excluded = try MessageStore.jsonString(try StorageLocal.conversationIds(db, r.excludedRecipients))
        let unknown = StorageLocal.unknownFields(r)
        let version = Int64(ctx.version)
        let columns: StatementArguments = [id, folderType, r.name, Int64(r.position), r.showOnlyUnread ? 1 : 0, r.showMutedChats ? 1 : 0,
                                           r.includeAllIndividualChats ? 1 : 0, r.includeAllGroupChats ? 1 : 0, included, excluded, deletedAt,
                                           storageID, version, unknown]
        let insert = """
            INSERT INTO chatFolders (id, folderType, name, position, showOnlyUnread, showMutedChats, includeAllIndividualChats, includeAllGroupChats,
              includedConversationIds, excludedConversationIds, deletedAtTimestampMs, storageID, storageVersion, storageUnknownFields, storageNeedsSync)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            """
        if folderType == 1 {
            // upsertAllChatsChatFolderFromSync
            if try Int.fetchOne(db, sql: "SELECT 1 FROM chatFolders WHERE folderType = 1") != nil {
                try db.execute(sql: """
                    UPDATE chatFolders SET id = ?, position = ?, storageID = ?, storageVersion = ?, storageUnknownFields = ?, storageNeedsSync = 0
                    WHERE folderType = 1
                    """, arguments: [id, Int64(r.position), storageID, version, unknown])
            } else {
                try db.execute(sql: insert, arguments: columns)
            }
        } else if deletedAt > 0 {
            if local == nil {
                try db.execute(sql: insert, arguments: columns)
            } else if localDeletedAt == deletedAt {
                try setChatFolderStorage(db, id: id, storageID: storageID, version: version, unknown: unknown)
            } else {
                // markChatFolderDeleted / updateChatFolderDeletedAtTimestampMsFromSync
                try db.execute(sql: """
                    UPDATE chatFolders SET deletedAtTimestampMs = ?, position = ?, includedConversationIds = '[]', excludedConversationIds = '[]'
                    WHERE id = ?
                    """, arguments: [deletedAt, Int64(StorageLocal.chatFolderDeletedPosition), id])
                try setChatFolderStorage(db, id: id, storageID: storageID, version: version, unknown: unknown)
            }
        } else if local == nil {
            try db.execute(sql: insert, arguments: columns)
        } else {
            try db.execute(sql: """
                UPDATE chatFolders SET folderType = ?, name = ?, position = ?, showOnlyUnread = ?, showMutedChats = ?, includeAllIndividualChats = ?,
                  includeAllGroupChats = ?, includedConversationIds = ?, excludedConversationIds = ?, deletedAtTimestampMs = ?, storageID = ?,
                  storageVersion = ?, storageUnknownFields = ?, storageNeedsSync = 0 WHERE id = ?
                """, arguments: [folderType, r.name, Int64(r.position), r.showOnlyUnread ? 1 : 0, r.showMutedChats ? 1 : 0, r.includeAllIndividualChats ? 1 : 0,
                                 r.includeAllGroupChats ? 1 : 0, included, excluded, deletedAt, storageID, version, unknown, id])
        }
        return StorageMergeResult(shouldDrop: deletedAt > 0 && StorageLocal.isOlderThan(deletedAt, ctx.messageQueueTime, now: ctx.now))
    }

    static func setChatFolderStorage(_ db: Database, id: String, storageID: String, version: Int64, unknown: Data?) throws {
        try db.execute(sql: "UPDATE chatFolders SET storageID = ?, storageVersion = ?, storageUnknownFields = ?, storageNeedsSync = 0 WHERE id = ?",
                       arguments: [storageID, version, unknown, id])
    }

    /// processManifest: `createAllChatsChatFolder` when there is no current All Chats folder.
    static func ensureAllChatsFolder(_ db: Database) throws {
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM chatFolders WHERE folderType = 1 AND deletedAtTimestampMs = 0") == nil else { return }
        try db.execute(sql: "UPDATE chatFolders SET position = position + 1 WHERE deletedAtTimestampMs = 0")
        try db.execute(sql: """
            INSERT INTO chatFolders (id, folderType, name, position, showOnlyUnread, showMutedChats, includeAllIndividualChats, includeAllGroupChats,
              includedConversationIds, excludedConversationIds, deletedAtTimestampMs, storageNeedsSync) VALUES (?, 1, '', 0, 0, 1, 1, 1, '[]', '[]', 0, 1)
            """, arguments: [UUID().uuidString.lowercased()])
    }

    // MARK: notification profiles

    /// `DEFAULT_PROFILE_COLOR`
    static let defaultProfileColor: Int64 = 0xFF3F51B5

    static func notificationProfileEntries(_ db: Database, ctx: StorageMergeContext) throws -> [StorageLocalEntry] {
        let syncDisabled = try Items.get(db, "notificationProfileSyncDisabled", as: Bool.self) ?? false
        return try Row.fetchAll(db, sql: "SELECT * FROM notificationProfiles ORDER BY id").compactMap { row in
            let storageID: String? = row["storageID"]
            // Sync off on a linked device: local-only profiles stay local.
            if syncDisabled && storageID == nil { return nil }
            let id: String = row["id"]
            var r = Signalservice_NotificationProfile()
            r.id = Data(hex: id) ?? Data()
            r.name = row["name"] ?? ""
            if let emoji: String = row["emoji"] { r.emoji = emoji }
            r.color = UInt32(truncatingIfNeeded: row["color"] as Int64? ?? 0)
            r.createdAtMs = UInt64(max(0, row["createdAtMs"] as Int64? ?? 0))
            let deletedAt: Int64? = row["deletedAtTimestampMs"]
            if let deletedAt, deletedAt > 0 { r.deletedAtTimestampMs = UInt64(deletedAt) }
            r.allowAllCalls = (row["allowAllCalls"] as Int64? ?? 0) != 0
            r.allowAllMentions = (row["allowAllMentions"] as Int64? ?? 0) != 0
            r.scheduleEnabled = (row["scheduleEnabled"] as Int64? ?? 0) != 0
            r.scheduleStartTime = UInt32(clamping: row["scheduleStartTime"] as Int64? ?? 0)
            r.scheduleEndTime = UInt32(clamping: row["scheduleEndTime"] as Int64? ?? 0)
            r.scheduleDaysEnabled = toDayOfWeekArray(row["scheduleDaysEnabledJson"])
            r.allowedMembers = try StorageLocal.recipients(db, jsonArray(row["allowedMembersJson"]))
            try StorageLocal.attach(row["storageUnknownFields"], to: &r)
            let expired = deletedAt.map { $0 != 0 && StorageLocal.isOlderThan($0, ctx.messageQueueTime, now: ctx.now) } ?? false
            return StorageLocalEntry(type: .notificationProfile, owner: .notificationProfile(id), storageID: storageID, storageVersion: u64(row, "storageVersion"),
                                     needsSync: (row["storageNeedsSync"] as Int64? ?? 0) != 0, record: record(.notificationProfile(r)), drop: expired)
        }
    }

    /// `toDayOfWeekArray` over the `{"1": true, …}` JSON.
    static func toDayOfWeekArray(_ json: String?) -> [Signalservice_NotificationProfile.DayOfWeek] {
        guard let json, let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Bool] else { return [] }
        return (1...7).filter { d[String($0)] == true }.compactMap { Signalservice_NotificationProfile.DayOfWeek(rawValue: $0) }
    }

    /// `fromDayOfWeekArray`: UNKNOWN counts as Monday.
    static func fromDayOfWeekArray(_ days: [Signalservice_NotificationProfile.DayOfWeek]) throws -> String {
        let raw = Set(days.map { $0.rawValue >= 0 && $0.rawValue <= 7 ? $0.rawValue : 0 })
        var d: [String: Bool] = [:]
        for day in 1...7 { d[String(day)] = raw.contains(day) || (day == 1 && raw.contains(0)) }
        return try MessageStore.jsonString(d)
    }

    /// `mergeNotificationProfileRecord`
    static func mergeNotificationProfile(_ db: Database, _ r: Signalservice_NotificationProfile, storageID: String,
                                         ctx: StorageMergeContext) throws -> StorageMergeResult {
        guard !r.id.isEmpty else { return .drop("no id") }
        guard !r.name.isEmpty else { return .drop("no name") }
        let id = r.id.hexString
        let deletedAt: Int64? = r.deletedAtTimestampMs > 0 ? Int64(clamping: r.deletedAtTimestampMs) : nil
        let shouldDrop = deletedAt.map { StorageLocal.isOlderThan($0, ctx.messageQueueTime, now: ctx.now) } ?? false
        let localDeletedAt = try Int64.fetchOne(db, sql: "SELECT deletedAtTimestampMs FROM notificationProfiles WHERE id = ?", arguments: [id])
        let earliest = [localDeletedAt ?? 0, deletedAt ?? 0].filter { $0 > 0 }.min()
        let allowed = try MessageStore.jsonString(try StorageLocal.conversationIds(db, r.allowedMembers))
        try db.execute(sql: """
            INSERT INTO notificationProfiles (id, name, emoji, color, createdAtMs, allowAllCalls, allowAllMentions, allowedMembersJson, scheduleEnabled,
              scheduleStartTime, scheduleEndTime, scheduleDaysEnabledJson, deletedAtTimestampMs, storageID, storageVersion, storageUnknownFields, storageNeedsSync)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, emoji = excluded.emoji, color = excluded.color, createdAtMs = excluded.createdAtMs,
              allowAllCalls = excluded.allowAllCalls, allowAllMentions = excluded.allowAllMentions, allowedMembersJson = excluded.allowedMembersJson,
              scheduleEnabled = excluded.scheduleEnabled, scheduleStartTime = excluded.scheduleStartTime, scheduleEndTime = excluded.scheduleEndTime,
              scheduleDaysEnabledJson = excluded.scheduleDaysEnabledJson, deletedAtTimestampMs = excluded.deletedAtTimestampMs,
              storageID = excluded.storageID, storageVersion = excluded.storageVersion, storageUnknownFields = excluded.storageUnknownFields,
              storageNeedsSync = 0
            """, arguments: [id, r.name, r.hasEmoji ? r.emoji : nil, r.color != 0 ? Int64(r.color) : defaultProfileColor,
                             r.createdAtMs > 0 ? Int64(clamping: r.createdAtMs) : ctx.now, r.allowAllCalls ? 1 : 0, r.allowAllMentions ? 1 : 0, allowed,
                             r.scheduleEnabled ? 1 : 0, r.scheduleStartTime > 0 ? Int64(r.scheduleStartTime) : nil,
                             r.scheduleEndTime > 0 ? Int64(r.scheduleEndTime) : nil, try fromDayOfWeekArray(r.scheduleDaysEnabled), earliest,
                             storageID, Int64(ctx.version), StorageLocal.unknownFields(r)])
        return StorageMergeResult(shouldDrop: shouldDrop)
    }
}

extension StorageOwner {
    /// postUploadUpdateFunctions: the record was uploaded under `storageID` at `version`.
    func setUploaded(_ db: Database, storageID: String, version: UInt64) throws {
        let v = Int64(version)
        switch self {
        case .conversation(let id), .account(let id):
            try StorageLocal.setStorageFields(db, conversationId: id, storageID: storageID, version: version, needsSync: false)
        case .storyList(let id):
            try db.execute(sql: "UPDATE storyDistributions SET storageID = ?, storageVersion = ?, storageNeedsSync = 0 WHERE id = ?", arguments: [storageID, v, id])
        case .installedPack(let id):
            try db.execute(sql: "UPDATE sticker_packs SET storageID = ?, storageVersion = ?, storageNeedsSync = 0 WHERE id = ?", arguments: [storageID, v, id])
        case .uninstalledPack(let id):
            try db.execute(sql: "UPDATE uninstalled_sticker_packs SET storageID = ?, storageVersion = ?, storageNeedsSync = 0 WHERE id = ?",
                           arguments: [storageID, v, id])
        case .favoriteSticker(let packId, let stickerId):
            try db.execute(sql: "UPDATE favorite_stickers SET storageID = ?, storageVersion = ?, storageNeedsSync = 0 WHERE packId = ? AND stickerId = ?",
                           arguments: [storageID, v, packId, stickerId])
        case .callLink(let roomId):
            try db.execute(sql: "UPDATE callLinks SET storageID = ?, storageVersion = ?, storageNeedsSync = 0 WHERE roomId = ?", arguments: [storageID, v, roomId])
        case .defunctCallLink(let roomId):
            try db.execute(sql: "UPDATE defunctCallLinks SET storageID = ?, storageVersion = ?, storageNeedsSync = 0 WHERE roomId = ?",
                           arguments: [storageID, v, roomId])
        case .pendingCallLink(let jobId):
            try StorageRecords.updatePendingCallLink(db, jobId: jobId) { $0.storageID = storageID; $0.storageVersion = version; $0.storageNeedsSync = false }
        case .chatFolder(let id):
            try db.execute(sql: "UPDATE chatFolders SET storageID = ?, storageVersion = ?, storageNeedsSync = 0 WHERE id = ?", arguments: [storageID, v, id])
        case .notificationProfile(let id):
            try db.execute(sql: "UPDATE notificationProfiles SET storageID = ?, storageVersion = ?, storageNeedsSync = 0 WHERE id = ?",
                           arguments: [storageID, v, id])
        }
    }

    /// The record changed again and still has to go up (the flag `setUploaded` clears).
    func markNeedsSync(_ db: Database) throws {
        switch self {
        case .conversation(let id), .account(let id):
            try MessageStore.updateConversationJSON(db, conversationId: id) { $0["needsStorageServiceSync"] = true }
        case .storyList(let id): try db.execute(sql: "UPDATE storyDistributions SET storageNeedsSync = 1 WHERE id = ?", arguments: [id])
        case .installedPack(let id): try db.execute(sql: "UPDATE sticker_packs SET storageNeedsSync = 1 WHERE id = ?", arguments: [id])
        case .uninstalledPack(let id): try db.execute(sql: "UPDATE uninstalled_sticker_packs SET storageNeedsSync = 1 WHERE id = ?", arguments: [id])
        case .favoriteSticker(let packId, let stickerId):
            try db.execute(sql: "UPDATE favorite_stickers SET storageNeedsSync = 1 WHERE packId = ? AND stickerId = ?", arguments: [packId, stickerId])
        case .callLink(let roomId): try db.execute(sql: "UPDATE callLinks SET storageNeedsSync = 1 WHERE roomId = ?", arguments: [roomId])
        case .defunctCallLink(let roomId): try db.execute(sql: "UPDATE defunctCallLinks SET storageNeedsSync = 1 WHERE roomId = ?", arguments: [roomId])
        case .pendingCallLink(let jobId): try StorageRecords.updatePendingCallLink(db, jobId: jobId) { $0.storageNeedsSync = true }
        case .chatFolder(let id): try db.execute(sql: "UPDATE chatFolders SET storageNeedsSync = 1 WHERE id = ?", arguments: [id])
        case .notificationProfile(let id): try db.execute(sql: "UPDATE notificationProfiles SET storageNeedsSync = 1 WHERE id = ?", arguments: [id])
        }
    }

    /// generateManifest: an expired tombstone (or a dropped contact) leaves the local state.
    func dropLocal(_ db: Database) throws {
        switch self {
        case .conversation(let id):
            try StorageLocal.setStorageFields(db, conversationId: id, storageID: nil, version: nil, needsSync: false)
        case .account: break
        case .storyList(let id): try db.execute(sql: "DELETE FROM storyDistributions WHERE id = ?", arguments: [id])
        case .uninstalledPack(let id): try db.execute(sql: "DELETE FROM uninstalled_sticker_packs WHERE id = ?", arguments: [id])
        case .favoriteSticker(let packId, let stickerId):
            try db.execute(sql: "DELETE FROM favorite_stickers WHERE packId = ? AND stickerId = ?", arguments: [packId, stickerId])
        case .notificationProfile(let id): try db.execute(sql: "DELETE FROM notificationProfiles WHERE id = ?", arguments: [id])
        case .installedPack, .callLink, .defunctCallLink, .pendingCallLink, .chatFolder: break
        }
    }

    /// processManifest: the record's storageID is not in the remote manifest. Tombstones are
    /// removed, live records lose their storageID (so the next upload inserts them again).
    func handleMissingRemotely(_ db: Database, entry: StorageLocalEntry, syncDisabled: Bool) throws {
        let tombstone: Bool
        switch entry.record.record {
        case .storyDistributionList(let r): tombstone = r.deletedAtTimestamp > 0
        case .sticker(let r): tombstone = r.deletedAtTimestamp > 0
        case .callLink(let r): tombstone = r.deletedAtTimestampMs > 0
        case .chatFolder(let r): tombstone = r.deletedAtTimestampMs > 0
        case .notificationProfile(let r): tombstone = r.deletedAtTimestampMs > 0 || syncDisabled
        default: tombstone = false
        }
        switch self {
        case .conversation(let id), .account(let id):
            try MessageStore.updateConversationJSON(db, conversationId: id) { $0["storageID"] = nil; $0["storageVersion"] = nil }
        case .uninstalledPack(let id):
            try db.execute(sql: "DELETE FROM uninstalled_sticker_packs WHERE id = ?", arguments: [id])
        case .installedPack(let id):
            try db.execute(sql: "UPDATE sticker_packs SET storageID = NULL, storageVersion = NULL, storageUnknownFields = NULL, storageNeedsSync = 0 WHERE id = ?",
                           arguments: [id])
        case .favoriteSticker(let packId, let stickerId):
            if tombstone {
                try db.execute(sql: "DELETE FROM favorite_stickers WHERE packId = ? AND stickerId = ?", arguments: [packId, stickerId])
            } else {
                try db.execute(sql: "UPDATE favorite_stickers SET storageID = NULL, storageVersion = NULL WHERE packId = ? AND stickerId = ?",
                               arguments: [packId, stickerId])
            }
        case .storyList(let id):
            if tombstone { try db.execute(sql: "DELETE FROM storyDistributions WHERE id = ?", arguments: [id]) } else {
                try db.execute(sql: "UPDATE storyDistributions SET storageID = NULL, storageVersion = NULL WHERE id = ?", arguments: [id])
            }
        case .callLink(let roomId):
            if tombstone { try db.execute(sql: "DELETE FROM callLinks WHERE roomId = ?", arguments: [roomId]) } else {
                try db.execute(sql: "UPDATE callLinks SET storageID = NULL, storageVersion = NULL WHERE roomId = ?", arguments: [roomId])
            }
        case .defunctCallLink(let roomId):
            try db.execute(sql: "DELETE FROM defunctCallLinks WHERE roomId = ?", arguments: [roomId])
        case .pendingCallLink(let jobId):
            try StorageRecords.updatePendingCallLink(db, jobId: jobId) { $0.storageID = nil; $0.storageVersion = nil }
        case .chatFolder(let id):
            if tombstone { try db.execute(sql: "DELETE FROM chatFolders WHERE id = ?", arguments: [id]) } else {
                try db.execute(sql: "UPDATE chatFolders SET storageID = NULL, storageVersion = NULL WHERE id = ?", arguments: [id])
            }
        case .notificationProfile(let id):
            if tombstone { try db.execute(sql: "DELETE FROM notificationProfiles WHERE id = ?", arguments: [id]) } else {
                try db.execute(sql: "UPDATE notificationProfiles SET storageID = NULL, storageVersion = NULL WHERE id = ?", arguments: [id])
            }
        }
    }
}
