// ts/components/conversation/conversation-details/ConversationNotificationsSettings.dom.stories.tsx
// and WhileMutedSettings.dom.stories.tsx. The stories run in London; "Muted" ends at
// Date.UTC(2099, 5, 9).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct ConversationNotificationsSettingsTests {
    static func settings(isGroup: Bool = true, muteExpiresAt: Double? = nil, notify: NotifyWhileMuted = .default,
                         reminders: Bool = true) -> some View {
        ConversationNotificationsSettings(isGroup: isGroup, muteExpiresAt: muteExpiresAt, notifyWhileMuted: notify, showUnreadReminders: reminders)
            .frame(width: 1168)
            .environment(\.conversationListNow, Date(timeIntervalSince1970: 1_793_793_600))
            .environment(\.timeZone, TimeZone(identifier: "Europe/London")!)
    }

    static let stories: [(String, AnyView)] = [
        ("not-muted", AnyView(settings())),
        ("muted", AnyView(settings(muteExpiresAt: 4_084_646_400_000))),
        ("muted-always", AnyView(settings(muteExpiresAt: MuteExpirationTime.always))),
        ("nothing-while-muted", AnyView(settings(notify: NotifyWhileMuted(calls: false, mentions: false, replies: false)))),
        ("everything-while-muted", AnyView(settings(notify: NotifyWhileMuted(calls: true, mentions: true, replies: true)))),
        ("unread-reminders-off", AnyView(settings(reminders: false))),
        ("direct-conversation", AnyView(settings(isGroup: false, notify: NotifyWhileMuted(calls: true, mentions: true, replies: true)))),
    ]

    @Test(arguments: ["light", "dark"], 0..<7)
    func story(theme: String, index: Int) throws {
        let (name, view) = Self.stories[index]
        try Snapshot.assertMatches(view, story: "components-conversation-conversationdetails-conversationnotificationssettings--\(name)", theme: theme)
    }
}

@MainActor
@Suite struct WhileMutedSettingsTests {
    static let stories: [(String, Bool, NotifyWhileMuted)] = [
        ("defaults", true, .default),
        ("direct-conversation", false, .default),
        ("all-on", true, NotifyWhileMuted(calls: true, mentions: true, replies: true)),
        ("all-off", true, NotifyWhileMuted(calls: false, mentions: false, replies: false)),
    ]

    @Test(arguments: ["light", "dark"], 0..<4)
    func story(theme: String, index: Int) throws {
        let (name, isGroup, notify) = Self.stories[index]
        try Snapshot.assertMatches(WhileMutedSettings(isGroup: isGroup, notifyWhileMuted: notify).frame(width: 1168),
                                   story: "components-conversation-conversationdetails-whilemutedsettings--\(name)", theme: theme)
    }
}
