// Port of ts/components/StoriesSettingsModal.dom.tsx (+ stylesheets/components/
// StoriesSettingsModal.scss): "Story privacy", a paged 420px modal. The list page shows
// "New Story", My Story and the custom lists (with who sees them), the group stories, the
// view-receipts checkbox and "Turn off stories". From there:
//   DistributionListSettingsModal  a list's viewers (add / remove), replies & reactions, delete
//   EditMyStoryPrivacy             My Story: all connections / all except… / only share with…
//   EditDistributionListModal      choose viewers (search, pills, checkbox list), hide from,
//                                  then name a new story
//   GroupStorySettingsModal        a group story's members, remove the group story
//
// EditMyStoryPrivacy and EditDistributionListModal are shared with SendStoryModal.

import SignalI18n
import SwiftUI

/// `StoryDistributionListWithMembersDataType`
public struct StoryDistributionList: Identifiable {
    public var id: String
    public var name: String
    public var allowsReplies: Bool
    public var isBlockList: Bool
    public var members: [SearchableConversation]

    public init(id: String, name: String, allowsReplies: Bool = true, isBlockList: Bool = false, members: [SearchableConversation] = []) {
        self.id = id
        self.name = name
        self.allowsReplies = allowsReplies
        self.isBlockList = isBlockList
        self.members = members
    }

    public var isMyStory: Bool { id == MyStoryList.myStoryId }

    /// `getStoryDistributionListName`
    @MainActor public func displayName(_ i18n: Localizer) -> String { isMyStory ? i18n("icu:Stories__mine") : name }

    /// `getListViewers`: "N viewers" (My Story as a block list counts the connections left).
    @MainActor public func viewers(_ i18n: Localizer, signalConnectionsCount: Int) -> String {
        var count = members.count
        if isMyStory && isBlockList { count = signalConnectionsCount - members.count }
        return i18n("icu:StoriesSettings__viewers", ["count": .number(Double(count))])
    }

    /// `getI18nForMyStory`
    @MainActor public func myStoryLabel(_ i18n: Localizer) -> String {
        if members.isEmpty || isBlockList { return i18n("icu:StoriesSettings__mine__all--label") }
        return i18n("icu:SendStoryModal__only-share-with")
    }
}

/// A group with stories (`ConversationWithStoriesType`), with its members for the settings page.
public struct GroupStoryInfo: Identifiable {
    public var id: String
    public var title: String
    public var avatar: ConversationAvatarData
    public var membersCount: Int
    public var members: [SearchableConversation]
    /// Members' ACIs (`memberships`); nil while unknown, when the group can't be picked.
    public var memberServiceIds: [String]?
    public var announcementsOnly = false
    public var areWeAdmin = false
    public var terminated = false
    public init(id: String, title: String, avatar: ConversationAvatarData? = nil, membersCount: Int, members: [SearchableConversation] = [],
                memberServiceIds: [String]? = []) {
        self.memberServiceIds = memberServiceIds
        self.id = id
        self.title = title
        self.avatar = avatar ?? ConversationAvatarData(title: title, conversationType: .group)
        self.membersCount = membersCount
        self.members = members
    }
}

public struct StoriesSettingsActions {
    public var hideStoriesSettings: () -> Void = {}
    public var onDeleteList: (String) -> Void = { _ in }
    public var toggleGroupsForStorySend: ([String]) -> Void = { _ in }
    public var onDistributionListCreated: (_ name: String, _ viewerServiceIds: [String]) -> Void = { _, _ in }
    public var onHideMyStoriesFrom: ([String]) -> Void = { _ in }
    public var onRemoveMembers: (_ listId: String, _ serviceIds: [String]) -> Void = { _, _ in }
    public var onRepliesNReactionsChanged: (_ listId: String, _ allowsReplies: Bool) -> Void = { _, _ in }
    public var onStoryViewReceiptsChange: (Bool) -> Void = { _ in }
    public var onViewersUpdated: (_ listId: String, _ serviceIds: [String]) -> Void = { _, _ in }
    public var setMyStoriesToAllSignalConnections: () -> Void = {}
    public var toggleSignalConnectionsModal: () -> Void = {}
    public var setStoriesDisabled: (Bool) -> Void = { _ in }
    public init() {}
}

/// `Page`
public enum StoriesSettingsPage: Sendable, Hashable { case distributionLists, addViewer, chooseViewers, nameStory, hideStoryFrom }

enum StoriesSettingsStyle {
    static var secondary: AxoColor { AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25) }
    static var divider: AxoColor { AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray65) }
    static var iconCircle: AxoColor { AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray75) }
    static var iconColor: AxoColor { AxoColor(light: LegacyColor.black, dark: LegacyColor.white) }
    static var destructive: AxoColor { AxoColor(LegacyColor.accentRed) }
}

public struct StoriesSettingsModal: View {
    let candidateConversations: [SearchableConversation]
    let distributionLists: [StoryDistributionList]
    let groupStories: [GroupStoryInfo]
    let signalConnectionsCount: Int
    let me: ConversationAvatarData
    let storyViewReceiptsEnabled: Bool
    let regionCode: String?
    let actions: StoriesSettingsActions
    @State private var listToEditId: String?
    @State private var groupToViewId: String?
    @State private var page: StoriesSettingsPage = .distributionLists
    @State private var selectedContacts: [SearchableConversation] = []
    @State private var confirmDeleteList: (id: String, name: String)?
    @State private var confirmRemoveGroup: (id: String, title: String)?
    @State private var confirmDiscard = false
    @Environment(\.i18n) var i18n

    public init(candidateConversations: [SearchableConversation], distributionLists: [StoryDistributionList], groupStories: [GroupStoryInfo],
                signalConnectionsCount: Int, me: ConversationAvatarData, storyViewReceiptsEnabled: Bool, regionCode: String? = nil,
                actions: StoriesSettingsActions = StoriesSettingsActions()) {
        self.candidateConversations = candidateConversations
        self.distributionLists = distributionLists
        self.groupStories = groupStories
        self.signalConnectionsCount = signalConnectionsCount
        self.me = me
        self.storyViewReceiptsEnabled = storyViewReceiptsEnabled
        self.regionCode = regionCode
        self.actions = actions
    }

    var strings: ModalStrings { ModalStrings(back: i18n("icu:back"), close: i18n("icu:close")) }
    var listToEdit: StoryDistributionList? { distributionLists.first { $0.id == listToEditId } }
    var groupToView: GroupStoryInfo? { groupStories.first { $0.id == groupToViewId } }

    /// `useConfirmDiscard`: closing with contacts picked asks first.
    func confirmDiscardIf(_ condition: Bool, _ action: @escaping () -> Void) {
        if condition { confirmDiscard = true; pendingDiscard = action } else { action() }
    }
    @State private var pendingDiscard: (() -> Void)?

    func onTryClose() { confirmDiscardIf(!selectedContacts.isEmpty, actions.hideStoriesSettings) }

    func resetChooseViewersScreen() {
        selectedContacts = []
        page = .distributionLists
    }

    public var body: some View {
        ModalHost(onClose: onTryClose, maxWidth: 420) {
            currentPage
        }
        .overlay { dialogs }
    }

    @ViewBuilder var currentPage: some View {
        if page != .distributionLists {
            EditDistributionListPage(candidateConversations: candidateConversations, page: page, regionCode: regionCode,
                                     selectedContacts: $selectedContacts, onClose: onTryClose,
                                     onBackButtonClick: {
                                         confirmDiscardIf(!selectedContacts.isEmpty) {
                                             if page == .nameStory { page = .chooseViewers } else { resetChooseViewersScreen() }
                                         }
                                     },
                                     onCreateList: { name, ids in
                                         actions.onDistributionListCreated(name, ids)
                                         resetChooseViewersScreen()
                                     },
                                     onViewersUpdated: { ids in
                                         if let listToEditId, page == .addViewer {
                                             actions.onViewersUpdated(listToEditId, ids)
                                             resetChooseViewersScreen()
                                         }
                                         if page == .chooseViewers { page = .nameStory }
                                         if page == .hideStoryFrom {
                                             actions.onHideMyStoriesFrom(ids)
                                             resetChooseViewersScreen()
                                         }
                                     })
        } else if let listToEdit {
            DistributionListSettingsPage(listToEdit: listToEdit, signalConnectionsCount: signalConnectionsCount, actions: actions,
                                         onDeleteList: { confirmDeleteList = (listToEdit.id, listToEdit.name) },
                                         setPage: { page = $0 }, setSelectedContacts: { selectedContacts = $0 },
                                         onBackButtonClick: { listToEditId = nil }, onClose: onTryClose)
        } else if let groupToView {
            GroupStorySettingsPage(group: groupToView, onClose: onTryClose, onBackButtonClick: { groupToViewId = nil }) {
                confirmRemoveGroup = (groupToView.id, groupToView.title)
            }
        } else {
            listsPage
        }
    }

    var listsPage: some View {
        ModalPage(modalName: "StoriesSettingsModal__list", strings: strings, title: i18n("icu:StoriesSettings__title"), hasXButton: true,
                  onClose: onTryClose) {
            CSSBlockText(i18n("icu:StoriesSettings__description"), style: LegacyType.subtitle(), color: StoriesSettingsStyle.secondary)
                .padding(.bottom, 16)
            // __listHeader
            CSSText(i18n("icu:StoriesSettings__my_stories"), style: LegacyType.body1(weight: 600), wrap: .nowrap)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
                .accessibilityAddTraits(.isHeader)
            StoriesSettingsListRow(avatar: .icon("v3/plus/plus"), title: i18n("icu:StoriesSettings__new-list")) { page = .chooseViewers }
            ForEach(distributionLists) { list in
                StoriesSettingsListRow(avatar: list.isMyStory ? .conversation(me) : .icon("v3/stories/stories"),
                                       title: list.displayName(i18n),
                                       subtitle: (list.isMyStory ? list.myStoryLabel(i18n) : i18n("icu:StoriesSettings__custom-story-subtitle"))
                                           + "\u{00A0}·\u{00A0}" + list.viewers(i18n, signalConnectionsCount: signalConnectionsCount)) {
                    listToEditId = list.id
                }
            }
            ForEach(groupStories) { group in
                StoriesSettingsListRow(avatar: .conversation(group.avatar), title: group.title,
                                       subtitle: i18n("icu:StoriesSettings__group-story-subtitle") + "\u{00A0}·\u{00A0}"
                                           + i18n("icu:StoriesSettings__viewers", ["count": .number(Double(group.membersCount))])) {
                    groupToViewId = group.id
                }
            }
            StoriesSettingsDivider()
            Checkbox(label: i18n("icu:StoriesSettings__view-receipts--label"), description: i18n("icu:StoriesSettings__view-receipts--new-description"),
                     name: "view-receipts", checked: storyViewReceiptsEnabled, onChange: actions.onStoryViewReceiptsChange)
                .padding(.vertical, 14)
            // __stories-off-container: flex, gap 16, centred.
            HStack(alignment: .center, spacing: 16) {
                CSSBlockText(i18n("icu:Stories__settings-toggle--description"), style: LegacyType.subtitle(), color: StoriesSettingsStyle.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                LegacyButton(i18n("icu:Stories__settings-toggle--button"), variant: .secondaryDestructive) {
                    actions.setStoriesDisabled(true)
                    actions.hideStoriesSettings()
                }
                .fixedSize()
            }
        }
    }

    @ViewBuilder var dialogs: some View {
        if let list = confirmDeleteList {
            AxoConfirmDialog.Root(title: nil, description: i18n("icu:StoriesSettings__delete-list--confirm", ["name": .string(list.name)])) {
                AxoConfirmDialog.Cancel(i18n("icu:cancel")) { confirmDeleteList = nil }
                AxoConfirmDialog.Action(i18n("icu:delete"), variant: .strongDestructive) {
                    actions.onDeleteList(list.id)
                    listToEditId = nil
                    confirmDeleteList = nil
                }
            }
        } else if let group = confirmRemoveGroup {
            AxoConfirmDialog.Root(title: nil, description: i18n("icu:StoriesSettings__remove_group--confirm", ["groupTitle": .string(group.title)])) {
                AxoConfirmDialog.Cancel(i18n("icu:cancel")) { confirmRemoveGroup = nil }
                AxoConfirmDialog.Action(i18n("icu:delete"), variant: .strongDestructive) {
                    actions.toggleGroupsForStorySend([group.id])
                    confirmRemoveGroup = nil
                    groupToViewId = nil
                }
            }
        } else if confirmDiscard {
            ConfirmDiscardDialog(onClose: {
                confirmDiscard = false
                pendingDiscard = nil
            }) {
                confirmDiscard = false
                pendingDiscard?()
                pendingDiscard = nil
            }
        }
    }
}

/// `.StoriesSettingsModal__divider`: a 1px gray-15 / gray-65 rule.
struct StoriesSettingsDivider: View {
    var body: some View { Rectangle().fill(StoriesSettingsStyle.divider).frame(height: 1).frame(maxWidth: .infinity) }
}

/// `.StoriesSettingsModal__list`: a row (8px above and below) with a 32px avatar, the title and
/// optional "subtitle · N viewers" 12px after it; a button unless `action` is nil
/// (`--no-pointer`); `trailing` is the remove-member button.
struct StoriesSettingsListRow: View {
    enum AvatarKind {
        case conversation(ConversationAvatarData)
        /// `__avatar--new` / `--custom`: the icon on a gray-15 / gray-75 circle.
        case icon(String)
    }
    let avatar: AvatarKind
    let title: String
    var subtitle: String?
    var trailing: AnyView?
    let action: (() -> Void)?

    init(avatar: AvatarKind, title: String, subtitle: String? = nil, trailing: AnyView? = nil, action: (() -> Void)? = nil) {
        self.avatar = avatar
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.action = action
    }

    var row: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                avatarView
                VStack(alignment: .leading, spacing: 0) {
                    CSSText(runs: [Emojify.run(title)], style: LegacyType.body1(), wrap: .wrap)
                    if let subtitle {
                        CSSText(subtitle, style: LegacyType.body2(), wrap: .wrap, color: StoriesSettingsStyle.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if let trailing { trailing }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder var avatarView: some View {
        switch avatar {
        case .conversation(let data):
            ListAvatar(data: data, size: 32)
        case .icon(let name):
            SignalIcon(name, size: 20, color: StoriesSettingsStyle.iconColor, mask: true)
                .frame(width: 32, height: 32)
                .background(Circle().fill(StoriesSettingsStyle.iconCircle))
        }
    }

    var body: some View {
        if let action {
            Button(action: action) { row }.buttonStyle(UndimmedButtonStyle())
        } else {
            row
        }
    }
}

/// `.StoriesSettingsModal__title`: body-1 bold, 32px above.
struct StoriesSettingsSectionTitle: View {
    let text: String
    var body: some View {
        CSSText(text, style: LegacyType.body1(weight: 600), wrap: .wrap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 32)
    }
}

/// `.StoriesSettingsModal__delete-list` / `.GroupStorySettingsModal__remove_group`: an accent-red
/// row with its 20px icon 20px before the text.
struct StoriesSettingsDestructiveRow: View {
    let icon: String
    let text: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                SignalIcon(icon, size: 20, color: StoriesSettingsStyle.destructive, mask: true).frame(width: 20, height: 20)
                CSSText(text, style: LegacyType.body1(), wrap: .wrap, color: StoriesSettingsStyle.destructive)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(UndimmedButtonStyle())
    }
}

/// `DistributionListSettingsModal`
struct DistributionListSettingsPage: View {
    let listToEdit: StoryDistributionList
    let signalConnectionsCount: Int
    let actions: StoriesSettingsActions
    let onDeleteList: () -> Void
    let setPage: (StoriesSettingsPage) -> Void
    let setSelectedContacts: ([SearchableConversation]) -> Void
    let onBackButtonClick: () -> Void
    let onClose: () -> Void
    @State private var confirmRemoveMember: SearchableConversation?
    @State private var hoveredMember: String?
    @Environment(\.i18n) var i18n

    var body: some View {
        ModalPage(modalName: "DistributionListSettingsModal", strings: ModalStrings(back: i18n("icu:back"), close: i18n("icu:close")),
                  title: listToEdit.displayName(i18n), hasXButton: true, onBackButtonClick: onBackButtonClick, onClose: onClose) {
            if !listToEdit.isMyStory {
                StoriesSettingsListRow(avatar: .icon("v3/stories/stories"), title: listToEdit.displayName(i18n))
                StoriesSettingsDivider()
            }
            StoriesSettingsSectionTitle(text: i18n("icu:StoriesSettings__who-can-see"))
            if listToEdit.isMyStory {
                EditMyStoryPrivacy(kind: .mine, myStories: listToEdit, signalConnectionsCount: signalConnectionsCount,
                                   onClickExclude: { setPage(.hideStoryFrom) }, onClickOnlyShareWith: { setPage(.addViewer) },
                                   setSelectedContacts: setSelectedContacts,
                                   setMyStoriesToAllSignalConnections: actions.setMyStoriesToAllSignalConnections,
                                   toggleSignalConnectionsModal: actions.toggleSignalConnectionsModal)
            } else {
                StoriesSettingsListRow(avatar: .icon("v3/plus/plus"), title: i18n("icu:StoriesSettings__add-viewer")) {
                    setSelectedContacts(listToEdit.members)
                    setPage(.addViewer)
                }
                ForEach(listToEdit.members) { member in
                    StoriesSettingsListRow(avatar: .conversation(member.listItem.avatar), title: member.title,
                                           trailing: AnyView(removeButton(member))) as StoriesSettingsListRow
                }
                .onHover { _ in }
            }
            StoriesSettingsDivider().padding(.top, listToEdit.isMyStory ? 0 : 0)
            StoriesSettingsSectionTitle(text: i18n("icu:StoriesSettings__replies-reactions--title"))
            Checkbox(label: i18n("icu:StoriesSettings__replies-reactions--label"), description: i18n("icu:StoriesSettings__replies-reactions--description"),
                     name: "replies-reactions", checked: listToEdit.allowsReplies) { actions.onRepliesNReactionsChanged(listToEdit.id, $0) }
                .padding(.vertical, 14)
            if !listToEdit.isMyStory {
                StoriesSettingsDivider()
                StoriesSettingsDestructiveRow(icon: "v3/trash/trash", text: i18n("icu:StoriesSettings__delete-list"), action: onDeleteList)
            }
        }
        .overlay {
            if let member = confirmRemoveMember {
                AxoConfirmDialog.Root(title: i18n("icu:StoriesSettings__remove--title", ["title": .string(member.title)]),
                                      description: i18n("icu:StoriesSettings__remove--body")) {
                    AxoConfirmDialog.Cancel(i18n("icu:cancel")) { confirmRemoveMember = nil }
                    AxoConfirmDialog.Action(i18n("icu:StoriesSettings__remove--action"), variant: .strongDestructive) {
                        if let serviceId = member.serviceId { actions.onRemoveMembers(listToEdit.id, [serviceId]) }
                        confirmRemoveMember = nil
                    }
                }
            }
        }
    }

    /// `__list__delete`: the 20px trash icon (gray-45 / gray-25), visible while the row is hovered.
    func removeButton(_ member: SearchableConversation) -> some View {
        Button { confirmRemoveMember = member } label: {
            SignalIcon("v3/trash/trash", size: 20, color: AxoColor(light: LegacyColor.gray45, dark: LegacyColor.gray25), mask: true)
                .frame(width: 20, height: 20)
                .opacity(hoveredMember == member.id ? 1 : 0)
        }
        .buttonStyle(UndimmedButtonStyle())
        .accessibilityLabel(i18n("icu:StoriesSettings__remove--title", ["title": .string(member.title)]))
        .onHover { hoveredMember = $0 ? member.id : (hoveredMember == member.id ? nil : hoveredMember) }
    }
}

/// `EditMyStoryPrivacy`: three radios (all connections, all except…, only share with…), the
/// checked one showing its viewer count, and the disclaimer with its "Learn more" button.
public struct EditMyStoryPrivacy: View {
    public enum Kind: Sendable { case privacy, mine }
    let hasDisclaimerAbove: Bool
    let kind: Kind
    let myStories: StoryDistributionList
    let signalConnectionsCount: Int
    let onClickExclude: () -> Void
    let onClickOnlyShareWith: () -> Void
    let setSelectedContacts: ([SearchableConversation]) -> Void
    let setMyStoriesToAllSignalConnections: () -> Void
    let toggleSignalConnectionsModal: () -> Void
    @Environment(\.i18n) var i18n

    public init(hasDisclaimerAbove: Bool = false, kind: Kind, myStories: StoryDistributionList, signalConnectionsCount: Int,
                onClickExclude: @escaping () -> Void, onClickOnlyShareWith: @escaping () -> Void,
                setSelectedContacts: @escaping ([SearchableConversation]) -> Void, setMyStoriesToAllSignalConnections: @escaping () -> Void,
                toggleSignalConnectionsModal: @escaping () -> Void) {
        self.hasDisclaimerAbove = hasDisclaimerAbove
        self.kind = kind
        self.myStories = myStories
        self.signalConnectionsCount = signalConnectionsCount
        self.onClickExclude = onClickExclude
        self.onClickOnlyShareWith = onClickOnlyShareWith
        self.setSelectedContacts = setSelectedContacts
        self.setMyStoriesToAllSignalConnections = setMyStoriesToAllSignalConnections
        self.toggleSignalConnectionsModal = toggleSignalConnectionsModal
    }

    func viewers(_ count: Int) -> String { i18n("icu:StoriesSettings__viewers", ["count": .number(Double(count))]) }

    var disclaimer: some View {
        let key = kind == .mine ? "icu:StoriesSettings__mine__disclaimer--link" : "icu:SendStoryModal__privacy-disclaimer--link"
        return CSSText(runs: CSSTextRun.runs(i18n.richText(key), tags: ["learnMoreLink": I18nTagStyle(
                           color: AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05), action: "learnMore")]),
                       style: LegacyType.subtitle(), color: StoriesSettingsStyle.secondary) { _ in toggleSignalConnectionsModal() }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasDisclaimerAbove { disclaimer }
            let all = myStories.isBlockList && myStories.members.isEmpty
            let except = myStories.isBlockList && !myStories.members.isEmpty
            let only = !myStories.isBlockList && !myStories.members.isEmpty
            Checkbox(label: i18n("icu:StoriesSettings__mine__all--label"), description: all ? viewers(signalConnectionsCount) : nil, name: "share",
                     checked: all, isRadio: true, onChange: { _ in setMyStoriesToAllSignalConnections() })
                .descriptionBeside()
                .padding(.vertical, 14)
            Checkbox(label: i18n("icu:StoriesSettings__mine__exclude--label"), description: except ? viewers(myStories.members.count) : nil,
                     name: "share", checked: except, isRadio: true, onChange: { _ in }) {
                if myStories.isBlockList { setSelectedContacts(myStories.members) }
                onClickExclude()
            }
            .descriptionBeside()
            .padding(.bottom, 14)
            Checkbox(label: i18n("icu:StoriesSettings__mine__only--label"), description: only ? viewers(myStories.members.count) : nil,
                     name: "share", checked: only, isRadio: true, onChange: { _ in }) {
                if !myStories.isBlockList { setSelectedContacts(myStories.members) }
                onClickOnlyShareWith()
            }
            .descriptionBeside()
            .padding(.bottom, 14)
            if !hasDisclaimerAbove { disclaimer }
        }
    }
}

/// `EditDistributionListModal`: pick viewers (search, the chosen as pills, a checkbox list) for a
/// new list, a list's added viewers or who My Story is hidden from; then name the new list.
public struct EditDistributionListPage: View {
    let candidateConversations: [SearchableConversation]
    let page: StoriesSettingsPage
    let regionCode: String?
    @Binding var selectedContacts: [SearchableConversation]
    let onClose: () -> Void
    let onBackButtonClick: () -> Void
    let onCreateList: (String, [String]) -> Void
    let onViewersUpdated: ([String]) -> Void
    @State private var storyName = ""
    @State private var searchTerm = ""
    @State private var filtered: [SearchableConversation]
    @Environment(\.i18n) var i18n

    public init(candidateConversations: [SearchableConversation], page: StoriesSettingsPage, regionCode: String? = nil,
                selectedContacts: Binding<[SearchableConversation]>, onClose: @escaping () -> Void, onBackButtonClick: @escaping () -> Void,
                onCreateList: @escaping (String, [String]) -> Void, onViewersUpdated: @escaping ([String]) -> Void) {
        self.candidateConversations = candidateConversations
        self.page = page
        self.regionCode = regionCode
        _selectedContacts = selectedContacts
        self.onClose = onClose
        self.onBackButtonClick = onBackButtonClick
        self.onCreateList = onCreateList
        self.onViewersUpdated = onViewersUpdated
        _filtered = State(initialValue: ConversationSearch.filterAndSort(candidateConversations, searchTerm: "", regionCode: regionCode)
            .filter { $0.serviceId != nil })
    }

    var strings: ModalStrings { ModalStrings(back: i18n("icu:back"), close: i18n("icu:close")) }
    var selectedServiceIds: [String] { selectedContacts.compactMap(\.serviceId) }
    var isChoosingViewers: Bool { page == .chooseViewers || page == .addViewer }

    func toggle(_ id: String) {
        if selectedContacts.contains(where: { $0.id == id }) {
            selectedContacts.removeAll { $0.id == id }
        } else if let contact = candidateConversations.first(where: { $0.id == id }) {
            selectedContacts.append(contact)
        }
    }

    public var body: some View {
        if page == .nameStory {
            namePage
        } else {
            choosePage
        }
    }

    var namePage: some View {
        ModalPage(modalName: "StoriesSettings__name-story", strings: strings, title: i18n("icu:StoriesSettings__name-story"), hasXButton: true,
                  onBackButtonClick: onBackButtonClick, onClose: onClose) {
            Input(value: $storyName, placeholder: i18n("icu:StoriesSettings__name-placeholder"), clearLabel: i18n("icu:cancel"))
                .padding(.top, 15)
            CSSBlockText(i18n("icu:SendStoryModal__new-custom--name-visibility"), style: LegacyType.subtitle(), color: StoriesSettingsStyle.secondary)
                .padding(.top, 10)
            StoriesSettingsSectionTitle(text: i18n("icu:StoriesSettings__who-can-see"))
            ForEach(selectedContacts) { contact in
                StoriesSettingsListRow(avatar: .conversation(contact.listItem.avatar), title: contact.title)
            }
        } footer: {
            LegacyButton(i18n("icu:done"), variant: .primary, disabled: storyName.isEmpty) {
                onCreateList(storyName, selectedServiceIds)
                storyName = ""
            }
        }
    }

    var choosePage: some View {
        ModalPage(modalName: "EditDistributionListModal__\(page)", strings: strings,
                  title: page == .hideStoryFrom ? i18n("icu:StoriesSettings__hide-story") : i18n("icu:StoriesSettings__choose-viewers"),
                  hasXButton: true, padded: !isChoosingViewers, onBackButtonClick: onBackButtonClick, onClose: onClose) {
            SearchInput(value: $searchTerm, placeholder: i18n("icu:contactSearchPlaceholder"), disabled: candidateConversations.isEmpty) { EmptyView() }
            if !selectedContacts.isEmpty {
                ContactPills(count: selectedContacts.count) {
                    ForEach(selectedContacts) { contact in
                        ContactPill(id: contact.id, title: contact.title, firstName: contact.firstName, color: contact.listItem.avatar.color ?? "A200",
                                    image: contact.listItem.avatar.image.map { AnyView(PixelImage($0, fit: .cover)) },
                                    hasAvatar: contact.listItem.avatar.hasAvatar, avatarStrings: AvatarStrings(i18n: i18n),
                                    removeLabel: i18n("icu:ContactPill--remove")) { toggle($0) }
                    }
                }
            }
            if candidateConversations.isEmpty {
                CSSText(i18n("icu:noContactsFound"), style: LegacyType.body1(), color: .labelPrimary)
                    .frame(maxWidth: .infinity)
            } else {
                // __conversation-list: at least 300px.
                AxoDialog.AxoScrollContainer {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { contact in
                            ContactCheckbox(contact.listItem, isChecked: selectedContacts.contains { $0.id == contact.id }) { id, _ in toggle(id) }
                                .frame(height: 52, alignment: .top)
                        }
                    }
                }
                .frame(minHeight: 300)
            }
        } footer: {
            LegacyButton(page == .hideStoryFrom ? i18n("icu:update") : page == .addViewer ? i18n("icu:done") : i18n("icu:next2"),
                         variant: .primary, disabled: selectedContacts.isEmpty) { onViewersUpdated(selectedServiceIds) }
        }
        .task(id: searchTerm) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            filtered = ConversationSearch.filterAndSort(candidateConversations, searchTerm: searchTerm.trimmingCharacters(in: .whitespaces),
                                                        regionCode: regionCode).filter { $0.serviceId != nil }
        }
    }
}

/// `GroupStorySettingsModal`: the group, its members, who can see it, and "Remove group story".
struct GroupStorySettingsPage: View {
    let group: GroupStoryInfo
    let onClose: () -> Void
    let onBackButtonClick: () -> Void
    let onRemoveGroup: () -> Void
    @Environment(\.i18n) var i18n

    var body: some View {
        ModalPage(modalName: "GroupStorySettingsModal", strings: ModalStrings(back: i18n("icu:back"), close: i18n("icu:close")),
                  title: group.title, hasXButton: true, onBackButtonClick: onBackButtonClick, onClose: onClose) {
            HStack(spacing: 12) {
                ListAvatar(data: group.avatar, size: 32)
                CSSText(runs: [Emojify.run(group.title)], style: LegacyType.body1())
                Spacer(minLength: 0)
            }
            .padding(.bottom, 12)
            StoriesSettingsDivider()
            CSSText(i18n("icu:GroupStorySettingsModal__members_title"), style: LegacyType.body1(weight: 600))
                .padding(.vertical, 14)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(group.members) { member in
                    HStack(spacing: 12) {
                        ListAvatar(data: member.listItem.avatar, size: 32)
                        CSSText(runs: [Emojify.run(member.title)], style: LegacyType.body1())
                            .padding(.vertical, 14)
                        Spacer(minLength: 0)
                    }
                }
            }
            CSSBlockText(i18n("icu:GroupStorySettingsModal__members_help", ["groupTitle": .string(group.title)]), style: LegacyType.body2(),
                         color: StoriesSettingsStyle.secondary)
                .padding(.vertical, 14)
            StoriesSettingsDivider()
            StoriesSettingsDestructiveRow(icon: "v3/minus/minus-circle", text: i18n("icu:GroupStorySettingsModal__remove_group"), action: onRemoveGroup)
                .padding(.top, 12)
        }
    }
}
