// Port of ts/components/conversation/conversation-details/GroupMembersSearchDialog.dom.tsx and
// ts/util/groupByFirstInitial.std.ts: "Search members", a md AxoDialog with a search field and
// a filter menu (all / admins / contacts). With no query the members are listed by first
// initial; with one, the search results. "Add members" and "Invite via group link" follow.
//
// The ranking is `filterAndSortConversations` (Fuse.js scores plus recency), passed in as
// `search`; the default is a diacritic-insensitive substring match in title order.

import SignalI18n
import SwiftUI

public struct GroupMembersSearchDialog: View {
    public enum Filter: String, Sendable { case all, admins, systemContacts }

    let members: [GroupV2Membership]
    let canAddNewMembers: Bool
    let canInviteViaGroupLink: Bool
    let search: ([GroupV2Membership], String) -> [GroupV2Membership]
    let onSelectMember: (GroupV2Membership) -> Void
    let onSelectAddMember: () -> Void
    let onInviteViaGroupLink: () -> Void
    let onClose: () -> Void
    @State private var searchValue: String
    @State private var filter: Filter
    @State private var filterMenuOpen = false
    @Environment(\.i18n) var i18n

    public init(members: [GroupV2Membership], canAddNewMembers: Bool, canInviteViaGroupLink: Bool,
                search: @escaping ([GroupV2Membership], String) -> [GroupV2Membership] = GroupMembersSearchDialog.defaultSearch,
                initialSearchValue: String = "", initialFilter: Filter = .all, onSelectMember: @escaping (GroupV2Membership) -> Void = { _ in },
                onSelectAddMember: @escaping () -> Void = {}, onInviteViaGroupLink: @escaping () -> Void = {}, onClose: @escaping () -> Void = {}) {
        self.members = members
        self.canAddNewMembers = canAddNewMembers
        self.canInviteViaGroupLink = canInviteViaGroupLink
        self.search = search
        self.onSelectMember = onSelectMember
        self.onSelectAddMember = onSelectAddMember
        self.onInviteViaGroupLink = onInviteViaGroupLink
        self.onClose = onClose
        _searchValue = State(initialValue: initialSearchValue)
        _filter = State(initialValue: initialFilter)
    }

    /// `SearchResults`: `filterAndSortConversations` over the members' conversations.
    nonisolated public static func defaultSearch(_ members: [GroupV2Membership], _ query: String) -> [GroupV2Membership] {
        let byId = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let conversations = members.map { m in
            m.searchable ?? SearchableConversation(listItem: ContactListItemData(id: m.id, title: m.avatar.title, avatar: m.avatar))
        }
        return ConversationSearch.filterAndSort(conversations, searchTerm: query, regionCode: nil).compactMap { byId[$0.id] }
    }

    /// `groupByFirstInitial`: sections in initial order (no-letter titles last), members in
    /// their original order within each.
    nonisolated public static func groupByFirstInitial(_ members: [GroupV2Membership]) -> [(initial: String, items: [GroupV2Membership])] {
        var order: [String] = []
        var groups: [String: [GroupV2Membership]] = [:]
        for m in members {
            let initial = m.avatar.title.first(where: { $0.isLetter }).map { String($0).uppercased() } ?? ""
            if groups[initial] == nil { order.append(initial) }
            groups[initial, default: []].append(m)
        }
        let sorted = order.sorted { a, b in
            if a.isEmpty { return false }
            if b.isEmpty { return true }
            return a.localizedCompare(b) == .orderedAscending
        }
        return sorted.map { ($0, groups[$0] ?? []) }
    }

    var filtered: [GroupV2Membership] {
        switch filter {
        case .all: members
        case .admins: members.filter(\.isAdmin)
        case .systemContacts: members.filter(\.isInSystemContacts)
        }
    }

    var placeholder: String {
        switch filter {
        case .all: i18n("icu:GroupMembersSearchDialog__SearchField__Placeholder")
        case .admins: i18n("icu:GroupMembersSearchDialog__SearchField__Placeholder--FilteringByAdmins")
        case .systemContacts: i18n("icu:GroupMembersSearchDialog__SearchField__Placeholder--FilteringBySystemContacts")
        }
    }

    func memberItem(_ m: GroupV2Membership) -> some View {
        let title = m.isMe ? i18n("icu:you") : m.avatar.title
        return AxoContactList.Item(title: title, titleView: AnyView(HStack(spacing: 0) {
            CSSText(runs: [Emojify.run(title)], style: CSSTextStyle(AxoType.bodyMedium), wrap: .truncate)
            if m.isInSystemContacts {
                CSSText("\u{00A0}", style: CSSTextStyle(AxoType.bodyMedium), wrap: .nowrap)
                AxoContactName.SystemContactEmblem()
            }
        }), value: m.isAdmin ? i18n("icu:GroupMembersSearchDialog__MemberItem__Admin") : nil, onClick: {
            onClose()
            onSelectMember(m)
        }) {
            ListAvatar(data: m.avatar, size: 32)
        } description: { EmptyView() } accessory: { EmptyView() }
    }

    @ViewBuilder var memberLists: some View {
        let query = searchValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            let sections = Self.groupByFirstInitial(filtered)
            ForEach(sections, id: \.initial) { section in
                AxoContactList.Root(title: section.initial) { ForEach(section.items) { memberItem($0) } }
            }
            if sections.isEmpty {
                AxoContactList.Root {
                    AxoContactList.EmptyStateItem(title: i18n("icu:GroupMembersSearchDialog__EmptyState__NoResults--WithoutSearchQuery"))
                }
            }
        } else {
            let results = search(filtered, query)
            AxoContactList.Root(title: i18n("icu:GroupMembersSearchDialog__SearchResults__Title")) {
                ForEach(results) { memberItem($0) }
                if results.isEmpty {
                    AxoContactList.EmptyStateItem(title: i18n("icu:GroupMembersSearchDialog__EmptyState__NoResults--WithSearchQuery",
                                                              ["searchQuery": .string(query)]))
                }
            }
        }
    }

    var filterMenu: some View {
        let value = Binding<String?>(get: { filter.rawValue }, set: { if let v = $0, let f = Filter(rawValue: v) { filter = f } })
        return AxoDropdownMenu.Root(isOpen: $filterMenuOpen) {
            AxoIconButton.Root(label: i18n("icu:GroupMembersSearchDialog__FilterMenu__Label"), variant: .impliedSecondary, size: .md, symbol: "filter",
                               pressed: filter != .all)
        } items: {
            AxoDropdownMenu.Label(i18n("icu:GroupMembersSearchDialog__FilterMenu__Label"))
            AxoDropdownMenu.RadioGroup(value: value) {
                AxoDropdownMenu.RadioItem(i18n("icu:GroupMembersSearchDialog__FilterMenu__AllMembers"), value: Filter.all.rawValue, symbol: "group")
                AxoDropdownMenu.Separator()
                AxoDropdownMenu.RadioItem(i18n("icu:GroupMembersSearchDialog__FilterMenu__Admins"), value: Filter.admins.rawValue, symbol: "key")
                AxoDropdownMenu.RadioItem(i18n("icu:GroupMembersSearchDialog__FilterMenu__SystemContacts"), value: Filter.systemContacts.rawValue,
                                          symbol: "person-circle")
            }
        }
    }

    public var body: some View {
        AxoDialog.Content(size: .md, hasFooter: false) {
            AxoDialog.Header {
                AxoDialog.Title(i18n("icu:GroupMembersSearchDialog__DialogTitle"))
                AxoDialog.Close(action: onClose)
            }
            AxoDialog.Search {
                AxoSearchField.Root(value: $searchValue) {
                    AxoSearchField.Icon()
                    AxoSearchField.Input(placeholder: placeholder, autoFocus: true)
                    AxoSearchField.Clear()
                }
                filterMenu
            }
            AxoDialog.Body(padding: .md, forceMaxHeight: true) {
                VStack(alignment: .leading, spacing: 8) {
                    memberLists
                    if canAddNewMembers || canInviteViaGroupLink {
                        AxoContactList.Root {
                            if canAddNewMembers {
                                AxoContactList.ActionItem(symbol: "plus", title: i18n("icu:GroupMembersSearchDialog__BottomActions__AddMembers"),
                                                          onClick: onSelectAddMember)
                            }
                            if canInviteViaGroupLink {
                                AxoContactList.ActionItem(symbol: "link", title: i18n("icu:GroupMembersSearchDialog__BottomActions__InviteViaGroupLink"),
                                                          onClick: onInviteViaGroupLink)
                            }
                        }
                    }
                }
            }
        }
    }
}
