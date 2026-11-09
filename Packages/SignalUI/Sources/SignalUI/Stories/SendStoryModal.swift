// Port of ts/components/SendStoryModal.dom.tsx (+ stylesheets/components/SendStoryModal.scss):
// "Send to" — the story's 80×140 preview, "Stories" with the "+ New" menu (custom story or
// group story), then My Story, the group stories and the custom lists (My Story first, the
// rest by recency) as round checkboxes; the footer lists the chosen names with the send
// button. Each row's context menu opens its settings or deletes it. Other pages:
//   SetMyStoriesPrivacy      the first post to My Story: pick who can see it (EditMyStoryPrivacy)
//   EditingDistributionList  a list's settings (DistributionListSettingsModal)
//   ChooseViewers / NameStory / AddViewer / HideStoryFrom   EditDistributionListModal
//   ChooseGroups             pick groups to post stories to

import SignalI18n
import SwiftUI

public struct SendStoryActions {
    public var onClose: () -> Void = {}
    public var onSend: (_ listIds: [String], _ conversationIds: [String]) -> Void = { _, _ in }
    public var onDeleteList: (String) -> Void = { _ in }
    /// Creates the list and returns its id.
    public var onDistributionListCreated: (_ name: String, _ viewerServiceIds: [String]) -> String = { _, _ in "" }
    public var onSelectedStoryList: (_ conversationId: String, _ distributionId: String?, _ serviceIds: [String]) -> Void = { _, _, _ in }
    public var toggleGroupsForStorySend: ([String]) -> Void = { _ in }
    public var settings = StoriesSettingsActions()
    public init() {}
}

public struct SendStoryModal: View {
    enum Page: Hashable { case sendStory, chooseGroups, editingDistributionList, setMyStoriesPrivacy, settings(StoriesSettingsPage) }

    let draftAttachment: StoryAttachmentData
    let candidateConversations: [SearchableConversation]
    let distributionLists: [StoryDistributionList]
    let groupConversations: [GroupStoryInfo]
    let groupStories: [GroupStoryInfo]
    let hasFirstStoryPostExperience: Bool
    let ourConversationId: String?
    let me: ConversationAvatarData
    let signalConnections: [SearchableConversation]
    let mostRecentActiveStoryTimestamp: [String: Double]
    let regionCode: String?
    let actions: SendStoryActions
    @State private var page: Page = .sendStory
    @State private var selectedListIds: [String] = []
    @State private var selectedGroupIds: Set<String> = []
    @State private var chosenGroupIds: Set<String> = []
    @State private var groupSearchTerm = ""
    @State private var selectedContacts: [SearchableConversation] = []
    @State private var hasAnnouncementsOnlyAlert = false
    @State private var confirmRemoveGroupId: String?
    @State private var confirmDeleteList: (id: String, name: String)?
    @State private var listIdToEdit: String?
    @State private var stagedMyStories: StoryDistributionList?
    @State private var confirmDiscard: (() -> Void)?
    @Environment(\.i18n) var i18n

    public init(draftAttachment: StoryAttachmentData, candidateConversations: [SearchableConversation], distributionLists: [StoryDistributionList],
                groupConversations: [GroupStoryInfo], groupStories: [GroupStoryInfo], hasFirstStoryPostExperience: Bool = false,
                ourConversationId: String? = nil, me: ConversationAvatarData, signalConnections: [SearchableConversation],
                mostRecentActiveStoryTimestamp: [String: Double] = [:], regionCode: String? = nil, actions: SendStoryActions = SendStoryActions()) {
        self.draftAttachment = draftAttachment
        self.candidateConversations = candidateConversations
        self.distributionLists = distributionLists
        self.groupConversations = groupConversations
        self.groupStories = groupStories
        self.hasFirstStoryPostExperience = hasFirstStoryPostExperience
        self.ourConversationId = ourConversationId
        self.me = me
        self.signalConnections = signalConnections
        self.mostRecentActiveStoryTimestamp = mostRecentActiveStoryTimestamp
        self.regionCode = regionCode
        self.actions = actions
    }

    var strings: ModalStrings { ModalStrings(back: i18n("icu:back"), close: i18n("icu:close")) }
    var listToEdit: StoryDistributionList? { listIdToEdit.flatMap { id in distributionLists.first { $0.id == id } } }

    /// The first-post privacy page's working copy of My Story.
    var initialMyStories: StoryDistributionList {
        let og = distributionLists.first { $0.isMyStory }
        return StoryDistributionList(id: MyStoryList.myStoryId, name: i18n("icu:Stories__mine"), allowsReplies: true,
                                     isBlockList: og?.isBlockList ?? true, members: og?.members ?? [])
    }
    var myStories: StoryDistributionList { stagedMyStories ?? initialMyStories }

    var selectedStoryNames: [String] {
        distributionLists.filter { selectedListIds.contains($0.id) }.map { $0.displayName(i18n) }
            + groupStories.filter { selectedGroupIds.contains($0.id) }.map(\.title)
    }

    /// `getListMemberServiceIds`: My Story as a block list is every connection not excluded.
    func memberServiceIds(_ list: StoryDistributionList) -> [String] {
        let ids = list.members.compactMap(\.serviceId)
        if list.isMyStory && list.isBlockList {
            let excluded = Set(ids)
            return signalConnections.compactMap(\.serviceId).filter { !excluded.contains($0) }
        }
        return ids
    }

    func confirmDiscardIf(_ condition: Bool, _ action: @escaping () -> Void) {
        if condition { confirmDiscard = action } else { action() }
    }

    func onTryClose() { confirmDiscardIf(!selectedContacts.isEmpty, actions.onClose) }

    public var body: some View {
        ModalHost(onClose: onTryClose) { currentPage }
            .overlay { dialogs }
    }

    @ViewBuilder var currentPage: some View {
        switch page {
        case .setMyStoriesPrivacy: privacyPage
        case .editingDistributionList:
            if let listToEdit {
                var settings = actions.settings
                let _ = { settings.onDeleteList = actions.onDeleteList }()
                DistributionListSettingsPage(listToEdit: listToEdit, signalConnectionsCount: signalConnections.count, actions: settings,
                                             onDeleteList: { confirmDeleteList = (listToEdit.id, listToEdit.name) },
                                             setPage: { page = .settings($0) }, setSelectedContacts: { selectedContacts = $0 },
                                             onBackButtonClick: { confirmDiscardIf(!selectedContacts.isEmpty) { closeListEditor() } },
                                             onClose: onTryClose)
            } else {
                sendPage
            }
        case .settings(let settingsPage): editListPage(settingsPage)
        case .chooseGroups: chooseGroupsPage
        case .sendStory: sendPage
        }
    }

    func closeListEditor() {
        listIdToEdit = nil
        page = .sendStory
    }

    func editListPage(_ settingsPage: StoriesSettingsPage) -> some View {
        EditDistributionListPage(candidateConversations: candidateConversations, page: settingsPage, regionCode: regionCode,
                                 selectedContacts: $selectedContacts, onClose: onTryClose,
                                 onBackButtonClick: {
                                     confirmDiscardIf(!selectedContacts.isEmpty) {
                                         if listIdToEdit != nil {
                                             if settingsPage == .nameStory { closeListEditor() } else { page = .editingDistributionList }
                                         } else if settingsPage == .hideStoryFrom || settingsPage == .addViewer {
                                             selectedContacts = []
                                             stagedMyStories = initialMyStories
                                             page = .setMyStoriesPrivacy
                                         } else if settingsPage == .chooseViewers {
                                             selectedContacts = []
                                             page = .sendStory
                                         } else if settingsPage == .nameStory {
                                             page = .settings(.chooseViewers)
                                         }
                                     }
                                 },
                                 onCreateList: { name, ids in
                                     let id = actions.onDistributionListCreated(name, ids)
                                     selectedContacts = []
                                     if !selectedListIds.contains(id) { selectedListIds.append(id) }
                                     page = .sendStory
                                 },
                                 onViewersUpdated: { ids in
                                     if let listIdToEdit, settingsPage == .addViewer {
                                         actions.settings.onViewersUpdated(listIdToEdit, ids)
                                         page = .editingDistributionList
                                     } else if settingsPage == .chooseViewers {
                                         page = .settings(.nameStory)
                                     } else if listIdToEdit != nil, settingsPage == .hideStoryFrom {
                                         actions.settings.onHideMyStoriesFrom(ids)
                                         page = .sendStory
                                     } else if settingsPage == .hideStoryFrom || settingsPage == .addViewer {
                                         let set = Set(ids)
                                         var staged = myStories
                                         staged.members = candidateConversations.filter { $0.serviceId.map(set.contains) ?? false }
                                         stagedMyStories = staged
                                         page = .setMyStoriesPrivacy
                                     } else {
                                         page = .sendStory
                                     }
                                 })
    }

    var privacyPage: some View {
        ModalPage(modalName: "SendStoryModal__my-stories-privacy", strings: strings, title: i18n("icu:SendStoryModal__my-stories-privacy"),
                  hasXButton: true, onClose: onTryClose) {
            EditMyStoryPrivacy(hasDisclaimerAbove: true, kind: .privacy, myStories: myStories, signalConnectionsCount: signalConnections.count,
                               onClickExclude: {
                                   var next = myStories.members
                                   if !myStories.isBlockList {
                                       var staged = myStories
                                       staged.isBlockList = true
                                       staged.members = []
                                       stagedMyStories = staged
                                       next = []
                                   }
                                   selectedContacts = next
                                   page = .settings(.hideStoryFrom)
                               },
                               onClickOnlyShareWith: {
                                   if !myStories.isBlockList {
                                       selectedContacts = myStories.members
                                   } else {
                                       var staged = myStories
                                       staged.isBlockList = false
                                       staged.members = []
                                       stagedMyStories = staged
                                   }
                                   page = .settings(.addViewer)
                               },
                               setSelectedContacts: { selectedContacts = $0 },
                               setMyStoriesToAllSignalConnections: {
                                   var staged = myStories
                                   staged.isBlockList = true
                                   staged.members = []
                                   stagedMyStories = staged
                                   selectedContacts = []
                               },
                               toggleSignalConnectionsModal: actions.settings.toggleSignalConnectionsModal)
        } footer: {
            Color.clear.frame(width: 0, height: 0)
            HStack(spacing: 0) {
                LegacyButton(i18n("icu:cancel"), variant: .secondary) { page = .sendStory }
                LegacyButton(i18n("icu:save"), variant: .primary) {
                    let staged = myStories
                    let ids = staged.members.compactMap(\.serviceId)
                    if staged.isBlockList {
                        if staged.members.isEmpty { actions.settings.setMyStoriesToAllSignalConnections() } else { actions.settings.onHideMyStoriesFrom(ids) }
                    } else {
                        actions.settings.onViewersUpdated(MyStoryList.myStoryId, ids)
                    }
                    selectedContacts = []
                    page = .sendStory
                }
                .padding(.leading, 4)
            }
        }
    }

    // MARK: Choose groups

    var filteredGroups: [GroupStoryInfo] {
        let searchable = groupConversations.map { g in
            SearchableConversation(listItem: ContactListItemData(id: g.id, title: g.title, type: .group, avatar: g.avatar))
        }
        let ids = ConversationSearch.filterAndSort(searchable, searchTerm: groupSearchTerm.trimmingCharacters(in: .whitespaces), regionCode: regionCode)
            .map(\.id)
        return ids.compactMap { id in groupConversations.first { $0.id == id } }
    }

    var chooseGroupsPage: some View {
        let groups = filteredGroups
        let names = groups.filter { chosenGroupIds.contains($0.id) }.map(\.title).joined(separator: ", ")
        return ModalPage(modalName: "SendStoryModal__choose-groups", strings: strings, title: i18n("icu:SendStoryModal__choose-groups"),
                         hasXButton: true, onClose: onTryClose) {
            SearchInput(value: $groupSearchTerm, placeholder: i18n("icu:contactSearchPlaceholder"), disabled: groupConversations.isEmpty) { EmptyView() }
                .padding(.horizontal, -16)      // .module-SearchInput__container { margin-inline: 0 }
            if groups.isEmpty {
                CSSText(i18n("icu:noGroupsFound"), style: LegacyType.body1(), color: .labelPrimary).frame(maxWidth: .infinity)
            } else {
                ForEach(groups) { group in
                    SendStoryRow(avatar: .conversation(group.avatar), name: group.title,
                                 description: i18n("icu:ConversationHero--members", ["count": .number(Double(group.membersCount))]),
                                 checked: chosenGroupIds.contains(group.id)) { value in
                        if group.announcementsOnly && !group.areWeAdmin {
                            hasAnnouncementsOnlyAlert = true
                            return
                        }
                        if value { chosenGroupIds.insert(group.id) } else { chosenGroupIds.remove(group.id) }
                    }
                }
            }
        } footer: {
            SendStoryFooter(names: names, buttonLabel: i18n("icu:ok"), icon: "v3/check/check", disabled: chosenGroupIds.isEmpty) {
                actions.toggleGroupsForStorySend(Array(chosenGroupIds))
                selectedGroupIds = chosenGroupIds
                chosenGroupIds = []
                page = .sendStory
            }
        }
        .noBodyBottomPadding()
    }

    // MARK: Send

    /// My Story first, then the groups and lists by their latest story (stable).
    var fullList: [SendStoryEntry] {
        let entries = groupStories.filter { !$0.terminated }.map(SendStoryEntry.group) + distributionLists.map(SendStoryEntry.list)
        return entries.enumerated().sorted { a, b in
            func key(_ e: SendStoryEntry) -> Double {
                if case .list(let l) = e, l.isMyStory { return -.infinity }
                return -(mostRecentActiveStoryTimestamp[e.id] ?? 0)
            }
            let ka = key(a.element), kb = key(b.element)
            return ka == kb ? a.offset < b.offset : ka < kb
        }.map(\.element)
    }

    var sendPage: some View {
        let names = selectedStoryNames.joined(separator: ", ")
        return ModalPage(modalName: "SendStoryModal__title", strings: strings, title: i18n("icu:SendStoryModal__title"), hasXButton: true,
                         onClose: onTryClose) {
            // __story-preview: 80×140, 12px corners, the story's background (cover), 16px below.
            StoryImage(attachment: draftAttachment, firstName: i18n("icu:you"), fitContain: true)
                .frame(width: 80, height: 140)
                .background { SendStoryPreviewBackground(attachment: draftAttachment) }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 16)
            // __top-bar: min-height 40, "Stories" and the "+ New" menu.
            HStack(spacing: 0) {
                CSSText(i18n("icu:stories"), style: LegacyType.body1(), wrap: .nowrap)
                    .frame(maxWidth: .infinity, alignment: .leading)
                NewStoryMenu { page = .settings(.chooseViewers) } onNewGroup: { page = .chooseGroups }
            }
            .frame(minHeight: 40)
            ForEach(fullList) { entry in
                switch entry {
                case .list(let list): listRow(list)
                case .group(let group): groupRow(group)
                }
            }
        } footer: {
            SendStoryFooter(names: names, buttonLabel: i18n("icu:SendStoryModal__send"), icon: "v3/send/send-fill",
                            disabled: selectedListIds.isEmpty && selectedGroupIds.isEmpty) {
                actions.onSend(selectedListIds, Array(selectedGroupIds))
            }
        }
        .noBodyBottomPadding()
    }

    func listRow(_ list: StoryDistributionList) -> some View {
        let description: String
        if hasFirstStoryPostExperience && list.isMyStory {
            description = i18n("icu:SendStoryModal__choose-who-can-view")
        } else {
            let kind = list.isMyStory ? list.myStoryLabel(i18n) : i18n("icu:SendStoryModal__custom-story")
            let count = list.isBlockList && !list.members.isEmpty
                ? i18n("icu:SendStoryModal__excluded", ["count": .number(Double(list.members.count))])
                : list.viewers(i18n, signalConnectionsCount: signalConnections.count)
            description = kind + "\u{00A0}·\u{00A0}" + count
        }
        return SendStoryRow(avatar: list.isMyStory ? .conversation(me) : .icon("v3/stories/stories"), name: list.displayName(i18n),
                            description: description, checked: selectedListIds.contains(list.id)) { value in
            if list.isMyStory && hasFirstStoryPostExperience && value {
                page = .setMyStoriesPrivacy
                return
            }
            if value { if !selectedListIds.contains(list.id) { selectedListIds.append(list.id) } } else { selectedListIds.removeAll { $0 == list.id } }
            if value, let ourConversationId {
                actions.onSelectedStoryList(ourConversationId, list.id, memberServiceIds(list))
            }
        }
        .contextMenu {
            Button(i18n("icu:StoriesSettings__context-menu")) {
                listIdToEdit = list.id
                page = .editingDistributionList
            }
            if !list.isMyStory {
                Button(i18n("icu:SendStoryModal__delete-story")) { confirmDeleteList = (list.id, list.name) }
            }
        }
    }

    func groupRow(_ group: GroupStoryInfo) -> some View {
        SendStoryRow(avatar: .conversation(group.avatar), name: group.title,
                     description: i18n("icu:SendStoryModal__group-story") + "\u{00A0}·\u{00A0}"
                         + i18n("icu:ConversationHero--members", ["count": .number(Double(group.membersCount))]),
                     checked: selectedGroupIds.contains(group.id)) { value in
            guard let members = group.memberServiceIds else { return }
            if group.announcementsOnly && !group.areWeAdmin {
                hasAnnouncementsOnlyAlert = true
                return
            }
            if value { selectedGroupIds.insert(group.id) } else { selectedGroupIds.remove(group.id) }
            if value { actions.onSelectedStoryList(group.id, nil, members) }
        }
        .contextMenu {
            Button(i18n("icu:SendStoryModal__delete-story")) { confirmRemoveGroupId = group.id }
        }
    }

    @ViewBuilder var dialogs: some View {
        if hasAnnouncementsOnlyAlert {
            AxoConfirmDialog.Root(title: nil, description: i18n("icu:SendStoryModal__announcements-only")) {
                AxoConfirmDialog.Ok(i18n("icu:Confirmation--confirm")) { hasAnnouncementsOnlyAlert = false }
            }
        } else if let id = confirmRemoveGroupId {
            AxoConfirmDialog.Root(title: nil, description: i18n("icu:SendStoryModal__confirm-remove-group")) {
                AxoConfirmDialog.Cancel(i18n("icu:cancel")) { confirmRemoveGroupId = nil }
                AxoConfirmDialog.Action(i18n("icu:delete"), variant: .strongDestructive) {
                    actions.toggleGroupsForStorySend([id])
                    confirmRemoveGroupId = nil
                }
            }
        } else if let list = confirmDeleteList {
            AxoConfirmDialog.Root(title: nil, description: i18n("icu:StoriesSettings__delete-list--confirm", ["name": .string(list.name)])) {
                AxoConfirmDialog.Action(i18n("icu:delete"), variant: .strongDestructive) {
                    actions.onDeleteList(list.id)
                    confirmDeleteList = nil
                }
            }
        } else if let pending = confirmDiscard {
            ConfirmDiscardDialog(onClose: { confirmDiscard = nil }) {
                confirmDiscard = nil
                pending()
            }
        }
    }
}

enum SendStoryEntry: Identifiable {
    case list(StoryDistributionList)
    case group(GroupStoryInfo)
    var id: String {
        switch self {
        case .list(let l): l.id
        case .group(let g): g.id
        }
    }
}

/// `getStoryBackground`: the text story's colour or gradient (a picture's own pixels show anyway).
struct SendStoryPreviewBackground: View {
    let attachment: StoryAttachmentData
    var body: some View {
        if let text = attachment.textAttachment {
            StoryColors.background(text)
        } else if let image = attachment.image ?? attachment.thumbnail {
            PixelImage(image, fit: .cover)
        }
    }
}

/// `.SendStoryModal__distribution-list`: a 52px row (its 54px content overflows it) with the
/// 32px avatar, the name (body-1) over the 12px gray-25 description, and a round checkbox.
struct SendStoryRow: View {
    let avatar: StoriesSettingsListRow.AvatarKind
    let name: String
    let description: String
    let checked: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Button { onChange(!checked) } label: {
            HStack(alignment: .center, spacing: 0) {
                HStack(alignment: .center, spacing: 8) {
                    StoriesSettingsListRow(avatar: avatar, title: "", action: nil).avatarView
                    VStack(alignment: .leading, spacing: 0) {
                        CSSText(runs: [Emojify.run(name)], style: LegacyType.body1(), wrap: .truncate)
                        CSSText(description, style: CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 12, lineHeight: 18,
                                                                 letterSpacing: LegacyType.body2().letterSpacing),
                                wrap: .truncate, color: AxoColor(LegacyColor.gray25))
                    }
                    Spacer(minLength: 0)
                }
                SendStoryCheckbox(checked: checked)
            }
            .padding(.vertical, 8)
            .frame(height: 52, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(UndimmedButtonStyle())
        .accessibilityAddTraits(checked ? [.isSelected] : [])
    }
}

/// The restyled checkbox: an 18px box drawing a 20px circle from its top-left corner, a 1.5px
/// gray-60 ring, or ultramarine with a white check (a rotated 6×11 corner, 2px strokes).
struct SendStoryCheckbox: View {
    let checked: Bool
    var body: some View {
        Color.clear.frame(width: 18, height: 18)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    if checked {
                        Circle().fill(Color(rgba: LegacyColor.ultramarine))
                        SendStoryCheckMark()
                            .stroke(Color(rgba: LegacyColor.white), style: StrokeStyle(lineWidth: 2))
                            .frame(width: 6, height: 11)
                            .rotationEffect(.degrees(45))
                            .offset(x: 7, y: 3)
                    } else {
                        Circle().strokeBorder(Color(rgba: LegacyColor.gray60), lineWidth: 1.5)
                    }
                }
                .frame(width: 20, height: 20)
            }
    }
}

/// The check's right and bottom border edges, inset by half the stroke.
struct SendStoryCheckMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX - 1, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 1, y: r.maxY - 1))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - 1))
        return p
    }
}

/// The footer: the chosen names (body-2 gray-15, at least 32px tall, flex 1) and, once there
/// are any, the 32px ultramarine send / ok button (gray-60 when disabled).
struct SendStoryFooter: View {
    let names: String
    let buttonLabel: String
    let icon: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        CSSText(names, style: LegacyType.body2(), wrap: .wrap, color: AxoColor(LegacyColor.gray15))
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .padding(.trailing, 16)
            .layoutPriority(1)
        if !names.isEmpty {
            Button(action: action) {
                SignalIcon(icon, size: 18, color: AxoColor(LegacyColor.white), mask: true)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color(rgba: disabled ? LegacyColor.gray60 : LegacyColor.ultramarine)))
                    .contentShape(Circle())
            }
            .buttonStyle(UndimmedButtonStyle())
            .disabled(disabled)
            .accessibilityLabel(buttonLabel)
            .padding(.leading, -4)      // a plain button: no `.module-Button` margin
        }
    }
}

/// "+ New": a custom story or a group story.
struct NewStoryMenu: View {
    let onNewCustom: () -> Void
    let onNewGroup: () -> Void
    @State private var open = false
    @Environment(\.i18n) var i18n

    var body: some View {
        AxoDropdownMenu.Root(isOpen: $open) {
            AxoButton.Root(i18n("icu:SendStoryModal__new"), variant: .strongSecondary, size: .sm, symbol: "plus")
        } items: {
            AxoDropdownMenu.Item(i18n("icu:SendStoryModal__new-custom--title"), symbol: "stories",
                                 description: i18n("icu:SendStoryModal__new-custom--description"), action: onNewCustom)
            AxoDropdownMenu.Item(i18n("icu:SendStoryModal__new-group--title"), symbol: "group",
                                 description: i18n("icu:SendStoryModal__new-group--description"), action: onNewGroup)
        }
    }
}
