// ts/components/Preferences.dom.stories.tsx. The references are spliced: the sidebar's
// "Donate to Signal" and "Backups" rows are cut out (Tools/splice-reference.py, sidebar column
// only), as SignalSafe has neither.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct PreferencesTests {
    /// `me`: getDefaultConversation() (seeded: Mattie Grady, kitten-2) with the story's number and username.
    static let me = PreferencesMe(title: "Mattie Grady", avatar: fixtureImage("kitten-2-64-64.jpg"), phoneNumber: "(215) 555-2345", username: "someone.243")

    static func stage(_ page: SettingsPage, height: CGFloat, me: PreferencesMe = me, @ViewBuilder content: @escaping (SettingsPage) -> some View) -> some View {
        Preferences(me: me, page: .constant(page), pageContent: content).frame(width: 1200, height: height)
    }

    @Test(arguments: ["light", "dark"])
    func appearance(theme: String) throws {
        let view = Self.stage(.appearance, height: 567) { _ in
            PreferencesAppearancePage(localeText: "System Language", themeSetting: .constant("system"), zoomFactor: .constant("1"))
        }
        try Snapshot.assertMatches(view, story: "components-preferences--appearance-without-donations", theme: theme)
    }

    static let microphones = AudioDeviceList(devices: [AudioDevice(name: "DefAuLt (Headphones)", uniqueId: "Default")],
                                             defaultDevice: AudioDevice(name: "Monitor of UE Boom (Bluetooth)", uniqueId: "bb.monitor"))
    static let speakers = AudioDeviceList(devices: [AudioDevice(name: "Default", uniqueId: "Default"), AudioDevice(name: "Natalie's Airpods (Bluetooth)", uniqueId: "aa"),
                                                    AudioDevice(name: "UE Boom (Bluetooth)", uniqueId: "bb")],
                                          defaultDevice: AudioDevice(name: "Default", uniqueId: "Default"))
    static let cameras = [CameraDevice(deviceId: "dfbe6effe70b0611ba0fdc2a9ea3f39f6cb110e6687948f7e5f016c111b7329c", label: "FaceTime HD Camera (Built-in) (9fba:bced)"),
                          CameraDevice(deviceId: "e2db196a31d50ff9b135299dc0beea67f65b1a25a06d8a4ce76976751bb7a08d", label: "Logitech Webcam (4e72:9058)")]

    @Test(arguments: ["light", "dark"])
    func callsAndDataUsage(theme: String) throws {
        let calls = Self.stage(.calls, height: 567) { _ in
            PreferencesCallsPage(hasIncomingCallNotifications: .constant(true), hasCallRingtoneNotification: .constant(false), hasRelayCalls: .constant(false),
                                 devices: CallingDeviceSelectionItems(availableCameras: Self.cameras, availableMicrophones: Self.microphones,
                                                                      availableSpeakers: Self.speakers, selectedCamera: Self.cameras[0].deviceId,
                                                                      selectedMicrophone: .nonWindowsDefault, selectedSpeaker: .specificDevice(Self.speakers.devices[1])))
        }
        try Snapshot.assertMatches(calls, story: "components-preferences--calls-without-donations", theme: theme)
        let data = Self.stage(.dataUsage, height: 567) { _ in
            PreferencesDataUsagePage(autoDownload: .constant(AutoDownloadAttachment()), sentMediaQuality: .constant("standard"))
        }
        try Snapshot.assertMatches(data, story: "components-preferences--data-usage-without-donations", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func notifications(theme: String) throws {
        var disabled = NotificationSettings()
        disabled.hasNotifications = false
        disabled.notificationContent = "off"
        // The three-profile stories render the same page: profiles show only on their home page.
        for (name, settings) in [("notifications", NotificationSettings()), ("notifications-disabled", disabled),
                                 ("notifications-page-with-three-profiles", NotificationSettings()),
                                 ("notifications-page-with-three-profiles-and-no-other-devices", NotificationSettings())] {
            let view = Self.stage(.notifications, height: 872) { _ in PreferencesNotificationsPage(settings: .constant(settings)) }
            try Snapshot.assertMatches(view, story: "components-preferences--\(name)-without-donations", theme: theme)
        }
    }

    @Test(arguments: ["light", "dark"])
    func privacy(theme: String) throws {
        var custom = PrivacySettings()
        custom.universalExpireTimer = 9000
        func blocked(_ contacts: Int, _ groups: Int) -> PrivacySettings {
            var s = PrivacySettings()
            s.blockedContactCount = contacts
            s.blockedGroupCount = groups
            return s
        }
        let stories = [("privacy", PrivacySettings()), ("custom-universal-expire-timer", custom), ("privacy-blocked-1-contact", blocked(1, 0)),
                       ("privacy-blocked-1-group", blocked(0, 1)), ("privacy-blocked-1-both-with-blocked-at", blocked(1, 1)),
                       ("privacy-blocked-many-contacts", blocked(55, 0)), ("privacy-blocked-many-groups", blocked(0, 55)),
                       ("privacy-blocked-many-both", blocked(20, 20))]
        for (name, settings) in stories {
            let view = Self.stage(.privacy, height: 906) { _ in PreferencesPrivacyPage(settings: .constant(settings)) }
            try Snapshot.assertMatches(view, story: "components-preferences--\(name)-without-donations", theme: theme)
        }
    }

    @Test(arguments: ["light", "dark"])
    func chats(theme: String) throws {
        var settings = ChatsSettings()
        settings.lastSyncDate = "11/4/2026"
        settings.lastSyncTime = "12:00:00 PM"
        let view = Self.stage(.chats, height: 766) { _ in PreferencesChatsPage(settings: .constant(settings)) }
        try Snapshot.assertMatches(view, story: "components-preferences--chats-without-donations", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func account(theme: String) throws {
        let view = Self.stage(.account, height: 567) { _ in PreferencesAccountPage() }
        try Snapshot.assertMatches(view, story: "components-preferences--account-without-donations", theme: theme)
    }

    /// The story's platform flags: launch at login, menu bar and tray all supported.
    @Test(arguments: ["light", "dark"])
    func general(theme: String) throws {
        var settings = GeneralSettings()
        settings.phoneNumber = "+1 555 123-4567"
        settings.deviceName = "Work Windows ME"
        settings.isHideMenuBarSupported = true
        settings.isSystemTraySupported = true
        settings.hasMinimizeToSystemTray = true
        settings.isMinimizeToAndStartInSystemTraySupported = true
        settings.hasMinimizeToAndStartInSystemTray = true
        let view = Self.stage(.general, height: 700) { _ in PreferencesGeneralPage(settings: .constant(settings)) }
        try Snapshot.assertMatches(view, story: "components-preferences--general-without-donations", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func pnp(theme: String) throws {
        for (name, find) in [("pnp-sharing-disabled", PhoneNumberDiscoverability.discoverable), ("pnp-discoverability-disabled", .notDiscoverable)] {
            let view = Self.stage(.pnp, height: 567) { _ in PreferencesPNPPage(whoCanSeeMe: .constant(.nobody), whoCanFindMe: .constant(find)) }
            try Snapshot.assertMatches(view, story: "components-preferences--\(name)-without-donations", theme: theme)
        }
    }

    @Test(arguments: ["light", "dark"])
    func whileMuted(theme: String) throws {
        let view = Self.stage(.whileMuted, height: 567) { _ in PreferencesWhileMutedPage(notifyWhileMuted: .constant(.default)) }
        try Snapshot.assertMatches(view, story: "components-preferences--notifications-while-muted-without-donations", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func chatFolders(theme: String) throws {
        let view = Self.stage(.chatFolders, height: 567) { _ in PreferencesChatFoldersPage(chatFolders: []) }
        try Snapshot.assertMatches(view, story: "components-preferences--chat-folders-without-donations", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func editChatFolder(theme: String) throws {
        let view = Self.stage(.editChatFolder, height: 645) { _ in
            PreferencesEditChatFolderPage(conversationSelector: { SelectedChatPill(data: ContactListItemData(id: $0, title: $0)) })
        }
        try Snapshot.assertMatches(view, story: "components-preferences--edit-chat-folder-without-donations", theme: theme)
    }

    static let serviceId = "d09c9826-e74a-4c8c-95d2-af60442ed47e"
    static let backupKey = "uy38jh2778hjjhj8lk19ga61s672jsj089r023s6a57809bap92j2yh5t326vv7t"

    @Test(arguments: ["light", "dark"])
    func accountE164Less(theme: String) throws {
        var e164Less = Self.me
        e164Less.phoneNumber = nil
        let account = Self.stage(.account, height: 567, me: e164Less) { _ in PreferencesAccountPage(hasPhoneNumber: false) }
        try Snapshot.assertMatches(account, story: "components-preferences--account-e-164-less-without-donations", theme: theme)
        let keys = Self.stage(.accountKeys, height: 567, me: e164Less) { _ in
            PreferencesAccountKeysPage(serviceId: Self.serviceId, backupKey: Self.backupKey, saveAccountKeysPDF: {})
        }
        try Snapshot.assertMatches(keys, story: "components-preferences--account-keys-without-donations", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func signalAccountKeys(theme: String) throws {
        let key = "22rsumdlqxa8r7lsghj12ah6ae2anhk4vjvccor4pc75mee49i9t9dcwmvso4wyn"
        for (story, save) in [("default", true), ("print", false)] {
            let view = SignalAccountKeys(serviceId: "f83a157c-aed6-41ff-9d84-637c7af95f02", backupKey: key, saveAccountKeysPDF: save ? {} : nil)
                .frame(width: 1168)
            try Snapshot.assertMatches(TimelineMessageTests.stage(view), story: "components-preferences-signalaccountkeys--\(story)", theme: theme)
        }
    }

    @Test func backupKeyDisplay() {
        #expect(formatBackupKeyForDisplay("ab0O cdef12", convertAmbiguousChars: true) == "AB=# CDEF 12")
        #expect(formatBackupKeyForDisplay("ab0O", convertAmbiguousChars: false) == "AB0O")
    }

    /// renderProfileEditor: me's first name, no colour, about or avatar.
    @Test(arguments: ["light", "dark"])
    func profile(theme: String) throws {
        let view = Self.stage(.profile, height: 567) { _ in
            ProfileEditor(firstName: "Mattie", editState: .constant(.none), usernameEditState: .constant(.editing))
        }
        try Snapshot.assertMatches(view, story: "components-preferences--preferences-without-donations", theme: theme)
    }

    /// The Template's default page (Profile) with the nav-tabs toggle or the update dialog.
    @Test(arguments: ["light", "dark"])
    func navTabsAndUpdateDialog(theme: String) throws {
        let profile = ProfileEditor(firstName: "Mattie", editState: .constant(.none), usernameEditState: .constant(.editing))
        let cases: [(String, NavSidebarNavTabs, Bool)] = [
            ("nav-tabs-collapsed", NavSidebarNavTabs(collapsed: true), false),
            ("nav-tabs-collapsed-with-badges", NavSidebarNavTabs(collapsed: true, otherTabsUnreadCount: 1), false),
            ("nav-tabs-collapsed-with-exclamation", NavSidebarNavTabs(collapsed: true, hasFailedStorySends: true, otherTabsUnreadCount: 1), false),
            ("showing-update-dialog", NavSidebarNavTabs(), true),
        ]
        for (story, navTabs, update) in cases {
            let dialog = update ? AnyView(DialogUpdate(containerWidthBreakpoint: .wide, dialogType: .downloadReady, disableDismiss: true, downloadSize: 100_000,
                                                       downloadedSize: 50_000, version: "8.99.0", currentVersion: "8.98.00")) : nil
            let view = Preferences(me: Self.me, page: .constant(.profile), navTabs: navTabs, updateDialog: dialog) { _ in profile }
                .frame(width: 1200, height: 567)
            try Snapshot.assertMatches(view, story: "components-preferences--\(story)-without-donations", theme: theme)
        }
    }

    /// The story's overrides: DRED 0, direct max bitrate 1000000, the SVC defaults, the SFU URL.
    @Test(arguments: ["light", "dark"])
    func `internal`(theme: String) throws {
        var settings = InternalSettings()
        settings.dredDuration = 0
        settings.directMaxBitrate = 1_000_000
        settings.enableVp9Encode = true
        settings.enableVp9Decode = true
        settings.isGroupSvcEnabled = false
        settings.groupSvcMode = PreferencesInternal.svcDefaultMode
        settings.groupSvcModeForScreenshare = PreferencesInternal.svcDefaultModeForScreenshare
        settings.sfuUrl = "https://sfu.voip.signal.org"
        let view = Preferences(me: Self.me, page: .constant(.internal), isInternalUser: true) { _ in
            PreferencesInternal(settings: .constant(settings), keyTransparencySelfHealth: .ok)
        }
        .frame(width: 1200, height: 1663)
        try Snapshot.assertMatches(view, story: "components-preferences--internal-without-donations", theme: theme)
    }
}
