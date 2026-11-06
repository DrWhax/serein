// What the Sticker manager panel and the sticker picker show (ts/state/selectors/stickers.std.ts):
// installed packs by position, received and blessed packs newest first, known packs, recent
// stickers (`getRecentStickers`, 24) and installed favourites. Images are read on demand with
// `StickerService.stickerData` and decoded by the media service.

import Foundation
import GRDB

public struct StickerPackSummary: Sendable, Equatable, Identifiable {
    public var id: String
    public var key: String
    public var title: String
    public var author: String
    public var status: StickerPackStatus
    public var isBlessed: Bool
    public var coverStickerId: Int
    public var stickerCount: Int
    public var position: Int
    public var createdAt: Int64
    /// Stickers that are here (cover-only stickers are not offered).
    public var stickers: [StickerSummary]
}

public struct StickerSummary: Sendable, Equatable, Hashable {
    public var packId: String
    public var id: Int
    public var emoji: String?
    public var width: Int?
    public var height: Int?
}

public struct StickerManagerState: Sendable, Equatable {
    public var installed: [StickerPackSummary]
    public var received: [StickerPackSummary]
    public var blessed: [StickerPackSummary]
    public var known: [StickerPackSummary]
    public var recents: [StickerSummary]
    public var favorites: [StickerSummary]
}

extension Stickers {
    public static func managerState(_ db: Database) throws -> StickerManagerState {
        let stickers = Dictionary(grouping: try Row.fetchAll(db, sql: """
            SELECT packId, id, emoji, width, height FROM stickers WHERE path IS NOT NULL AND ifnull(isCoverOnly, 0) = 0 ORDER BY packId, id
            """).map { StickerSummary(packId: $0["packId"], id: $0["id"], emoji: $0["emoji"], width: $0["width"], height: $0["height"]) }, by: \.packId)
        let packs = try Row.fetchAll(db, sql: "SELECT * FROM sticker_packs").compactMap { r -> StickerPackSummary? in
            guard let status = StickerPackStatus(rawValue: r["status"] ?? "") else { return nil }
            let id: String = r["id"]
            return StickerPackSummary(id: id, key: r["key"] ?? "", title: r["title"] ?? "", author: r["author"] ?? "", status: status, isBlessed: isBlessed(id),
                                      coverStickerId: r["coverStickerId"] ?? 0, stickerCount: r["stickerCount"] ?? 0, position: r["position"] ?? 0,
                                      createdAt: r["createdAt"] ?? 0, stickers: stickers[id] ?? [])
        }
        let newestFirst: (StickerPackSummary, StickerPackSummary) -> Bool = { $0.createdAt > $1.createdAt }
        func sticker(_ row: Row) -> StickerSummary {
            StickerSummary(packId: row["packId"], id: row["id"], emoji: row["emoji"], width: row["width"], height: row["height"])
        }
        let recents = try Row.fetchAll(db, sql: """
            SELECT stickers.* FROM stickers JOIN sticker_packs ON stickers.packId = sticker_packs.id
            WHERE stickers.lastUsed > 0 AND sticker_packs.status = 'installed' ORDER BY stickers.lastUsed DESC LIMIT 24
            """).map(sticker)
        let favorites = try Row.fetchAll(db, sql: """
            SELECT s.* FROM favorite_stickers f JOIN stickers s ON s.packId = f.packId AND s.id = f.stickerId
            WHERE f.status = 'installed' AND f.deletedAtTimestampMs IS NULL AND s.path IS NOT NULL ORDER BY f.favoritedAtTimestampMs DESC
            """).map(sticker)
        return StickerManagerState(
            installed: packs.filter { $0.status == .installed }.sorted { ($0.position, $0.id) < ($1.position, $1.id) },
            received: packs.filter { [.downloaded, .pending, .installed].contains($0.status) && !$0.isBlessed }.sorted(by: newestFirst),
            blessed: packs.filter(\.isBlessed).sorted(by: newestFirst),
            known: packs.filter { !$0.isBlessed && $0.status == .known }.sorted(by: newestFirst),
            recents: recents, favorites: favorites)
    }
}
