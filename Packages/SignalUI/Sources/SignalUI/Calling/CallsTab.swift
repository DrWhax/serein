// Ports of ts/components/CallsTab.dom.tsx, CallsList.dom.tsx and CallsNewCallButton.dom.tsx
// (+ CallsTab.scss): the Calls tab's sidebar — the call history ("Create a call link", the
// search and the missed-calls filter, one row per call history group with its call / join
// button), or the new-call picker (contacts then groups) — beside the selected call's
// details or the empty state. The history search runs in the app (SQL); the list shows what
// it returns.

import SignalI18n
import SwiftUI

/// One call history group as the Calls list shows it, resolved by the app.
public struct CallsListItem: Sendable, Hashable, Identifiable {
    public var id: String
    /// The conversation id, or the call link's room id (`type == .adhoc`).
    public var peerId: String
    public var group: CallHistoryGroup
    public var conversation: CallingConversation
    public var isMutedForCalls: Bool
    /// Direct / group: the conversation was terminated. Call links: the link is unknown.
    public var canCall: Bool
    /// The call is active on the server, with somebody in it.
    public var isAnybodyInCall: Bool
    /// We are in this call.
    public var isInCall: Bool

    public init(id: String, peerId: String, group: CallHistoryGroup, conversation: CallingConversation, isMutedForCalls: Bool = false,
                canCall: Bool = true, isAnybodyInCall: Bool = false, isInCall: Bool = false) {
        self.id = id
        self.peerId = peerId
        self.group = group
        self.conversation = conversation
        self.isMutedForCalls = isMutedForCalls
        self.canCall = canCall
        self.isAnybodyInCall = isAnybodyInCall
        self.isInCall = isInCall
    }

    var wasMissed: Bool { group.direction == .incoming && group.status == .missed }
    var wasDeclined: Bool { group.direction == .incoming && group.status == .declined }
}

/// `CallsTabSelectedView`
public enum CallsTabSelectedView: Sendable, Hashable {
    case conversation(conversationId: String, callHistoryGroup: CallHistoryGroup?)
    case callLink(roomId: String, callHistoryGroup: CallHistoryGroup)

    var callHistoryGroup: CallHistoryGroup? {
        switch self {
        case .conversation(_, let g): g
        case .callLink(_, let g): g
        }
    }
}

/// `CallsNewCallButton`: a 20px phone / video glyph, or "Join" / "Return" on a green pill
/// when the call is active; dimmed while in another call.
public struct CallsNewCallButton: View {
    let callType: CallType
    let isActive: Bool
    let isEnabled: Bool
    let isInCall: Bool
    let onClick: () -> Void
    @State var hovered = false
    @Environment(\.i18n) var i18n

    public init(callType: CallType, isActive: Bool, isEnabled: Bool, isInCall: Bool, onClick: @escaping () -> Void) {
        self.callType = callType
        self.isActive = isActive
        self.isEnabled = isEnabled
        self.isInCall = isInCall
        self.onClick = onClick
    }

    public var body: some View {
        let white = AxoColor(light: LegacyColor.white, dark: LegacyColor.white)
        Button(action: onClick) {
            if isActive {
                // mixins.button-active-call: accent green, 16px video glyph, body-2 bold.
                HStack(spacing: 4) {
                    SignalIcon("v3/video/video-compact-fill", size: 16, color: white, mask: true).frame(width: 16, height: 16)
                    CSSText(i18n(isInCall ? "icu:CallsNewCallButton--return" : "icu:joinOngoingCall"), style: LegacyType.body2(weight: 600),
                            wrap: .nowrap, color: white)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(rgba: hovered && isEnabled
                    ? RGBA.mix(LegacyColor.accentGreen, LegacyColor.black, 0.75) : LegacyColor.accentGreen)))
            } else {
                SignalIcon(callType == .audio ? "v3/phone/phone" : "v3/video/video", size: 20,
                           color: AxoColor(light: LegacyColor.black, dark: LegacyColor.gray15), mask: true)
                    .frame(width: 20, height: 20)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(rgba: hovered && isEnabled ? LegacyColor.gray20 : RGBA(0, 0, 0, 0))))
                    .opacity(isEnabled ? 1 : 0.5)
            }
        }
        .buttonStyle(UndimmedButtonStyle())
        .opacity(isActive && !isEnabled ? 0.5 : 1)
        .onHover { hovered = $0 }
        .accessibilityLabel(isActive ? "" : i18n(callType == .audio ? "icu:makeOutgoingCall" : "icu:makeOutgoingVideoCall"))
        .help(isEnabled ? "" : i18n("icu:calling__in-another-call-tooltip"))
    }
}

/// `.ListTile.CallsList__ItemTile`: a ListTile with 10px block padding, 12px corners and the
/// selection fill.
struct CallsListTile<Leading: View, Title: View, Subtitle: View, Trailing: View>: View {
    let selected: Bool
    let onClick: (() -> Void)?
    @ViewBuilder let leading: Leading
    @ViewBuilder let title: Title
    @ViewBuilder let subtitle: Subtitle
    @ViewBuilder let trailing: Trailing
    @State var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            leading.padding(.trailing, 12)
            VStack(alignment: .leading, spacing: 0) {
                title.frame(maxWidth: .infinity, alignment: .leading).frame(height: 20, alignment: .topLeading).clipped()
                subtitle.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            trailing.padding(.leading, 12)
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 12).fill(AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray65))
            } else if hovered && onClick != nil {
                RoundedRectangle(cornerRadius: 12).fill(AxoColor(light: LegacyColor.blackAlpha06, dark: LegacyColor.whiteAlpha06))
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { onClick?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

public struct CallsList: View {
    /// nil while the search is pending (loading rows are shown).
    let items: [CallsListItem]?
    @Binding var query: String
    @Binding var missedOnly: Bool
    let hasActiveCall: Bool
    let selected: CallHistoryGroup?
    let onCreateCallLink: () -> Void
    let onSelect: (CallsTabSelectedView) -> Void
    let onCall: (CallsListItem) -> Void
    let onRowAppear: (CallsListItem) -> Void
    @Environment(\.i18n) var i18n

    /// - Parameters:
    ///   - onCall: the row's call button (the app decides: PiP when in this call, the
    ///     leave-call confirmation when in another, else the lobby / an outgoing call).
    ///   - onRowAppear: a row scrolled into view (the app peeks visible group calls and call links).
    public init(items: [CallsListItem]?, query: Binding<String>, missedOnly: Binding<Bool>, hasActiveCall: Bool, selected: CallHistoryGroup?,
                onCreateCallLink: @escaping () -> Void, onSelect: @escaping (CallsTabSelectedView) -> Void,
                onCall: @escaping (CallsListItem) -> Void, onRowAppear: @escaping (CallsListItem) -> Void = { _ in }) {
        self.items = items
        _query = query
        _missedOnly = missedOnly
        self.hasActiveCall = hasActiveCall
        self.selected = selected
        self.onCreateCallLink = onCreateCallLink
        self.onSelect = onSelect
        self.onCall = onCall
        self.onRowAppear = onRowAppear
    }

    enum Row: Hashable {
        case createCallLink, emptyState, filterHeader, clearFilterButton, loading(Int), item(CallsListItem)
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var filtering: Bool { !trimmedQuery.isEmpty || missedOnly }

    var rows: [Row] {
        guard let items else { return (0..<10).map { .loading($0) } }
        let results = items.map { Row.item($0) }
        if results.isEmpty && filtering { return missedOnly ? [.filterHeader, .emptyState, .clearFilterButton] : [.emptyState] }
        if !filtering { return [.createCallLink] + results }
        return missedOnly ? [.filterHeader] + results + [.clearFilterButton] : results
    }

    static var subtitleStyle: CSSTextStyle { LegacyType.body2() }

    @ViewBuilder func row(_ row: Row) -> some View {
        switch row {
        case .createCallLink:
            ComposeStepButton(icon: .callLink, title: i18n("icu:CallsList__CreateCallLink"), onClick: onCreateCallLink)
        case .emptyState:
            let key = !trimmedQuery.isEmpty && missedOnly ? "icu:CallsList__EmptyState--hasQueryAndMissedCalls"
                : missedOnly ? "icu:CallsList__EmptyState--missedCalls" : "icu:CallsList__EmptyState--hasQuery"
            I18n(key, components: ["query": .string(trimmedQuery)])
                .padding(.vertical, 28).padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
        case .filterHeader:
            CSSText(i18n("icu:CallsList__FilteredByMissedHeader"), style: LegacyType.body1(weight: 600), wrap: .truncate,
                    color: AxoColor(light: LegacyColor.black, dark: LegacyColor.gray05))
                .padding(.leading, 24)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        case .clearFilterButton:
            ClearFilterButton(isOnNoResultsPage: items?.isEmpty ?? true) { missedOnly = false }
        case .loading:
            CallsListTile(selected: false, onClick: nil) {
                Circle().fill(AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray75)).frame(width: 36, height: 36)
            } title: {
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 4).fill(AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray75))
                        .frame(width: g.size.width * 0.75, height: 14).padding(.top, 3)
                }
            } subtitle: {
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 4).fill(AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray75))
                        .frame(width: g.size.width * 0.6, height: 13).padding(.top, 2.5)
                }
                .frame(height: 18)
            } trailing: { EmptyView() }
        case .item(let item):
            itemRow(item)
        }
    }

    func statusText(_ item: CallsListItem) -> String {
        if item.wasMissed { return i18n("icu:CallsList__ItemCallInfo--Missed") }
        if item.wasDeclined { return i18n("icu:CallsList__ItemCallInfo--Declined") }
        if item.group.type == .adhoc { return i18n("icu:CallsList__ItemCallInfo--CallLink") }
        return i18n(item.group.direction == .outgoing ? "icu:CallsList__ItemCallInfo--Outgoing" : "icu:CallsList__ItemCallInfo--Incoming")
    }

    func itemRow(_ item: CallsListItem) -> some View {
        let c = item.conversation
        let isActiveVisible = item.canCall && item.isAnybodyInCall
        let count = item.group.children.count > 1 ? "(\(item.group.children.count)) " : ""
        let subtitleColor = item.wasMissed || item.wasDeclined ? AxoColor(light: LegacyColor.accentRed, dark: LegacyColor.accentRed)
            : ListTile<EmptyView, EmptyView, EmptyView, EmptyView>.subtitleColor
        return CallsListTile(selected: selected.map { Self.isSame($0, item.group) } ?? false, onClick: {
            onSelect(item.group.type == .adhoc ? .callLink(roomId: item.peerId, callHistoryGroup: item.group)
                     : .conversation(conversationId: item.peerId, callHistoryGroup: item.group))
        }) {
            Avatar(strings: AvatarStrings(i18n: i18n), title: c.title, size: 36, conversationType: c.conversationType, color: c.color,
                   image: c.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: c.avatar != nil)
        } title: {
            HStack(spacing: 0) {
                CSSText(c.title, style: LegacyType.body1(weight: 600), wrap: .truncate, color: .labelPrimary)
                if item.isMutedForCalls {
                    AxoSymbol.InlineGlyph("bell-slash", size: 14, weight: 400).cssTextColor(.labelSecondary)
                        .padding(.leading, 8).fixedSize().accessibilityLabel(i18n("icu:muted"))
                }
            }
        } subtitle: {
            Group {
                if isActiveVisible {
                    CSSText(count + statusText(item) + " · " + i18n("icu:CallsList__ItemCallInfo--Active"), style: Self.subtitleStyle, wrap: .truncate)
                } else {
                    CallsListTimestamp(prefix: count + statusText(item) + " · ", date: item.group.timestamp)
                }
            }
            .cssTextColor(subtitleColor)
        } trailing: {
            if item.canCall {
                CallsNewCallButton(callType: item.group.type, isActive: isActiveVisible, isEnabled: item.isInCall || !hasActiveCall,
                                   isInCall: item.isInCall) { onCall(item) }
            }
        }
        .onAppear { onRowAppear(item) }
    }

    /// `isSameCallHistoryGroup`: same peer, mode and timestamp (the app's ids carry the peer).
    static func isSame(_ a: CallHistoryGroup, _ b: CallHistoryGroup) -> Bool {
        a.timestamp == b.timestamp && a.type == b.type && a.direction == b.direction && a.status == b.status && a.children == b.children
    }

    public var body: some View {
        let empty = items?.isEmpty ?? false
        VStack(spacing: 0) {
            NavSidebarSearchHeader {
                SearchInput(value: $query, placeholder: i18n(filtering && missedOnly ? "icu:CallsList__SearchInputPlaceholder--missed-calls"
                                                             : "icu:CallsList__SearchInputPlaceholder"),
                            onClear: { query = "" })
                MissedFilterToggle(pressed: $missedOnly)
            }
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.self) { row($0) }
                }
                .padding(.leading, 11).padding(.trailing, 5)
            }
            .scrollIndicators(.automatic)
            .scrollDisabled(items == nil || empty)
        }
        .overlay {
            if empty && !filtering {
                NavSidebarEmpty(title: i18n("icu:CallsList__EmptyState--noQuery__title"), subtitle: i18n("icu:CallsList__EmptyState--noQuery__subtitle"))
            }
        }
    }
}

/// `<Timestamp>` in a row's subtitle: `formatDateTimeShort`, refreshed every second.
struct CallsListTimestamp: View {
    let prefix: String
    let date: Date
    @Environment(\.i18n) var i18n
    @Environment(\.timeZone) var timeZone
    @Environment(\.conversationListNow) var fixedNow

    var body: some View {
        if let fixedNow {
            label(fixedNow)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in label(context.date) }
        }
    }

    func label(_ now: Date) -> some View {
        CSSText(prefix + FormatTimestamp.dateTimeShort(date, now: now, i18n: i18n, timeZone: timeZone), style: CallsList.subtitleStyle, wrap: .truncate)
    }
}

/// `CallsList__ToggleFilterByMissed`: the 20px filter glyph in a 4px-padded button, a blue
/// circle while pressed.
struct MissedFilterToggle: View {
    @Binding var pressed: Bool
    @State var hovered = false
    @Environment(\.i18n) var i18n

    var body: some View {
        Button { pressed.toggle() } label: {
            SignalIcon("v3/filter/filter", size: 20, color: pressed ? AxoColor(light: LegacyColor.white, dark: LegacyColor.white)
                       : AxoColor(light: LegacyColor.black, dark: LegacyColor.gray15), mask: true)
                .frame(width: 20, height: 20)
                .padding(4)
                .background {
                    if pressed {
                        Circle().fill(Color(rgba: LegacyColor.accentBlue))
                    } else if hovered {
                        RoundedRectangle(cornerRadius: 4).fill(AxoColor(light: LegacyColor.blackAlpha06, dark: LegacyColor.whiteAlpha06))
                    }
                }
        }
        .buttonStyle(UndimmedButtonStyle())
        .onHover { hovered = $0 }
        .padding(.trailing, 8)
        .help(i18n("icu:CallsList__ToggleFilterByMissedLabel"))
        .accessibilityLabel(i18n("icu:CallsList__ToggleFilterByMissedLabel"))
        .accessibilityAddTraits(pressed ? .isSelected : [])
    }
}

/// A conversation the new-call picker can call (`activeAt` set, not archived).
public struct CallsNewCallConversation: Sendable, Hashable, Identifiable {
    public var conversation: CallingConversation
    public var isGroup: Bool
    public var id: String { conversation.id }
    public init(conversation: CallingConversation, isGroup: Bool) {
        self.conversation = conversation
        self.isGroup = isGroup
    }
}

/// `CallsNewCall`: the search, then "Contacts" and "Groups" with audio (direct only) and video
/// buttons; the search filtering is the app's `filterAndSortConversations`.
public struct CallsNewCall: View {
    let conversations: [CallsNewCallConversation]
    @Binding var query: String
    let hasActiveCall: Bool
    let onSelect: (String) -> Void
    let onAudioCall: (String) -> Void
    let onVideoCall: (String) -> Void
    @Environment(\.i18n) var i18n

    public init(conversations: [CallsNewCallConversation], query: Binding<String>, hasActiveCall: Bool, onSelect: @escaping (String) -> Void,
                onAudioCall: @escaping (String) -> Void, onVideoCall: @escaping (String) -> Void) {
        self.conversations = conversations
        _query = query
        self.hasActiveCall = hasActiveCall
        self.onSelect = onSelect
        self.onAudioCall = onAudioCall
        self.onVideoCall = onVideoCall
    }

    func header(_ title: String) -> some View {
        CSSText(title, style: LegacyType.body1(weight: 600), wrap: .truncate, color: .labelPrimary)
            .padding(.vertical, 10).padding(.horizontal, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    func item(_ c: CallsNewCallConversation) -> some View {
        ListTile(variant: .item, onClick: { onSelect(c.id) }) {
            Avatar(strings: AvatarStrings(i18n: i18n), title: c.conversation.title, size: 32, conversationType: .group, color: c.conversation.color,
                   image: c.conversation.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: c.conversation.avatar != nil)
        } title: {
            CSSText(c.conversation.title, style: ListTile<EmptyView, EmptyView, EmptyView, EmptyView>.titleStyle, wrap: .clamp(1))
        } subtitle: {
            EmptyView()
        } trailing: {
            HStack(spacing: 12) {
                if !c.isGroup {
                    CallsNewCallButton(callType: .audio, isActive: false, isEnabled: !hasActiveCall, isInCall: false) {
                        if !hasActiveCall { onAudioCall(c.id) }
                    }
                }
                CallsNewCallButton(callType: .video, isActive: false, isEnabled: !hasActiveCall, isInCall: false) {
                    if !hasActiveCall { onVideoCall(c.id) }
                }
            }
        }
    }

    public var body: some View {
        let direct = conversations.filter { !$0.isGroup }
        let groups = conversations.filter(\.isGroup)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        VStack(spacing: 0) {
            NavSidebarSearchHeader {
                SearchInput(value: $query, placeholder: "Search", onClear: { query = "" })
            }
            if conversations.isEmpty {
                Group {
                    if trimmed.isEmpty {
                        CSSText(i18n("icu:CallsNewCall__EmptyState--noQuery"), style: LegacyType.body1(), alignment: .center)
                    } else {
                        I18n("icu:CallsNewCall__EmptyState--hasQuery", components: ["query": .string(trimmed)], style: LegacyType.body1())
                    }
                }
                .padding(.vertical, 28).padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        if !direct.isEmpty {
                            header(i18n("icu:contactsHeader"))
                            ForEach(direct) { item($0) }
                        }
                        if !groups.isEmpty {
                            header(i18n("icu:groupsHeader"))
                            ForEach(groups) { item($0) }
                        }
                    }
                }
            }
        }
    }
}

/// `CallsTab`: the sidebar (history or new call) and the selected details / empty state, with
/// the clear-history confirmation.
public struct CallsTab<CallLinkDetailsView: View, ConversationDetailsView: View>: View {
    enum SidebarView { case callsList, newCall }

    let preferredLeftPaneWidth: CGFloat
    let navTabsCollapsed: Bool
    let otherTabsUnreadCount: Int
    let hasFailedStorySends: Bool
    let hasPendingUpdate: Bool
    let hasAnyAdminCallLinks: Bool
    let hasActiveCall: Bool
    let callsListItems: [CallsListItem]?
    @Binding var historyQuery: String
    @Binding var missedOnly: Bool
    let newCallConversations: [CallsNewCallConversation]
    @Binding var newCallQuery: String
    let actions: CallsTabActions
    let renderCallLinkDetails: (String, CallHistoryGroup, @escaping () -> Void) -> CallLinkDetailsView
    let renderConversationDetails: (String, CallHistoryGroup?) -> ConversationDetailsView
    @State var sidebarView = SidebarView.callsList
    @State var selectedView: CallsTabSelectedView?
    @State var selectedViewKey = 1
    @State var moreMenuOpen = false
    @State var confirmClearOpen = false
    @Environment(\.i18n) var i18n

    public init(preferredLeftPaneWidth: CGFloat, navTabsCollapsed: Bool = false, otherTabsUnreadCount: Int = 0, hasFailedStorySends: Bool = false,
                hasPendingUpdate: Bool = false, hasAnyAdminCallLinks: Bool, hasActiveCall: Bool, callsListItems: [CallsListItem]?,
                historyQuery: Binding<String>, missedOnly: Binding<Bool>, newCallConversations: [CallsNewCallConversation],
                newCallQuery: Binding<String>, actions: CallsTabActions,
                @ViewBuilder renderCallLinkDetails: @escaping (String, CallHistoryGroup, @escaping () -> Void) -> CallLinkDetailsView,
                @ViewBuilder renderConversationDetails: @escaping (String, CallHistoryGroup?) -> ConversationDetailsView) {
        self.preferredLeftPaneWidth = preferredLeftPaneWidth
        self.navTabsCollapsed = navTabsCollapsed
        self.otherTabsUnreadCount = otherTabsUnreadCount
        self.hasFailedStorySends = hasFailedStorySends
        self.hasPendingUpdate = hasPendingUpdate
        self.hasAnyAdminCallLinks = hasAnyAdminCallLinks
        self.hasActiveCall = hasActiveCall
        self.callsListItems = callsListItems
        _historyQuery = historyQuery
        _missedOnly = missedOnly
        self.newCallConversations = newCallConversations
        _newCallQuery = newCallQuery
        self.actions = actions
        self.renderCallLinkDetails = renderCallLinkDetails
        self.renderConversationDetails = renderConversationDetails
    }

    func select(_ view: CallsTabSelectedView?) {
        selectedView = view
        selectedViewKey += 1
        // Opening a conversation's calls marks them read.
        if case .conversation(let id, let group)? = view {
            group?.children.forEach { actions.onMarkCallHistoryRead(id, $0.callId) }
        }
    }

    func show(_ view: SidebarView) {
        sidebarView = view
        select(nil)
    }

    public var body: some View {
        HStack(spacing: 0) {
            NavSidebar(title: i18n(sidebarView == .callsList ? "icu:CallsTab__HeaderTitle--CallsList" : "icu:CallsTab__HeaderTitle--NewCall"),
                       hasFailedStorySends: hasFailedStorySends, hasPendingUpdate: hasPendingUpdate, navTabsCollapsed: navTabsCollapsed,
                       onBack: sidebarView == .newCall ? { show(.callsList) } : nil, onToggleNavTabsCollapse: actions.onToggleNavTabsCollapse,
                       preferredLeftPaneWidth: preferredLeftPaneWidth, requiresFullWidth: true,
                       savePreferredLeftPaneWidth: actions.savePreferredLeftPaneWidth, otherTabsUnreadCount: otherTabsUnreadCount) {
                if sidebarView == .callsList {
                    AxoIconButton.Root(label: i18n("icu:CallsTab__NewCallActionLabel"), variant: .impliedSecondary, size: .sm, symbol: "phone-plus") {
                        show(.newCall)
                    }
                    AxoDropdownMenu.Root(isOpen: $moreMenuOpen) {
                        AxoIconButton.Root(label: i18n("icu:CallsTab__MoreActionsLabel"), variant: .impliedSecondary, size: .sm, symbol: "more") {
                            moreMenuOpen.toggle()
                        }
                    } items: {
                        AxoDropdownMenu.Item(i18n("icu:CallsTab__ClearCallHistoryLabel"), symbol: "trash") { confirmClearOpen = true }
                    }
                }
            } content: {
                switch sidebarView {
                case .callsList:
                    CallsList(items: callsListItems, query: $historyQuery, missedOnly: $missedOnly, hasActiveCall: hasActiveCall,
                              selected: selectedView?.callHistoryGroup, onCreateCallLink: actions.onCreateCallLink, onSelect: select,
                              onCall: actions.onCall, onRowAppear: actions.onRowAppear)
                case .newCall:
                    CallsNewCall(conversations: newCallConversations, query: $newCallQuery, hasActiveCall: hasActiveCall,
                                 onSelect: { select(.conversation(conversationId: $0, callHistoryGroup: nil)) },
                                 onAudioCall: { actions.onOutgoingAudioCallInConversation($0); show(.callsList) },
                                 onVideoCall: { actions.onOutgoingVideoCallInConversation($0); show(.callsList) })
                }
            }
            ZStack {
                switch selectedView {
                case nil:
                    emptyState
                case .conversation(let id, let group)?:
                    ScrollView { renderConversationDetails(id, group).padding(.top, 80) }.id(selectedViewKey)
                case .callLink(let roomId, let group)?:
                    ScrollView { renderCallLinkDetails(roomId, group) { select(nil) }.padding(.top, 80) }.id(selectedViewKey)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onExitCommand { if sidebarView == .newCall { show(.callsList) } }
        .overlay {
            if confirmClearOpen {
                AxoBaseDialog.Host {
                    AxoConfirmDialog.Root(title: i18n("icu:CallsTab__ConfirmClearCallHistory__Title"),
                                          description: i18n(hasAnyAdminCallLinks ? "icu:CallsTab__ConfirmClearCallHistory__Body--call-links"
                                                            : "icu:CallsTab__ConfirmClearCallHistory__Body")) {
                        AxoConfirmDialog.Cancel(i18n("icu:cancel")) { confirmClearOpen = false }
                        AxoConfirmDialog.Action(i18n("icu:CallsTab__ConfirmClearCallHistory__ConfirmButton"), variant: .strongDestructive) {
                            confirmClearOpen = false
                            actions.onClearCallHistory()
                        }
                    }
                }
            }
        }
    }

    /// `CallsTab__EmptyState`: the 40px phone glyph and "Click [+] to start a new voice or
    /// video call.", both at 70% in gray-60 / gray-25.
    var emptyState: some View {
        let ink = AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25)
        let rich = i18n.richText("icu:CallsTab__EmptyStateText--with-icon-2", ["newCallButtonIcon": .element("icon")])
        let pieces: [AxoInlinePiece] = rich.runs.map { run in
            switch run.content {
            case .text(let s): .text(s)
            case .element: .glyph(AxoSymbol.inlineGlyph("phone-plus"))
            }
        }
        return VStack(spacing: 12) {
            SignalIcon("v3/phone/phone-display-bold", size: 40, color: ink, mask: true).frame(width: 40, height: 40)
            AxoInlineFlowText(pieces: pieces, style: LegacyType.body1(), alignment: .center, maxLines: nil) { _ in }
                .cssTextColor(ink)
                .accessibilityLabel(rich.plainText.replacingOccurrences(of: "\u{FFFC}", with: i18n("icu:CallsTab__NewCallActionLabel")))
        }
        .opacity(0.7)
        .padding(.top, 78).padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What the Calls tab asks the app to do.
public struct CallsTabActions {
    public var onCreateCallLink: () -> Void = {}
    public var onCall: (CallsListItem) -> Void = { _ in }
    public var onRowAppear: (CallsListItem) -> Void = { _ in }
    public var onOutgoingAudioCallInConversation: (String) -> Void = { _ in }
    public var onOutgoingVideoCallInConversation: (String) -> Void = { _ in }
    public var onMarkCallHistoryRead: (String, String) -> Void = { _, _ in }
    public var onClearCallHistory: () -> Void = {}
    public var onToggleNavTabsCollapse: (Bool) -> Void = { _ in }
    public var savePreferredLeftPaneWidth: (CGFloat) -> Void = { _ in }
    public init() {}
}
