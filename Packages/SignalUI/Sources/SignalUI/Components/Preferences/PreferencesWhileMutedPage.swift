// The While muted page of ts/components/Preferences.dom.tsx: notify for calls, mentions and
// replies in muted chats.

import SignalI18n
import SwiftUI

public struct PreferencesWhileMutedPage: View {
    @Binding var notifyWhileMuted: NotifyWhileMuted
    let onBack: () -> Void
    @Environment(\.i18n) var i18n

    public init(notifyWhileMuted: Binding<NotifyWhileMuted>, onBack: @escaping () -> Void = {}) {
        _notifyWhileMuted = notifyWhileMuted
        self.onBack = onBack
    }

    public var body: some View {
        AxoPanel.Root {
            AxoPanel.Header {
                AxoPanel.Back(onClick: onBack)
                AxoPanel.Label(i18n("icu:WhileMuted__title"))
            }
            AxoPanel.Content {
                AxoList.Group {
                    PreferencesList {
                        AxoSwitchItem.Root(symbol: "phone", label: i18n("icu:WhileMuted__calls__title"),
                                           description: i18n("icu:Preferences__WhileMuted__calls__description"), checked: $notifyWhileMuted.calls)
                        AxoSwitchItem.Root(symbol: "at", label: i18n("icu:WhileMuted__mentions__title"),
                                           description: i18n("icu:Preferences__WhileMuted__mentions__description"), checked: $notifyWhileMuted.mentions)
                        AxoSwitchItem.Root(symbol: "reply", label: i18n("icu:WhileMuted__replies__title"),
                                           description: i18n("icu:Preferences__WhileMuted__replies__description"), checked: $notifyWhileMuted.replies)
                    }
                }
            }
        }
    }
}
