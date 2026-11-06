// Notification profiles' schedules (cases from ts/test-node/types/NotificationProfile_test)
// and the notify / badge rules against stored messages.

import Foundation
import GRDB
import Testing
@testable import SignalCore

@Suite struct NotificationProfileTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()
    /// 10am on a Monday, local time.
    var now: Int64 {
        let monday = cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 10))!
        return Int64(monday.timeIntervalSince1970 * 1000)
    }
    let hour: Int64 = 3_600_000
    let minute: Int64 = 60_000

    func profile(_ id: String, created: Int64? = nil, days: [Int] = [], start: Int? = nil, end: Int? = nil) -> NotificationProfile {
        NotificationProfile(id: id, name: id, createdAtMs: created ?? now, allowAllCalls: true, allowedMembers: ["c1"], scheduleEnabled: !days.isEmpty,
                            scheduleStartTime: start, scheduleEndTime: end,
                            scheduleDaysEnabled: Dictionary(uniqueKeysWithValues: (1...7).map { ($0, days.contains($0)) }))
    }

    @Test func noProfilesNoChange() {
        #expect(NotificationProfiles.nextEvent(override: nil, profiles: [], time: now, calendar: cal) == .noChange(activeProfile: nil))
        #expect(NotificationProfiles.nextEvent(override: nil, profiles: [profile("a"), profile("b")], time: now, calendar: cal) == .noChange(activeProfile: nil))
    }

    @Test func manualOverride() {
        let p = profile("a")
        #expect(NotificationProfiles.nextEvent(override: .enabled(profileId: "a", endsAtMs: nil), profiles: [p], time: now, calendar: cal)
                == .noChange(activeProfile: "a"))
        #expect(NotificationProfiles.nextEvent(override: .enabled(profileId: "a", endsAtMs: now + hour), profiles: [p], time: now, calendar: cal)
                == .willDisable(at: now + hour, activeProfile: "a", clearEnableOverride: true))
    }

    @Test func activeBySchedule() {
        let p = profile("a", days: [1], start: 900, end: 1200)
        #expect(NotificationProfiles.nextEvent(override: nil, profiles: [p, profile("work")], time: now, calendar: cal)
                == .willDisable(at: now + 2 * hour, activeProfile: "a", clearEnableOverride: false))
    }

    @Test func newerProfilePreempts() {
        let base = profile("base", created: now, days: [1], start: 900, end: 1200)
        let preempt = profile("preempt", created: now + 10, days: [1], start: 1030, end: 1200)
        let older = profile("older", created: now - 10, days: [1], start: 1015, end: 1200)
        let sorted = [preempt, base, older].sorted { $0.createdAtMs > $1.createdAtMs }
        // The newest scheduled profile active now wins; base isn't active (preempt starts at 10:30).
        let event = NotificationProfiles.nextEvent(override: nil, profiles: sorted, time: now, calendar: cal)
        #expect(event == .willDisable(at: now + 30 * minute, activeProfile: "base", clearEnableOverride: false))
    }

    @Test func overnightScheduleFromYesterday() {
        // Sunday 20:00 → Monday 11:00: on now, ends in an hour.
        let p = profile("night", days: [7], start: 2000, end: 1100)
        #expect(NotificationProfiles.nextEvent(override: nil, profiles: [p], time: now, calendar: cal)
                == .willDisable(at: now + hour, activeProfile: "night", clearEnableOverride: false))
    }

    @Test func willEnable() {
        #expect(NotificationProfiles.nextEvent(override: nil, profiles: [profile("a", days: [1], start: 1100, end: 1400)], time: now, calendar: cal)
                == .willEnable(at: now + hour, toEnable: "a", clearDisableOverride: false))
        #expect(NotificationProfiles.nextEvent(override: nil, profiles: [profile("a", days: [1], start: 2000, end: 1100)], time: now, calendar: cal)
                == .willEnable(at: now + 10 * hour, toEnable: "a", clearDisableOverride: false))
        #expect(NotificationProfiles.nextEvent(override: .disabled(atMs: now), profiles: [profile("a", days: [1], start: 1100, end: 1400)],
                                               time: now, calendar: cal)
                == .willEnable(at: now + hour, toEnable: "a", clearDisableOverride: true))
        // Six days out: Sunday.
        let sunday = profile("a", days: [7], start: 1000, end: 1100)
        #expect(NotificationProfiles.nextEvent(override: nil, profiles: [sunday], time: now, calendar: cal)
                == .willEnable(at: now + 6 * 24 * hour, toEnable: "a", clearDisableOverride: false))
    }

    @Test func shouldNotifyRules() {
        let p = profile("a")
        #expect(NotificationProfiles.shouldNotify(isCall: false, isMentionOrReply: false, conversationId: "x", activeProfile: nil))
        #expect(NotificationProfiles.shouldNotify(isCall: false, isMentionOrReply: false, conversationId: "c1", activeProfile: p))
        #expect(!NotificationProfiles.shouldNotify(isCall: false, isMentionOrReply: true, conversationId: "x", activeProfile: p))
        #expect(NotificationProfiles.shouldNotify(isCall: true, isMentionOrReply: false, conversationId: "x", activeProfile: p))
    }
}

@Suite(.serialized) struct NotificationPolicyTests {
    @Test func incomingMessageNotifiesUnlessMutedOrProfiled() async throws {
        try await LinkedClient.with { c in
            let (id, _) = try await c.receiveFromAlice("ping", withProfileKey: true)
            let aci = c.account.aci
            let pending = try await c.database.pool.read { db in try NotificationPolicy.pending(db, messageId: id, ourAci: aci) }
            #expect(pending?.body == "ping" && pending?.groupTitle == nil && pending?.kind == .message)
            #expect(try await c.database.pool.read { db in try NotificationPolicy.badgeCount(db) } == 1)

            // Muted 1:1 chats never notify (and drop out of the badge).
            let alice = c.aliceAci
            try await c.database.pool.write { db in
                let conv = try MessageStore.privateConversation(db, serviceId: alice)
                try MessageStore.updateConversationJSON(db, conversationId: conv) { $0["muteExpiresAt"] = Int64.max }
            }
            #expect(try await c.database.pool.read { db in try NotificationPolicy.pending(db, messageId: id, ourAci: aci) } == nil)
            #expect(try await c.database.pool.read { db in try NotificationPolicy.badgeCount(db) } == 0)
            try await c.database.pool.write { db in try Items.set(db, "badge-count-muted-conversations", true) }
            #expect(try await c.database.pool.read { db in try NotificationPolicy.badgeCount(db) } == 1)

            // Unmuted, but a manually enabled profile that doesn't allow alice.
            try await c.database.pool.write { db in
                let conv = try MessageStore.privateConversation(db, serviceId: alice)
                try MessageStore.updateConversationJSON(db, conversationId: conv) { $0["muteExpiresAt"] = nil }
                try db.execute(sql: """
                    INSERT INTO notificationProfiles (id, name, color, createdAtMs, allowAllCalls, allowAllMentions, allowedMembersJson, scheduleEnabled)
                    VALUES ('0102', 'Focus', 0, 1, 1, 0, '[]', 0)
                    """)
                try Items.set(db, "notificationProfileOverride", StorageRecords.NotificationProfileOverride(disabledAtMs: nil, enabled: .init(profileId: "0102", endsAtMs: nil)))
            }
            #expect(try await c.database.pool.read { db in try NotificationPolicy.pending(db, messageId: id, ourAci: aci) } == nil)
        }
    }

    @Test func settingsDefaults() async throws {
        let (db, _) = try LinkedClient.temporaryDatabase()
        let s = try await db.pool.read { try NotificationSettings.load($0) }
        #expect(s.setting == .message && s.playSound && !s.drawAttention && s.notifyForMentionsIfMuted && !s.badgeCountMutedConversations)
    }
}
