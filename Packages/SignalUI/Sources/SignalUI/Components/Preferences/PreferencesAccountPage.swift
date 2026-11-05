// The Account page of ts/components/Preferences.dom.tsx: on a linked device, the linked-device
// row (opening LinkedDevicesOnboardingDialog); without a phone number, the Signal login
// (account keys) list.

import AppKit
import SignalI18n
import SwiftUI

public struct PreferencesAccountPage: View {
    let weArePrimaryDevice: Bool
    let hasPhoneNumber: Bool
    let onOpenLinkedDevicesOnboarding: () -> Void
    let onOpenAccountKeys: () -> Void
    /// `promptOSAuth('view-aep')` before the keys are shown.
    let promptOSAuth: () async -> PromptOSAuthResult
    /// Upstream focuses the pane's first control when the page opens.
    @State private var firstFocused = true
    @State private var linkedDevicesOnboarding = false
    @Environment(\.i18n) var i18n

    static let restoreAccountURL = URL(string: "https://support.signal.org/hc/articles/11197884108826/")!

    public init(weArePrimaryDevice: Bool = false, hasPhoneNumber: Bool = true, onOpenLinkedDevicesOnboarding: @escaping () -> Void = {},
                onOpenAccountKeys: @escaping () -> Void = {}, promptOSAuth: @escaping () async -> PromptOSAuthResult = { .unsupported }) {
        self.promptOSAuth = promptOSAuth
        self.weArePrimaryDevice = weArePrimaryDevice
        self.hasPhoneNumber = hasPhoneNumber
        self.onOpenLinkedDevicesOnboarding = onOpenLinkedDevicesOnboarding
        self.onOpenAccountKeys = onOpenAccountKeys
    }

    public var body: some View {
        PreferencesContent(title: i18n("icu:Preferences__button--account")) {
            AxoList.Group {
                if !weArePrimaryDevice {
                    PreferencesList {
                        AxoClickableItem.Root(symbol: "device-laptop", label: i18n("icu:Preferences__Account__LinkedDevice__label"),
                                              description: i18n("icu:Preferences__Account__LinkedDevice__description"), arrow: .next) {
                            firstFocused = false
                            linkedDevicesOnboarding = true
                            onOpenLinkedDevicesOnboarding()
                        }
                        .environment(\.axoItemFocusVisible, firstFocused)
                    }
                }
                if !hasPhoneNumber {
                    AxoList.Root {
                        AxoList.Header { AxoList.Label(i18n("icu:Preferences--signal-login")) }
                        AxoList.Body {
                            AxoItem.Group {
                                SignalAccountKeysButton(promptOSAuth: promptOSAuth, onClick: onOpenAccountKeys)
                            }
                        }
                        AxoList.Footer {
                            CSSText(runs: CSSTextRun.runs(i18n.richText("icu:Preferences--signal-login-description"),
                                                          tags: ["learnMoreLink": I18nTagStyle(color: .labelPrimary, action: "learn-more")]),
                                    style: CSSTextStyle(AxoType.bodySmall), color: .labelSecondary) { _ in NSWorkspace.shared.open(Self.restoreAccountURL) }
                        }
                    }
                }
            }
        }
        .viewportPortal {
            if linkedDevicesOnboarding {
                AxoBaseDialog.Host { LinkedDevicesOnboardingDialog { linkedDevicesOnboarding = false } }
            }
        }
    }
}
