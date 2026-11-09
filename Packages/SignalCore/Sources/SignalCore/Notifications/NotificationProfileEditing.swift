// Creating, editing and deleting notification profiles, and turning profile sync with our other
// devices off and on (upstream ducks/notificationProfiles createProfile / updateProfile /
// markProfileDeleted / setIsSyncEnabled, and storageRecordOps prepareFor{Disabled,Enabled}-
// NotificationProfileSync). Profiles are storage records; every change is queued for upload.

import Foundation
import GRDB

extension NotificationProfiles {
    /// `generateNotificationProfileId`: 16 random bytes, hex.
    public static func newId() -> String {
        (0..<16).map { _ in String(UInt8.random(in: 0...255), radix: 16).leftPadded(to: 2) }.joined()
    }

    /// Inserts or replaces a profile's row (keeping its storage fields).
    static func write(_ db: Database, _ p: NotificationProfile) throws {
        let members = String(decoding: try JSONSerialization.data(withJSONObject: p.allowedMembers.sorted()), as: UTF8.self)
        let days = try p.scheduleDaysEnabled.map { d in
            String(decoding: try JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: d.map { (String($0.key), $0.value) }),
                                                        options: .sortedKeys), as: UTF8.self)
        }
        try db.execute(sql: """
            INSERT INTO notificationProfiles (id, name, emoji, color, createdAtMs, allowAllCalls, allowAllMentions, allowedMembersJson,
                scheduleEnabled, scheduleStartTime, scheduleEndTime, scheduleDaysEnabledJson, deletedAtTimestampMs, storageNeedsSync)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, emoji = excluded.emoji, color = excluded.color,
                allowAllCalls = excluded.allowAllCalls, allowAllMentions = excluded.allowAllMentions, allowedMembersJson = excluded.allowedMembersJson,
                scheduleEnabled = excluded.scheduleEnabled, scheduleStartTime = excluded.scheduleStartTime, scheduleEndTime = excluded.scheduleEndTime,
                scheduleDaysEnabledJson = excluded.scheduleDaysEnabledJson, deletedAtTimestampMs = excluded.deletedAtTimestampMs, storageNeedsSync = 1
            """, arguments: [p.id, p.name, p.emoji, Int64(p.color), p.createdAtMs, p.allowAllCalls, p.allowAllMentions, members, p.scheduleEnabled,
                             p.scheduleStartTime, p.scheduleEndTime, days, p.deletedAtTimestampMs])
    }

    /// Every profile row, deleted ones included, with whether it has a storage record.
    static func allRows(_ db: Database) throws -> [(profile: NotificationProfile, remote: Bool)] {
        let remote = Set(try String.fetchAll(db, sql: "SELECT id FROM notificationProfiles WHERE storageID IS NOT NULL"))
        return try rows(db, sql: "SELECT * FROM notificationProfiles WHERE coalesce(deletedAtTimestampMs, 0) = 0 ORDER BY createdAtMs DESC")
            .map { ($0, remote.contains($0.id)) }
    }

    static func saveOverride(_ db: Database, _ o: StorageRecords.NotificationProfileOverride?) throws {
        if let o { try Items.set(db, "notificationProfileOverride", o) } else { try Items.remove(db, "notificationProfileOverride") }
    }

    /// `cleanNotificationProfileForComparision`: the profile without what differs per device.
    static func comparable(_ p: NotificationProfile) -> NotificationProfile {
        var c = p
        c.id = ""
        c.color = 0
        c.createdAtMs = 0
        return c
    }
}

extension String {
    fileprivate func leftPadded(to n: Int) -> String { count >= n ? self : String(repeating: "0", count: n - count) + self }
}

extension Messenger {
    /// `createProfile`: a new profile (its id assigned here); returns the id.
    @discardableResult
    public func createNotificationProfile(_ profile: NotificationProfile) async throws -> String {
        var p = profile
        p.id = NotificationProfiles.newId()
        p.createdAtMs = MessageStore.now()
        p.deletedAtTimestampMs = nil
        let saved = p
        try await database.pool.write { try NotificationProfiles.write($0, saved) }
        jobs.poke()
        return saved.id
    }

    /// `updateProfile`.
    public func updateNotificationProfile(_ profile: NotificationProfile) async throws {
        try await database.pool.write { try NotificationProfiles.write($0, profile) }
        jobs.poke()
    }

    /// `markProfileDeleted`: kept as a tombstone for storage; an override for it is cleared.
    public func deleteNotificationProfile(_ id: String) async throws {
        let account = self.account
        try await database.pool.write { db in
            try db.execute(sql: "UPDATE notificationProfiles SET deletedAtTimestampMs = ?, storageNeedsSync = 1 WHERE id = ?",
                           arguments: [MessageStore.now(), id])
            if let o = try Items.get(db, "notificationProfileOverride", as: StorageRecords.NotificationProfileOverride.self), o.enabled?.profileId == id {
                try NotificationProfiles.saveOverride(db, nil)
                try StorageWriteBack.accountChanged(db, account: account)
            }
        }
        jobs.poke()
    }

    /// Whether profiles sync with our other devices (`notificationProfileSyncDisabled`).
    public func notificationProfileSyncEnabled() async throws -> Bool {
        try await database.pool.read { !((try Items.get($0, "notificationProfileSyncDisabled", as: Bool.self)) ?? false) }
    }

    /// `setIsSyncEnabled` on a linked device. Off: the synced profiles are copied as this
    /// device's own (createdAtMs + 1 marks the copy) and the override follows its copy. On: a
    /// local profile matching a synced one goes (the override follows the synced one); a copy
    /// that diverged is kept, renamed with `copyLabel`.
    public func setNotificationProfileSyncEnabled(_ enabled: Bool, copyLabel: @escaping @Sendable (String) -> String) async throws {
        let account = self.account
        try await database.pool.write { db in
            let wasDisabled = try Items.get(db, "notificationProfileSyncDisabled", as: Bool.self) ?? false
            guard wasDisabled == enabled else { return }
            var override = try Items.get(db, "notificationProfileOverride", as: StorageRecords.NotificationProfileOverride.self)
            let rows = try NotificationProfiles.allRows(db)
            if !enabled {
                try Items.set(db, "notificationProfileOverrideFromPrimary", override)
                for (profile, remote) in rows where remote {
                    var copy = profile
                    copy.id = NotificationProfiles.newId()
                    copy.createdAtMs = profile.createdAtMs + 1
                    try db.execute(sql: "DELETE FROM notificationProfiles WHERE id = ?", arguments: [copy.id])
                    try NotificationProfiles.write(db, copy)
                    try db.execute(sql: "UPDATE notificationProfiles SET storageNeedsSync = 0 WHERE id = ?", arguments: [copy.id])
                    if override?.enabled?.profileId == profile.id {
                        override = .init(disabledAtMs: nil, enabled: .init(profileId: copy.id, endsAtMs: override?.enabled?.endsAtMs))
                    }
                }
                try Items.set(db, "notificationProfileSyncDisabled", true)
            } else {
                try Items.remove(db, "notificationProfileOverrideFromPrimary")
                let remote = rows.filter(\.remote).map(\.profile)
                var local = rows.filter { !$0.remote }.map(\.profile)
                for r in remote {
                    guard let match = local.first(where: { NotificationProfiles.comparable($0) == NotificationProfiles.comparable(r) }) else { continue }
                    try db.execute(sql: "DELETE FROM notificationProfiles WHERE id = ?", arguments: [match.id])
                    local.removeAll { $0.id == match.id }
                    if override?.enabled?.profileId == match.id {
                        override = .init(disabledAtMs: nil, enabled: .init(profileId: r.id, endsAtMs: override?.enabled?.endsAtMs))
                    }
                }
                for var l in local where remote.contains(where: { $0.name == l.name && $0.createdAtMs + 1 == l.createdAtMs }) {
                    l.name = copyLabel(l.name)
                    try NotificationProfiles.write(db, l)
                }
                // This device's profiles now go to storage too.
                try db.execute(sql: "UPDATE notificationProfiles SET storageNeedsSync = 1 WHERE storageID IS NULL")
                try Items.set(db, "notificationProfileSyncDisabled", false)
            }
            try NotificationProfiles.saveOverride(db, override)
            try StorageWriteBack.accountChanged(db, account: account)
        }
        jobs.poke()
    }

    /// `hasSeenNotificationProfileOnboarding`.
    public func setNotificationProfileOnboardingSeen() async throws {
        try await database.pool.write { try Items.set($0, "hasSeenNotificationProfileOnboarding", true) }
    }
}

extension SignalDatabase {
    public func notificationProfileOnboardingSeen() async throws -> Bool {
        try await pool.read { (try Items.get($0, "hasSeenNotificationProfileOnboarding", as: Bool.self)) ?? false }
    }
}
