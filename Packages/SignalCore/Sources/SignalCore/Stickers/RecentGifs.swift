// Recently sent GIFs (ts/sql/Server.node.ts getRecentGifs / addRecentGif / removeRecentGif,
// ts/state/ducks/gifs.preload.ts): the `recentGifs` table, newest first, at most 64.

import Foundation
import GRDB

/// A GIF from the GIF search, as the picker shows and sends it (upstream `GifType`).
public struct RecentGif: Sendable, Equatable {
    public struct Media: Sendable, Equatable {
        public var url: String
        public var width: Int
        public var height: Int
        public init(url: String, width: Int, height: Int) {
            self.url = url
            self.width = width
            self.height = height
        }
    }
    public var id: String
    public var title: String
    public var description: String
    public var previewMedia: Media
    public var attachmentMedia: Media
    public init(id: String, title: String, description: String, previewMedia: Media, attachmentMedia: Media) {
        self.id = id
        self.title = title
        self.description = description
        self.previewMedia = previewMedia
        self.attachmentMedia = attachmentMedia
    }
}

public enum RecentGifs {
    /// `MAX_RECENT_GIFS`
    public static let limit = 64

    public static func all(_ db: Database) throws -> [RecentGif] {
        try Row.fetchAll(db, sql: "SELECT * FROM recentGifs ORDER BY lastUsedAt DESC LIMIT ?", arguments: [limit]).map { r in
            RecentGif(id: r["id"], title: r["title"], description: r["description"],
                      previewMedia: .init(url: r["previewMedia_url"], width: r["previewMedia_width"], height: r["previewMedia_height"]),
                      attachmentMedia: .init(url: r["attachmentMedia_url"], width: r["attachmentMedia_width"], height: r["attachmentMedia_height"]))
        }
    }

    /// `addRecentGif`: used now; the oldest beyond the limit go.
    public static func add(_ db: Database, _ gif: RecentGif, at lastUsedAt: Int64? = nil) throws {
        let lastUsedAt = lastUsedAt ?? MessageStore.now()
        try db.execute(sql: """
            INSERT OR REPLACE INTO recentGifs (id, title, description, previewMedia_url, previewMedia_width, previewMedia_height,
                                               attachmentMedia_url, attachmentMedia_width, attachmentMedia_height, lastUsedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [gif.id, gif.title, gif.description, gif.previewMedia.url, gif.previewMedia.width, gif.previewMedia.height,
                             gif.attachmentMedia.url, gif.attachmentMedia.width, gif.attachmentMedia.height, lastUsedAt])
        try db.execute(sql: "DELETE FROM recentGifs WHERE id NOT IN (SELECT id FROM recentGifs ORDER BY lastUsedAt DESC LIMIT ?)", arguments: [limit])
    }

    /// `removeRecentGif`
    public static func remove(_ db: Database, id: String) throws {
        try db.execute(sql: "DELETE FROM recentGifs WHERE id = ?", arguments: [id])
    }
}

extension SignalDatabase {
    public func recentGifUpdates() -> AsyncThrowingStream<[RecentGif], Error> { observe(RecentGifs.all) }
}
