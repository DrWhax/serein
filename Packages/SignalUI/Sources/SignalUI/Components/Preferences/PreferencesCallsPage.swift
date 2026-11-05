// The Calls and Data usage pages of ts/components/Preferences.dom.tsx.

import SignalI18n
import SwiftUI

public struct PreferencesCallsPage: View {
    @Binding var hasIncomingCallNotifications: Bool
    @Binding var hasCallRingtoneNotification: Bool
    @Binding var hasRelayCalls: Bool
    let devices: CallingDeviceSelectionItems
    @Environment(\.i18n) var i18n

    public init(hasIncomingCallNotifications: Binding<Bool>, hasCallRingtoneNotification: Binding<Bool>, hasRelayCalls: Binding<Bool>,
                devices: CallingDeviceSelectionItems) {
        _hasIncomingCallNotifications = hasIncomingCallNotifications
        _hasCallRingtoneNotification = hasCallRingtoneNotification
        _hasRelayCalls = hasRelayCalls
        self.devices = devices
    }

    public var body: some View {
        AxoPanel.Root {
            AxoPanel.Header { AxoPanel.Label(i18n("icu:Preferences__button--calls")) }
            AxoPanel.Content {
                AxoList.Group {
                    PreferencesList(accessibilityLabel: i18n("icu:calling")) {
                        AxoSwitchItem.Root(label: i18n("icu:incomingCallNotificationDescription"), checked: $hasIncomingCallNotifications)
                        AxoSwitchItem.Root(label: i18n("icu:callRingtoneNotificationDescription"), checked: $hasCallRingtoneNotification)
                    }
                    PreferencesList(label: i18n("icu:Preferences__devices")) { devices }
                    PreferencesList(label: i18n("icu:Preferences--advanced")) {
                        AxoSwitchItem.Root(label: i18n("icu:alwaysRelayCallsDescription"), description: i18n("icu:alwaysRelayCallsDetail"), checked: $hasRelayCalls)
                    }
                }
            }
        }
    }
}

/// `autoDownloadAttachment`
public struct AutoDownloadAttachment: Sendable, Hashable {
    public var photos, videos, audio, documents: Bool
    public init(photos: Bool = true, videos: Bool = false, audio: Bool = false, documents: Bool = false) {
        self.photos = photos
        self.videos = videos
        self.audio = audio
        self.documents = documents
    }
}

public struct PreferencesDataUsagePage: View {
    @Binding var autoDownload: AutoDownloadAttachment
    @Binding var sentMediaQuality: String?
    @Environment(\.i18n) var i18n

    public init(autoDownload: Binding<AutoDownloadAttachment>, sentMediaQuality: Binding<String?>) {
        _autoDownload = autoDownload
        _sentMediaQuality = sentMediaQuality
    }

    public var body: some View {
        AxoPanel.Root {
            AxoPanel.Header { AxoPanel.Label(i18n("icu:Preferences__button--data-usage")) }
            AxoPanel.Content {
                AxoList.Group {
                    PreferencesList(label: i18n("icu:Preferences__media-auto-download"),
                                    footerDescription: i18n("icu:Preferences__media-auto-download__description")) {
                        AxoSwitchItem.Root(label: i18n("icu:Preferences__media-auto-download__photos"), checked: $autoDownload.photos)
                        AxoSwitchItem.Root(label: i18n("icu:Preferences__media-auto-download__videos"), checked: $autoDownload.videos)
                        AxoSwitchItem.Root(label: i18n("icu:Preferences__media-auto-download__audio"), checked: $autoDownload.audio)
                        AxoSwitchItem.Root(label: i18n("icu:Preferences__media-auto-download__documents"), checked: $autoDownload.documents)
                    }
                    PreferencesList {
                        AxoSelectItem.Root(label: i18n("icu:Preferences__sent-media-quality"), description: i18n("icu:Preferences__sent-media-quality__description"),
                                           placeholder: "", value: $sentMediaQuality,
                                           options: [.init(value: "standard", label: i18n("icu:sentMediaQualityStandard")),
                                                     .init(value: "high", label: i18n("icu:sentMediaQualityHigh"))])
                    }
                }
            }
        }
    }
}
