import Foundation
import GRDB

/// References which still authorize displaying cached attachment data.
public struct MediaAvailability: Sendable, Equatable {
    public var messageIds: Set<String> = []
    public var paths: Set<String> = []
    public var messagePaths: [String: Set<String>] = [:]
    public var nextExpiration: Int64?
    public init() {}

    static func fetch(_ db: Database, now: Int64 = MessageStore.now()) throws -> MediaAvailability {
        var result = MediaAvailability()
        let rows = try Row.fetchAll(db, sql: """
            SELECT a.messageId, a.path, a.thumbnailPath, a.screenshotPath, m.expiresAt
            FROM message_attachments a JOIN messages m ON m.id = a.messageId
            WHERE COALESCE(m.json ->> '$.isErased', 0) = 0 AND (m.expiresAt IS NULL OR m.expiresAt > ?)
            """, arguments: [now])
        for row in rows {
            let id: String = row["messageId"]
            result.messageIds.insert(id)
            for column in ["path", "thumbnailPath", "screenshotPath"] {
                if let path: String = row[column] {
                    result.paths.insert(path)
                    result.messagePaths[id, default: []].insert(path)
                }
            }
            if let expiry: Int64 = row["expiresAt"] {
                result.nextExpiration = min(result.nextExpiration ?? expiry, expiry)
            }
        }
        return result
    }

    /// Checks the reference again after asynchronous decode or a save-panel interaction.
    public static func permits(_ db: Database, path: String, messageId: String? = nil, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM message_attachments a JOIN messages m ON m.id = a.messageId
            WHERE (a.path = ? OR a.thumbnailPath = ? OR a.screenshotPath = ?)
              AND (? IS NULL OR a.messageId = ?) AND COALESCE(m.json ->> '$.isErased', 0) = 0
              AND (m.expiresAt IS NULL OR m.expiresAt > ?))
            """, arguments: [path, path, path, messageId, messageId, now]) ?? false
    }
}

extension SignalDatabase {
    public func mediaAvailabilityUpdates() -> AsyncThrowingStream<MediaAvailability, Error> {
        observe { try MediaAvailability.fetch($0) }
    }
    public func mediaAvailability() async throws -> MediaAvailability {
        try await pool.read { try MediaAvailability.fetch($0) }
    }
}
