// Port of ts/components/preferences/PreferencesSelectChatsDialog.dom.tsx: choose the chats
// (and, optionally, the 1:1 / group chat types) a chat folder includes.

import SignalI18n
import SwiftUI

/// `ChatFolderSelection`
public struct ChatFolderSelection: Equatable {
    public var selectedRecipientIds: [String]
    public var selectAllIndividualChats: Bool
    public var selectAllGroupChats: Bool

    public init(selectedRecipientIds: [String] = [], selectAllIndividualChats: Bool = false, selectAllGroupChats: Bool = false) {
        self.selectedRecipientIds = selectedRecipientIds
        self.selectAllIndividualChats = selectAllIndividualChats
        self.selectAllGroupChats = selectAllGroupChats
    }
}

/// What a pill shows for a selected id (`conversationSelector`).
public struct SelectedChatPill {
    public var data: ContactListItemData
    public var firstName: String?
    public init(data: ContactListItemData, firstName: String? = nil) {
        self.data = data
        self.firstName = firstName
    }
}

public struct PreferencesSelectChatsDialog: View {
    let title: String
    let conversations: [SearchableConversation]
    let conversationSelector: (String) -> SelectedChatPill
    let showChatTypes: Bool
    let onClose: (ChatFolderSelection) -> Void
    @State private var search = ""
    @State private var selectAllIndividualChats: Bool
    @State private var selectAllGroupChats: Bool
    /// Insertion-ordered, as upstream's Set.
    @State private var selectedRecipientIds: [String]
    @Environment(\.i18n) var i18n

    public init(title: String, conversations: [SearchableConversation], conversationSelector: @escaping (String) -> SelectedChatPill,
                initialSelection: ChatFolderSelection = ChatFolderSelection(), showChatTypes: Bool = false,
                onClose: @escaping (ChatFolderSelection) -> Void = { _ in }) {
        self.title = title
        self.conversations = conversations
        self.conversationSelector = conversationSelector
        self.showChatTypes = showChatTypes
        self.onClose = onClose
        _selectAllIndividualChats = State(initialValue: initialSelection.selectAllIndividualChats)
        _selectAllGroupChats = State(initialValue: initialSelection.selectAllGroupChats)
        var seen = Set<String>()
        _selectedRecipientIds = State(initialValue: initialSelection.selectedRecipientIds.filter { seen.insert($0).inserted })
    }

    func toggle(_ id: String) {
        if let i = selectedRecipientIds.firstIndex(of: id) { selectedRecipientIds.remove(at: i) } else { selectedRecipientIds.append(id) }
    }

    func close() {
        onClose(ChatFolderSelection(selectedRecipientIds: selectedRecipientIds, selectAllIndividualChats: selectAllIndividualChats,
                                    selectAllGroupChats: selectAllGroupChats))
    }

    var rows: [ConversationListRow] {
        var out: [ConversationListRow] = []
        let filtered = ConversationSearch.filterAndSort(conversations, searchTerm: search, regionCode: nil)
        if showChatTypes && search.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(.header(i18n("icu:Preferences__EditChatFolderPage__SelectChatsDialog__ChatTypesSection__Title")))
            out.append(.genericCheckbox(icon: .contact, label: i18n("icu:Preferences__EditChatFolderPage__SelectChatsDialog__ChatTypesSection__DirectChats"),
                                        isChecked: selectAllIndividualChats, onClick: { selectAllIndividualChats.toggle() }))
            out.append(.genericCheckbox(icon: .group, label: i18n("icu:Preferences__EditChatFolderPage__SelectChatsDialog__ChatTypesSection__GroupChats"),
                                        isChecked: selectAllGroupChats, onClick: { selectAllGroupChats.toggle() }))
            out.append(.header(i18n("icu:Preferences__EditChatFolderPage__SelectChatsDialog__RecentChats__Title")))
        }
        for c in filtered {
            out.append(.contactCheckbox(c.listItem, isChecked: selectedRecipientIds.contains(c.id)))
        }
        if filtered.isEmpty {
            out.append(.emptyResults(i18n("icu:Preferences__EditChatFolderPage__SelectChatsDialog__NoChats")))
        }
        return out
    }

    public var body: some View {
        var actions = ConversationListActions()
        actions.onClickContactCheckbox = { id, _ in toggle(id) }
        let rows = rows
        return AxoDialog.Content(size: .md) {
            AxoDialog.Header {
                AxoDialog.Title(title)
                AxoDialog.Close(action: close)
            }
            AxoDialog.Search {
                SearchInput(value: $search, placeholder: i18n("icu:Preferences__EditChatFolderPage__SelectChatsDialog__Search__Placeholder"),
                            noMargin: true) { EmptyView() }
            }
            AxoDialog.Body(padding: .onlyScrollbarGutter) {
                VStack(spacing: 0) {
                    if !selectedRecipientIds.isEmpty {
                        ContactPills(count: selectedRecipientIds.count) {
                            ForEach(selectedRecipientIds, id: \.self) { id in
                                let p = conversationSelector(id)
                                ContactPill(id: id, title: p.data.title, firstName: p.firstName, color: p.data.avatar.color ?? "A200",
                                            image: p.data.avatar.image.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: p.data.avatar.image != nil,
                                            avatarStrings: AvatarStrings(i18n: i18n), removeLabel: i18n("icu:ContactPill--remove"), onClickRemove: toggle)
                            }
                        }
                    }
                    // h-96: the conversation list's own scroller.
                    AxoDialog.AxoScrollContainer {
                        VStack(spacing: 0) {
                            ForEach(rows.indices, id: \.self) { i in
                                ConversationListRowView(row: rows[i], actions: actions).frame(height: rows[i].height, alignment: .top)
                            }
                        }
                        .padding(.horizontal, 11)
                    }
                    .frame(height: 384)
                    .cssTextColor(.labelPrimary)            // text-primary
                }
            }
            AxoDialog.Footer {
                AxoDialog.Actions {
                    AxoDialog.Action(i18n("icu:Preferences__EditChatFolderPage__SelectChatsDialog__DoneButton"), variant: .strongPrimary, action: close)
                }
            }
        }
    }
}
