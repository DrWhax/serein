// The Privacy page of ts/components/Preferences.dom.tsx: phone number privacy, blocked,
// receipts and typing, the default disappearing timer (with the custom-time dialog), screen
// security, stories on / off, and the sealed-sender and key-transparency switches.

import AppKit
import SignalI18n
import SwiftUI

public struct PrivacySettings: Sendable, Hashable {
    public var blockedContactCount = 0
    public var blockedGroupCount = 0
    public var hasReadReceipts = true
    public var hasTypingIndicators = true
    /// Seconds.
    public var universalExpireTimer = 3600
    public var isContentProtectionSupported = true
    public var hasContentProtection: Bool? = false
    public var hasStoriesDisabled = false
    public var hasSealedSenderIndicators = true
    public var isKeyTransparencyAvailable = true
    public var hasKeyTransparencyDisabled = false
    public init() {}
}

public struct PreferencesPrivacyPage: View {
    @Binding var settings: PrivacySettings
    let onOpenPNP: () -> Void
    let onOpenBlocked: () -> Void
    @State private var showDisappearingTimerDialog = false
    @State private var confirmContentProtection = false
    @State private var confirmStoriesOff = false
    @Environment(\.i18n) var i18n

    static let keyTransparencyURL = URL(string: "https://support.signal.org/hc/articles/10223569377562")!

    public init(settings: Binding<PrivacySettings>, onOpenPNP: @escaping () -> Void = {}, onOpenBlocked: @escaping () -> Void = {}) {
        _settings = settings
        self.onOpenPNP = onOpenPNP
        self.onOpenBlocked = onOpenBlocked
    }

    var blockedDescription: String {
        let c = settings.blockedContactCount, g = settings.blockedGroupCount
        if (c == 0 && g == 0) || (c > 0 && g > 0) { return i18n("icu:Preferences--blocked-count-both-new", ["num": .number(Double(c + g))]) }
        if c > 0 { return i18n("icu:Preferences--blocked-count-contacts-new", ["num": .number(Double(c))]) }
        return i18n("icu:Preferences--blocked-count-groups-new", ["num": .number(Double(g))])
    }

    var timerOptions: [AxoSelectItem.Option] {
        let t = settings.universalExpireTimer
        let custom = !ExpirationTimer.defaultDurations.contains(t)
        return ExpirationTimer.defaultDurations.map { .init(value: String($0), label: ExpirationTimer.format(i18n, $0, capitalizeOff: true)) }
            + [.init(value: custom ? String(t) : "-1", label: custom ? ExpirationTimer.format(i18n, t) : i18n("icu:selectedCustomDisappearingTimeOption"))]
    }

    public var body: some View {
        AxoPanel.Root {
            AxoPanel.Header { AxoPanel.Label(i18n("icu:Preferences__button--privacy")) }
            AxoPanel.Content {
                AxoList.Group {
                    PreferencesList {
                        AxoClickableItem.Root(label: i18n("icu:Preferences__pnp__row--title"), description: i18n("icu:Preferences__pnp__row--body"),
                                              arrow: .next, onClick: onOpenPNP)
                    }
                    PreferencesList {
                        AxoClickableItem.Root(label: i18n("icu:Preferences--blocked"), description: blockedDescription, arrow: .next, onClick: onOpenBlocked)
                    }
                    PreferencesList(label: i18n("icu:Preferences--messaging"), footerDescription: i18n("icu:Preferences--messaging-help")) {
                        AxoSwitchItem.Root(label: i18n("icu:Preferences--read-receipts"), checked: $settings.hasReadReceipts)
                        AxoSwitchItem.Root(label: i18n("icu:Preferences--typing-indicators"), checked: $settings.hasTypingIndicators)
                    }
                    PreferencesList(label: i18n("icu:disappearingMessages")) {
                        AxoSelectItem.Root(label: i18n("icu:settings__DisappearingMessages__timer__label"),
                                           description: i18n("icu:settings__DisappearingMessages__footer"), placeholder: "",
                                           value: Binding { String(settings.universalExpireTimer) } set: { value in
                                               guard let value else { return }
                                               if value == String(settings.universalExpireTimer) || value == "-1" {
                                                   showDisappearingTimerDialog = true
                                                   return
                                               }
                                               settings.universalExpireTimer = Int(value) ?? settings.universalExpireTimer
                                           }, options: timerOptions)
                    }
                    if settings.isContentProtectionSupported {
                        PreferencesList(label: i18n("icu:Preferences__Privacy__Application")) {
                            AxoSwitchItem.Root(label: i18n("icu:Preferences__content-protection--label"),
                                               description: i18n("icu:Preferences__content-protection--description"),
                                               disabled: settings.hasContentProtection == nil,
                                               checked: Binding { settings.hasContentProtection ?? false } set: { on in
                                                   // Turning screen security off asks first.
                                                   if on { settings.hasContentProtection = true } else { confirmContentProtection = true }
                                               })
                        }
                    }
                    PreferencesList(label: i18n("icu:Stories__title")) {
                        PreferencesItemWithAction(label: i18n("icu:Stories__settings-toggle--title"), description: i18n("icu:Stories__settings-toggle--description")) {
                            if settings.hasStoriesDisabled {
                                AxoItem.Action(i18n("icu:Preferences__turn-stories-on"), variant: .subtleSecondary) { settings.hasStoriesDisabled = false }
                            } else {
                                AxoItem.Action(i18n("icu:Preferences__turn-stories-off"), variant: .subtleDestructive) { confirmStoriesOff = true }
                            }
                        }
                    }
                    PreferencesList(label: i18n("icu:Preferences--advanced")) {
                        AxoSwitchItem.Root(label: i18n("icu:Preferences__PrivacyPage__ShowStatusIcon__Label"),
                                           description: i18n("icu:Preferences__PrivacyPage__ShowStatusIcon__Description"), checked: $settings.hasSealedSenderIndicators)
                            .labelSuffix(SignalIcon("v2/unidentified-delivery-solid-20", size: 18, color: .labelSecondary, mask: true)
                                .padding(.leading, 3).offset(y: 2))
                        if settings.isKeyTransparencyAvailable {
                            let link = "kt-learn-more"
                            AxoSwitchItem.Root(label: i18n("icu:Preferences__PrivacyPage__KeyTransparency__Label"),
                                               checked: Binding { !settings.hasKeyTransparencyDisabled } set: { settings.hasKeyTransparencyDisabled = !$0 })
                                .descriptionRuns([CSSTextRun(i18n("icu:Preferences__PrivacyPage__KeyTransparency__Description") + "\u{00A0}"),
                                                  CSSTextRun(i18n("icu:Preferences__PrivacyPage__KeyTransparency__LearnMore"), color: .labelPrimary, action: link)]) {
                                    if $0 == link { NSWorkspace.shared.open(Self.keyTransparencyURL) }
                                }
                        }
                    }
                }
            }
        }
        .viewportPortal {
            if showDisappearingTimerDialog {
                AxoBaseDialog.Host {
                    DisappearingTimeDialog(initialValue: settings.universalExpireTimer, onSubmit: { settings.universalExpireTimer = $0 },
                                           onClose: { showDisappearingTimerDialog = false })
                }
            } else if confirmContentProtection {
                AxoBaseDialog.Host {
                    AxoConfirmDialog.Root(title: i18n("icu:Preferences__content-protection__modal--title"),
                                          description: i18n("icu:Preferences__content-protection__modal--body")) {
                        AxoConfirmDialog.Cancel(i18n("icu:cancel")) { confirmContentProtection = false }
                        AxoConfirmDialog.Action(i18n("icu:Preferences__content-protection__modal--disable"), variant: .strongDestructive) {
                            settings.hasContentProtection = false
                            confirmContentProtection = false
                        }
                    }
                }
            } else if confirmStoriesOff {
                AxoBaseDialog.Host {
                    AxoConfirmDialog.Root(title: nil, description: i18n("icu:Preferences__turn-stories-off--body")) {
                        AxoConfirmDialog.Cancel(i18n("icu:cancel")) { confirmStoriesOff = false }
                        AxoConfirmDialog.Action(i18n("icu:Preferences__turn-stories-off--action"), variant: .strongDestructive) {
                            settings.hasStoriesDisabled = true
                            confirmStoriesOff = false
                        }
                    }
                }
            }
        }
    }
}
