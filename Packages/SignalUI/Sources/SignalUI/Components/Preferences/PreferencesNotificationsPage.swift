// The Notifications page of ts/components/Preferences.dom.tsx: notifications on / content /
// while muted, reactions and reminders, sounds, the app badge, notification profiles, and
// reset (with its confirmation).

import SignalI18n
import SwiftUI

/// The Notifications page's settings (`hasNotifications`, `notificationContent`, …).
public struct NotificationSettings: Sendable, Hashable {
    public var hasNotifications = true
    /// `message` / `name` / `count` (`off` when notifications are off).
    public var notificationContent = "name"
    public var notifyWhileMuted = NotifyWhileMuted.default
    public var hasReactionNotifications = true
    public var hasUnreadReminders = true
    public var isNotificationAttentionSupported = true
    public var hasNotificationAttention = false
    public var hasAudioNotifications = true
    public var hasMessageAudio = true
    /// `unread-messages` / `unread-chats`
    public var unreadCountBadgeType = "unread-messages"
    public var hasCountMutedConversations = false
    public init() {}
}

public struct PreferencesNotificationsPage: View {
    @Binding var settings: NotificationSettings
    let onOpenWhileMuted: () -> Void
    let onOpenNotificationProfiles: () -> Void
    let onResetNotificationSettings: () -> Void
    @State private var confirmReset = false
    @Environment(\.i18n) var i18n

    public init(settings: Binding<NotificationSettings>, onOpenWhileMuted: @escaping () -> Void = {}, onOpenNotificationProfiles: @escaping () -> Void = {},
                onResetNotificationSettings: @escaping () -> Void = {}) {
        _settings = settings
        self.onOpenWhileMuted = onOpenWhileMuted
        self.onOpenNotificationProfiles = onOpenNotificationProfiles
        self.onResetNotificationSettings = onResetNotificationSettings
    }

    public var body: some View {
        let on = settings.hasNotifications
        AxoPanel.Root {
            AxoPanel.Header { AxoPanel.Label(i18n("icu:Preferences__button--notifications")) }
            AxoPanel.Content {
                AxoList.Group {
                    PreferencesList {
                        AxoSwitchItem.Root(label: i18n("icu:Preferences__enable-notifications"), checked: $settings.hasNotifications)
                        // Falls back to the first option while notifications are off.
                        AxoSelectItem.Root(label: i18n("icu:Preferences__Notifications__Show__Label"), disabled: !on, placeholder: i18n("icu:nameAndMessage"),
                                           value: Binding { on ? settings.notificationContent : nil } set: { if let v = $0 { settings.notificationContent = v } },
                                           options: [.init(value: "message", label: i18n("icu:nameAndMessage")), .init(value: "name", label: i18n("icu:nameOnly")),
                                                     .init(value: "count", label: i18n("icu:noNameOrMessage"))])
                        AxoClickableItem.Root(label: i18n("icu:WhileMuted__title"), description: i18n("icu:Preferences__WhileMuted__description"),
                                              value: settings.notifyWhileMuted.summary(i18n), arrow: .next, disabled: !on, onClick: onOpenWhileMuted)
                    }
                    PreferencesList {
                        AxoSwitchItem.Root(label: i18n("icu:Preferences__reaction-notifications-title"),
                                           description: i18n("icu:Preferences__reaction-notifications-description"), disabled: !on,
                                           checked: $settings.hasReactionNotifications)
                        AxoSwitchItem.Root(label: i18n("icu:UnreadReminders__title"), description: i18n("icu:Preferences__UnreadReminders__description"),
                                           disabled: !on, checked: $settings.hasUnreadReminders)
                        if settings.isNotificationAttentionSupported {
                            AxoSwitchItem.Root(label: i18n("icu:notificationDrawAttention"), disabled: !on, checked: $settings.hasNotificationAttention)
                        }
                    }
                    PreferencesList(label: i18n("icu:Preferences__Notifications__SoundsSection__Title")) {
                        AxoSwitchItem.Root(label: i18n("icu:audioNotificationDescription"), disabled: !on, checked: $settings.hasAudioNotifications)
                        AxoSwitchItem.Root(label: i18n("icu:Preferences__message-audio-title"), description: i18n("icu:Preferences__message-audio-description"),
                                           checked: $settings.hasMessageAudio)
                    }
                    PreferencesList(label: i18n("icu:Preferences__Notifications__AppBadgeSection__Title-v2")) {
                        AxoSelectItem.Root(label: i18n("icu:Preferences__Notifications__AppBadgeSection__BadgeCount__Label"),
                                           description: i18n("icu:Preferences__Notifications__AppBadgeSection__BadgeCount__Description"), placeholder: "",
                                           value: Binding { settings.unreadCountBadgeType } set: { if let v = $0 { settings.unreadCountBadgeType = v } },
                                           options: [.init(value: "unread-messages", label: i18n("icu:Preferences__Notifications__AppBadgeSection__BadgeCount__UnreadMessages")),
                                                     .init(value: "unread-chats", label: i18n("icu:Preferences__Notifications__AppBadgeSection__BadgeCount__UnreadChats"))])
                        AxoSwitchItem.Root(label: i18n("icu:Preferences__Notifications__AppBadgeSection__BadgeCount__MutedChats"),
                                           description: i18n("icu:Preferences__Notifications__AppBadgeSection__BadgeCount__MutedChats__description"),
                                           checked: $settings.hasCountMutedConversations)
                    }
                    PreferencesList {
                        AxoClickableItem.Root(label: i18n("icu:NotificationProfiles--setting"), description: i18n("icu:NotificationProfiles--manage-description"),
                                              arrow: .next, onClick: onOpenNotificationProfiles)
                    }
                    PreferencesList {
                        PreferencesItemWithAction(label: i18n("icu:Preferences__Notifications__Reset__title")) {
                            AxoItem.Action(i18n("icu:Preferences__Notifications__Reset__button"), variant: .subtleDestructive) { confirmReset = true }
                        }
                    }
                }
            }
        }
        .viewportPortal {
            if confirmReset {
                AxoBaseDialog.Host {
                    AxoAlertDialog.Content {
                        AxoAlertDialog.Body {
                            AxoAlertDialog.Title(i18n("icu:Preferences__Notifications__Reset__title"), screenReaderOnly: true)
                            AxoAlertDialog.Description(i18n("icu:Preferences__Notifications__Reset__modal--body"))
                        }
                        AxoAlertDialog.Footer {
                            AxoAlertDialog.Cancel(i18n("icu:cancel")) { confirmReset = false }
                            AxoAlertDialog.Action(i18n("icu:Preferences__Notifications__Reset__modal--confirm"), variant: .strongDestructive) {
                                onResetNotificationSettings()
                                confirmReset = false
                            }
                        }
                    }
                }
            }
        }
    }
}

/// `ItemWithAction`: a label (and description) with an action button as the accessory.
struct PreferencesItemWithAction<Action: View>: View {
    let label: String
    var description: String?
    @ViewBuilder let action: Action
    var body: some View {
        AxoItem.Root {
            AxoItem.Content {
                AxoItem.Label(label)
                if let description { AxoItem.Description(description) }
                AxoItem.Accessory { action }
            }
        }
    }
}
