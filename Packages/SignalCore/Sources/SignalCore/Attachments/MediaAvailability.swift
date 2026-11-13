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

extension MediaAvailability {
    /// Exports an attachment after the save panel: in one writer transaction, the message's own reference to
    /// the file is checked again (the message may have expired, or been deleted, while the panel
    /// was open; another message referencing the same file does not count), then the plaintext
    /// is written.
    public static func export(_ a: MessageAttachment, of messageId: String, to url: URL, database: SignalDatabase,
                              store: AttachmentStore) throws {
        guard let path = a.path else { throw AttachmentStoreError.invalidPath("") }
        // A WAL read snapshot would allow deletion to commit while the file is being written.
        // Serialize the authorization and export with revocation writes.
        try database.pool.write { db in
            guard try permits(db, path: path, messageId: messageId) else { throw AttachmentStoreError.invalidPath(path) }
            try store.export(a, to: url)
        }
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
