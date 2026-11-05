// LeftPane (ts/components/LeftPane.dom.tsx, `.module-left-pane` in stylesheets/_modules.scss):
// the Chats tab's NavSidebar: header actions (compose, more), the mode's header and search
// input, the banners (red / update / yellow dialogs, username banner), chat folders, and the
// ConversationList filled by the mode's LeftPaneHelper (Inbox, Search, Archive, Compose,
// ChooseGroupMembers, FindByUsername, FindByPhoneNumber, SetGroupMetadata).

import SignalI18n
import SwiftUI

/// What a LeftPaneMode contributes (ts/components/leftPane/LeftPaneHelper.dom.tsx).
@MainActor public protocol LeftPaneHelper {
    func headerContents(_ ctx: LeftPaneContext) -> AnyView?
    func searchInput(_ ctx: LeftPaneContext) -> AnyView?
    func backAction(_ ctx: LeftPaneContext) -> (() -> Void)?
    func emptyView(_ ctx: LeftPaneContext) -> AnyView?
    func preRows(_ ctx: LeftPaneContext) -> AnyView?
    func footer(_ ctx: LeftPaneContext) -> AnyView?
    /// The list rows (header texts come from `i18n`, upstream's `getHeaderText(i18n)`).
    func rows(_ i18n: Localizer) -> [ConversationListRow]
    var isScrollable: Bool { get }
    var requiresFullWidth: Bool { get }
    /// Modes other than Inbox hide the NavSidebar header (and the dialogs).
    var hidesHeader: Bool { get }
    var isInbox: Bool { get }
    /// `module-left-pane--mode-compose` / `--mode-choose-group-members`: list tiles extend
    /// to the edges.
    var listExtendsToEdges: Bool { get }
}

extension LeftPaneHelper {
    public func headerContents(_ ctx: LeftPaneContext) -> AnyView? { nil }
    public func searchInput(_ ctx: LeftPaneContext) -> AnyView? { nil }
    public func backAction(_ ctx: LeftPaneContext) -> (() -> Void)? { nil }
    public func emptyView(_ ctx: LeftPaneContext) -> AnyView? { nil }
    public func preRows(_ ctx: LeftPaneContext) -> AnyView? { nil }
    public func footer(_ ctx: LeftPaneContext) -> AnyView? { nil }
    public var isScrollable: Bool { true }
    public var requiresFullWidth: Bool { true }
    public var hidesHeader: Bool { true }
    public var isInbox: Bool { false }
    public var listExtendsToEdges: Bool { false }
}

/// The actions a helper's views can call (LeftPane's props, forwarded).
public struct LeftPaneContext {
    public var i18n: Localizer
    public var showInbox: () -> Void = {}
    public var startComposing: () -> Void = {}
    public var showChooseGroupMembers: () -> Void = {}
    public var showArchivedConversations: () -> Void = {}
    public var clearSearchQuery: () -> Void = {}
    public var clearConversationSearch: () -> Void = {}
    public var endConversationSearch: () -> Void = {}
    public var endSearch: () -> Void = {}
    public var updateSearchTerm: (String) -> Void = { _ in }
    public var updateFilterByUnread: (Bool) -> Void = { _ in }
    public var renderLeftPaneChatFolders: () -> AnyView = { AnyView(EmptyView()) }
    public var removeSelectedContact: (String) -> Void = { _ in }
    public var startSettingGroupMetadata: () -> Void = {}
    public var createGroup: () -> Void = {}
    public init(i18n: Localizer) { self.i18n = i18n }
}

/// The banner inputs: which dialogs to show and how to render each (LeftPane's has*Dialog
/// flags and render* props).
public struct LeftPaneDialogs {
    public var unsupportedOSDialogType: LeftPaneDialogType?
    public var hasNetworkDialog = false
    public var hasRelinkDialog = false
    public var hasUpdateDialog = false
    public var isUpdateDownloaded = false
    public var hasExpiredDialog = false
    public var hasClockSkewDialog = false
    public var serverAlert: AnyView?
    public var usernameCorrupted = false
    public var usernameLinkCorrupted = false
    public var renderUnsupportedOSDialog: (LeftPaneDialogType, WidthBreakpoint) -> AnyView = { _, _ in AnyView(EmptyView()) }
    public var renderNetworkStatus: (WidthBreakpoint) -> AnyView = { _ in AnyView(EmptyView()) }
    public var renderRelinkDialog: (WidthBreakpoint) -> AnyView = { _ in AnyView(EmptyView()) }
    public var renderUpdateDialog: (WidthBreakpoint) -> AnyView = { _ in AnyView(EmptyView()) }
    public var renderExpiredBuildDialog: (WidthBreakpoint) -> AnyView = { _ in AnyView(EmptyView()) }
    public var renderClockSkewDialog: (WidthBreakpoint) -> AnyView = { _ in AnyView(EmptyView()) }
    public var onUsernameBanner: () -> Void = {}
    public var onUsernameLinkBanner: () -> Void = {}
    public init() {}

    /// Red first (then update, else yellow); without red: update, then yellow; then the banner.
    @MainActor func views(_ breakpoint: WidthBreakpoint, i18n: Localizer) -> [AnyView] {
        var yellow: AnyView?
        if unsupportedOSDialogType == .warning {
            yellow = renderUnsupportedOSDialog(.warning, breakpoint)
        } else if hasNetworkDialog {
            yellow = renderNetworkStatus(breakpoint)
        } else if hasRelinkDialog {
            yellow = renderRelinkDialog(breakpoint)
        } else if let serverAlert {
            yellow = serverAlert
        }
        let update = hasUpdateDialog && (!hasNetworkDialog || isUpdateDownloaded) ? renderUpdateDialog(breakpoint) : nil
        var red: AnyView?
        if unsupportedOSDialogType == .error {
            red = renderUnsupportedOSDialog(.error, breakpoint)
        } else if hasExpiredDialog {
            red = renderExpiredBuildDialog(breakpoint)
        } else if hasClockSkewDialog {
            red = renderClockSkewDialog(breakpoint)
        }
        var out: [AnyView] = []
        if let red {
            out.append(red)
            if let update { out.append(update) } else if let yellow { out.append(yellow) }
        } else {
            if let update { out.append(update) }
            if let yellow { out.append(yellow) }
        }
        if usernameCorrupted {
            out.append(AnyView(LeftPaneBanner(actionText: i18n("icu:LeftPane--corrupted-username--action-text"), onClick: onUsernameBanner,
                                              text: i18n("icu:LeftPane--corrupted-username--text"))))
        } else if usernameLinkCorrupted {
            out.append(AnyView(LeftPaneBanner(actionText: i18n("icu:LeftPane--corrupted-username-link--action-text"), onClick: onUsernameLinkBanner,
                                              text: i18n("icu:LeftPane--corrupted-username-link--text"))))
        }
        return out
    }
}

public struct LeftPane: View {
    let helper: any LeftPaneHelper
    let context: LeftPaneContext
    let dialogs: LeftPaneDialogs
    let preferredLeftPaneWidth: CGFloat
    let savePreferredLeftPaneWidth: (CGFloat) -> Void
    let navTabsCollapsed: Bool
    let onToggleNavTabsCollapse: (Bool) -> Void
    let hasFailedStorySends: Bool
    let hasPendingUpdate: Bool
    let otherTabsUnreadCount: Int
    let listActions: ConversationListActions
    @Environment(\.i18n) var i18n

    public init(helper: any LeftPaneHelper, context: LeftPaneContext, dialogs: LeftPaneDialogs = LeftPaneDialogs(),
                preferredLeftPaneWidth: CGFloat = 320, savePreferredLeftPaneWidth: @escaping (CGFloat) -> Void = { _ in },
                navTabsCollapsed: Bool = false, onToggleNavTabsCollapse: @escaping (Bool) -> Void = { _ in }, hasFailedStorySends: Bool = false,
                hasPendingUpdate: Bool = false, otherTabsUnreadCount: Int = 0, listActions: ConversationListActions = ConversationListActions()) {
        self.helper = helper
        self.context = context
        self.dialogs = dialogs
        self.preferredLeftPaneWidth = preferredLeftPaneWidth
        self.savePreferredLeftPaneWidth = savePreferredLeftPaneWidth
        self.navTabsCollapsed = navTabsCollapsed
        self.onToggleNavTabsCollapse = onToggleNavTabsCollapse
        self.hasFailedStorySends = hasFailedStorySends
        self.hasPendingUpdate = hasPendingUpdate
        self.otherTabsUnreadCount = otherTabsUnreadCount
        self.listActions = listActions
    }

    public var body: some View {
        NavSidebar(title: i18n("icu:LeftPane--chats"), hideHeader: helper.hidesHeader, hasFailedStorySends: hasFailedStorySends,
                   hasPendingUpdate: hasPendingUpdate, navTabsCollapsed: navTabsCollapsed, onToggleNavTabsCollapse: onToggleNavTabsCollapse,
                   preferredLeftPaneWidth: preferredLeftPaneWidth, requiresFullWidth: helper.requiresFullWidth,
                   savePreferredLeftPaneWidth: savePreferredLeftPaneWidth, otherTabsUnreadCount: otherTabsUnreadCount) {
            AxoIconButton.Root(label: i18n("icu:newConversation"), variant: .impliedSecondary, size: .sm, symbol: "compose",
                               action: context.startComposing)
            AxoIconButton.Root(label: i18n("icu:LeftPane__MoreActionsLabel"), variant: .impliedSecondary, size: .sm, symbol: "more")
        } content: {
            LeftPaneContent(helper: helper, context: context, dialogs: dialogs, listActions: listActions)
        }
    }
}

/// `nav.module-left-pane`
struct LeftPaneContent: View {
    let helper: any LeftPaneHelper
    let context: LeftPaneContext
    let dialogs: LeftPaneDialogs
    let listActions: ConversationListActions
    @Environment(\.i18n) var i18n
    @Environment(\.navSidebarWidthBreakpoint) var breakpoint

    var body: some View {
        let widthBreakpoint = breakpoint ?? .wide
        let dialogViews = helper.hidesHeader ? [] : dialogs.views(widthBreakpoint, i18n: i18n)
        let rows = helper.rows(i18n)
        VStack(spacing: 0) {
            if let header = helper.headerContents(context) { header }
            if widthBreakpoint == .wide || !helper.isInbox {
                // Rendered even when the mode has no search input: its 8px bottom margin stays.
                NavSidebarSearchHeader { if let search = helper.searchInput(context) { search } }
            }
            if !dialogViews.isEmpty {
                VStack(spacing: 0) { ForEach(dialogViews.indices, id: \.self) { dialogViews[$0] } }
            }
            if let pre = helper.preRows(context) { pre }
            // `__list--measure`: the list fills the rest.
            GeometryReader { geo in
                if rows.isEmpty, let empty = helper.emptyView(context) {
                    empty.frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ConversationList(width: geo.size.width, height: geo.size.height, rows: rows, hasDialogPadding: !dialogViews.isEmpty,
                                     scrollable: helper.isScrollable, extendsToEdges: helper.listExtendsToEdges, actions: listActions)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let footer = helper.footer(context) {
                HStack(spacing: 0) { Spacer(minLength: 0); footer }.padding(12)
            }
        }
    }
}

/// The Inbox helper's empty view (`flex h-full flex-col items-center justify-center gap-3`).
struct LeftPaneEmptyView<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 12) { content }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
