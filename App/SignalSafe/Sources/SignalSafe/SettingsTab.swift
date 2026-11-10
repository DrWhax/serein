// The Settings tab (upstream Preferences): the page selector, and the pages backed so far —
// General, Appearance, Chats and Privacy — over AppModel (this Mac's settings) and SignalCore's
// AccountSettings (synced to the account through the storage service). Other pages are blank
// until wired.

import AppKit
import LocalAuthentication
import UniformTypeIdentifiers
import Foundation
import SignalCore
import SignalI18n
import SignalUI
import SwiftUI

struct SettingsTab: View {
    @Bindable var model: AppModel
    @Bindable var session: SignalSession
    let i18n: Localizer
    /// The page (on the model: the chat list's menu opens chat folders, the profile menu notifications).
    private var page: SettingsPage {
        get { model.settingsPage }
        nonmutating set { model.settingsPage = newValue }
    }
    private var pageBinding: Binding<SettingsPage> { Binding(get: { model.settingsPage }, set: { model.settingsPage = $0 }) }
    @State private var editingFolderId: String?
    @State private var accountKey: String?
    @State private var internalSettings = InternalSettings()
    @State private var profilePage: ProfileEditorPage = .none
    /// Notification profiles: sync with our other devices, and whether the onboarding was seen
    /// (nil until read).
    @State private var profileSyncEnabled = true
    @State private var profileOnboardingSeen: Bool?
    @State private var usernameEdit: UsernameEditState = .editing

    var body: some View {
        Preferences(me: me, page: pageBinding, preferredWidth: model.preferredLeftPaneWidth,
                    navTabs: NavSidebarNavTabs(collapsed: model.navTabsCollapsed, onToggleCollapse: { model.navTabsCollapsed = $0 })) { page in
            switch page {
            case .general: PreferencesGeneralPage(settings: general)
            case .appearance: PreferencesAppearancePage(localeText: nil, themeSetting: theme, zoomFactor: zoom, onOpenChatColor: { self.page = .chatColor })
            case .chatColor: chatColorPage
            case .chats: PreferencesChatsPage(settings: chats, onOpenChatFolders: { self.page = .chatFolders },
                                              startPlaintextExport: { session.startPlaintextExport() })
            case .privacy: PreferencesPrivacyPage(settings: privacy, onOpenPNP: { self.page = .pnp }, onOpenBlocked: { self.page = .blocked })
            case .pnp:
                PreferencesPNPPage(whoCanSeeMe: Binding(get: { session.accountSettings.sharesPhoneNumber ? .everybody : .nobody },
                                                        set: { session.setSharesPhoneNumber($0 == .everybody) }),
                                   whoCanFindMe: Binding(get: { session.accountSettings.discoverableByPhoneNumber ? .discoverable : .notDiscoverable },
                                                         set: { session.setDiscoverableByPhoneNumber($0 == .discoverable) }),
                                   onBack: { self.page = .privacy }, showReadOnlyToast: { session.toast = .whoCanFindMeReadOnly })
            case .notifications: PreferencesNotificationsPage(settings: notifications, onOpenWhileMuted: { self.page = .whileMuted },
                                                              onOpenNotificationProfiles: { self.page = .notificationProfilesHome })
            case .notificationProfilesHome: notificationProfilesHome
            case .notificationProfilesCreateFlow: notificationProfilesCreateFlow
            case .whileMuted: PreferencesWhileMutedPage(notifyWhileMuted: whileMuted, onBack: { self.page = .notifications })
            case .blocked: PreferencesBlocked(blockedContacts: blocked(groups: false), blockedGroups: blocked(groups: true),
                                              goBack: { self.page = .privacy }, onUnblock: { session.unblock($0) })
            case .chatFolders: chatFoldersPage
            case .editChatFolder: editChatFolderPage
            case .account: PreferencesAccountPage(onOpenAccountKeys: { self.page = .accountKeys }, promptOSAuth: Self.promptOSAuth)
            case .accountKeys:
                PreferencesAccountKeysPage(serviceId: session.ourAci, backupKey: accountKey, saveAccountKeysPDF: { await saveAccountKeysPDF() },
                                           onBack: { accountKey = nil; self.page = .account })
                    .task { accountKey = await session.accountEntropyPool() }
            case .profile: profilePageView
            case .internal: PreferencesInternal(settings: $internalSettings)
            case .calls: callsPage
            case .dataUsage: dataUsagePage
            default: Rectangle().fill(AxoColor.surfacePrimary)
            }
        }
        .background(AxoColor.surfacePrimary)
    }

    // MARK: notification profiles

    /// The chats a profile can let through (conversation ids), for the chooser.
    var profileChats: [SearchableConversation] {
        session.conversations.map { c in
            SearchableConversation(listItem: ContactListItemData(id: c.id, title: c.title, type: c.kind == .group ? .group : .direct,
                                                                 avatar: ConversationAvatarData(title: c.title, conversationType: c.kind == .group ? .group : .direct,
                                                                                                color: c.color, image: session.avatarImage(c.avatar))))
        }
    }

    func profileChatPill(_ chats: [SearchableConversation]) -> (String) -> SelectedChatPill {
        { id in SelectedChatPill(data: chats.first { $0.id == id }?.listItem ?? ContactListItemData(id: id, title: i18n("icu:unknownContact"))) }
    }

    var profileActions: NotificationProfilesActions {
        var a = NotificationProfilesActions()
        a.onBackToNotifications = { page = .notifications }
        a.onOpenCreateFlow = { page = .notificationProfilesCreateFlow }
        a.onOpenHome = { page = .notificationProfilesHome }
        a.createProfile = { session.createNotificationProfile(Self.coreProfile($0)) }
        a.updateProfile = { session.updateNotificationProfile(Self.coreProfile($0)) }
        a.markProfileDeleted = { session.deleteNotificationProfile($0) }
        a.setProfileOverride = { id, on in session.setNotificationProfileOverride(id, enabled: on, endsAt: nil) }
        a.setIsSyncEnabled = { on in
            profileSyncEnabled = on
            let label = i18n
            session.setNotificationProfileSyncEnabled(on) { label("icu:NotificationProfile--copy-label", ["profileName": .string($0)]) }
        }
        a.setHasOnboardingBeenSeen = { _ in
            profileOnboardingSeen = true
            session.setNotificationProfileOnboardingSeen()
        }
        return a
    }

    var notificationProfilesHome: some View {
        let chats = profileChats
        return NotificationProfilesHome(activeProfileId: session.notificationProfiles.activeProfileId,
                                        allProfiles: session.notificationProfiles.profiles.map(Self.uiProfile), conversations: chats,
                                        conversationSelector: profileChatPill(chats), doWeHaveOtherDevices: true,
                                        hasOnboardingBeenSeen: profileOnboardingSeen ?? true, isSyncEnabled: profileSyncEnabled,
                                        actions: profileActions)
            .id(profileOnboardingSeen == nil)     // the onboarding check runs once the flag is known
            .task {
                profileSyncEnabled = await session.notificationProfileSyncEnabled()
                profileOnboardingSeen = await session.notificationProfileOnboardingSeen()
            }
    }

    var notificationProfilesCreateFlow: some View {
        let chats = profileChats
        return NotificationProfilesCreateFlow(conversations: chats, conversationSelector: profileChatPill(chats), actions: profileActions)
    }

    static func uiProfile(_ p: NotificationProfile) -> NotificationProfileData {
        NotificationProfileData(id: p.id, name: p.name, emoji: p.emoji, color: p.color, allowAllCalls: p.allowAllCalls, allowAllMentions: p.allowAllMentions,
                                allowedMembers: p.allowedMembers.sorted(), scheduleEnabled: p.scheduleEnabled, scheduleStartTime: p.scheduleStartTime,
                                scheduleEndTime: p.scheduleEndTime, scheduleDaysEnabled: p.scheduleDaysEnabled)
    }

    static func coreProfile(_ p: NotificationProfileData) -> NotificationProfile {
        NotificationProfile(id: p.id, name: p.name, emoji: p.emoji, color: p.color, createdAtMs: 0, allowAllCalls: p.allowAllCalls,
                            allowAllMentions: p.allowAllMentions, allowedMembers: Set(p.allowedMembers), scheduleEnabled: p.scheduleEnabled,
                            scheduleStartTime: p.scheduleStartTime, scheduleEndTime: p.scheduleEndTime, scheduleDaysEnabled: p.scheduleDaysEnabled)
    }

    /// Settings → Calls: notifications, the ringtone, devices (ringrtc's microphones and
    /// speakers, the cameras), and always relaying calls.
    var callsPage: some View {
        let devices = session.callDevices
        func pref(_ id: String?, _ list: AudioDeviceList) -> AudioDevicePref {
            id.flatMap { id in list.devices.first { $0.uniqueId == id } }.map { .specificDevice($0) } ?? .nonWindowsDefault
        }
        return PreferencesCallsPage(
            hasIncomingCallNotifications: Binding(get: { session.accountSettings.incomingCallNotification },
                                                  set: { v in session.updateAccountSettings { $0.incomingCallNotification = v } }),
            hasCallRingtoneNotification: Binding(get: { session.accountSettings.callRingtoneNotification },
                                                 set: { v in session.updateAccountSettings { $0.callRingtoneNotification = v } }),
            hasRelayCalls: Binding(get: { session.accountSettings.alwaysRelayCalls }, set: { v in session.updateAccountSettings { $0.alwaysRelayCalls = v } }),
            devices: CallingDeviceSelectionItems(availableCameras: devices.cameras, availableMicrophones: devices.microphones,
                                                 availableSpeakers: devices.speakers, selectedCamera: session.preferredCameraId,
                                                 selectedMicrophone: pref(session.preferredMicrophoneId, devices.microphones),
                                                 selectedSpeaker: pref(session.preferredSpeakerId, devices.speakers),
                                                 onSelectedCameraChange: { session.selectCamera($0) },
                                                 onSelectedMicrophoneChange: { session.selectMicrophone($0) },
                                                 onSelectedSpeakerChange: { session.selectSpeaker($0) }))
            .task { session.refreshCallDevices() }
    }

    /// Settings → Appearance → Chat color: the default bubble colour for chats without their
    /// own (upstream's ChatColorPicker with no conversation).
    var chatColorPage: some View {
        let colors = session.chatColors.customColors
        var preset: String?
        var custom: Int?
        switch session.chatColors.defaultColor {
        case .preset(let p)?: preset = p
        case .custom(let id)?: custom = Int(id)
        case nil: break
        }
        return PreferencesContent(title: i18n("icu:ChatColorPicker__menu-title"),
                                  backButton: AnyView(PreferencesBackButton(label: i18n("icu:goBack"), action: { self.page = .appearance }))) {
            ChatColorPicker(conversationId: nil,
                            customChatColors: colors.map { SignalUI.CustomChatColor(id: Int($0.id), color: SignalSession.bubble($0)) },
                            selectedPreset: preset, selectedCustomColorId: custom, defaultBubbleColor: session.bubbleColor(nil),
                            onSelectPreset: { session.setDefaultChatColor(.preset($0)) },
                            onSelectCustomColor: { session.setDefaultChatColor(.custom(Int64($0))) },
                            onAddCustomColor: { session.customColorEditor = CustomColorEditing(forDefault: true) },
                            onEditCustomColor: { c in session.customColorEditor = CustomColorEditing(editing: colors.first { $0.id == Int64(c.id) }, forDefault: true) },
                            onDuplicateCustomColor: { c in
                                session.customColorEditor = CustomColorEditing(editing: colors.first { $0.id == Int64(c.id) }, duplicate: true, forDefault: true)
                            },
                            onRemoveCustomColor: { c in session.removeCustomColor(Int64(c.id)) },
                            onResetChatColor: { session.setDefaultChatColor(nil) },
                            onResetAll: { session.resetAllChatColors() })
        }
        .task { session.observeChatColors() }
    }

    /// Settings → Data usage: media auto-download and the default sent media quality.
    var dataUsagePage: some View {
        PreferencesDataUsagePage(
            autoDownload: Binding(get: {
                let a = session.accountSettings.autoDownload
                return AutoDownloadAttachment(photos: a.photos, videos: a.videos, audio: a.audio, documents: a.documents)
            }, set: { v in
                session.updateAccountSettings {
                    $0.autoDownload.photos = v.photos
                    $0.autoDownload.videos = v.videos
                    $0.autoDownload.audio = v.audio
                    $0.autoDownload.documents = v.documents
                }
            }),
            sentMediaQuality: Binding(get: { session.accountSettings.sentMediaQuality.rawValue },
                                      set: { v in
                                          guard let q = v.flatMap(SentMediaQuality.init) else { return }
                                          session.updateAccountSettings { $0.sentMediaQuality = q }
                                      }))
    }

    var me: PreferencesMe {
        let mine = session.ourAci.flatMap { aci in session.contacts[aci] }
        return PreferencesMe(title: mine?.title ?? i18n("icu:noteToSelf"), color: mine?.color ?? "A200",
                             avatar: session.avatarImage(mine?.avatar), phoneNumber: session.accountSettings.phoneNumber)
    }

    var general: Binding<GeneralSettings> {
        Binding {
            var s = GeneralSettings()
            s.phoneNumber = session.accountSettings.phoneNumber
            s.deviceName = Host.current().localizedName ?? ""
            s.isAutoLaunchSupported = model.openAtLogin != nil
            s.hasAutoLaunch = model.openAtLogin
            s.isAutoDownloadUpdatesSupported = false    // no auto-updater (user decision)
            return s
        } set: { s in
            if let on = s.hasAutoLaunch, on != model.openAtLogin { model.setOpenAtLogin(on) }
        }
    }

    /// `themeSetting`: system / light / dark, applied to every window.
    var theme: Binding<String?> {
        Binding { model.themeSetting } set: { model.themeSetting = $0 ?? "system" }
    }

    /// Chromium's zoom factor; AppModel keeps a 1.2^level zoom.
    var zoom: Binding<String?> {
        Binding {
            Self.zoomText(Double(model.zoomFactor))
        } set: { v in
            if let f = v.flatMap(Double.init), f > 0 { model.zoomLevel = log(f) / log(1.2) }
        }
    }

    static let zoomFactors: [Double] = [0.75, 1, 1.25, 1.5, 2]
    static func zoomText(_ f: Double) -> String {
        var best = 1.0
        for z in zoomFactors where abs(z - f) < abs(best - f) { best = z }
        return best == 1 ? "1" : String(best)
    }

    var chats: Binding<ChatsSettings> {
        Binding {
            var s = ChatsSettings()
            s.hasSpellCheck = model.spellCheck
            s.initialSpellCheckSetting = model.spellCheckAtLaunch
            s.hasLinkPreviews = session.accountSettings.linkPreviews
            s.isSyncSupported = false
            return s
        } set: { s in
            if let on = s.hasSpellCheck { model.spellCheck = on }
            if s.hasLinkPreviews != session.accountSettings.linkPreviews { session.updateAccountSettings { $0.linkPreviews = s.hasLinkPreviews } }
        }
    }

    var privacy: Binding<PrivacySettings> {
        Binding {
            let a = session.accountSettings
            var s = PrivacySettings()
            s.blockedContactCount = a.blockedContacts
            s.blockedGroupCount = a.blockedGroups
            s.hasReadReceipts = a.readReceipts
            s.hasTypingIndicators = a.typingIndicators
            s.universalExpireTimer = a.universalExpireTimer
            s.hasContentProtection = model.hasContentProtection
            s.hasSealedSenderIndicators = a.sealedSenderIndicators
            s.hasStoriesDisabled = a.storiesDisabled
            s.isKeyTransparencyAvailable = false
            return s
        } set: { s in
            if let on = s.hasContentProtection { model.hasContentProtection = on }
            if s.hasStoriesDisabled != session.accountSettings.storiesDisabled { session.setStoriesDisabled(s.hasStoriesDisabled) }
            session.updateAccountSettings {
                $0.readReceipts = s.hasReadReceipts
                $0.typingIndicators = s.hasTypingIndicators
                $0.universalExpireTimer = s.universalExpireTimer
                $0.sealedSenderIndicators = s.hasSealedSenderIndicators
            }
        }
    }

    // MARK: notifications

    var notifications: Binding<SignalUI.NotificationSettings> {
        Binding {
            let n = session.notificationSettings
            var s = SignalUI.NotificationSettings()
            s.hasNotifications = n.setting != .off
            s.notificationContent = n.setting == .off ? "off" : n.setting.rawValue
            s.notifyWhileMuted = NotifyWhileMuted(calls: n.notifyForCallsIfMuted, mentions: n.notifyForMentionsIfMuted, replies: n.notifyForRepliesIfMuted)
            s.hasReactionNotifications = n.reactions
            s.hasNotificationAttention = n.drawAttention
            s.hasAudioNotifications = n.playSound
            s.unreadCountBadgeType = n.badgeCountsChats ? "unread-chats" : "unread-messages"
            s.hasCountMutedConversations = n.badgeCountMutedConversations
            return s
        } set: { s in
            session.saveNotificationSettings { n in
                if !s.hasNotifications { n.setting = .off }
                else { n.setting = NotificationSetting(rawValue: s.notificationContent == "off" ? "message" : s.notificationContent) ?? .message }
                n.reactions = s.hasReactionNotifications
                n.drawAttention = s.hasNotificationAttention
                n.playSound = s.hasAudioNotifications
                n.badgeCountsChats = s.unreadCountBadgeType == "unread-chats"
                n.badgeCountMutedConversations = s.hasCountMutedConversations
            }
        }
    }

    var whileMuted: Binding<NotifyWhileMuted> {
        Binding {
            let n = session.notificationSettings
            return NotifyWhileMuted(calls: n.notifyForCallsIfMuted, mentions: n.notifyForMentionsIfMuted, replies: n.notifyForRepliesIfMuted)
        } set: { w in
            session.saveNotificationSettings {
                $0.notifyForCallsIfMuted = w.calls
                $0.notifyForMentionsIfMuted = w.mentions
                $0.notifyForRepliesIfMuted = w.replies
            }
        }
    }

    // MARK: blocked

    func blocked(groups: Bool) -> [BlockedConversation] {
        session.blockedConversationIds.compactMap { id in
            guard let c = session.conversation(id) ?? session.composable.first(where: { $0.id == id }) else {
                return groups ? nil : BlockedConversation(id: id, title: i18n("icu:unknownContact"))
            }
            guard (c.kind == .group) == groups else { return nil }
            return BlockedConversation(id: id, title: c.title, isGroup: groups, color: c.color, avatar: session.avatarImage(c.avatar))
        }
    }

    // MARK: chat folders

    func uiFolder(_ f: SignalCore.ChatFolder, position: Int) -> SignalUI.ChatFolder {
        SignalUI.ChatFolder(id: f.id, folderType: f.folderType == .all ? .all : .custom, name: f.name, position: position,
                            preset: ChatFolderPreset(showOnlyUnread: f.showOnlyUnread, showMutedChats: f.showMutedChats,
                                                     includeAllIndividualChats: f.includeAllIndividualChats, includeAllGroupChats: f.includeAllGroupChats,
                                                     includedConversationIds: f.includedConversationIds, excludedConversationIds: f.excludedConversationIds))
    }

    static func coreFolder(_ id: String, _ name: String, _ p: ChatFolderPreset) -> SignalCore.ChatFolder {
        SignalCore.ChatFolder(id: id, name: name, showOnlyUnread: p.showOnlyUnread, showMutedChats: p.showMutedChats,
                              includeAllIndividualChats: p.includeAllIndividualChats, includeAllGroupChats: p.includeAllGroupChats,
                              includedConversationIds: p.includedConversationIds, excludedConversationIds: p.excludedConversationIds)
    }

    var chatFoldersPage: some View {
        PreferencesChatFoldersPage(
            chatFolders: session.chatFolders.enumerated().map { uiFolder($1, position: $0) },
            onBack: { page = .chats },
            onOpenEditChatFoldersPage: { id in editingFolderId = id; page = .editChatFolder },
            onCreateChatFolder: { name, preset in
                let folder = Self.coreFolder(UUID().uuidString.lowercased(), name, preset)
                session.editChatFolders { db in
                    _ = try ChatFolderStore.ensureAllChats(db)
                    _ = try ChatFolderStore.create(db, folder)
                }
            },
            onDeleteChatFolder: { id in
                session.editChatFolders { try ChatFolderStore.delete($0, id: id, at: Int64(Date().timeIntervalSince1970 * 1000)) }
            },
            onUpdateChatFoldersPositions: { ids in session.editChatFolders { try ChatFolderStore.reorder($0, ids: ids) } })
    }

    var editChatFolderPage: some View {
        let existing = editingFolderId.flatMap { id in session.chatFolders.first { $0.id == id } }
        let params = existing.map { ChatFolderParams(name: $0.name, preset: uiFolder($0, position: 0).preset) } ?? ChatFolderParams()
        let chats = session.conversations.map { c in
            SearchableConversation(listItem: ContactListItemData(id: c.id, title: c.title, type: c.kind == .group ? .group : .direct,
                                                                 avatar: ConversationAvatarData(title: c.title, conversationType: c.kind == .group ? .group : .direct,
                                                                                                color: c.color, image: session.avatarImage(c.avatar))))
        }
        return PreferencesEditChatFolderPage(
            existingChatFolderId: editingFolderId, initChatFolderParams: params, conversations: chats,
            conversationSelector: { id in
                let c = chats.first { $0.id == id }
                return SelectedChatPill(data: c?.listItem ?? ContactListItemData(id: id, title: i18n("icu:unknownContact")))
            },
            onBack: { page = .chatFolders },
            onCreateChatFolder: { p in
                let folder = Self.coreFolder(UUID().uuidString.lowercased(), p.name, p.preset)
                session.editChatFolders { db in
                    _ = try ChatFolderStore.ensureAllChats(db)
                    _ = try ChatFolderStore.create(db, folder)
                }
                page = .chatFolders
            },
            onUpdateChatFolder: { id, p in
                guard var f = session.chatFolders.first(where: { $0.id == id }) else { return }
                let updated = Self.coreFolder(id, p.name, p.preset)
                f.name = updated.name
                f.showOnlyUnread = updated.showOnlyUnread
                f.showMutedChats = updated.showMutedChats
                f.includeAllIndividualChats = updated.includeAllIndividualChats
                f.includeAllGroupChats = updated.includeAllGroupChats
                f.includedConversationIds = updated.includedConversationIds
                f.excludedConversationIds = updated.excludedConversationIds
                let save = f
                session.editChatFolders { try ChatFolderStore.update($0, save) }
                page = .chatFolders
            },
            onDeleteChatFolder: { id in
                session.editChatFolders { try ChatFolderStore.delete($0, id: id, at: Int64(Date().timeIntervalSince1970 * 1000)) }
                page = .chatFolders
            })
    }

    // MARK: account

    /// `promptOSAuth`: Touch ID or the login password before showing the account keys.
    static func promptOSAuth() async -> PromptOSAuthResult {
        do {
            return try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show your Signal account keys") ? .success : .unauthorized
        } catch let e as LAError where e.code == .biometryNotAvailable || e.code == .passcodeNotSet || e.code == .notInteractive {
            return .unsupported
        } catch {
            return .unauthorized
        }
    }

    /// The account keys PDF (AccountKeysPDF) saved where the user picks.
    func saveAccountKeysPDF() async {
        guard let key = await session.accountEntropyPool() else { return }
        let pdf = AccountKeysPDF.generate(serviceId: session.ourAci, backupKey: key, i18n: i18n)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Signal Account Keys.pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? pdf.write(to: url, options: [.atomic, .completeFileProtection])
    }

    // MARK: profile

    var profilePageView: some View {
        let mine = session.ourAci.flatMap { session.contacts[$0] }
        let title = mine?.title ?? ""
        let parts = title.split(separator: " ", maxSplits: 1).map(String.init)
        return ProfileEditor(color: mine?.color, avatar: session.avatarImage(mine?.avatar), firstName: parts.first ?? title,
                             familyName: parts.count > 1 ? parts[1] : nil, username: session.accountSettings.username,
                             usernameLink: session.accountSettings.usernameLink, hasCompletedUsernameLinkOnboarding: true,
                             editState: $profilePage, usernameEditState: $usernameEdit, actions: {
            var a = ProfileEditor.Actions()
            a.copyUsername = { NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string) }
            return a
        }()) { subpage, close in
            if subpage == .usernameLink, let link = session.accountSettings.usernameLink, let name = session.accountSettings.username {
                AnyView(UsernameLinkSave(link: link, username: name, i18n: i18n, close: close))
            } else {
                AnyView(EmptyView())
            }
        }
    }
}

/// The username link: copy it, or save the QR card PNG (UsernameLinkCard, drawn by us).
struct UsernameLinkSave: View {
    let link: String
    let username: String
    let i18n: Localizer
    let close: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Text(link).textSelection(.enabled).font(.system(size: 13))
            HStack {
                Button(i18n("icu:UsernameLinkModalBody__copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                }
                Button(i18n("icu:UsernameLinkModalBody__save")) {
                    guard let png = UsernameLinkCard.png(link: link, username: username, color: .blue, i18n: i18n) else { return }
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "signal-username-qr.png"
                    panel.allowedContentTypes = [.png]
                    if panel.runModal() == .OK, let url = panel.url { try? Data(png).write(to: url) }
                }
                Button(i18n("icu:close"), action: close)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AxoColor.surfacePrimary)
    }
}
