// The `callLinks` table (ts/sql/server/callLinks.node.ts): links we created (with an admin
// key) or joined, their SFU state (name, restrictions, revoked, expiration) and deletion
// tombstones that the storage service syncs.

import Foundation
import GRDB

public struct CallLinkRecord: Sendable, Equatable {
    /// Hex of HKDF(rootKey) (`getRoomIdFromRootKey`).
    public var roomId: String
    public var rootKey: Data
    public var adminKey: Data?
    public var name: String
    /// ringrtc CallLinkRestrictions (0 none, 1 admin approval, 2 unknown).
    public var restrictions: Int
    public var revoked: Bool
    /// Milliseconds.
    public var expiration: Int64?
    public var deleted: Bool
    public var deletedAt: Int64?

    public init(roomId: String, rootKey: Data, adminKey: Data?, name: String = "", restrictions: Int = 0, revoked: Bool = false,
                expiration: Int64? = nil, deleted: Bool = false, deletedAt: Int64? = nil) {
        self.roomId = roomId
        self.rootKey = rootKey
        self.adminKey = adminKey
        self.name = name
        self.restrictions = restrictions
        self.revoked = revoked
        self.expiration = expiration
        self.deleted = deleted
        self.deletedAt = deletedAt
    }

    public var isAdmin: Bool { adminKey != nil }
}

public enum CallLinkStore {
    public static func roomId(rootKey: Data) throws -> String { try StorageRecords.roomId(rootKey: rootKey) }

    static func decode(_ r: Row) -> CallLinkRecord {
        CallLinkRecord(roomId: r["roomId"], rootKey: r["rootKey"], adminKey: r["adminKey"], name: r["name"] ?? "", restrictions: r["restrictions"] ?? 0,
                       revoked: (r["revoked"] as Int64? ?? 0) != 0, expiration: r["expiration"], deleted: (r["deleted"] as Int64? ?? 0) != 0,
                       deletedAt: r["deletedAt"])
    }

    public static func get(_ db: Database, roomId: String) throws -> CallLinkRecord? {
        try Row.fetchOne(db, sql: "SELECT * FROM callLinks WHERE roomId = ?", arguments: [roomId]).map(decode)
    }

    /// `getAllCallLinks` (not deleted).
    public static func all(_ db: Database) throws -> [CallLinkRecord] {
        try Row.fetchAll(db, sql: "SELECT * FROM callLinks WHERE deleted IS NOT 1 ORDER BY roomId").map(decode)
    }

    /// `insertCallLink`; links we administer are uploaded to the storage service.
    public static func insert(_ db: Database, _ l: CallLinkRecord) throws {
        try db.execute(sql: """
            INSERT INTO callLinks (roomId, rootKey, adminKey, name, restrictions, revoked, expiration, deleted, deletedAt, storageNeedsSync)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            """, arguments: [l.roomId, l.rootKey, l.adminKey, l.name, l.restrictions, l.revoked ? 1 : 0, l.expiration, l.deleted ? 1 : 0, l.deletedAt])
        if l.isAdmin { try StorageWriteBack.recordChanged(db, .callLink(roomId: l.roomId)) }
    }

    /// `insertOrUpdateCallLinkFromSync`: a new link, or a known one that gained its admin key.
    @discardableResult
    public static func insertOrUpdateFromSync(_ db: Database, _ l: CallLinkRecord) throws -> (inserted: Bool, updated: Bool) {
        if let existing = try get(db, roomId: l.roomId) {
            guard let adminKey = l.adminKey, adminKey != existing.adminKey else { return (false, false) }
            try db.execute(sql: "UPDATE callLinks SET adminKey = ? WHERE roomId = ?", arguments: [adminKey, l.roomId])
            return (false, true)
        }
        try db.execute(sql: """
            INSERT INTO callLinks (roomId, rootKey, adminKey, name, restrictions, revoked, expiration, deleted, storageNeedsSync)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0)
            """, arguments: [l.roomId, l.rootKey, l.adminKey, l.name, l.restrictions, l.revoked ? 1 : 0, l.expiration])
        return (true, false)
    }

    /// `updateCallLinkState`
    public static func updateState(_ db: Database, roomId: String, name: String, restrictions: Int, revoked: Bool, expiration: Int64?) throws {
        try db.execute(sql: "UPDATE callLinks SET name = ?, restrictions = ?, revoked = ?, expiration = ? WHERE roomId = ?",
                       arguments: [name, restrictions, revoked ? 1 : 0, expiration, roomId])
    }

    /// `markCallLinkDeleted`: links we never administered or synced are removed; others keep
    /// a tombstone for the storage service. Returns whether a storage upload is needed.
    @discardableResult
    public static func markDeleted(_ db: Database, roomId: String, at deletedAt: Int64) throws -> Bool {
        try db.execute(sql: "DELETE FROM callLinks WHERE adminKey IS NULL AND storageID IS NULL AND roomId = ?", arguments: [roomId])
        if db.changesCount != 0 { return false }
        try db.execute(sql: "UPDATE callLinks SET deleted = 1, deletedAt = ?, storageNeedsSync = 1 WHERE roomId = ? AND deleted IS NOT 1",
                       arguments: [deletedAt, roomId])
        guard db.changesCount != 0 else { return false }
        try StorageService.scheduleUpload(db)
        return true
    }

    /// `markAllCallLinksDeleted` (clearing the call history).
    @discardableResult
    public static func markAllDeleted(_ db: Database, at deletedAt: Int64) throws -> Bool {
        try db.execute(sql: """
            UPDATE callLinks SET deleted = 1, deletedAt = ?, storageNeedsSync = 1
            WHERE (adminKey IS NOT NULL OR storageID IS NOT NULL) AND deleted IS NOT 1
            """, arguments: [deletedAt])
        let marked = db.changesCount
        try db.execute(sql: "DELETE FROM callLinks WHERE adminKey IS NULL AND storageID IS NULL")
        if marked > 0 { try StorageService.scheduleUpload(db) }
        return marked > 0
    }

    /// `handleCallLinkUpdate` (a CallLinkUpdate sync): the link is recorded, a link we now
    /// administer gets a placeholder call-history row, and its state is read from the SFU by
    /// the "call link refresh" job.
    public static func applyUpdateSync(_ db: Database, rootKey: Data, adminKey: Data?, now: Int64) throws {
        let roomId = try roomId(rootKey: rootKey)
        let (inserted, _) = try insertOrUpdateFromSync(db, CallLinkRecord(roomId: roomId, rootKey: rootKey, adminKey: adminKey))
        if inserted, adminKey != nil { try CallHistoryStore.save(db, placeholderHistory(roomId: roomId, now: now)) }
        try JobQueue.insert(db, queueType: CallLinkRefreshJob.queueType,
                            payload: CallLinkRefreshJob(rootKey: rootKey.base64EncodedString(), adminKey: adminKey?.base64EncodedString(),
                                                        source: "handleCallLinkUpdate"))
    }

    /// `toCallHistoryFromUnusedCallLink`
    public static func placeholderHistory(roomId: String, now: Int64) -> CallHistoryDetails {
        CallHistoryDetails(details: CallDetails(callId: UUID().uuidString.lowercased(), peerId: roomId, ringerId: nil, startedById: nil, mode: .adhoc,
                                                type: .adhoc, direction: .incoming, timestamp: now),
                           status: .pending)
    }

    /// `finalizeDeletedCallLinks` once the SFU has deleted them.
    public static func finalizeDeleted(_ db: Database, roomId: String) throws {
        try db.execute(sql: "DELETE FROM callsHistory WHERE peerId = ?", arguments: [roomId])
    }
}
