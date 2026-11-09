// Notification profiles edited on this device: create / update / delete (storage-queued, the
// override cleared with its profile), and profile sync off (synced profiles copied locally)
// and back on (matching copies folded into the synced ones, diverged copies renamed).

import Foundation
import GRDB
import Testing
@testable import SignalCore

@Suite(.serialized) struct NotificationProfileEditingTests {
    func profiles(_ c: LinkedClient) async throws -> [NotificationProfile] { try await c.database.pool.read { try NotificationProfiles.all($0) } }

    @Test func createUpdateDelete() async throws {
        try await LinkedClient.with { c in
            let id = try await c.messenger.createNotificationProfile(NotificationProfile(id: "", name: "Work", emoji: "💪", color: 0xFFE3E3FE, createdAtMs: 0,
                                                                                         allowedMembers: ["conv-1"], scheduleEnabled: true,
                                                                                         scheduleStartTime: 900, scheduleEndTime: 1700,
                                                                                         scheduleDaysEnabled: [1: true, 2: true, 6: false]))
            #expect(id.count == 32)
            var p = try #require(try await profiles(c).first)
            #expect(p.id == id && p.name == "Work" && p.emoji == "💪" && p.allowedMembers == ["conv-1"] && p.scheduleDaysEnabled?[2] == true)
            #expect(try await c.database.pool.read { try Int.fetchOne($0, sql: "SELECT storageNeedsSync FROM notificationProfiles WHERE id = ?", arguments: [id]) } == 1)

            p.name = "Deep work"
            p.allowAllMentions = true
            try await c.messenger.updateNotificationProfile(p)
            #expect(try await profiles(c).first?.name == "Deep work")
            #expect(try await profiles(c).first?.allowAllMentions == true)

            try await c.messenger.setNotificationProfileOverride(profileId: id, enabled: true, endsAt: nil)
            try await c.messenger.deleteNotificationProfile(id)
            #expect(try await profiles(c).isEmpty)
            #expect(try await c.database.pool.read { try NotificationProfiles.override($0) } == nil)
        }
    }

    @Test func syncOffCopiesAndSyncOnFolds() async throws {
        try await LinkedClient.with { c in
            // A synced profile (it has a storage record) that is on.
            let id = try await c.messenger.createNotificationProfile(NotificationProfile(id: "", name: "Sleep", createdAtMs: 0))
            try await c.database.pool.write { try $0.execute(sql: "UPDATE notificationProfiles SET storageID = 'abc' WHERE id = ?", arguments: [id]) }
            try await c.messenger.setNotificationProfileOverride(profileId: id, enabled: true, endsAt: nil)

            try await c.messenger.setNotificationProfileSyncEnabled(false) { "\($0) (copy)" }
            let local = try await profiles(c)
            #expect(local.count == 1 && local[0].id != id && local[0].name == "Sleep")
            if case .enabled(let active, _)? = try await c.database.pool.read({ try NotificationProfiles.override($0) }) {
                #expect(active == local[0].id)
            } else {
                Issue.record("override should follow the local copy")
            }

            try await c.messenger.setNotificationProfileSyncEnabled(true) { "\($0) (copy)" }
            let synced = try await profiles(c)
            #expect(synced.map(\.id) == [id])
        }
    }
}
