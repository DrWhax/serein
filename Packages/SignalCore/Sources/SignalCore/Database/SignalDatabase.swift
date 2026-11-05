// Encrypted local database: SQLCipher via GRDB, WAL mode, schema = latest
// upstream Signal Desktop schema (UpstreamSchema.generated.swift).

import Foundation
import GRDB

public final class SignalDatabase: Sendable {
    public let pool: DatabasePool

    /// Opens (creating if needed) the database at `url`, keyed with a raw 256-bit key.
    public init(url: URL, key: Data) throws {
        precondition(key.count == 32)
        var config = Configuration()
        let rawKey = "x'\(key.hex)'"
        config.prepareDatabase { db in
            try db.usePassphrase(rawKey)
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        pool = try DatabasePool(path: url.path, configuration: config)
        try Self.migrator.migrate(pool)
    }

    /// Opens the database with the key held in `keyStore`.
    public convenience init(url: URL, keyStore: any DatabaseKeyStore) throws {
        try self.init(url: url, key: try keyStore.loadOrCreateKey())
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        // Upstream schema version 1870 (ts/sql/migrations), reproduced in one step:
        // SignalSafe never opens Signal Desktop databases, so legacy migrations are not needed.
        m.registerMigration("upstream-1870") { db in
            for statement in UpstreamSchema.statements { try db.execute(sql: statement) }
        }
        return m
    }

    public var tableNames: [String] {
        get throws {
            try pool.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name") }
        }
    }
}

struct ItemBox<T> { var id: String?; var value: T }
extension ItemBox: Decodable where T: Decodable {}
extension ItemBox: Encodable where T: Encodable {}

/// The upstream `items` key-value table: `json = {"id": key, "value": value}`.
public enum Items {
    public static func get<T: Decodable>(_ db: Database, _ key: String, as: T.Type = T.self) throws -> T? {
        guard let json = try String.fetchOne(db, sql: "SELECT json FROM items WHERE id = ?", arguments: [key]) else { return nil }
        return try JSONDecoder().decode(ItemBox<T>.self, from: Data(json.utf8)).value
    }

    public static func set<T: Encodable>(_ db: Database, _ key: String, _ value: T) throws {
        let json = String(decoding: try JSONEncoder().encode(ItemBox(id: key, value: value)), as: UTF8.self)
        try db.execute(sql: "INSERT INTO items (id, json) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json",
                       arguments: [key, json])
    }

    public static func remove(_ db: Database, _ key: String) throws {
        try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [key])
    }
}
