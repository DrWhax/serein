// The phone number privacy page of ts/components/Preferences.dom.tsx: who can see my number
// and who can find me by it (with the not-discoverable confirmation).

import SignalI18n
import SwiftUI

public enum PhoneNumberSharingMode: String, Sendable { case everybody = "Everybody", nobody = "Nobody" }
public enum PhoneNumberDiscoverability: String, Sendable { case discoverable = "Discoverable", notDiscoverable = "NotDiscoverable" }

public struct PreferencesPNPPage: View {
    @Binding var whoCanSeeMe: PhoneNumberSharingMode
    @Binding var whoCanFindMe: PhoneNumberDiscoverability
    let onBack: () -> Void
    /// `ToastType.WhoCanFindMeReadOnly`
    let showReadOnlyToast: () -> Void
    @State private var confirmNotDiscoverable = false
    @Environment(\.i18n) var i18n

    public init(whoCanSeeMe: Binding<PhoneNumberSharingMode>, whoCanFindMe: Binding<PhoneNumberDiscoverability>, onBack: @escaping () -> Void = {},
                showReadOnlyToast: @escaping () -> Void = {}) {
        _whoCanSeeMe = whoCanSeeMe
        _whoCanFindMe = whoCanFindMe
        self.onBack = onBack
        self.showReadOnlyToast = showReadOnlyToast
    }

    var sharingDescription: String {
        if whoCanSeeMe == .everybody { return i18n("icu:Preferences__pnp__sharing--description--everyone") }
        if whoCanFindMe == .discoverable { return i18n("icu:Preferences__pnp__sharing--description--nobody") }
        return i18n("icu:Preferences__pnp__sharing--description--nobody--not-discoverable")
    }

    public var body: some View {
        let everybody = whoCanSeeMe == .everybody
        PreferencesContent(title: i18n("icu:Preferences__pnp--page-title"),
                           backButton: AnyView(PreferencesBackButton(label: i18n("icu:goBack"), action: onBack))) {
            SettingsRow(title: i18n("icu:Preferences__pnp__sharing--title"), minHeight: 185) {
                SettingsRadio(value: whoCanSeeMe, options: [.init(text: i18n("icu:Preferences__pnp__sharing__everyone"), value: .everybody),
                                                            .init(text: i18n("icu:Preferences__pnp__sharing__nobody"), value: .nobody)]) { whoCanSeeMe = $0 }
                PreferencesDescription(text: sharingDescription)
            }
            SettingsRow(title: i18n("icu:Preferences__pnp__discoverability--title"), isLast: true) {
                SettingsRadio(value: whoCanFindMe, options: [
                    .init(text: i18n("icu:Preferences__pnp__discoverability__everyone"), value: .discoverable),
                    .init(text: i18n("icu:Preferences__pnp__discoverability__nobody"), value: .notDiscoverable, readOnly: everybody,
                          onClick: everybody ? showReadOnlyToast : nil),
                ]) { value in
                    if value == .notDiscoverable { confirmNotDiscoverable = true } else { whoCanFindMe = value }
                }
                PreferencesDescription(text: i18n(whoCanFindMe == .discoverable ? "icu:Preferences__pnp__discoverability--description--everyone"
                                                  : "icu:Preferences__pnp__discoverability--description--nobody"))
            }
        }
        .viewportPortal {
            if confirmNotDiscoverable {
                AxoBaseDialog.Host {
                    AxoConfirmDialog.Root(title: i18n("icu:Preferences__pnp__discoverability__nobody__confirmModal__title"),
                                          description: i18n("icu:Preferences__pnp__discoverability__nobody__confirmModal__description", [
                                              "settingTitle": .string(i18n("icu:Preferences__pnp__discoverability--title")),
                                              "nobodyLabel": .string(i18n("icu:Preferences__pnp__discoverability__nobody")),
                                          ])) {
                        AxoConfirmDialog.Cancel(i18n("icu:cancel")) { confirmNotDiscoverable = false }
                        AxoConfirmDialog.Action(i18n("icu:ok"), variant: .strongPrimary) {
                            whoCanFindMe = .notDiscoverable
                            confirmNotDiscoverable = false
                        }
                    }
                }
            }
        }
    }
}
