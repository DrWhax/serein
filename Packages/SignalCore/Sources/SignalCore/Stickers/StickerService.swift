// Sticker packs (ts/types/Stickers.preload.ts, ts/state/ducks/stickers.preload.ts and the
// sticker SQL in ts/sql): manifest and sticker download from CDN 0, decrypt with the pack key
// (`deriveStickerPackKey` + `decryptAttachmentV1`), every image checked by the sandboxed media
// service before it is stored (encrypted at rest), install / uninstall / favourites with
// storage write-back and StickerPackOperation syncs, and message references resolved once a
// pack's stickers are local.

import Foundation
import GRDB
import LibSignalClient
import MediaXPCInterface
import SignalProtos

public enum StickerError: Error, Equatable {
    case invalidPackId
    case malformedManifest(String)
    case allStickersFailed
    case notAnImage
    case unknownSticker
}

/// `StickerPackStatusType`
public enum StickerPackStatus: String, Sendable {
    case known, ephemeral, downloaded, installed, pending, error
}

/// Where a pack change came from (`ActionSourceType`): only `ui` changes are announced to our
/// other devices; `storageService` and `startup` changes are not uploaded again.
public enum StickerActionSource: String, Codable, Sendable {
    case ui, syncMessage, storageService, startup, blessed
}

struct StickerReferenceJob: Codable, Sendable {
    static let queueType = "sticker references"
    var packId: String
}

public enum Stickers {
    /// `MAX_STICKERS_PER_PACK`
    static let maxStickersPerPack = 1024
    /// Download attempts before a pack is left in `error` (`downloadAttempts > 3`).
    static let maxDownloadAttempts = 3

    /// `BLESSED_PACKS`: the default packs every client has.
    static let blessedPacks: [(id: String, key: String)] = [
        ("42fb75e1827c0c945cfb5ca0975db03c", "7uJ+K593PgpV6iTDQLe+hYcRpuK9m27nBEND4OQovmU="),
        ("ccc89a05dc077856b57351e90697976c", "RXMOYPCdVWYRUiN0RTemt9nqmc7qy3eh+9aAG5YH+88="),
        ("fb535407d2f6497ec074df8b9c51dd1d", "F+lxwTQDViJ4HS7iSeZHO3dFg3ULaMEbuCt1CcaLbf0="),
        ("3044281a51307306e5442f2e9070953a", "xMqqhDl+GmMKWWD1SguCdTyIpeUuDe/mFbpN2A8TDL8="),
        ("a2414255948558316f37c1d36c64cd28", "/aEpNxltI28cqeEZalZULh0c72/4TivgOChxf6IK02Y="),
        ("684d2b7bcfc2eec6f57f2e7be0078e0f", "hm4Ny0obJfKwTfJwzXQnI+SmVVwKGrw/PzDcxaIBDFU="),
        ("f19548e5afa38d1ce4f5c3191eba5e30", "LLMHZ0D2aapExsBjKQskmn0ApLAu2PnppbkCo38bvEE="),
        ("9acc9e8aba563d26a4994e69263e3b25", "Wm3/OUjCjvubeq+T7MN1xp/DFueAd+0mhnoU0QoPahI="),
        ("e61fa0867031597467ccc036cc65d403", "E657GnQHMYKA6bOMEmHe044OcTi5+WSmzLtz5A9zeps="),
        ("cca32f5b905208b7d0f1e17f23fdc185", "i/jpX3pFver+DI9bAC7wGrlbjxtbqsQBnM1ra+Cxg3o="),
        ("cfc50156556893ef9838069d3890fe49", "X1vqt9OCRDywCh5I65Upe2uMrf0GMeXQ2dyUnmmZ/0s="),
    ]
    static func isBlessed(_ packId: String) -> Bool { blessedPacks.contains { $0.id == packId } }

    /// `isPackIdValid`: 32 hex digits.
    /// A sticker pack link's pack (`signalRoutes` addStickers): `https://signal.art/addstickers/#pack_id=<32 hex>&pack_key=<64 hex>`
    /// or `sgnl://addstickers/?pack_id=…&pack_key=…`. The key comes back in base64, as the store keeps it.
    public static func packLink(_ url: URL) -> (packId: String, packKey: String)? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let params: String?
        if c.scheme == "https", c.host == "signal.art", c.path == "/addstickers" || c.path == "/addstickers/" {
            params = c.fragment
        } else if c.scheme == "sgnl", c.host == "addstickers", c.path.isEmpty || c.path == "/" {
            params = c.query
        } else {
            return nil
        }
        var values: [String: String] = [:]
        for pair in (params ?? "").split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { values[String(kv[0])] = String(kv[1]) }
        }
        guard let id = values["pack_id"]?.lowercased(), isPackIdValid(id), let hex = values["pack_key"], hex.count == 64 else { return nil }
        var key = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i ..< j], radix: 16) else { return nil }
            key.append(b)
            i = j
        }
        return (id, key.base64EncodedString())
    }

    public static func isPackIdValid(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { $0.isHexDigit }
    }

    /// `deriveStickerPackKey`: HKDF-SHA256(packKey, salt 0^32, "Sticker Pack") → 64 bytes
    /// (AES key ‖ MAC key).
    public static func derivePackKey(_ packKey: Data) throws -> Data {
        try SignalCrypto.hkdf(64, ikm: packKey, info: Data("Sticker Pack".utf8), salt: Data(count: 32))
    }

    /// `decryptSticker`
    public static func decrypt(_ ciphertext: Data, packKey: Data) throws -> Data {
        try AttachmentCipher.decryptV1(ciphertext, keys: derivePackKey(packKey))
    }

    struct ParsedManifest: Sendable {
        var title: String
        var author: String
        var cover: Signalservice_StickerPack.Sticker
        var coverIncludedInList: Bool
        var nonCover: [Signalservice_StickerPack.Sticker]
        var stickerCount: Int
    }

    /// `parseStickerPackManifest`
    static func parseManifest(_ proto: Signalservice_StickerPack) throws -> ParsedManifest {
        let stickers = Array(proto.stickers.prefix(maxStickersPerPack))
        guard var cover = proto.hasCover ? proto.cover : stickers.first else { throw StickerError.malformedManifest("no cover and no stickers") }
        let coverId = cover.id
        let nonCover = stickers.filter { $0.id != coverId }
        if cover.emoji.isEmpty, let match = stickers.first(where: { $0.id == coverId }) { cover.emoji = match.emoji }
        return ParsedManifest(title: proto.title, author: proto.author, cover: cover, coverIncludedInList: nonCover.count < stickers.count,
                              nonCover: nonCover, stickerCount: stickers.count)
    }

    /// `sniffImageMimeType` for the formats sticker packs use.
    static func sniffContentType(_ d: Data) -> String? {
        let b = [UInt8](d.prefix(12))
        if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        if b.count >= 8, b[0...7] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return "image/png" }
        if b.count >= 6, b[0...2] == [0x47, 0x49, 0x46] { return "image/gif" }
        if b.count >= 3, b[0...2] == [0xFF, 0xD8, 0xFF] { return "image/jpeg" }
        return nil
    }

    // MARK: SQL (ts/sql/Server.node.ts sticker functions)

    static func status(_ db: Database, _ packId: String) throws -> StickerPackStatus? {
        try String.fetchOne(db, sql: "SELECT status FROM sticker_packs WHERE id = ?", arguments: [packId]).flatMap(StickerPackStatus.init)
    }

    /// `savePackMetadata`: a pack seen in a message (or favourite) becomes `known`, with the
    /// message's reference.
    static func savePackMetadata(_ db: Database, packId: String, packKey: String, messageId: String? = nil, stickerId: Int? = nil,
                                 isUnresolved: Bool = false, resetDownloadAttempts: Bool = false) throws {
        if try status(db, packId) != nil {
            if resetDownloadAttempts { try db.execute(sql: "UPDATE sticker_packs SET downloadAttempts = 0 WHERE id = ?", arguments: [packId]) }
        } else {
            try db.execute(sql: """
                INSERT INTO sticker_packs (id, key, author, coverStickerId, createdAt, downloadAttempts, status, stickerCount, title)
                VALUES (?, ?, '', 0, 0, 0, 'known', 0, '')
                """, arguments: [packId, packKey])
        }
        if let messageId, let stickerId {
            try db.execute(sql: "INSERT INTO sticker_references (messageId, packId, stickerId, isUnresolved) VALUES (?, ?, ?, ?)",
                           arguments: [messageId, packId, stickerId, isUnresolved ? 1 : 0])
        }
    }

    /// `installStickerPack` (SQL): returns whether it was not installed before.
    @discardableResult
    static func installSQL(_ db: Database, packId: String, timestamp: Int64, position: Int? = nil) throws -> Bool {
        try db.execute(sql: "DELETE FROM uninstalled_sticker_packs WHERE id = ?", arguments: [packId])
        let newPosition = try position ?? Int.fetchOne(db, sql: "SELECT IFNULL(MAX(position) + 1, 0) FROM sticker_packs WHERE id != ?", arguments: [packId]) ?? 0
        let old = try status(db, packId)
        try db.execute(sql: "UPDATE sticker_packs SET status = 'installed', installedAt = ?, position = ? WHERE id = ?",
                       arguments: [timestamp, newPosition, packId])
        guard old != .installed else { return false }
        try db.execute(sql: "UPDATE sticker_packs SET storageNeedsSync = 1 WHERE id = ?", arguments: [packId])
        return true
    }

    /// `uninstallStickerPack` (SQL): returns whether it was installed.
    @discardableResult
    static func uninstallSQL(_ db: Database, packId: String, timestamp: Int64) throws -> Bool {
        let wasInstalled = try status(db, packId) == .installed
        try db.execute(sql: """
            UPDATE sticker_packs SET status = 'downloaded', installedAt = NULL, storageID = NULL, storageVersion = NULL, storageUnknownFields = NULL,
              storageNeedsSync = 0 WHERE id = ?
            """, arguments: [packId])
        try db.execute(sql: """
            INSERT OR REPLACE INTO uninstalled_sticker_packs (id, uninstalledAt, storageID, storageVersion, storageUnknownFields, storageNeedsSync)
            VALUES (?, ?, NULL, NULL, NULL, ?)
            """, arguments: [packId, timestamp, wasInstalled ? 1 : 0])
        return wasInstalled
    }

    /// `deleteStickerPackReference` + `maybeDeletePack`: a pack nothing refers to (no message,
    /// not installed, no favourite, not blessed) is deleted; returns the sticker files to remove.
    static func deleteReference(_ db: Database, messageId: String, packId: String) throws -> [String] {
        guard !isBlessed(packId) else { return [] }
        try db.execute(sql: "DELETE FROM sticker_references WHERE messageId = ? AND packId = ?", arguments: [messageId, packId])
        guard try Int.fetchOne(db, sql: "SELECT count(1) FROM sticker_references WHERE packId = ?", arguments: [packId]) == 0,
              let s = try status(db, packId), s != .installed,
              try Int.fetchOne(db, sql: "SELECT count(1) FROM favorite_stickers WHERE packId = ? AND deletedAtTimestampMs IS NULL", arguments: [packId]) == 0
        else { return [] }
        let paths = try String.fetchAll(db, sql: "SELECT path FROM stickers WHERE packId = ? AND path IS NOT NULL", arguments: [packId])
        try db.execute(sql: "DELETE FROM sticker_packs WHERE id = ?", arguments: [packId])
        return paths
    }

    /// `createFavoriteStickerFromStickerRef`; nil when the pack is unknown.
    static func favoriteSQL(_ db: Database, packId: String, stickerId: Int, now: Int64) throws -> (packKey: String, needsSync: Bool)? {
        if let row = try Row.fetchOne(db, sql: "SELECT packKey, deletedAtTimestampMs, storageNeedsSync FROM favorite_stickers WHERE packId = ? AND stickerId = ?",
                                      arguments: [packId, stickerId]), (row["deletedAtTimestampMs"] as Int64?) == nil, let key: String = row["packKey"] {
            return (key, (row["storageNeedsSync"] as Int64? ?? 0) != 0)
        }
        guard let key = try String.fetchOne(db, sql: "SELECT key FROM sticker_packs WHERE id = ?", arguments: [packId]) else { return nil }
        let installed = try Int.fetchOne(db, sql: "SELECT 1 FROM stickers WHERE packId = ? AND id = ? AND path IS NOT NULL", arguments: [packId, stickerId]) != nil
        try db.execute(sql: """
            INSERT INTO favorite_stickers (packId, stickerId, packKey, favoritedAtTimestampMs, deletedAtTimestampMs, status, storageNeedsSync)
            VALUES (?, ?, ?, ?, NULL, ?, 1)
            ON CONFLICT(packId, stickerId) DO UPDATE SET packKey = excluded.packKey, favoritedAtTimestampMs = excluded.favoritedAtTimestampMs,
              deletedAtTimestampMs = NULL, status = excluded.status, storageNeedsSync = 1
            """, arguments: [packId, stickerId, key, now, installed ? "installed" : "known"])
        return (key, true)
    }

    /// `markFavoriteStickerDeleted`: returns whether a favourite was removed.
    static func unfavoriteSQL(_ db: Database, packId: String, stickerId: Int, now: Int64) throws -> Bool {
        try db.execute(sql: """
            UPDATE favorite_stickers SET deletedAtTimestampMs = ?, status = 'deleted', storageNeedsSync = 1
            WHERE packId = ? AND stickerId = ? AND deletedAtTimestampMs IS NULL
            """, arguments: [now, packId, stickerId])
        return db.changesCount > 0
    }

    /// A local sticker's file (if it has one): path, local key, size.
    static func localSticker(_ db: Database, packId: String, stickerId: Int) throws -> (path: String, localKey: String, size: Int, emoji: String?,
                                                                                         width: Int?, height: Int?)? {
        guard let row = try Row.fetchOne(db, sql: "SELECT path, localKey, size, emoji, width, height FROM stickers WHERE packId = ? AND id = ?",
                                         arguments: [packId, stickerId]),
              let path: String = row["path"], let key: String = row["localKey"], let size: Int = row["size"] else { return nil }
        return (path, key, size, row["emoji"], row["width"], row["height"])
    }
}

/// Downloads and changes sticker packs. Downloads run one at a time (`downloadQueue`).
public actor StickerService {
    let account: Account
    let database: SignalDatabase
    let http: HTTPClient
    let endpoints: ServiceEndpoints
    let store: AttachmentStore
    let media: any MediaProcessing
    var jobs: JobQueue?

    public init(account: Account, database: SignalDatabase, http: HTTPClient, endpoints: ServiceEndpoints, store: AttachmentStore,
                media: any MediaProcessing) {
        self.account = account
        self.database = database
        self.http = http
        self.endpoints = endpoints
        self.store = store
        self.media = media
    }

    /// Runs the queued work: downloads from storage sync / sync messages, reference resolution.
    public func register(on jobs: JobQueue) async {
        self.jobs = jobs
        await jobs.register(StickerPackDownloadJob.queueType) { [self] job in
            let p = try JSONDecoder().decode(StickerPackDownloadJob.self, from: job.data)
            try await self.download(packId: p.packId, packKey: p.packKey, finalStatus: StickerPackStatus(rawValue: p.finalStatus) ?? .downloaded,
                                    position: p.position, favoriteStickerIds: p.favoriteStickerIds,
                                    actionSource: StickerActionSource(rawValue: p.actionSource) ?? .storageService)
        }
        await jobs.register(StickerPackOperationJob.queueType) { [self] job in
            let op = try JSONDecoder().decode(StickerPackOperationJob.self, from: job.data)
            if op.install { try await self.install(packId: op.packId, packKey: op.packKey, actionSource: .syncMessage) } else {
                try await self.uninstall(packId: op.packId, actionSource: .syncMessage)
            }
        }
        await jobs.register(StickerReferenceJob.queueType) { [self] job in
            try await self.resolveReferences(packId: try JSONDecoder().decode(StickerReferenceJob.self, from: job.data).packId)
        }
    }

    func cdn(_ path: String) -> URL { URL(string: endpoints.cdnURLs[0]!.absoluteString + path)! }

    func fetch(_ path: String) async throws -> Data {
        var client = http
        client.maxResponseBytes = 2 << 20
        return try await client.send("GET", cdn(path)).body
    }

    /// `downloadStickerPack` / `doDownloadStickerPack`. `favoriteStickerIds` limits the
    /// download to those stickers (a favourite from a pack we do not have, status `known`).
    public func download(packId: String, packKey: String, finalStatus: StickerPackStatus = .downloaded, position: Int? = nil,
                         favoriteStickerIds: [Int]? = nil, actionSource: StickerActionSource) async throws {
        guard Stickers.isPackIdValid(packId), let key = Data(base64Encoded: packKey), key.count == 32 else { throw StickerError.invalidPackId }
        let existing = try await database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT status, stickerCount, downloadAttempts, position FROM sticker_packs WHERE id = ?", arguments: [packId])
                .map { (status: StickerPackStatus(rawValue: $0["status"] ?? "") , count: $0["stickerCount"] as Int? ?? 0,
                        attempts: $0["downloadAttempts"] as Int? ?? 0, position: $0["position"] as Int?) }
        }
        var wanted = favoriteStickerIds
        if let existing, existing.status == .installed || existing.status == .downloaded, existing.count > 0 {
            // doesPackNeedDownload false: only missing favourites are fetched.
            guard let ids = favoriteStickerIds else { return }
            let have = try await database.pool.write { db -> Set<Int> in
                let have = Set(try Int.fetchAll(db, sql: "SELECT id FROM stickers WHERE packId = ? AND path IS NOT NULL", arguments: [packId]))
                for id in ids where have.contains(id) {
                    try db.execute(sql: "UPDATE favorite_stickers SET status = 'installed' WHERE packId = ? AND stickerId = ?", arguments: [packId, id])
                }
                return have
            }
            wanted = ids.filter { !have.contains($0) }
            if wanted?.isEmpty == true { return }
        }
        let attempts = (existing?.attempts ?? 0) + 1
        if attempts > Stickers.maxDownloadAttempts {
            try await database.pool.write { db in
                try db.execute(sql: "UPDATE sticker_packs SET status = 'error' WHERE id = ? AND status != 'error'", arguments: [packId])
            }
            return
        }

        let manifest: Stickers.ParsedManifest
        do {
            let proto = try Signalservice_StickerPack(serializedBytes: try Stickers.decrypt(try await fetch("/stickers/\(packId)/manifest.proto"), packKey: key))
            manifest = try Stickers.parseManifest(proto)
        } catch {
            try await database.pool.write { db in
                try self.upsertPack(db, packId: packId, packKey: packKey, status: .error, attempted: finalStatus, attempts: attempts, position: position)
            }
            throw error
        }
        try await database.pool.write { db in
            try self.upsertPack(db, packId: packId, packKey: packKey, status: .pending, attempted: finalStatus, attempts: attempts, position: position,
                                manifest: manifest)
        }

        var toFetch: [Signalservice_StickerPack.Sticker]
        if let wanted {
            toFetch = wanted.compactMap { id in id == Int(manifest.cover.id) ? manifest.cover : manifest.nonCover.first { Int($0.id) == id } }
        } else {
            toFetch = [manifest.cover] + manifest.nonCover
        }
        var fetched: [Int] = []
        for s in toFetch {
            if let id = try? await downloadSticker(packId: packId, packKey: key, s, isCoverOnly: !manifest.coverIncludedInList && s.id == manifest.cover.id) {
                fetched.append(id)
            }
        }
        if fetched.isEmpty && !manifest.nonCover.isEmpty {
            try await database.pool.write { db in
                try db.execute(sql: "UPDATE sticker_packs SET status = 'error', attemptedStatus = ? WHERE id = ?", arguments: [finalStatus.rawValue, packId])
            }
            throw StickerError.allStickersFailed
        }
        let done = fetched
        try await database.pool.write { db in
            let current = try Stickers.status(db, packId)
            if current == .installed {
                // stays installed
            } else if finalStatus == .installed {
                let pos = try position ?? Int.fetchOne(db, sql: "SELECT position FROM sticker_packs WHERE id = ?", arguments: [packId])
                try self.installInTransaction(db, packId: packId, packKey: packKey, position: pos, actionSource: actionSource)
            } else {
                try db.execute(sql: "UPDATE sticker_packs SET status = ? WHERE id = ?", arguments: [finalStatus.rawValue, packId])
            }
            if favoriteStickerIds != nil {
                for id in done {
                    try db.execute(sql: "UPDATE favorite_stickers SET status = 'installed' WHERE packId = ? AND stickerId = ?", arguments: [packId, id])
                }
            }
        }
        jobs?.poke()
        try await resolveReferences(packId: packId)
    }

    nonisolated func upsertPack(_ db: Database, packId: String, packKey: String, status: StickerPackStatus, attempted: StickerPackStatus, attempts: Int,
                    position: Int?, manifest: Stickers.ParsedManifest? = nil) throws {
        try db.execute(sql: """
            INSERT INTO sticker_packs (id, key, author, coverStickerId, createdAt, downloadAttempts, status, stickerCount, title, attemptedStatus, position)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET key = excluded.key, author = coalesce(?, author), coverStickerId = coalesce(?, coverStickerId),
              createdAt = coalesce(?, createdAt), downloadAttempts = excluded.downloadAttempts,
              status = CASE WHEN status = 'installed' AND excluded.status = 'pending' THEN status ELSE excluded.status END,
              stickerCount = coalesce(?, stickerCount), title = coalesce(?, title), attemptedStatus = excluded.attemptedStatus,
              position = coalesce(?, position)
            """, arguments: [packId, packKey, manifest?.author ?? "", Int(manifest?.cover.id ?? 0), MessageStore.now(), attempts, status.rawValue,
                             manifest?.stickerCount ?? 0, manifest?.title ?? "", attempted.rawValue, position ?? 0,
                             manifest?.author, manifest.map { Int($0.cover.id) }, manifest.map { _ in MessageStore.now() },
                             manifest?.stickerCount, manifest?.title, position])
    }

    /// `downloadSticker` + `processNewSticker`: decrypt, have the media service read it (it must
    /// be an image; its dimensions come from there), store it encrypted.
    func downloadSticker(packId: String, packKey: Data, _ s: Signalservice_StickerPack.Sticker, isCoverOnly: Bool) async throws -> Int {
        let plaintext = try Stickers.decrypt(try await fetch("/stickers/\(packId)/full/\(s.id)"), packKey: packKey)
        guard Stickers.sniffContentType(plaintext) != nil else { throw StickerError.notAnImage }
        let info = try await media.imageInfo(plaintext).validated()
        let local = try store.storeLocally(plaintext)
        try await database.pool.write { db in
            let old = try String.fetchOne(db, sql: "SELECT path FROM stickers WHERE packId = ? AND id = ?", arguments: [packId, Int(s.id)])
            try db.execute(sql: """
                INSERT INTO stickers (id, packId, emoji, height, isCoverOnly, path, width, version, localKey, size) VALUES (?, ?, ?, ?, ?, ?, ?, 2, ?, ?)
                ON CONFLICT(id, packId) DO UPDATE SET emoji = excluded.emoji, height = excluded.height, isCoverOnly = excluded.isCoverOnly,
                  path = excluded.path, width = excluded.width, version = 2, localKey = excluded.localKey, size = excluded.size
                """, arguments: [Int(s.id), packId, s.emoji.isEmpty ? nil : s.emoji, info.height, isCoverOnly ? 1 : 0, local.path, info.width,
                                 local.localKey.base64EncodedString(), plaintext.count])
            if let old, old != local.path { try? self.store.delete(old) }
        }
        return Int(s.id)
    }

    /// `getStickerPackPreview`'s pack: title, author and cover image, from the local pack when
    /// it is downloaded, else fetched without being stored (`downloadEphemeralPack`).
    public func preview(packId: String, packKey: String) async throws -> (title: String, author: String, cover: Data) {
        guard Stickers.isPackIdValid(packId), let key = Data(base64Encoded: packKey), key.count == 32 else { throw StickerError.invalidPackId }
        let local = try await database.pool.read { db -> (String, String, Int, String)? in
            guard let r = try Row.fetchOne(db, sql: "SELECT title, author, coverStickerId, key, status FROM sticker_packs WHERE id = ?", arguments: [packId]),
                  let status = StickerPackStatus(rawValue: r["status"] ?? ""), status == .downloaded || status == .installed else { return nil }
            return (r["title"] ?? "", r["author"] ?? "", r["coverStickerId"] ?? 0, r["key"] ?? "")
        }
        if let (title, author, cover, storedKey) = local, storedKey == packKey, let data = try? await stickerData(packId: packId, stickerId: cover) {
            return (title, author, data)
        }
        let manifest = try Stickers.parseManifest(Signalservice_StickerPack(serializedBytes: try Stickers.decrypt(try await fetch("/stickers/\(packId)/manifest.proto"), packKey: key)))
        let cover = try Stickers.decrypt(try await fetch("/stickers/\(packId)/full/\(manifest.cover.id)"), packKey: key)
        guard Stickers.sniffContentType(cover) != nil else { throw StickerError.notAnImage }
        _ = try await media.imageInfo(cover).validated()
        return (manifest.title, manifest.author, cover)
    }

    /// A local sticker's image.
    public func stickerData(packId: String, stickerId: Int) async throws -> Data {
        guard let s = try await database.pool.read({ try Stickers.localSticker($0, packId: packId, stickerId: stickerId) }),
              let key = Data(base64Encoded: s.localKey) else { throw StickerError.unknownSticker }
        return try AttachmentCipher.decryptLocal(store.read(s.path), localKey: key, size: s.size)
    }

    // MARK: install / uninstall / favourites

    /// `installStickerPack`: downloads first when the pack's stickers are not here.
    public func install(packId: String, packKey: String, position: Int? = nil, actionSource: StickerActionSource) async throws {
        let ready = try await database.pool.read { db in
            let s = try Stickers.status(db, packId)
            let count = try Int.fetchOne(db, sql: "SELECT stickerCount FROM sticker_packs WHERE id = ?", arguments: [packId]) ?? 0
            return (s == .downloaded || s == .installed) && count > 0
        }
        guard ready else {
            return try await download(packId: packId, packKey: packKey, finalStatus: .installed, position: position, actionSource: actionSource)
        }
        try await database.pool.write { db in try self.installInTransaction(db, packId: packId, packKey: packKey, position: position, actionSource: actionSource) }
        jobs?.poke()
    }

    nonisolated func installInTransaction(_ db: Database, packId: String, packKey: String, position: Int?, actionSource: StickerActionSource) throws {
        let changed = try Stickers.installSQL(db, packId: packId, timestamp: MessageStore.now(), position: position)
        if actionSource == .ui { try Self.queueOperationSync(db, packId: packId, packKey: packKey, install: true) }
        if changed && actionSource != .storageService && actionSource != .startup { try StorageService.scheduleUpload(db) }
    }

    /// `uninstallStickerPack`
    public func uninstall(packId: String, actionSource: StickerActionSource, uninstalledAt: Int64? = nil) async throws {
        let paths = try await database.pool.write { db -> [String] in
            guard let key = try String.fetchOne(db, sql: "SELECT key FROM sticker_packs WHERE id = ?", arguments: [packId]) else { return [] }
            let changed = try Stickers.uninstallSQL(db, packId: packId, timestamp: uninstalledAt ?? MessageStore.now())
            if actionSource == .ui { try Self.queueOperationSync(db, packId: packId, packKey: key, install: false) }
            if changed && actionSource != .storageService && actionSource != .startup { try StorageService.scheduleUpload(db) }
            return try Stickers.deleteReference(db, messageId: "NOT-USED", packId: packId)
        }
        for p in paths { try? store.delete(p) }
        jobs?.poke()
    }

    /// `markStickerAsFavorite`
    public func setFavorite(packId: String, stickerId: Int, _ favorite: Bool) async throws {
        let now = MessageStore.now()
        if favorite {
            guard let fav = try await database.pool.write({ db -> (packKey: String, needsSync: Bool)? in
                guard let f = try Stickers.favoriteSQL(db, packId: packId, stickerId: stickerId, now: now) else { return nil }
                try Stickers.savePackMetadata(db, packId: packId, packKey: f.packKey, resetDownloadAttempts: true)
                if f.needsSync { try StorageService.scheduleUpload(db) }
                return f
            }) else { throw StickerError.unknownSticker }
            jobs?.poke()
            // installFavoriteSticker
            try await download(packId: packId, packKey: fav.packKey, finalStatus: .known, favoriteStickerIds: [stickerId], actionSource: .ui)
        } else {
            try await database.pool.write { db in
                if try Stickers.unfavoriteSQL(db, packId: packId, stickerId: stickerId, now: now) { try StorageService.scheduleUpload(db) }
            }
            jobs?.poke()
        }
    }

    /// `sendStickerPackSync`
    static func queueOperationSync(_ db: Database, packId: String, packKey: String, install: Bool) throws {
        var job = ConversationJob.fetchLatest([])
        job.type = .stickerPackSync
        job.stickerPack = .init(packId: packId, packKey: packKey, install: install)
        try JobQueue.insert(db, queueType: ConversationJob.queueType, payload: job)
    }

    /// `load` on first start: the blessed packs are fetched as `downloaded`.
    public func ensureBlessedPacks() async throws {
        let missing = try await database.pool.read { db in
            try Stickers.blessedPacks.filter { try Stickers.status(db, $0.id) == nil }
        }
        guard !missing.isEmpty else { return }
        try await database.pool.write { db in
            for p in missing {
                try JobQueue.insert(db, queueType: StickerPackDownloadJob.queueType,
                                    payload: StickerPackDownloadJob(packId: p.id, packKey: p.key, finalStatus: "downloaded", position: nil,
                                                                    actionSource: StickerActionSource.blessed.rawValue))
            }
        }
        jobs?.poke()
    }

    // MARK: references

    /// `resolveReferences`: messages that arrived with a sticker of this pack before it was
    /// local get their own copy of the sticker image.
    public func resolveReferences(packId: String) async throws {
        let refs = try await database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT messageId, stickerId FROM sticker_references WHERE packId = ? AND isUnresolved = 1", arguments: [packId])
                .map { (messageId: $0["messageId"] as String? ?? "", stickerId: $0["stickerId"] as Int? ?? -1) }
        }
        for ref in refs {
            guard let data = try? await stickerData(packId: packId, stickerId: ref.stickerId) else { continue }
            let local = try store.storeLocally(data)
            let contentType = Stickers.sniffContentType(data) ?? "image/webp"
            let dims = try await database.pool.read { try Stickers.localSticker($0, packId: packId, stickerId: ref.stickerId) }
            try await database.pool.write { db in
                guard let row = try Row.fetchOne(db, sql: "SELECT conversationId, sent_at, received_at, type FROM messages WHERE id = ?", arguments: [ref.messageId])
                else { return }
                let loc = MessageAttachments.Location(messageId: ref.messageId, type: .sticker, order: 0)
                var a = try MessageAttachments.fetch(db, loc) ?? MessageAttachment(contentType: contentType, size: data.count)
                guard !a.isDownloaded else {
                    try db.execute(sql: "UPDATE sticker_references SET isUnresolved = 0 WHERE messageId = ? AND packId = ?", arguments: [ref.messageId, packId])
                    return
                }
                a.contentType = contentType
                a.size = data.count
                a.path = local.path
                a.localKey = local.localKey.base64EncodedString()
                a.plaintextHash = local.plaintextHash
                a.version = 2
                a.width = dims?.width
                a.height = dims?.height
                a.pending = false
                try MessageAttachments.upsert(db, loc, conversationId: row["conversationId"], sentAt: row["sent_at"], receivedAt: row["received_at"],
                                              messageType: row["type"] ?? "incoming", a)
                try db.execute(sql: "DELETE FROM attachment_downloads WHERE messageId = ? AND attachmentType = 'sticker'", arguments: [ref.messageId])
                try db.execute(sql: "UPDATE sticker_references SET isUnresolved = 0 WHERE messageId = ? AND packId = ?", arguments: [ref.messageId, packId])
                try MessageAttachments.updateMessageFlags(db, messageId: ref.messageId)
            }
        }
    }
}
