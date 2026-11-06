import SignalI18n
import SignalUI
import SwiftUI

/// The main window's content: `App` → `Inbox` → NavTabs + the selected tab's NavSidebar.
struct RootView: View {
    @Bindable var model: AppModel
    let i18n: Localizer

    var body: some View {
        Zoomed(factor: model.zoomFactor) {
            App(appView: model.appView, renderInstallScreen: { Rectangle().fill(AxoColor.surfacePrimary) }, renderInbox: {
                Inbox(navTabs: NavTabsState(selected: model.selectedTab, collapsed: model.navTabsCollapsed,
                                            onSelect: { model.selectedTab = $0 },
                                            onToggleCollapse: { model.navTabsCollapsed = $0 })) { tab in
                    if tab == .chats {
                        ChatsTab(selectedConversationId: nil) { leftPane } renderConversationView: { _ in EmptyView() } renderMiniPlayer: { EmptyView() }
                            .background(AxoColor.surfacePrimary)
                    } else if tab == .calls {
                        callsTab.background(AxoColor.surfacePrimary)
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
            }, renderOverlays: {
                if model.isShowingShortcutGuide {
                    ShortcutGuideModal(platform: "darwin") { model.isShowingShortcutGuide = false }
                }
            })
            .environment(\.titleBarDragAreaHeight, model.isFullScreen ? 0 : 28 / model.zoomFactor)
            .axoModalHost()
            .axoViewport()
        }
        .environment(\.i18n, i18n)
        .environment(\.layoutDirection, i18n.direction == .rightToLeft ? .rightToLeft : .leftToRight)
        .frame(minWidth: 300, minHeight: 200)
        .ignoresSafeArea()    // content runs under the hidden title bar (fullSizeContentView)
    }

    /// The Chats tab: LeftPane in Inbox mode over demo data (SignalCore is not wired in yet).
    var leftPane: some View {
        let demo = DemoData.conversations(now: Date())
        var dialogs = LeftPaneDialogs()
        dialogs.hasUpdateDialog = true
        dialogs.renderUpdateDialog = { width in
            AnyView(DialogUpdate(containerWidthBreakpoint: width, dialogType: .downloadReady, downloadSize: 30_123_456, version: "v0.1.1",
                                 currentVersion: "0.1.0"))
        }
        var actions = ConversationListActions()
        actions.onSelectConversation = { _ in }
        return LeftPane(helper: LeftPaneInboxHelper(conversations: demo.chats, archivedConversations: demo.archived,
                                                    pinnedConversations: demo.pinned),
                        context: LeftPaneContext(i18n: i18n), dialogs: dialogs,
                        preferredLeftPaneWidth: model.preferredLeftPaneWidth,
                        savePreferredLeftPaneWidth: { model.preferredLeftPaneWidth = $0 },
                        navTabsCollapsed: model.navTabsCollapsed, onToggleNavTabsCollapse: { model.navTabsCollapsed = $0 },
                        listActions: actions)
    }

    /// The Calls tab over demo call history (SignalCore's CallHistory is not wired in yet);
    /// the search and the missed filter run over the demo rows as the app's SQL query will.
    var callsTab: some View {
        let now = Date()
        let items = DemoData.calls(now: now).filter { item in
            let q = model.callsHistoryQuery.trimmingCharacters(in: .whitespaces).lowercased()
            return (q.isEmpty || item.conversation.title.lowercased().contains(q)) && (!model.callsMissedOnly || item.wasMissedForDemo)
        }
        let people = DemoData.conversations(now: now).chats.map {
            CallsNewCallConversation(conversation: CallingConversation(id: $0.id, title: $0.title, color: $0.avatar.color ?? "A100"), isGroup: false)
        }.filter { model.newCallQuery.isEmpty || $0.conversation.title.lowercased().contains(model.newCallQuery.lowercased()) }
        return CallsTab(preferredLeftPaneWidth: model.preferredLeftPaneWidth, navTabsCollapsed: model.navTabsCollapsed, hasAnyAdminCallLinks: false,
                        hasActiveCall: false, callsListItems: items, historyQuery: $model.callsHistoryQuery, missedOnly: $model.callsMissedOnly,
                        newCallConversations: people, newCallQuery: $model.newCallQuery, actions: {
                            var a = CallsTabActions()
                            a.onToggleNavTabsCollapse = { model.navTabsCollapsed = $0 }
                            a.savePreferredLeftPaneWidth = { model.preferredLeftPaneWidth = $0 }
                            return a
                        }()) { _, group, close in
            CallLinkDetails(callLink: CallLinkInfo(name: "Book club", rootKey: "bpmc-mrgn-hntf-mffd-mndd-xbxk-zmgq-qszg", isAdmin: true),
                            callHistoryGroup: group, onDeleteCallLink: close)
        } renderConversationDetails: { _, _ in
            EmptyView()
        }
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
