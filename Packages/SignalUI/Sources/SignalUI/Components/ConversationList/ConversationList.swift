// ConversationList (ts/components/ConversationList.dom.tsx, `.module-conversation-list` in
// stylesheets/_modules.scss): the virtualised list of rows in the left pane. Rows are
// upstream's RowType cases, each at its fixed height (76 normal, 52 select, 40 header).

import SignalI18n
import SwiftUI

public enum ConversationListRow {
    case archiveButton(archivedConversationsCount: Int)
    case blank
    case conversation(ConversationListItemData)
    case header(String)
    case contact(ContactListItemData, isClickable: Bool = true, hasContextMenu: Bool = false)
    case contactCheckbox(ContactListItemData, isChecked: Bool, disabledReason: ContactCheckboxDisabledReason? = nil)
    case startNewConversation(ParsedPhoneNumber, isFetching: Bool)
    case usernameSearchResult(String, isFetchingUsername: Bool)
    case searchResultsLoadingFakeHeader
    case messageSearchResult(messageId: String)
    /// The unread filter's "Clear filter" button (`isOnNoResultsPage`: aligned to the top).
    case clearFilterButton(isOnNoResultsPage: Bool)
    case createNewGroup
    case findByUsername
    case findByPhoneNumber
    case selectSingleGroup(GroupListItemData)
    case phoneNumberCheckbox(ParsedPhoneNumber, isChecked: Bool, isFetching: Bool)
    case usernameCheckbox(String, isChecked: Bool, isFetching: Bool)
    case searchResultsLoadingFakeRow
    /// A checkbox row with a round icon (the chat-folder chat types).
    case genericCheckbox(icon: GenericCheckboxRowIcon, label: String, isChecked: Bool, onClick: () -> Void)
    case emptyResults(String)

    public static let normalRowHeight: CGFloat = 76
    public static let selectRowHeight: CGFloat = 52
    public static let headerRowHeight: CGFloat = 40
    public static let emptyResultsRowHeight: CGFloat = 48 + 20 + 48

    var height: CGFloat {
        switch self {
        case .header, .searchResultsLoadingFakeHeader: Self.headerRowHeight
        case .emptyResults: Self.emptyResultsRowHeight
        case .contact, .contactCheckbox, .genericCheckbox, .createNewGroup, .findByUsername, .findByPhoneNumber, .selectSingleGroup: Self.selectRowHeight
        case .archiveButton, .blank, .conversation, .startNewConversation, .usernameSearchResult, .searchResultsLoadingFakeRow,
             .messageSearchResult, .clearFilterButton, .phoneNumberCheckbox, .usernameCheckbox:
            Self.normalRowHeight
        }
    }
}

/// The list's callbacks (ConversationList props).
public struct ConversationListActions {
    public var onClickArchiveButton: () -> Void = {}
    public var onSelectConversation: (String) -> Void = { _ in }
    public var onPreloadConversation: (String) -> Void = { _ in }
    public var onClickContactCheckbox: (String, ContactCheckboxDisabledReason?) -> Void = { _, _ in }
    public var lookupPhoneNumber: (ParsedPhoneNumber) -> Void = { _ in }
    public var showInvalidPhoneNumber: (ParsedPhoneNumber) -> Void = { _ in }
    public var lookupUsername: (String) -> Void = { _ in }
    /// `renderMessageSearchResult` (the smart MessageSearchResult for a message id).
    public var renderMessageSearchResult: (String) -> AnyView = { _ in AnyView(EmptyView()) }
    public var onClickClearFilterButton: () -> Void = {}
    /// `renderConversationListItemContextMenu`: the right-click menu for a chat row.
    public var contextMenu: ((ConversationListItemData) -> ConversationContextMenuModel)?
    public var showChooseGroupMembers: () -> Void = {}
    public var showFindByUsername: () -> Void = {}
    public var showFindByPhoneNumber: () -> Void = {}
    public var togglePhoneNumber: (ParsedPhoneNumber) -> Void = { _ in }
    public var toggleUsername: (String) -> Void = { _ in }
    public init() {}
}

public struct ConversationList: View {
    let width: CGFloat
    let height: CGFloat
    let rows: [ConversationListRow]
    let hasDialogPadding: Bool
    let scrollable: Bool
    let extendsToEdges: Bool
    let actions: ConversationListActions
    @Environment(\.axoStaticRendering) var isStatic
    @Environment(\.i18n) var i18n

    /// - Parameter extendsToEdges: compose / choose-members modes (`padding-inline: 0`).
    public init(width: CGFloat, height: CGFloat, rows: [ConversationListRow], hasDialogPadding: Bool = false, scrollable: Bool = true,
                extendsToEdges: Bool = false, actions: ConversationListActions = ConversationListActions()) {
        self.extendsToEdges = extendsToEdges
        self.width = width
        self.height = height
        self.rows = rows
        self.hasDialogPadding = hasDialogPadding
        self.scrollable = scrollable
        self.actions = actions
    }

    var breakpoint: WidthBreakpoint { WidthBreakpoint.navSidebar(width) }

    /// padding-inline: 11px, and 11px − the thin gutter at the end plus `scrollbar-gutter:
    /// stable` (Chromium's 15px classic scrollbar): 22px in all.
    static let leadingInset: CGFloat = 11
    static let trailingInset: CGFloat = 22
    static let scrollbarGutter: CGFloat = 11

    public var body: some View {
        let content = VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                row(rows[i]).frame(height: rows[i].height, alignment: .top)
            }
        }
        .padding(.top, hasDialogPadding ? 8 : 0)
        .padding(.leading, extendsToEdges ? 0 : Self.leadingInset)
        .padding(.trailing, extendsToEdges ? Self.scrollbarGutter : Self.trailingInset)
        .environment(\.conversationListWidthBreakpoint, breakpoint)
        Group {
            if isStatic || !scrollable {
                AxoDialog.TopAligned { content }.clipShape(Rectangle())
            } else {
                ScrollView { LazyVStack(spacing: 0) { content } }.scrollIndicators(.automatic)
            }
        }
        .frame(width: width, height: height)
        .accessibilityElement(children: .contain)
    }

    func row(_ row: ConversationListRow) -> some View { ConversationListRowView(row: row, actions: actions) }
}

/// One upstream row (`renderRow`), at its natural size; the list gives it the row height.
struct ConversationListRowView: View {
    let row: ConversationListRow
    let actions: ConversationListActions
    @Environment(\.i18n) var i18n

    var body: some View {
        switch row {
        case .archiveButton(let count):
            ConversationListArchiveButton(count: count, action: actions.onClickArchiveButton)
        case .blank:
            Color.clear
        case .conversation(let data):
            if let menu = actions.contextMenu {
                LeftPaneConversationListItemContextMenu(model: menu(data)) {
                    ConversationListItem(data, onClick: actions.onSelectConversation, onMouseDown: actions.onPreloadConversation)
                }
            } else {
                ConversationListItem(data, onClick: actions.onSelectConversation, onMouseDown: actions.onPreloadConversation)
            }
        case .header(let text):
            ConversationListHeader(text: text)
        case let .contact(data, isClickable, hasContextMenu):
            ContactListItem(data, hasContextMenu: hasContextMenu, onClick: isClickable ? actions.onSelectConversation : nil)
        case let .contactCheckbox(data, isChecked, disabledReason):
            ContactCheckbox(data, isChecked: isChecked, disabledReason: disabledReason) { actions.onClickContactCheckbox($0, $1) }
        case let .startNewConversation(phoneNumber, isFetching):
            StartNewConversation(phoneNumber: phoneNumber, isFetching: isFetching, lookup: actions.lookupPhoneNumber,
                                 onInvalid: actions.showInvalidPhoneNumber)
        case let .usernameSearchResult(username, isFetching):
            UsernameSearchResultListItem(username: username, isFetchingUsername: isFetching, lookup: actions.lookupUsername)
        case .searchResultsLoadingFakeHeader:
            SearchResultsLoadingFakeHeader()
        case .searchResultsLoadingFakeRow:
            SearchResultsLoadingFakeRow()
        case .messageSearchResult(let messageId):
            actions.renderMessageSearchResult(messageId)
        case .createNewGroup:
            ComposeStepButton(icon: .group, title: i18n("icu:createNewGroupButton"), onClick: actions.showChooseGroupMembers)
        case .findByUsername:
            ComposeStepButton(icon: .username, title: i18n("icu:LeftPane__compose__findByUsername"), onClick: actions.showFindByUsername)
        case .findByPhoneNumber:
            ComposeStepButton(icon: .phoneNumber, title: i18n("icu:LeftPane__compose__findByPhoneNumber"), onClick: actions.showFindByPhoneNumber)
        case let .phoneNumberCheckbox(phoneNumber, isChecked, isFetching):
            LookupCheckbox(title: phoneNumber.userInput, isChecked: isChecked, isFetching: isFetching) { actions.togglePhoneNumber(phoneNumber) }
        case let .usernameCheckbox(username, isChecked, isFetching):
            LookupCheckbox(title: username, isChecked: isChecked, isFetching: isFetching) { actions.toggleUsername(username) }
        case .selectSingleGroup(let group):
            GroupListItem(group: group, onSelectGroup: actions.onSelectConversation)
        case .clearFilterButton(let isOnNoResultsPage):
            ClearFilterButton(isOnNoResultsPage: isOnNoResultsPage, action: actions.onClickClearFilterButton)
        case let .genericCheckbox(icon, label, isChecked, onClick):
            ListTileCheckbox(isChecked: isChecked, onClick: onClick) {
                GenericCheckboxIcon(icon: icon)
            } title: {
                CSSText(label, style: ListTile<EmptyView, EmptyView, EmptyView, EmptyView>.titleStyle, wrap: .clamp(1))
            } subtitle: { EmptyView() }
        case .emptyResults(let message):
            // `.module-conversation-list__empty-results`: centred, padding 48px 12px.
            CSSText(message, style: LegacyType.body1(), alignment: .center)
                .padding(.vertical, 48).padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
        }
    }
}

public enum GenericCheckboxRowIcon: Sendable { case contact, group }

/// `.module-conversation-list__generic-checkbox-icon`: a 20px glyph in a 32px tinted circle.
struct GenericCheckboxIcon: View {
    let icon: GenericCheckboxRowIcon
    var body: some View {
        SignalIcon(icon == .contact ? "v3/person/person" : "v3/group/group", size: 20, color: AxoColor(light: LegacyColor.black, dark: LegacyColor.gray05))
            .frame(width: 32, height: 32)
            .background(Circle().fill(AxoColor(light: LegacyColor.blackAlpha06, dark: LegacyColor.whiteAlpha12)))
    }
}

extension EnvironmentValues {
    /// `.module-conversation-list--width-narrow`
    @Entry var conversationListWidthBreakpoint: WidthBreakpoint = .wide
}

/// `.module-conversation-list__item--archive-button`
struct ConversationListArchiveButton: View {
    let count: Int
    let action: () -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.conversationListWidthBreakpoint) var breakpoint
    @State private var hovered = false

    var body: some View {
        let narrow = breakpoint == .narrow
        let color = AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25)
        SwiftUI.Button(action: action) {
            HStack(spacing: 0) {
                SignalIcon("v3/archive/archive", size: 24, color: color)
                    .frame(width: 24, height: 24)
                    .padding(narrow ? 12 : 0)
                if !narrow {
                    CSSText(i18n("icu:archivedConversations"), style: LegacyType.body1(weight: 600), wrap: .nowrap, color: color)
                        .padding(.horizontal, 8)
                    CSSText(String(count), style: LegacyType.body2(weight: 600), wrap: .nowrap, color: color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 10).fill(AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray75)))
                }
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .background { if hovered { RoundedRectangle(cornerRadius: 10).fill(AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray75)) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(i18n("icu:archivedConversations"))
    }
}

/// `.ClearFilterButton`: a pill LegacyButton, centred (top-aligned on the no-results page).
struct ClearFilterButton: View {
    let isOnNoResultsPage: Bool
    let action: () -> Void
    @Environment(\.i18n) var i18n

    /// `color.mix(gray-04, white, 15%)` / `color.mix(gray-80, gray-65, 40%)`
    static var background: AxoColor {
        AxoColor(light: RGBA.mix(LegacyColor.gray04, LegacyColor.white, 0.15), dark: RGBA.mix(LegacyColor.gray80, LegacyColor.gray65, 0.4))
    }

    var body: some View {
        LegacyButton(i18n("icu:clearFilterButton"), variant: .secondaryAffirmative,
                     overrides: .init(paddingBlock: 5, background: Self.background, paddingInline: 15, radius: 50,
                                      textColor: AxoColor(light: LegacyColor.black, dark: LegacyColor.white)), action: action)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isOnNoResultsPage ? .top : .center)
    }
}

/// `.module-conversation-list__item--header`: bold text at the bottom of a 40px row.
struct ConversationListHeader: View {
    let text: String
    @Environment(\.conversationListWidthBreakpoint) var breakpoint

    var body: some View {
        if breakpoint == .narrow {
            // A 48×2 rule (margin 19px 0 19px 14px) in place of the text.
            RoundedRectangle(cornerRadius: 1).fill(AxoColor(light: LegacyColor.blackAlpha12, dark: LegacyColor.whiteAlpha12))
                .frame(width: 48, height: 2)
                .padding(.vertical, 19)
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(text)
        } else {
            CSSText(text, style: LegacyType.body1(weight: 600), wrap: .truncate)
                .cssTextColor(AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05))
                .padding(.leading, 16)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .accessibilityLabel(text)
                .accessibilityAddTraits(.isHeader)
        }
    }
}
