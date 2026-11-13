// Ports of ts/components/conversation/conversation-details/ConversationNotificationsSettings.dom.tsx
// and WhileMutedSettings.dom.tsx, with the helpers they use (ts/util/getMutedUntilText.std.ts,
// ts/util/notifyWhileMuted.std.ts, getConversationMuteMenu). Both are AxoList panels of AxoItem
// rows: mute (Mute menu / Unmute), "While muted" (summary + arrow), unread reminders (switch);
// and the calls / mentions / replies switches.

import SignalI18n
import SwiftUI

/// `MuteExpiration`: a timestamp in ms; `always` is Number.MAX_SAFE_INTEGER.
public enum MuteExpirationTime {
    public static let always: Double = 9_007_199_254_740_991
    public static func isAlways(_ ms: Double) -> Bool { ms >= always }
    /// `isConversationMuted`
    public static func isMuted(_ ms: Double?, now: Date) -> Bool { (ms ?? 0) > now.timeIntervalSince1970 * 1000 }

    /// `getMutedUntilText`: "Muted until 6:09 PM" today, else with the date (moment `L, LT`).
    @MainActor public static func mutedUntilText(_ ms: Double, now: Date, i18n: Localizer, timeZone: TimeZone) -> String {
        if isAlways(ms) { return i18n("icu:muteExpirationLabelAlways") }
        let date = Date(timeIntervalSince1970: ms / 1000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let locale = Locale(identifier: i18n.locale)
        func format(_ template: String) -> String {
            let f = DateFormatter()
            f.locale = locale
            f.timeZone = timeZone
            f.calendar = calendar
            f.dateFormat = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale)
            return f.string(from: date)
        }
        let time = format("jmm")
        let text = calendar.isDate(date, inSameDayAs: now) ? time : "\(format("MMddyyyy")), \(time)"
        return i18n("icu:muteExpirationLabel", ["duration": .string(text)])
    }
}

/// `NotifyWhileMuted`
public struct NotifyWhileMuted: Sendable, Hashable {
    public var calls: Bool
    public var mentions: Bool
    public var replies: Bool
    public init(calls: Bool, mentions: Bool, replies: Bool) {
        self.calls = calls
        self.mentions = mentions
        self.replies = replies
    }
    /// `DEFAULT_NOTIFY_IF_MUTED`
    public static let `default` = NotifyWhileMuted(calls: false, mentions: true, replies: true)

    public enum Key: Sendable { case calls, mentions, replies }

    /// `getNotifyWhileMutedSummary`
    @MainActor public func summary(_ i18n: Localizer) -> String {
        switch (calls, mentions, replies) {
        case (true, true, true): return i18n("icu:WhileMuted__value--calls-mentions-replies")
        case (true, true, false): return i18n("icu:WhileMuted__value--calls-mentions")
        case (true, false, true): return i18n("icu:WhileMuted__value--calls-replies")
        case (false, true, true): return i18n("icu:WhileMuted__value--mentions-replies")
        case (true, false, false): return i18n("icu:WhileMuted__value--calls")
        case (false, true, false): return i18n("icu:WhileMuted__value--mentions")
        case (false, false, true): return i18n("icu:WhileMuted__value--replies")
        case (false, false, false): return i18n("icu:WhileMuted__value--none")
        }
    }
}

public struct ConversationNotificationsSettings: View {
    let isGroup: Bool
    let muteExpiresAt: Double?
    let notifyWhileMuted: NotifyWhileMuted
    let onOpenWhileMutedSettings: () -> Void
    /// nil = unmute.
    let setMuteExpiration: (MuteOption?) -> Void
    let setShowUnreadReminders: (Bool) -> Void
    let showUnreadReminders: Bool
    @State private var muteMenuOpen = false
    @Environment(\.i18n) var i18n
    @Environment(\.conversationListNow) var fixedNow
    @Environment(\.timeZone) var timeZone

    public init(isGroup: Bool, muteExpiresAt: Double?, notifyWhileMuted: NotifyWhileMuted, showUnreadReminders: Bool,
                onOpenWhileMutedSettings: @escaping () -> Void = {}, setMuteExpiration: @escaping (MuteOption?) -> Void = { _ in },
                setShowUnreadReminders: @escaping (Bool) -> Void = { _ in }) {
        self.isGroup = isGroup
        self.muteExpiresAt = muteExpiresAt
        self.notifyWhileMuted = notifyWhileMuted
        self.showUnreadReminders = showUnreadReminders
        self.onOpenWhileMutedSettings = onOpenWhileMutedSettings
        self.setMuteExpiration = setMuteExpiration
        self.setShowUnreadReminders = setShowUnreadReminders
    }

    public var body: some View {
        let now = fixedNow ?? .now
        let mutedUntilText = muteExpiresAt.flatMap {
            MuteExpirationTime.isMuted($0, now: now) ? MuteExpirationTime.mutedUntilText($0, now: now, i18n: i18n, timeZone: timeZone) : nil
        }
        // Mentions and replies only apply to groups.
        let summarized = isGroup ? notifyWhileMuted : NotifyWhileMuted(calls: notifyWhileMuted.calls, mentions: false, replies: false)
        let unreadRemindersLabel = i18n("icu:UnreadReminders__title")
        AxoContainer.Root {
            AxoList.Group {
                AxoList.Root(accessibilityLabel: i18n("icu:ConversationDetails--notifications")) {
                    AxoList.Body {
                        AxoItem.Group {
                            AxoItem.Root {
                                AxoItem.Leading { AxoItem.Icon(symbol: "bell-slash") }
                                AxoItem.Content {
                                    AxoItem.Label(i18n("icu:muteNotificationsTitle"))
                                    AxoItem.Description(mutedUntilText ?? i18n("icu:notMuted"))
                                    AxoItem.Accessory {
                                        if mutedUntilText != nil {
                                            AxoItem.Action(i18n("icu:unmute"), variant: .subtleSecondary) { setMuteExpiration(nil) }
                                        } else {
                                            AxoDropdownMenu.Root(isOpen: $muteMenuOpen) {
                                                AxoItem.Action(i18n("icu:mute"), variant: .subtleSecondary) {}
                                            } items: {
                                                AxoDropdownMenu.Label(i18n("icu:MuteMenu__label"))
                                                ForEach(MuteOption.values(i18n), id: \.1) { name, option in
                                                    AxoDropdownMenu.Item(name) { setMuteExpiration(option) }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            AxoItem.Root {
                                AxoItem.Leading { AxoItem.Icon(symbol: "bell-badge") }
                                AxoItem.Content {
                                    AxoItem.Label(i18n("icu:WhileMuted__title"))
                                    AxoItem.Value(summarized.summary(i18n))
                                    AxoItem.Description(i18n("icu:WhileMuted__description"))
                                    AxoItem.HiddenTrigger(label: i18n("icu:WhileMuted__title"), action: onOpenWhileMutedSettings)
                                    AxoItem.Trailing { AxoItem.Arrow() }
                                }
                            }
                        }
                    }
                }
                AxoList.Root(accessibilityLabel: unreadRemindersLabel) {
                    AxoList.Body {
                        AxoItem.Group {
                            AxoItem.Root {
                                AxoItem.Leading { AxoItem.Icon(symbol: "arrow-clockwise") }
                                AxoItem.Content {
                                    AxoItem.Label(unreadRemindersLabel)
                                    AxoItem.Description(i18n("icu:UnreadReminders__description"))
                                    AxoItem.Accessory {
                                        AxoSwitch.Root(checked: Binding(get: { showUnreadReminders }, set: { setShowUnreadReminders($0) }),
                                                       label: unreadRemindersLabel)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

public struct WhileMutedSettings: View {
    let isGroup: Bool
    let notifyWhileMuted: NotifyWhileMuted
    let setNotifyWhileMuted: (NotifyWhileMuted.Key, Bool) -> Void
    @Environment(\.i18n) var i18n

    public init(isGroup: Bool, notifyWhileMuted: NotifyWhileMuted, setNotifyWhileMuted: @escaping (NotifyWhileMuted.Key, Bool) -> Void = { _, _ in }) {
        self.isGroup = isGroup
        self.notifyWhileMuted = notifyWhileMuted
        self.setNotifyWhileMuted = setNotifyWhileMuted
    }

    func row(_ key: NotifyWhileMuted.Key, _ symbol: AxoSymbol.Name, _ name: String, checked: Bool) -> some View {
        let label = i18n("icu:WhileMuted__\(name)__title")
        return AxoItem.Root {
            AxoItem.Icon(symbol: symbol)
            AxoItem.Content {
                AxoItem.Label(label)
                AxoItem.Description(i18n("icu:WhileMuted__\(name)__description"))
                AxoItem.Accessory {
                    AxoSwitch.Root(checked: Binding(get: { checked }, set: { setNotifyWhileMuted(key, $0) }), label: label)
                }
            }
        }
    }

    public var body: some View {
        AxoContainer.Root {
            AxoList.Group {
                AxoList.Root(accessibilityLabel: i18n("icu:WhileMuted__title")) {
                    AxoList.Body {
                        AxoItem.Group {
                            row(.calls, "phone", "calls", checked: notifyWhileMuted.calls)
                            if isGroup {
                                row(.mentions, "at", "mentions", checked: notifyWhileMuted.mentions)
                                row(.replies, "reply", "replies", checked: notifyWhileMuted.replies)
                            }
                        }
                    }
                }
            }
        }
    }
}
