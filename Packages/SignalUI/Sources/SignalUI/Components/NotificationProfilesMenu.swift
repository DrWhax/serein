// Port of ts/components/NotificationProfilesMenu.dom.tsx: the dropdown items for notification
// profiles — a header (on / on until …), each profile (ProfileAvatar small + name; the active
// one offers "for 1 hour" and "until <time>"), and Notification profile settings.

import SignalI18n
import SwiftUI

/// The parts of `NotificationProfileType` the menu shows.
public struct NotificationProfileSummary: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var emoji: String?
    /// ARGB
    public var color: UInt32
    public init(id: String, name: String, emoji: String? = nil, color: UInt32) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.color = color
    }
}

public struct NotificationProfilesMenu: View {
    let activeProfileId: String?
    let allProfiles: [NotificationProfileSummary]
    /// `currentOverride.enabled.endsAtMs`
    let enabledOverrideEndsAt: Date?
    let now: Date
    let onGoToSettings: () -> Void
    /// (id, enabled, endsAt)
    let setProfileOverride: (String, Bool, Date?) -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.timeZone) var zone

    public init(activeProfileId: String?, allProfiles: [NotificationProfileSummary], enabledOverrideEndsAt: Date? = nil, now: Date = Date(),
                onGoToSettings: @escaping () -> Void = {}, setProfileOverride: @escaping (String, Bool, Date?) -> Void = { _, _, _ in }) {
        self.activeProfileId = activeProfileId
        self.allProfiles = allProfiles
        self.enabledOverrideEndsAt = enabledOverrideEndsAt
        self.now = now
        self.onGoToSettings = onGoToSettings
        self.setProfileOverride = setProfileOverride
    }

    func short(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: i18n.locale)
        f.timeZone = zone
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// 6 PM today, or 8 AM today before then, or 8 AM tomorrow after 6 PM.
    var targetTime: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let midnight = cal.startOfDay(for: now)
        let eightAm = midnight.addingTimeInterval(8 * 3600), sixPm = midnight.addingTimeInterval(18 * 3600)
        if now < eightAm { return eightAm }
        if now > sixPm { return (cal.date(byAdding: .day, value: 1, to: midnight) ?? midnight).addingTimeInterval(8 * 3600) }
        return sixPm
    }

    public var body: some View {
        let label: String? = activeProfileId == nil ? nil : enabledOverrideEndsAt.map {
            i18n("icu:NotificationProfileMenu--on-with-end", ["endTime": .string(short($0))])
        } ?? i18n("icu:NotificationProfileMenu--on")
        AxoDropdownMenu.Header(label: i18n("icu:NotificationProfileMenu--header"), description: label)
        if !allProfiles.isEmpty { AxoDropdownMenu.Separator() }
        ForEach(Array(allProfiles.enumerated()), id: \.element.id) { index, profile in
            let isActive = profile.id == activeProfileId
            if index > 0 { AxoDropdownMenu.ContentSeparator() }
            AxoDropdownMenu.CustomItem(profile.name, leadingWidth: 20, keepsOpen: true, action: { setProfileOverride(profile.id, !isActive, nil) }) {
                NotificationProfileAvatar(emoji: profile.emoji, color: profile.color, isActive: isActive, size: .small)
            }
            if isActive {
                AxoDropdownMenu.Item(i18n("icu:NotificationProfileMenu--for-one-hour")) {
                    setProfileOverride(profile.id, true, Date().addingTimeInterval(3600))
                }
                AxoDropdownMenu.Item(i18n("icu:NotificationProfileMenu--until-time", ["time": .string(short(targetTime))])) {
                    setProfileOverride(profile.id, true, targetTime)
                }
            }
        }
        AxoDropdownMenu.Separator()
        AxoDropdownMenu.Item(i18n("icu:NotificationProfileMenu--settings"), symbol: "settings", action: onGoToSettings)
    }
}
