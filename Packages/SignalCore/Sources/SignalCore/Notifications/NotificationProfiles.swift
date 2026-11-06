// Port of ts/types/NotificationProfile.std.ts: notification profiles (who may still notify)
// and their schedules — which profile is active now, and when that next changes, given the
// manual override (on until a time, on until its schedule ends, or off since a time).
// Times are local wall-clock (the schedule's 24-hour HHMM ints, days Monday = 1 … Sunday = 7).

import Foundation
import GRDB

public struct NotificationProfile: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var emoji: String?
    public var color: UInt32
    public var createdAtMs: Int64
    public var allowAllCalls: Bool
    public var allowAllMentions: Bool
    /// conversation ids
    public var allowedMembers: Set<String>
    public var scheduleEnabled: Bool
    public var scheduleStartTime: Int?
    public var scheduleEndTime: Int?
    /// day (1 = Monday … 7 = Sunday) → enabled
    public var scheduleDaysEnabled: [Int: Bool]?
    public var deletedAtTimestampMs: Int64?

    public init(id: String, name: String, emoji: String? = nil, color: UInt32 = NotificationProfiles.defaultColor, createdAtMs: Int64,
                allowAllCalls: Bool = true, allowAllMentions: Bool = false, allowedMembers: Set<String> = [], scheduleEnabled: Bool = false,
                scheduleStartTime: Int? = nil, scheduleEndTime: Int? = nil, scheduleDaysEnabled: [Int: Bool]? = nil, deletedAtTimestampMs: Int64? = nil) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.color = color
        self.createdAtMs = createdAtMs
        self.allowAllCalls = allowAllCalls
        self.allowAllMentions = allowAllMentions
        self.allowedMembers = allowedMembers
        self.scheduleEnabled = scheduleEnabled
        self.scheduleStartTime = scheduleStartTime
        self.scheduleEndTime = scheduleEndTime
        self.scheduleDaysEnabled = scheduleDaysEnabled
        self.deletedAtTimestampMs = deletedAtTimestampMs
    }
}

/// `NotificationProfileOverride`
public enum NotificationProfileOverrideState: Sendable, Hashable {
    case disabled(atMs: Int64)
    case enabled(profileId: String, endsAtMs: Int64?)
}

/// `NextProfileEvent`
public enum NextProfileEvent: Sendable, Hashable {
    case noChange(activeProfile: String?)
    case willDisable(at: Int64, activeProfile: String, clearEnableOverride: Bool)
    case willEnable(at: Int64, toEnable: String, clearDisableOverride: Bool)

    /// The profile in force until the event.
    public var activeProfile: String? {
        switch self {
        case .noChange(let p): p
        case .willDisable(_, let p, _): p
        case .willEnable: nil
        }
    }
}

public enum NotificationProfiles {
    public static let defaultColor: UInt32 = 0xFFE3_E3FE
    static let hour: Int64 = 3_600_000
    static let minute: Int64 = 60_000
    static let day: Int64 = 86_400_000

    /// `shouldNotify`: no active profile, or the profile lets this through.
    public static func shouldNotify(isCall: Bool, isMentionOrReply: Bool, conversationId: String, activeProfile: NotificationProfile?) -> Bool {
        guard let p = activeProfile else { return true }
        if isCall && p.allowAllCalls { return true }
        if isMentionOrReply && p.allowAllMentions { return true }
        return p.allowedMembers.contains(conversationId)
    }

    /// `findNextProfileEvent`
    public static func nextEvent(override: NotificationProfileOverrideState?, profiles: [NotificationProfile], time: Int64,
                                 calendar: Calendar = .current) -> NextProfileEvent {
        let cal = calendar
        if case .enabled(let id, let endsAt)? = override, let endsAt {
            return .willDisable(at: endsAt, activeProfile: id, clearEnableOverride: true)
        }
        if case .enabled(let id, _)? = override {
            guard let profile = profiles.first(where: { $0.id == id }) else { return .noChange(activeProfile: nil) }
            let enabled = isEnabledBySchedule(time: time, timeForSchedule: time - day, profile, cal)
                || isEnabledBySchedule(time: time, timeForSchedule: time, profile, cal)
            if enabled, let disableAt = nextScheduledDisable(profile, time: time, cal) {
                return .willDisable(at: disableAt, activeProfile: id, clearEnableOverride: true)
            }
            guard let nextEnable = nextScheduledEnable(profile, time: time, cal) else { return .noChange(activeProfile: id) }
            guard let nextDisable = nextScheduledDisable(profile, time: nextEnable + 1, cal) else { return .noChange(activeProfile: id) }
            return .willDisable(at: nextDisable, activeProfile: id, clearEnableOverride: true)
        }
        if case .disabled(let at)? = override, at > 0 {
            if let next = nextScheduledEnableForAll(profiles, time: at + 1, cal) {
                return .willEnable(at: next.time, toEnable: next.profile.id, clearDisableOverride: true)
            }
            return .noChange(activeProfile: nil)
        }
        if let active = anyEnabledBySchedule(profiles, time: time, cal), let disabledAt = nextScheduledDisable(active, time: time, cal) {
            // A newer profile's schedule starting earlier takes over.
            let newer = profiles.filter { $0.createdAtMs > active.createdAtMs }
            let preempt = nextScheduledEnableForAll(newer, time: time + 1, cal)
            return .willDisable(at: preempt.map { min($0.time, disabledAt) } ?? disabledAt, activeProfile: active.id, clearEnableOverride: false)
        }
        if let next = nextScheduledEnableForAll(profiles, time: time, cal) {
            return .willEnable(at: next.time, toEnable: next.profile.id, clearDisableOverride: false)
        }
        return .noChange(activeProfile: nil)
    }

    // MARK: schedule helpers

    /// `getDayOfWeek`: Monday = 1 … Sunday = 7.
    public static func dayOfWeek(_ time: Int64, _ cal: Calendar) -> Int {
        let weekday = cal.component(.weekday, from: date(time))          // Sunday = 1
        return weekday == 1 ? 7 : weekday - 1
    }

    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    /// `getMidnight`: local midnight of the day.
    public static func midnight(_ time: Int64, _ cal: Calendar) -> Int64 {
        Int64((cal.startOfDay(for: date(time)).timeIntervalSince1970 * 1000).rounded())
    }

    /// `scheduleToTime`
    public static func scheduleToTime(_ midnight: Int64, _ scheduleTime: Int) -> Int64 {
        midnight + Int64(scheduleTime / 100) * hour + Int64(scheduleTime % 100) * minute
    }

    /// `getEndTime`: an end at or before the start is the next day.
    static func endTime(_ midnight: Int64, start: Int, end: Int) -> Int64 {
        let s = scheduleToTime(midnight, start), e = scheduleToTime(midnight, end)
        return e > s ? e : e + day
    }

    static func isEnabledBySchedule(time: Int64, timeForSchedule: Int64, _ p: NotificationProfile, _ cal: Calendar) -> Bool {
        let d = dayOfWeek(timeForSchedule, cal)
        guard p.scheduleEnabled, p.scheduleDaysEnabled?[d] == true, let start = p.scheduleStartTime, let end = p.scheduleEndTime else { return false }
        let m = midnight(timeForSchedule, cal)
        return time >= scheduleToTime(m, start) && time <= endTime(m, start: start, end: end)
    }

    static func anyEnabledBySchedule(_ profiles: [NotificationProfile], time: Int64, _ cal: Calendar) -> NotificationProfile? {
        profiles.first { isEnabledBySchedule(time: time, timeForSchedule: time - day, $0, cal) || isEnabledBySchedule(time: time, timeForSchedule: time, $0, cal) }
    }

    /// `loopThroughWeek`: yesterday, today and the next six days, each with its start of day.
    static func loopThroughWeek(time: Int64, _ cal: Calendar, _ check: (_ startOfDay: Int64, _ day: Int) -> Bool) {
        let today = midnight(time, cal)
        let startingDay = dayOfWeek(time, cal)
        for index in -1..<7 {
            var d = startingDay + index
            if d <= 0 { d += 7 }
            if d > 7 { d -= 7 }
            if check(today + day * Int64(index), d) { return }
        }
    }

    static func nextScheduledDisable(_ p: NotificationProfile, time: Int64, _ cal: Calendar) -> Int64? {
        guard p.scheduleEnabled else { return nil }
        var result: Int64?
        loopThroughWeek(time: time, cal) { startOfDay, d in
            guard p.scheduleDaysEnabled?[d] == true, let start = p.scheduleStartTime, let end = p.scheduleEndTime else { return false }
            let e = endTime(startOfDay, start: start, end: end)
            if time < e { result = e; return true }
            return false
        }
        return result
    }

    static func nextScheduledEnable(_ p: NotificationProfile, time: Int64, _ cal: Calendar) -> Int64? {
        guard p.scheduleEnabled else { return nil }
        var result: Int64?
        loopThroughWeek(time: time, cal) { startOfDay, d in
            guard p.scheduleDaysEnabled?[d] == true, let start = p.scheduleStartTime, p.scheduleEndTime != nil else { return false }
            let s = scheduleToTime(startOfDay, start)
            if time < s { result = s; return true }
            return false
        }
        return result
    }

    static func nextScheduledEnableForAll(_ profiles: [NotificationProfile], time: Int64, _ cal: Calendar) -> (profile: NotificationProfile, time: Int64)? {
        var earliest: (profile: NotificationProfile, time: Int64)?
        for p in profiles {
            if let t = nextScheduledEnable(p, time: time, cal), earliest.map({ t < $0.time }) ?? true { earliest = (p, t) }
        }
        return earliest
    }

    // MARK: database

    /// Live (not deleted) profiles, newest first (`sortProfiles`).
    public static func all(_ db: Database) throws -> [NotificationProfile] {
        try Row.fetchAll(db, sql: "SELECT * FROM notificationProfiles WHERE deletedAtTimestampMs IS NULL ORDER BY createdAtMs DESC").map { row in
            let members = (try? JSONSerialization.jsonObject(with: Data((row["allowedMembersJson"] as String? ?? "[]").utf8))) as? [String] ?? []
            var days: [Int: Bool]?
            if let json: String = row["scheduleDaysEnabledJson"],
               let d = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Bool] {
                days = Dictionary(uniqueKeysWithValues: d.compactMap { k, v in Int(k).map { ($0, v) } })
            }
            return NotificationProfile(id: row["id"], name: row["name"], emoji: row["emoji"], color: UInt32(truncatingIfNeeded: row["color"] as Int64),
                                       createdAtMs: row["createdAtMs"], allowAllCalls: (row["allowAllCalls"] as Int64) != 0,
                                       allowAllMentions: (row["allowAllMentions"] as Int64) != 0, allowedMembers: Set(members),
                                       scheduleEnabled: (row["scheduleEnabled"] as Int64) != 0, scheduleStartTime: row["scheduleStartTime"],
                                       scheduleEndTime: row["scheduleEndTime"], scheduleDaysEnabled: days)
        }
    }

    /// The manual override (from the primary when profile sync is off).
    public static func override(_ db: Database) throws -> NotificationProfileOverrideState? {
        let syncDisabled = try Items.get(db, "notificationProfileSyncDisabled", as: Bool.self) ?? false
        guard let o = try Items.get(db, syncDisabled ? "notificationProfileOverrideFromPrimary" : "notificationProfileOverride",
                                    as: StorageRecords.NotificationProfileOverride.self) else { return nil }
        if let at = o.disabledAtMs, at > 0 { return .disabled(atMs: at) }
        if let e = o.enabled { return .enabled(profileId: e.profileId, endsAtMs: e.endsAtMs) }
        return nil
    }

    /// The profile in force at `time`.
    public static func active(_ db: Database, time: Int64, calendar: Calendar = .current) throws -> NotificationProfile? {
        let profiles = try all(db)
        let id = nextEvent(override: try override(db), profiles: profiles, time: time, calendar: calendar).activeProfile
        return profiles.first { $0.id == id }
    }
}

/// What the notification-profile menu shows.
public struct NotificationProfilesMenuState: Sendable, Equatable {
    public var profiles: [NotificationProfile]
    public var activeProfileId: String?
    /// The manual override's end, when one is on with an end.
    public var enabledOverrideEndsAt: Int64?

    public init(profiles: [NotificationProfile] = [], activeProfileId: String? = nil, enabledOverrideEndsAt: Int64? = nil) {
        self.profiles = profiles
        self.activeProfileId = activeProfileId
        self.enabledOverrideEndsAt = enabledOverrideEndsAt
    }
}

extension NotificationProfiles {
    public static func menuState(_ db: Database, now: Int64? = nil) throws -> NotificationProfilesMenuState {
        let now = now ?? MessageStore.now()
        var endsAt: Int64?
        if case .enabled(_, let e)? = try override(db) { endsAt = e }
        return NotificationProfilesMenuState(profiles: try all(db), activeProfileId: try active(db, time: now)?.id, enabledOverrideEndsAt: endsAt)
    }
}

extension SignalDatabase {
    public func notificationProfilesUpdates() -> AsyncThrowingStream<NotificationProfilesMenuState, Error> {
        observe { try NotificationProfiles.menuState($0) }
    }
}

extension Messenger {
    /// `setProfileOverride`: a profile on (until `endsAt`, or until turned off), or off now;
    /// synced to our other devices (AccountRecord).
    public func setNotificationProfileOverride(profileId: String, enabled: Bool, endsAt: Int64?) async throws {
        let account = self.account
        try await database.pool.write { db in
            let o = enabled
                ? StorageRecords.NotificationProfileOverride(disabledAtMs: nil, enabled: .init(profileId: profileId, endsAtMs: endsAt))
                : StorageRecords.NotificationProfileOverride(disabledAtMs: MessageStore.now(), enabled: nil)
            try Items.set(db, "notificationProfileOverride", o)
            try StorageWriteBack.accountChanged(db, account: account)
        }
        jobs.poke()
    }
}
