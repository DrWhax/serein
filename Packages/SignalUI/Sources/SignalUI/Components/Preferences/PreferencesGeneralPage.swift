// The General page of ts/components/Preferences.dom.tsx for a linked device: number and
// device name, system (launch at login, menu bar, tray), permissions, updates, and clear
// data (with its confirmation). The primary-device rows (PIN, registration lock, delete
// account) are not shown: this app only links.

import SignalI18n
import SwiftUI

public struct GeneralSettings: Sendable, Hashable {
    public var phoneNumber: String?
    public var deviceName = ""
    public var isAutoLaunchSupported = true
    public var hasAutoLaunch: Bool? = true
    public var isHideMenuBarSupported = false
    public var hasHideMenuBar: Bool? = false
    public var isSystemTraySupported = false
    public var hasMinimizeToSystemTray: Bool? = false
    public var isMinimizeToAndStartInSystemTraySupported = false
    public var hasMinimizeToAndStartInSystemTray: Bool? = false
    public var hasMediaPermissions: Bool? = true
    public var hasMediaCameraPermissions: Bool? = true
    public var isAutoDownloadUpdatesSupported = true
    public var hasAutoDownloadUpdate = true
    public init() {}
}

public struct PreferencesGeneralPage: View {
    @Binding var settings: GeneralSettings
    let doDeleteAllData: () -> Void
    @State private var confirmDelete = false
    @Environment(\.i18n) var i18n

    public init(settings: Binding<GeneralSettings>, doDeleteAllData: @escaping () -> Void = {}) {
        _settings = settings
        self.doDeleteAllData = doDeleteAllData
    }

    func optional(_ keyPath: WritableKeyPath<GeneralSettings, Bool?>) -> Binding<Bool> {
        Binding { settings[keyPath: keyPath] ?? false } set: { settings[keyPath: keyPath] = $0 }
    }

    public var body: some View {
        let s = settings
        AxoPanel.Root {
            AxoPanel.Header { AxoPanel.Label(i18n("icu:Preferences__button--general")) }
            AxoPanel.Content {
                AxoList.Group {
                    PreferencesList(footerDescription: i18n("icu:Preferences--device-name__description")) {
                        if let phone = s.phoneNumber { AxoTextItem.Root(label: i18n("icu:Preferences--phone-number"), value: phone) }
                        AxoTextItem.Root(label: i18n("icu:Preferences--device-name"), value: s.deviceName)
                    }
                    PreferencesList(label: i18n("icu:Preferences--system")) {
                        if s.isAutoLaunchSupported {
                            AxoSwitchItem.Root(label: i18n("icu:autoLaunchDescription"), disabled: s.hasAutoLaunch == nil, checked: optional(\.hasAutoLaunch))
                        }
                        if s.isHideMenuBarSupported {
                            AxoSwitchItem.Root(label: i18n("icu:hideMenuBar"), checked: optional(\.hasHideMenuBar))
                        }
                        if s.isSystemTraySupported {
                            AxoSwitchItem.Root(label: i18n("icu:SystemTraySetting__minimize-to-system-tray"), disabled: s.hasMinimizeToSystemTray == nil,
                                               checked: optional(\.hasMinimizeToSystemTray))
                            if s.isMinimizeToAndStartInSystemTraySupported {
                                AxoSwitchItem.Root(label: i18n("icu:SystemTraySetting__minimize-to-and-start-in-system-tray"),
                                                   disabled: !(s.hasMinimizeToSystemTray ?? false) || s.hasMinimizeToAndStartInSystemTray == nil,
                                                   checked: optional(\.hasMinimizeToAndStartInSystemTray))
                            }
                        }
                    }
                    PreferencesList(label: i18n("icu:permissions")) {
                        AxoSwitchItem.Root(label: i18n("icu:mediaPermissionsDescription"), disabled: s.hasMediaPermissions == nil, checked: optional(\.hasMediaPermissions))
                        AxoSwitchItem.Root(label: i18n("icu:mediaCameraPermissionsDescription"), disabled: s.hasMediaCameraPermissions == nil,
                                           checked: optional(\.hasMediaCameraPermissions))
                    }
                    if s.isAutoDownloadUpdatesSupported {
                        PreferencesList(label: i18n("icu:Preferences--updates")) {
                            AxoSwitchItem.Root(label: i18n("icu:Preferences__download-update"), checked: $settings.hasAutoDownloadUpdate)
                        }
                    }
                    PreferencesList {
                        PreferencesItemWithAction(label: i18n("icu:clearDataHeader"), description: i18n("icu:clearDataExplanation")) {
                            AxoItem.Action(i18n("icu:clearDataButton"), variant: .subtleDestructive) { confirmDelete = true }
                        }
                    }
                }
            }
        }
        .viewportPortal {
            if confirmDelete {
                AxoBaseDialog.Host {
                    AxoConfirmDialog.Root(title: i18n("icu:deleteAllDataHeader"), description: i18n("icu:deleteAllDataBody")) {
                        AxoConfirmDialog.Cancel(i18n("icu:cancel")) { confirmDelete = false }
                        AxoConfirmDialog.Action(i18n("icu:clearDataButton"), variant: .strongDestructive) {
                            confirmDelete = false
                            doDeleteAllData()
                        }
                    }
                }
            }
        }
    }
}
