// Ports of ts/components/conversation/conversation-details/AddGroupMembersModal.dom.tsx, its
// AddGroupMembersModal/ChooseGroupMembersModal.dom.tsx and ConfirmAdditionsModal.dom.tsx, and
// ts/components/AddGroupMemberErrorDialog.dom.tsx (stylesheets/components/AddGroupMembersModal.scss).
//
// Choosing: a legacy 342px × 60vh modal with a search input, the selected contacts as pills,
// a checkbox list of candidates (already-added ones checked and disabled) and Cancel / Update.
// Confirming: "Add N members to "Group"?". Full groups first show the maximum-size dialog,
// and crossing the recommended size shows its warning once.
//
// Finding people by phone number or username (the extra rows) is not ported yet.

import SignalI18n
import SwiftUI

public struct AddGroupMembersModal: View {
    enum Stage { case choosingContacts, confirmingAdds }
    enum OneTimeModal { case neverShown, showing, shown }

    let candidateContacts: [ContactListItemData]
    let conversationIdsAlreadyInGroup: Set<String>
    let groupTitle: String
    let maxGroupSize: Int
    let maxRecommendedGroupSize: Int
    let requestState: RequestState
    let search: ([ContactListItemData], String) -> [ContactListItemData]
    let makeRequest: ([String]) -> Void
    let clearRequestError: () -> Void
    let onClose: () -> Void
    @State private var stage = Stage.choosingContacts
    @State private var searchTerm = ""
    @State private var selected: [String] = []
    @State private var maximumModal: OneTimeModal
    @State private var recommendedModal: OneTimeModal

    public init(candidateContacts: [ContactListItemData], conversationIdsAlreadyInGroup: Set<String> = [], groupTitle: String,
                maxGroupSize: Int = 1001, maxRecommendedGroupSize: Int = 151, requestState: RequestState = .inactive,
                search: @escaping ([ContactListItemData], String) -> [ContactListItemData] = AddGroupMembersModal.defaultSearch,
                makeRequest: @escaping ([String]) -> Void = { _ in }, clearRequestError: @escaping () -> Void = {}, onClose: @escaping () -> Void = {}) {
        self.candidateContacts = candidateContacts
        self.conversationIdsAlreadyInGroup = conversationIdsAlreadyInGroup
        self.groupTitle = groupTitle
        self.maxGroupSize = maxGroupSize
        self.maxRecommendedGroupSize = maxRecommendedGroupSize
        self.requestState = requestState
        self.search = search
        self.makeRequest = makeRequest
        self.clearRequestError = clearRequestError
        self.onClose = onClose
        _maximumModal = State(initialValue: conversationIdsAlreadyInGroup.count >= maxGroupSize ? .showing : .neverShown)
        _recommendedModal = State(initialValue: conversationIdsAlreadyInGroup.count >= maxRecommendedGroupSize ? .shown : .neverShown)
    }

    /// `filterAndSortConversations(candidateContacts, searchTerm, regionCode)`.
    nonisolated public static func defaultSearch(_ contacts: [ContactListItemData], _ term: String) -> [ContactListItemData] {
        let byId = Dictionary(contacts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ConversationSearch.filterAndSort(contacts.map { SearchableConversation(listItem: $0) }, searchTerm: term, regionCode: nil)
            .compactMap { byId[$0.id] }
    }

    func toggle(_ id: String) {
        if let i = selected.firstIndex(of: id) {
            selected.remove(at: i)
            return
        }
        let total = selected.count + conversationIdsAlreadyInGroup.count + 1
        guard total <= maxGroupSize else { return }
        selected.append(id)
        if total >= maxGroupSize { maximumModal = maximumModal == .neverShown ? .showing : maximumModal }
        if total >= maxRecommendedGroupSize, recommendedModal == .neverShown { recommendedModal = .showing }
    }

    public var body: some View {
        if maximumModal == .showing {
            AddGroupMemberMaximumGroupSizeErrorDialog(maximumNumberOfContacts: maxGroupSize) { maximumModal = .shown }
        } else if recommendedModal == .showing {
            AddGroupMemberRecommendedMaximumGroupSizeErrorDialog(recommendedMaximumNumberOfContacts: maxRecommendedGroupSize) { recommendedModal = .shown }
        } else {
            switch stage {
            case .choosingContacts:
                ChooseGroupMembersModal(candidateContacts: search(candidateContacts, searchTerm.trimmingCharacters(in: .whitespaces)),
                                        selectedContacts: selected.compactMap { id in candidateContacts.first { $0.id == id } },
                                        conversationIdsAlreadyInGroup: conversationIdsAlreadyInGroup,
                                        hasSelectedMaximum: selected.count + conversationIdsAlreadyInGroup.count >= maxGroupSize,
                                        searchTerm: $searchTerm, toggleSelectedContact: toggle,
                                        removeSelectedContact: { id in selected.removeAll { $0 == id } },
                                        confirmAdds: { stage = .confirmingAdds }, onClose: onClose)
            case .confirmingAdds:
                ConfirmAdditionsModal(groupTitle: groupTitle, selectedContacts: selected.compactMap { id in candidateContacts.first { $0.id == id } },
                                      requestState: requestState, makeRequest: { makeRequest(selected) }, onClose: {
                    stage = .choosingContacts
                    clearRequestError()
                })
            }
        }
    }
}

public struct ChooseGroupMembersModal: View {
    let candidateContacts: [ContactListItemData]
    let selectedContacts: [ContactListItemData]
    let conversationIdsAlreadyInGroup: Set<String>
    let hasSelectedMaximum: Bool
    @Binding var searchTerm: String
    let toggleSelectedContact: (String) -> Void
    let removeSelectedContact: (String) -> Void
    let confirmAdds: () -> Void
    let onClose: () -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.legacyModalMaxHeight) var maxHeight

    public init(candidateContacts: [ContactListItemData], selectedContacts: [ContactListItemData], conversationIdsAlreadyInGroup: Set<String>,
                hasSelectedMaximum: Bool, searchTerm: Binding<String>, toggleSelectedContact: @escaping (String) -> Void,
                removeSelectedContact: @escaping (String) -> Void, confirmAdds: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.candidateContacts = candidateContacts
        self.selectedContacts = selectedContacts
        self.conversationIdsAlreadyInGroup = conversationIdsAlreadyInGroup
        self.hasSelectedMaximum = hasSelectedMaximum
        _searchTerm = searchTerm
        self.toggleSelectedContact = toggleSelectedContact
        self.removeSelectedContact = removeSelectedContact
        self.confirmAdds = confirmAdds
        self.onClose = onClose
    }

    var canContinue: Bool { !selectedContacts.isEmpty }

    var list: some View {
        // The virtualised ListView: 52px rows, clipped to the wrapper.
        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    ForEach(candidateContacts, id: \.id) { contact in
                        let isSelected = selectedContacts.contains { $0.id == contact.id }
                        let alreadyIn = conversationIdsAlreadyInGroup.contains(contact.id)
                        let reason: ContactCheckboxDisabledReason? = alreadyIn ? .alreadyAdded : hasSelectedMaximum && !isSelected ? .maximumContactsSelected : nil
                        ContactCheckbox(contact, isChecked: isSelected || alreadyIn, disabledReason: reason) { id, reason in
                            if reason == nil { toggleSelectedContact(id) }
                        }
                        .frame(height: 52, alignment: .top)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .clipped()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        // height: 60vh, min-height 400px (the host passes 89vh as its max height)
        let height = max(400, (maxHeight.isFinite ? maxHeight / 0.89 : 900) * 0.6)
        ModalHost(onClose: onClose) {
            VStack(alignment: .leading, spacing: 0) {
                CSSText(i18n("icu:AddGroupMembersModal--title"), style: LegacyType.body1(weight: 700), color: .labelPrimary)
                    .padding(16)
                    .accessibilityAddTraits(.isHeader)
                SearchInput(value: $searchTerm, placeholder: i18n("icu:contactSearchPlaceholder"), focusesOnAppear: true,
                            onEnter: { if canContinue { confirmAdds() } })
                if !selectedContacts.isEmpty {
                    ContactPills(count: selectedContacts.count) {
                        ForEach(selectedContacts, id: \.id) { c in
                            ContactPill(id: c.id, title: c.title, color: c.avatar.color ?? "A200",
                                        image: c.avatar.image.map { AnyView(PixelImage($0, fit: .cover)) },
                                        avatarStrings: AvatarStrings(i18n: i18n), removeLabel: i18n("icu:ContactPill--remove"),
                                        onClickRemove: removeSelectedContact)
                        }
                    }
                    .frame(maxHeight: 50)
                }
                if candidateContacts.isEmpty {
                    CSSText(i18n("icu:noContactsFound"), style: LegacyType.body1(), color: .labelPrimary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
                HStack(spacing: 12) {
                    LegacyButton(i18n("icu:cancel"), variant: .secondary, action: onClose)
                    LegacyButton(i18n("icu:AddGroupMembersModal--continue-to-confirm"), disabled: !canContinue, action: confirmAdds)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(width: 342, height: height)
            .cssTextColor(.labelPrimary)
            .background(shape.fill(AxoColor.materialDialog))
            .clipShape(shape)
            .cssBoxShadow(ModalPage<EmptyView, EmptyView>.popperShadow, in: shape)
            .overlay(alignment: .topTrailing) {
                // __close-button: x.svg, gray-75 / gray-15, 12px in
                SwiftUI.Button(action: onClose) {
                    SignalIcon("v3/x/x", size: 24, color: AxoColor(light: LegacyColor.gray75, dark: LegacyColor.gray15))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(i18n("icu:close"))
                .padding(12)
            }
            .frame(width: 360)
        }
    }
}

public struct ConfirmAdditionsModal: View {
    let groupTitle: String
    let selectedContacts: [ContactListItemData]
    let requestState: RequestState
    let makeRequest: () -> Void
    let onClose: () -> Void
    @Environment(\.i18n) var i18n

    public init(groupTitle: String, selectedContacts: [ContactListItemData], requestState: RequestState, makeRequest: @escaping () -> Void,
                onClose: @escaping () -> Void) {
        self.groupTitle = groupTitle
        self.selectedContacts = selectedContacts
        self.requestState = requestState
        self.makeRequest = makeRequest
        self.onClose = onClose
    }

    public var body: some View {
        let one = selectedContacts.count == 1
        let title = one
            ? i18n("icu:AddGroupMembersModal--confirm-title--one", ["person": .string(selectedContacts.first?.title ?? ""), "group": .string(groupTitle)])
            : i18n("icu:AddGroupMembersModal--confirm-title--many", ["count": .number(Double(selectedContacts.count)), "group": .string(groupTitle)])
        AxoConfirmDialog.Root(title: title, description: requestState == .inactiveWithError ? i18n("icu:updateGroupAttributes__error-message") : nil) {
            AxoConfirmDialog.Cancel(i18n("icu:cancel"), action: onClose)
            AxoConfirmDialog.Action(i18n(one ? "icu:AddGroupMembersModal--confirm-button--one" : "icu:AddGroupMembersModal--confirm-button--many"),
                                    variant: .strongPrimary, pending: requestState == .active, action: makeRequest)
        }
    }
}

public struct AddGroupMemberMaximumGroupSizeErrorDialog: View {
    let maximumNumberOfContacts: Int
    let onClose: () -> Void
    @Environment(\.i18n) var i18n
    public init(maximumNumberOfContacts: Int, onClose: @escaping () -> Void) {
        self.maximumNumberOfContacts = maximumNumberOfContacts
        self.onClose = onClose
    }
    public var body: some View {
        AxoConfirmDialog.Root(title: i18n("icu:chooseGroupMembers__maximum-group-size__title"),
                              description: i18n("icu:chooseGroupMembers__maximum-group-size__body", ["max": .number(Double(maximumNumberOfContacts))])) {
            AxoAlertDialog.Ok(i18n("icu:ok"), action: onClose)
        }
    }
}

public struct AddGroupMemberRecommendedMaximumGroupSizeErrorDialog: View {
    let recommendedMaximumNumberOfContacts: Int
    let onClose: () -> Void
    @Environment(\.i18n) var i18n
    public init(recommendedMaximumNumberOfContacts: Int, onClose: @escaping () -> Void) {
        self.recommendedMaximumNumberOfContacts = recommendedMaximumNumberOfContacts
        self.onClose = onClose
    }
    public var body: some View {
        AxoConfirmDialog.Root(title: i18n("icu:chooseGroupMembers__maximum-recommended-group-size__title"),
                              description: i18n("icu:chooseGroupMembers__maximum-recommended-group-size__body",
                                                ["max": .number(Double(recommendedMaximumNumberOfContacts))])) {
            AxoAlertDialog.Ok(i18n("icu:ok"), action: onClose)
        }
    }
}
