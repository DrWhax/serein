import AppKit
import SignalCore
import SignalI18n
import SignalUI
import SwiftUI

/// The main window's content: `App` → `Inbox` → NavTabs + the selected tab's NavSidebar.
struct RootView: View {
    @Bindable var model: AppModel
    @Bindable var session: SignalSession
    let i18n: Localizer

    var body: some View {
        Zoomed(factor: model.zoomFactor) {
            App(appView: appView, renderInstallScreen: { installScreen }, renderInbox: {
                Inbox(navTabs: NavTabsState(selected: model.selectedTab, collapsed: model.navTabsCollapsed, storiesEnabled: !session.accountSettings.storiesDisabled,
                                            hasFailedStorySends: session.stories.contains { $0.isOutgoing && $0.sendStatuses.contains("Failed") },
                                            unreadChats: session.conversations.filter { $0.unreadCount > 0 && !$0.isArchived }.count,
                                            unreadStories: Set(session.stories.filter { !$0.isOutgoing && $0.isUnread }.map { $0.groupConversationId ?? $0.author }).count,
                                            onSelect: { model.selectedTab = $0 },
                                            onToggleCollapse: { model.navTabsCollapsed = $0 })) { tab in
                    // The chats tab stays alive under the others (hidden), so coming back to it
                    // does not lay the whole timeline out again.
                    ZStack {
                        ChatsTab(isStaging: session.isStaging, selectedConversationId: session.selectedConversationId) { leftPane } renderConversationView: { id in
                            if let c = session.conversation(id) {
                                ConversationPane(session: session, conversation: c, i18n: i18n).id(id)
                            }
                        } renderMiniPlayer: { if session.activeAudioMessageId != nil { AudioMiniPlayer(session: session, i18n: i18n) } }
                            .background(AxoColor.surfacePrimary)
                            .opacity(tab == .chats ? 1 : 0)
                            .allowsHitTesting(tab == .chats)
                            .accessibilityHidden(tab != .chats)
                        if tab != .chats { otherTab(tab) }
                    }
                }
            }, renderOverlays: {
                MediaLightbox(session: session, i18n: i18n)
                ViewOnceLightbox(session: session, i18n: i18n)
                AppCallManager(session: session, model: model, i18n: i18n)
                if model.pendingCrashReports > 0 {
                    CrashReportDialog(onSend: { model.saveCrashReports() }, onErase: { model.eraseCrashReports() })
                }
                if let step = session.exportStep {
                    PlaintextExportWorkflow(workflow: step, cancelWorkflow: { session.cancelPlaintextExport() },
                                            clearWorkflow: { session.cancelPlaintextExport() },
                                            openFileInFolder: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0)]) },
                                            verifyWithOSForExport: { includeMedia in
                                                Task {
                                                    if await SettingsTab.promptOSAuth() == .unauthorized { return session.cancelPlaintextExport() }
                                                    session.runPlaintextExport(includeMedia: includeMedia)
                                                }
                                            })
                }
                if let id = session.contactModalId { MemberContactModal(session: session, serviceId: id, i18n: i18n) }
                ContactSurfaceDialogs(session: session, model: model, i18n: i18n)
                StickerPackPreviewHost(session: session)
                ShareContactDialogHost(session: session)
                ChatDialogs(session: session, i18n: i18n)
                callLinkModal
                if let e = session.composeError {
                    ErrorModal(title: i18n("icu:error"), description: i18n(e.key, e.args.mapValues { .string($0) })) { session.composeError = nil }
                }
                if let r = session.deleteRequest {
                    DeleteMessagesModal(isMe: session.conversation(r.conversationId).map { $0.kind == .private && $0.serviceId != nil && $0.serviceId == session.ourAci } ?? false,
                                        canDeleteForEveryone: r.canDeleteForEveryone, needsAdminDelete: r.needsAdminDelete,
                                        isDeletingOwnMessages: r.isDeletingOwnMessages,
                                        // Shown once: the admin-delete explainer, then remembered.
                                        hasSeenAdminDeleteEducationDialog: UserDefaults.standard.bool(forKey: "hasSeenAdminDeleteEducationDialog"),
                                        messageCount: r.messageIds.count,
                                        onClose: { session.deleteRequest = nil }, onDeleteForMe: { session.deleteForMe(r) },
                                        onDeleteForEveryone: { session.deleteForEveryone(r) },
                                        onSeenAdminDeleteEducationDialog: { UserDefaults.standard.set(true, forKey: "hasSeenAdminDeleteEducationDialog") },
                                        showTooManyMessagesToast: { session.toast = .tooManyMessagesToDeleteForEveryone(count: $0) })
                }
                if let r = session.pinRequest {
                    PinMessageDialog(hasMaxPinnedMessages: r.hasMaxPinnedMessages, isPinningDisappearingMessage: r.isDisappearing,
                                     seenWarningCount: session.pinWarningSeenCount, onSeenWarning: { session.pinWarningSeenCount += 1 },
                                     onPinnedMessageAdd: { session.pin(r.messageId, durationSeconds: $0) }, onClose: { session.pinRequest = nil })
                }
                if model.isShowingShortcutGuide {
                    ShortcutGuideModal(platform: "darwin") { model.isShowingShortcutGuide = false }
                }
            })
            .environment(\.titleBarDragAreaHeight, model.isFullScreen ? 0 : 28 / model.zoomFactor)
            .axoModalHost()
            .environment(\.axoDialogBackdropBlur, true)
            .axoViewport()
        }
        .environment(\.i18n, i18n)
        .environment(\.layoutDirection, i18n.direction == .rightToLeft ? .rightToLeft : .leftToRight)
        .frame(minWidth: 300, minHeight: 200)
        .ignoresSafeArea()    // content runs under the hidden title bar (fullSizeContentView)
    }

    var appView: AppViewType {
        switch session.phase {
        case .starting: .blank
        case .linking, .linkError, .failed, .deletingData: .installer
        case .ready: model.appView
        }
    }

    /// The install screen (upstream InstallScreen): the QR code, or the error step.
    @ViewBuilder var installScreen: some View {
        switch session.phase {
        case .linking(let url):
            InstallScreenQrCodeNotScannedStep(provisioningUrl: url, isStaging: session.isStaging, retryGetQrCode: { session.link() })
        case .linkError(let error):
            InstallScreenErrorStep(error: error, quit: { NSApp.terminate(nil) }, tryAgain: { session.link() })
        case .failed(let reason):
            Text(reason).font(.system(size: 13)).foregroundStyle(.secondary).padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(AxoColor.surfacePrimary)
        case .deletingData:
            ClearingData(step: .deletingData)
        case .starting, .ready:
            Rectangle().fill(AxoColor.surfacePrimary)
        }
    }

    /// The Chats tab: LeftPane in Inbox mode over the database (live), or compose mode.
    /// The tabs other than chats.
    @ViewBuilder func otherTab(_ tab: NavTab) -> some View {
        if tab == .calls {
            callsTab.background(AxoColor.surfacePrimary)
        } else if tab == .stories {
            StoriesScreen(model: model, session: session, i18n: i18n)
        } else if tab == .settings {
            SettingsTab(model: model, session: session, i18n: i18n)
        } else {
            HStack(spacing: 0) {
                NavSidebar(title: title(tab), navTabsCollapsed: model.navTabsCollapsed,
                           onToggleNavTabsCollapse: { model.navTabsCollapsed = $0 },
                           preferredLeftPaneWidth: model.preferredLeftPaneWidth,
                           savePreferredLeftPaneWidth: { model.preferredLeftPaneWidth = $0 },
                           actions: { EmptyView() }, content: { EmptyView() })
                Rectangle().fill(AxoColor.surfacePrimary)    // Inbox__conversation-stack
            }
        }
    }

    var leftPane: some View {
        var context = LeftPaneContext(i18n: i18n)
        context.startComposing = { session.startComposing() }
        context.showInbox = {
            session.stopComposing()
            session.isShowingArchive = false
        }
        context.showArchivedConversations = {
            session.stopComposing()
            session.endSearch()
            session.isShowingArchive = true
        }
        context.hasAnyCurrentCustomChatFolders = session.chatFolders.contains { $0.folderType == .custom }
        context.onChatFoldersOpenSettings = {
            model.settingsPage = .chatFolders
            model.selectedTab = .settings
        }
        context.renderNotificationProfilesMenu = { AnyView(notificationProfilesMenu) }
        context.renderToastManager = {
            var actions = ToastManagerActions()
            actions.hideToast = { session.toast = nil }
            // "Undo" on "Chat archived": back to the inbox, pinned again if it was.
            actions.onUndoArchive = { id, wasPinned in
                session.setArchived(false, for: id)
                if wasPinned { session.setPinnedChat(true, for: id) }
            }
            actions.openFileInFolder = { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0)]) }
            return AnyView(ToastManager(toast: session.toast, actions: actions))
        }
        context.updateSearchTerm = { if session.isComposing { session.composeSearch = $0 } else { session.updateSearch($0) } }
        context.clearSearchQuery = { if session.isComposing { session.composeSearch = "" } else { session.updateSearch("") } }
        context.endConversationSearch = { session.endConversationSearch() }
        context.endSearch = {
            session.endSearch()
            session.filterByUnread = false
        }
        context.updateFilterByUnread = { session.filterByUnread = $0 }
        var actions = ConversationListActions()
        let helper: any LeftPaneHelper
        if session.isComposing {
            actions.onSelectConversation = { session.openFromCompose($0) }
            actions.showChooseGroupMembers = { session.showComposeMode(.chooseGroupMembers) }
            actions.showFindByUsername = { session.showComposeMode(.findByUsername) }
            actions.showFindByPhoneNumber = { session.showComposeMode(.findByPhoneNumber) }
            actions.lookupUsername = { session.lookUpUsername($0) }
            actions.lookupPhoneNumber = { session.lookUpPhoneNumber($0) }
            actions.onClickContactCheckbox = { id, reason in if reason == nil { session.toggleGroupMember(id) } }
            actions.togglePhoneNumber = { session.toggleGroupPhoneNumber($0) }
            actions.toggleUsername = { session.toggleGroupUsername($0) }
            context.showChooseGroupMembers = { session.composeMode = .chooseGroupMembers }
            context.startSettingGroupMetadata = { session.composeMode = .setGroupMetadata }
            context.createGroup = { session.createGroup() }
            context.removeSelectedContact = { session.toggleGroupMember($0) }
            helper = composeModeHelper
        } else if session.isShowingArchive && !session.isSearching {
            // Archived chats (back returns to the inbox).
            actions.onSelectConversation = { session.selectedConversationId = $0 }
            helper = LeftPaneArchiveHelper(archivedConversations: session.conversations.filter(\.isArchived).map { listItem($0).data })
        } else if session.isSearching || session.filterByUnread {
            // Search: chats whose title matches (searching everywhere), then messages. With the
            // unread filter, only unread, unmuted chats (and the open one), even without a term.
            actions.onSelectConversation = { session.selectedConversationId = $0 }
            actions.onClickClearFilterButton = { session.filterByUnread = false }
            let term = session.searchTerm.trimmingCharacters(in: .whitespaces)
            let scope = session.searchConversationId.flatMap { session.conversation($0) }
            let unreadOnly = session.filterByUnread && scope == nil
            func unread(_ d: ConversationListItemData) -> Bool {
                d.id == session.selectedConversationId
                    || (d.unreadCount > 0 || d.markedUnread || d.unreadMentionsCount > 0) && !((d.muteExpiresAt ?? .distantPast) > .now)
            }
            let chats = scope == nil && (!term.isEmpty || unreadOnly)
                ? session.conversations.map { listItem($0).data }
                    .filter { (term.isEmpty || $0.title.localizedCaseInsensitiveContains(term)) && (!unreadOnly || unread($0)) } : []
            let unreadIds = Set(chats.map(\.id))
            let shownHits = unreadOnly ? session.searchHits.filter { unreadIds.contains($0.conversationId) } : session.searchHits
            let hits = Dictionary(shownHits.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            actions.renderMessageSearchResult = { id in
                guard let h = hits[id] else { return AnyView(EmptyView()) }
                return AnyView(searchResult(h))
            }
            helper = LeftPaneSearchHelper(conversationResults: .loaded(chats), contactResults: .loaded([]), messageResults: .loaded(shownHits.map(\.id)),
                                          searchTerm: session.searchTerm,
                                          searchConversation: scope.map { SearchConversation(id: $0.id, avatar: listItem($0).data.avatar) },
                                          searchConversationName: scope.map { listItem($0).data.title }, isSearchingGlobally: scope == nil,
                                          filterByUnread: unreadOnly)
            if unreadOnly && session.chatFolders.count > 1 { context.renderLeftPaneChatFolders = { AnyView(folderBar) } }
        } else {
            actions.onSelectConversation = { session.selectedConversationId = $0 }
            actions.onClickArchiveButton = { session.isShowingArchive = true }
            actions.contextMenu = { data in
                let c = session.conversation(data.id)
                let id = data.id
                var m = ConversationContextMenuModel(conversationId: id, isUnread: data.unreadCount > 0 || data.unreadMentionsCount > 0,
                                                     markedUnread: data.markedUnread, isPinned: c?.isPinned ?? false,
                                                     isMuted: (data.muteExpiresAt ?? .distantPast) > .now, isArchived: c?.isArchived ?? false)
                m.onMarkRead = { session.markRead(id, force: true); session.setMarkedUnread(false, for: id) }
                m.onMarkUnread = { session.setMarkedUnread(true, for: id) }
                m.onPin = { session.setPinnedChat(true, for: id) }
                m.onUnpin = { session.setPinnedChat(false, for: id) }
                m.onMute = { session.setMute($0, for: id) }
                m.onUnmute = { session.setMute(nil, for: id) }
                m.onArchive = { session.setArchived(true, for: id) }
                m.onUnarchive = { session.setArchived(false, for: id) }
                m.onDelete = { session.deleteChat(id) }
                // Chat folders: add to or take out of a custom folder, or start a new one with it.
                let custom = session.chatFolders.filter { $0.folderType == .custom }
                m.customChatFolders = custom.enumerated().map { i, f in folderItem(f, position: i) }
                m.foldersContainingChat = Set(custom.filter { f in c.map { ChatFolderStore.contains(f, $0.folderProps, ignoreShowOnlyUnread: true,
                                                                                                    ignoreShowMutedChats: true) } ?? false }.map(\.id))
                let selected = session.chatFolders.first { $0.id == session.selectedChatFolderId && $0.folderType == .custom }
                m.selectedCustomChatFolderId = selected?.id
                m.onChatFolderToggleChat = { folderId, included in
                    session.editChatFolders { try ChatFolderStore.toggle($0, folderId: folderId, conversationId: id, included: included) }
                }
                m.onChatFolderRemoveChat = {
                    if let folderId = selected?.id {
                        session.editChatFolders { try ChatFolderStore.toggle($0, folderId: folderId, conversationId: id, included: false) }
                    }
                }
                m.onChatFolderCreateNew = {
                    model.newChatFolderWith = id
                    model.settingsPage = .editChatFolder
                    model.selectedTab = .settings
                }
                return m
            }
            let custom = session.chatFolders.first { $0.id == session.selectedChatFolderId }?.folderType == .custom
            let rows = session.folderFilteredConversations.map(listItem)
            helper = LeftPaneInboxHelper(conversations: rows.filter { !$0.isArchivedRow && !$0.isPinnedRow }.map(\.data),
                                         archivedConversations: custom ? [] : rows.filter(\.isArchivedRow).map(\.data),
                                         pinnedConversations: rows.filter { $0.isPinnedRow && !$0.isArchivedRow }.map(\.data),
                                         selectedCustomChatFolder: custom)
            if session.chatFolders.count > 1 {
                context.renderLeftPaneChatFolders = { AnyView(folderBar) }
            }
        }
        return LeftPane(helper: helper, context: context, dialogs: LeftPaneDialogs(),
                        preferredLeftPaneWidth: model.preferredLeftPaneWidth,
                        savePreferredLeftPaneWidth: { model.preferredLeftPaneWidth = $0 },
                        navTabsCollapsed: model.navTabsCollapsed, onToggleNavTabsCollapse: { model.navTabsCollapsed = $0 },
                        listActions: actions)
    }

    /// LeftPaneComposeHelper over SignalCore's composable list, filtered by the search term
    /// (upstream filterAndSortConversations: title, number or username contains the term).
    /// The compose screen for the current mode.
    var composeModeHelper: any LeftPaneHelper {
        let term = session.composeSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let contacts = session.composable.filter { $0.kind == .private && !isMe($0) && $0.serviceId != nil }
        func item(_ c: ConversationSummary) -> ContactListItemData { ContactListItemData(id: c.id, title: title(c), avatar: avatar(c)) }
        // Chosen members: contacts, and people found by number or username.
        let selected = session.groupSelection.compactMap { id -> ContactListItemData? in
            if let c = contacts.first(where: { $0.id == id }) { return item(c) }
            return session.groupLookups.first { $0.conversationId == id }.map { l in
                ContactListItemData(id: l.conversationId, title: session.contactTitle(l.serviceId) == l.serviceId ? l.title : session.contactTitle(l.serviceId),
                                    avatar: ConversationAvatarData(title: l.title, color: session.contactColor(l.serviceId)))
            }
        }
        let rawTerm = session.composeSearch.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let termIsUsername = rawTerm.range(of: #"^[A-Za-z_][A-Za-z0-9_]{2,31}\.[0-9]{2,9}$"#, options: .regularExpression) != nil
        switch session.composeMode {
        case .compose:
            return composeHelper
        case .chooseGroupMembers:
            let matches = contacts.filter { term.isEmpty || title($0).lowercased().contains(term) || ($0.e164 ?? "").contains(term) }
            return LeftPaneChooseGroupMembersHelper(candidateContacts: matches.map(item), selectedContacts: selected, searchTerm: session.composeSearch,
                                                    regionCode: session.phoneRegion, username: termIsUsername ? rawTerm : nil,
                                                    uuidFetchState: Set([session.groupLookupFetching].compactMap { $0 }),
                                                    selectedE164s: Set(session.groupLookups.compactMap(\.e164)),
                                                    selectedUsernames: Set(session.groupLookups.compactMap(\.username)))
        case .setGroupMetadata:
            return LeftPaneSetGroupMetadataHelper(groupName: session.newGroupName, groupExpireTimer: session.newGroupTimer, isCreating: session.isCreatingGroup,
                                                  selectedContacts: selected, onChangeGroupName: { session.newGroupName = $0 },
                                                  onChangeExpireTimer: { session.newGroupTimer = $0 },
                                                  onEditAvatar: { session.isEditingNewGroupAvatar = true },
                                                  groupAvatar: session.newGroupAvatarPreview)
        case .findByUsername:
            return LeftPaneFindByUsernameHelper(searchTerm: session.composeSearch, isFetching: session.isLookingUp,
                                                doLookup: { session.lookUpUsername(session.composeSearch) })
        case .findByPhoneNumber:
            let region = session.phoneRegion, selected = session.composeSelectedRegion
            return LeftPaneFindByPhoneNumberHelper(searchTerm: session.composeSearch, regionCode: region, selectedRegion: selected,
                                                   isFetching: session.isLookingUp, doLookup: {
                if let p = PhoneNumberParsing.parse(session.composeSearch, regionCode: selected ?? region) { session.lookUpPhoneNumber(p) }
            }, onShowCountryModal: { session.isChoosingCountry = true })
        }
    }

    var composeHelper: LeftPaneComposeHelper {
        let term = session.composeSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = session.composable.filter { c in
            term.isEmpty || title(c).lowercased().contains(term) || (c.e164 ?? "").contains(term)
        }
        let contacts = matches.filter { $0.kind == .private }.map { c in
            ContactListItemData(id: c.id, title: title(c), isMe: isMe(c), avatar: avatar(c))
        }
        let groups = matches.filter { $0.kind == .group }.map { c in
            GroupListItemData(id: c.id, title: c.title, membersCount: c.membersCount, avatar: avatar(c))
        }
        // A term shaped like a username (name.digits) offers a lookup row; numbers parse in our region.
        let raw = session.composeSearch.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let looksLikeUsername = raw.range(of: #"^[A-Za-z_][A-Za-z0-9_]{2,31}\.[0-9]{2,9}$"#, options: .regularExpression) != nil
        return LeftPaneComposeHelper(composeContacts: contacts, composeGroups: groups, searchTerm: session.composeSearch, regionCode: session.phoneRegion,
                                     username: looksLikeUsername ? raw : nil, contactE164s: Set(session.composable.compactMap(\.e164)))
    }

    func isMe(_ c: ConversationSummary) -> Bool { c.kind == .private && c.serviceId != nil && c.serviceId == session.ourAci }
    func title(_ c: ConversationSummary) -> String { isMe(c) ? i18n("icu:noteToSelf") : c.title }
    func avatar(_ c: ConversationSummary) -> ConversationAvatarData {
        var a = ConversationAvatarData(title: title(c), conversationType: c.kind == .group ? .group : .direct, color: c.color,
                                       image: isMe(c) ? nil : session.avatarImage(c.avatar))
        a.noteToSelf = isMe(c)
        return a
    }

    /// LeftPaneChatFolders over SignalCore's folders, with per-folder unread and mute stats.
    func folderItem(_ f: SignalCore.ChatFolder, position i: Int) -> SignalUI.ChatFolder {
        SignalUI.ChatFolder(id: f.id, folderType: f.folderType == .all ? .all : .custom, name: f.name, position: i,
                            preset: ChatFolderPreset(showOnlyUnread: f.showOnlyUnread, showMutedChats: f.showMutedChats,
                                                     includeAllIndividualChats: f.includeAllIndividualChats, includeAllGroupChats: f.includeAllGroupChats,
                                                     includedConversationIds: f.includedConversationIds, excludedConversationIds: f.excludedConversationIds))
    }

    var folderBar: some View {
        let folders = session.chatFolders.enumerated().map { i, f in folderItem(f, position: i) }
        var unread: [String: UnreadStats] = [:]
        var muted: [String: MutedStats] = [:]
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for f in session.chatFolders {
            let members = session.conversations.filter { ChatFolderStore.contains(f, $0.folderProps, ignoreShowOnlyUnread: true, ignoreShowMutedChats: true) }
            let unreadOnes = members.filter { $0.unreadCount > 0 || $0.folderProps.markedUnread }
            unread[f.id] = UnreadStats(unreadCount: members.reduce(0) { $0 + $1.unreadCount }, unreadChatsCount: unreadOnes.count,
                                       unreadMentionsCount: members.reduce(0) { $0 + $1.folderProps.unreadMentionsCount },
                                       readChatsMarkedUnreadCount: members.filter { $0.unreadCount == 0 && $0.folderProps.markedUnread }.count)
            let mutedCount = members.filter { $0.folderProps.muteExpiresAt > now }.count
            muted[f.id] = MutedStats(chatsMutedCount: mutedCount, chatsUnmutedCount: members.count - mutedCount)
        }
        return LeftPaneChatFolders(folders: folders, selectedChatFolderId: session.selectedChatFolderId ?? session.chatFolders.first?.id,
                                   unreadStats: unread, mutedStats: muted,
                                   onSelectedChatFolderIdChange: { session.selectedChatFolderId = $0 },
                                   onChatFolderMarkRead: { session.markFolderRead($0) },
                                   onChatFolderUpdateMute: { session.muteFolder($0, $1) },
                                   onChatFolderOpenSettings: { _ in model.selectedTab = .settings })
    }

    struct ListRow {
        var data: ConversationListItemData
        var isArchivedRow: Bool
        var isPinnedRow: Bool
    }

    /// The notification profile submenu: turn one on (for an hour, until tomorrow…) or off.
    var notificationProfilesMenu: some View {
        let state = session.notificationProfiles
        return NotificationProfilesMenu(activeProfileId: state.activeProfileId,
                                        allProfiles: state.profiles.map { NotificationProfileSummary(id: $0.id, name: $0.name, emoji: $0.emoji, color: $0.color) },
                                        enabledOverrideEndsAt: state.enabledOverrideEndsAt.map(Date.init(milliseconds:)),
                                        onGoToSettings: {
                                            model.settingsPage = .notifications
                                            model.selectedTab = .settings
                                        },
                                        setProfileOverride: { id, enabled, endsAt in session.setNotificationProfileOverride(id, enabled: enabled, endsAt: endsAt) })
    }

    /// MessageSearchResult for a hit: from (the author), to (the chat), the snippet.
    func searchResult(_ h: MessageSearchHit) -> some View {
        let chat = session.conversation(h.conversationId)
        let chatData = chat.map { listItem($0).data }
        let from: MessageSearchResultPerson = h.outgoing
            ? MessageSearchResultPerson(title: i18n("icu:you"), isMe: true)
            : MessageSearchResultPerson(title: session.contactTitle(h.author),
                                        avatar: ConversationAvatarData(title: session.contactTitle(h.author), conversationType: .direct,
                                                                       color: session.contactColor(h.author),
                                                                       image: session.avatarImage(h.author.flatMap { session.contacts[$0]?.avatar })))
        let to = chatData.map { MessageSearchResultPerson(title: $0.title, isMe: $0.isMe, type: $0.type, avatar: $0.avatar) }
        return MessageSearchResult(id: h.id, conversationId: h.conversationId, from: from, to: to, sentAt: Date(milliseconds: h.sentAt),
                                   snippet: h.snippet, body: h.body,
                                   showConversation: { c, m in session.openSearchResult(conversationId: c, messageId: m) })
    }

    func listItem(_ c: ConversationSummary) -> ListRow {
        let isMe = c.kind == .private && c.serviceId != nil && c.serviceId == session.ourAci
        let title = isMe ? i18n("icu:noteToSelf") : c.title
        var avatar = ConversationAvatarData(title: title, conversationType: c.kind == .group ? .group : .direct, color: c.color,
                                            image: isMe ? nil : session.avatarImage(c.avatar))
        avatar.noteToSelf = isMe
        let last = c.lastMessage.map { m in
            ConversationListItemData.LastMessage(text: m.isDeleted ? i18n("icu:message--deletedForEveryone") : Self.previewText(m, i18n),
                                                 status: m.status.map(Self.listStatus), deletedForEveryone: m.isDeleted,
                                                 isOutgoing: m.direction == .outgoing)
        }
        var d = ConversationListItemData(id: c.id, title: title, type: c.kind == .group ? .group : .direct, isMe: isMe,
                                         isSelected: c.id == session.selectedConversationId, acceptedMessageRequest: c.isAccepted, avatar: avatar, lastMessage: last,
                                         lastUpdated: c.activeAt.map { Date(milliseconds: $0) }, unreadCount: c.unreadCount)
        d.isMe = isMe
        d.markedUnread = c.folderProps.markedUnread
        d.isSomeoneTyping = session.isSomeoneTyping(c.id)
        // A draft shows ("Draft: …") in every row but the open chat's (upstream shouldShowDraft).
        if let draft = c.draft, c.id != session.selectedConversationId {
            d.shouldShowDraft = true
            d.draftPreview = ComposerController.displayText(body: draft, ranges: session.draftRanges(c))    // mentions as "@name"
            if let t = c.draftTimestamp {
                d.draftTimestamp = Date(milliseconds: t)
                if t > c.activeAt ?? 0 { d.lastUpdated = Date(milliseconds: t) }
            }
        }
        if c.folderProps.muteExpiresAt > Int64(Date().timeIntervalSince1970 * 1000) { d.muteExpiresAt = Date(milliseconds: c.folderProps.muteExpiresAt) }
        return ListRow(data: d, isArchivedRow: c.isArchived, isPinnedRow: c.isPinned)
    }

    /// getNotificationTextForMessage: the body, or "{emoji} {text}" for what the message carries.
    static func previewText(_ m: TimelineMessage, _ i18n: Localizer) -> String {
        func with(_ emoji: String, _ key: String) -> String {
            i18n("icu:message--getNotificationText--text-with-emoji", ["emoji": .string(emoji), "text": .string(m.body.isEmpty ? i18n(key) : m.body)])
        }
        // A poll: "Poll: {question}" (upstream's poll preview).
        if let poll = m.poll { return i18n("icu:Poll--preview", ["pollQuestion": .string(poll.question)]) }
        switch m.content {
        case .text: return m.body
        case .gif: return with("🎡", "icu:message--getNotificationText--gif")
        case .photo: return with("📷", "icu:message--getNotificationText--photo")
        case .video: return with("🎥", "icu:message--getNotificationText--video")
        case .voiceMessage: return with("🎤", "icu:message--getNotificationText--voice-message")
        case .audio: return with("🔈", "icu:message--getNotificationText--audio-message")
        case .file: return with("📎", "icu:message--getNotificationText--file")
        case .sticker(let emoji):
            return emoji.map { i18n("icu:message--getNotificationText--text-with-emoji", ["emoji": .string($0), "text": .string(i18n("icu:message--getNotificationText--stickers"))]) }
                ?? i18n("icu:message--getNotificationText--stickers")
        }
    }

    static func listStatus(_ s: TimelineMessage.Status) -> LastMessageStatus {
        switch s {
        case .pending: .sending
        case .sent: .sent
        case .delivered: .delivered
        case .read: .read
        case .viewed: .viewed
        case .failed: .error
        }
    }

    /// The Calls tab: the call history (CallHistoryStore groups, live), searched and filtered to
    /// missed calls; new calls to accepted chats; calling from a row or the new-call list.
    var callsTab: some View {
        let q = model.callsHistoryQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let items = session.callHistory.compactMap { g -> CallsListItem? in
            let group = CallHistoryGroup(type: SignalUI.CallType(rawValue: g.type.rawValue) ?? .unknown,
                                         direction: SignalUI.CallDirection(rawValue: g.direction.rawValue) ?? .unknown,
                                         status: SignalUI.CallStatus(rawValue: g.status.rawValue) ?? .unknown, timestamp: Date(milliseconds: g.timestamp),
                                         children: g.calls.map { .init(callId: $0.callId, timestamp: Date(milliseconds: $0.timestamp)) })
            // A call link's row: its name (else "Signal Call").
            if g.mode == .adhoc {
                guard let link = session.callLink(g.peerId) else { return nil }
                let conv = CallingConversation(id: link.roomId, title: session.callLinkTitle(link, i18n("icu:calling__call-link-default-title")),
                                               color: "A200", conversationType: .callLink)
                return CallsListItem(id: "\(g.peerId)|\(g.calls.first?.callId ?? "")", peerId: link.roomId, group: group, conversation: conv,
                                     isInCall: session.activeCall?.conversationId == link.roomId)
            }
            guard let c = session.callPeer(g.peerId, mode: g.mode) else { return nil }
            let conv = CallingConversation(id: c.id, title: title(c), color: c.color, avatar: session.avatarImage(c.avatar),
                                           conversationType: c.kind == .group ? .group : .direct, aci: c.serviceId)
            let _ = CallHistoryGroup(type: SignalUI.CallType(rawValue: g.type.rawValue) ?? .unknown,
                                         direction: SignalUI.CallDirection(rawValue: g.direction.rawValue) ?? .unknown,
                                         status: SignalUI.CallStatus(rawValue: g.status.rawValue) ?? .unknown, timestamp: Date(milliseconds: g.timestamp),
                                         children: g.calls.map { .init(callId: $0.callId, timestamp: Date(milliseconds: $0.timestamp)) })
            return CallsListItem(id: "\(g.peerId)|\(g.calls.first?.callId ?? "")", peerId: c.id, group: group, conversation: conv,
                                 isInCall: session.activeCall?.conversationId == c.id)
        }.filter { item in
            (q.isEmpty || item.conversation.title.lowercased().contains(q))
                && (!model.callsMissedOnly || item.group.status == .missed || item.group.status == .missedNotificationProfile)
        }
        let nq = model.newCallQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let people = session.conversations.filter { $0.isAccepted && !isMe($0) && (nq.isEmpty || title($0).lowercased().contains(nq)) }.map { c in
            CallsNewCallConversation(conversation: CallingConversation(id: c.id, title: title(c), color: c.color, avatar: session.avatarImage(c.avatar),
                                                                       conversationType: c.kind == .group ? .group : .direct, aci: c.serviceId),
                                     isGroup: c.kind == .group)
        }
        return CallsTab(preferredLeftPaneWidth: model.preferredLeftPaneWidth, navTabsCollapsed: model.navTabsCollapsed, hasAnyAdminCallLinks: session.callLinks.contains(where: \.isAdmin),
                        hasActiveCall: session.activeCall != nil, callsListItems: items, historyQuery: $model.callsHistoryQuery,
                        missedOnly: $model.callsMissedOnly, newCallConversations: people, newCallQuery: $model.newCallQuery, actions: {
                            var a = CallsTabActions()
                            a.onToggleNavTabsCollapse = { model.navTabsCollapsed = $0 }
                            a.savePreferredLeftPaneWidth = { model.preferredLeftPaneWidth = $0 }
                            a.onCall = { item in
                                if item.conversation.conversationType == .callLink {
                                    session.openCallLinkLobby(item.peerId)
                                } else {
                                    session.openCallLobby(item.peerId, video: item.group.type == .video || item.conversation.conversationType == .group)
                                }
                            }
                            a.onCreateCallLink = { session.createCallLink() }
                            a.onOutgoingAudioCallInConversation = { session.openCallLobby($0, video: false) }
                            a.onOutgoingVideoCallInConversation = { session.openCallLobby($0, video: true) }
                            a.onClearCallHistory = { session.clearCallHistory() }
                            a.onMarkCallHistoryRead = { id, _ in session.markCallHistoryRead(id) }
                            return a
                        }()) { roomId, group, close in
            callLinkDetails(roomId, group, close)
        } renderConversationDetails: { _, _ in
            EmptyView()
        }
        .task { session.observeCallHistory() }
    }

    /// CallLinkEditModal (after creating a link), CallLinkAddNameModal, and the screen-recording
    /// permission modal.
    @ViewBuilder var callLinkModal: some View {
        switch session.callLinkModal {
        case .edit(let roomId)?:
            if let link = session.callLink(roomId) {
                AxoBaseDialog.Host {
                    CallLinkEditModal(callLink: session.callLinkInfo(link), hasActiveCall: session.activeCall != nil,
                                      onClose: { session.callLinkModal = nil }, onCopyCallLink: { session.copyCallLink(roomId) },
                                      onOpenCallLinkAddNameModal: { session.callLinkModal = .addName(roomId: roomId) },
                                      onUpdateCallLinkRestrictions: { session.setCallLinkApproval(roomId, $0) },
                                      onShareCallLinkViaSignal: {
                                          session.shareCallLinkViaSignal(roomId) { i18n("icu:ShareCallLinkViaSignal__DraftMessageText", ["url": .string($0)]) }
                                      },
                                      onStartCallLinkLobby: { session.openCallLinkLobby(roomId) })
                }
            }
        case .addName(let roomId)?:
            if let link = session.callLink(roomId) {
                AxoBaseDialog.Host {
                    CallLinkAddNameModal(callLink: session.callLinkInfo(link), onClose: { session.callLinkModal = .edit(roomId: roomId) },
                                         onUpdateCallLinkName: { name in
                                             session.renameCallLink(roomId, name)
                                             session.callLinkModal = .edit(roomId: roomId)
                                         })
                }
            }
        case .needsScreenRecordingPermission?:
            AxoBaseDialog.Host { NeedsScreenRecordingPermissionsModal(toggleScreenRecordingPermissionsDialog: { _ in session.callLinkModal = nil }) }
        case nil:
            EmptyView()
        }
    }

    /// A call link's details (the Calls tab's right side).
    func callLinkDetails(_ roomId: String, _ group: CallHistoryGroup, _ close: @escaping () -> Void) -> some View {
        let link = session.callLink(roomId)
        return CallLinkDetails(callLink: link.map(session.callLinkInfo), callHistoryGroup: group,
                               isInCall: session.activeCall?.conversationId == roomId,
                               isInAnotherCall: session.activeCall != nil && session.activeCall?.conversationId != roomId,
                               onDeleteCallLink: {
                                   session.deleteCallLink(roomId)
                                   close()
                               },
                               onOpenCallLinkAddNameModal: { session.callLinkModal = .addName(roomId: roomId) },
                               onStartCallLinkLobby: { session.openCallLinkLobby(roomId) },
                               onShareCallLinkViaSignal: { session.shareCallLinkViaSignal(roomId) { i18n("icu:ShareCallLinkViaSignal__DraftMessageText", ["url": .string($0)]) } },
                               onCopyCallLink: { _ in session.copyCallLink(roomId) },
                               onUpdateCallLinkRestrictions: { session.setCallLinkApproval(roomId, $0) })
    }

    func title(_ tab: NavTab) -> String {
        switch tab {
        case .chats: i18n("icu:LeftPane--chats")
        case .calls: i18n("icu:CallsTab__HeaderTitle--CallsList")
        case .stories: i18n("icu:Stories__title")
        case .settings: i18n("icu:Preferences--header")
        }
    }
}

/// Chromium page zoom: the content lays out in a viewport of size / factor and is scaled up.
struct Zoomed<Content: View>: View {
    let factor: CGFloat
    @ViewBuilder let content: Content
    var body: some View {
        GeometryReader { geo in
            content
                .frame(width: geo.size.width / factor, height: geo.size.height / factor)
                .scaleEffect(factor, anchor: .topLeading)
        }
    }
}
