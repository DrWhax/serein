// Port of ts/components/AddUserToAnotherGroupModal.dom.tsx: pick a group to add a contact to
// (a searchable list of GroupListItems; members and pending members disabled), then confirm.

import SignalI18n
import SwiftUI

/// A candidate group (`ConversationType` of a group the user can add members to).
public struct AddUserToAnotherGroupCandidate: Identifiable {
    public var group: GroupListItemData
    /// ACIs of the group's members.
    public var memberAcis: Set<String>
    /// Service ids (ACI or PNI) of pending and pending-approval members.
    public var pendingServiceIds: Set<String>
    public var id: String { group.id }
    public init(group: GroupListItemData, memberAcis: Set<String> = [], pendingServiceIds: Set<String> = []) {
        self.group = group
        self.memberAcis = memberAcis
        self.pendingServiceIds = pendingServiceIds
    }
}

public struct AddUserToAnotherGroupModal: View {
    let contactTitle: String
    let contactServiceId: String?
    let contactPni: String?
    let candidates: [AddUserToAnotherGroupCandidate]
    let regionCode: String?
    let onAdd: (String) -> Void
    let onClose: () -> Void
    @State private var searchTerm = ""
    @State private var selected: AddUserToAnotherGroupCandidate?
    @Environment(\.i18n) var i18n

    public init(contactTitle: String, contactServiceId: String?, contactPni: String? = nil, candidates: [AddUserToAnotherGroupCandidate],
                regionCode: String? = nil, onAdd: @escaping (String) -> Void = { _ in }, onClose: @escaping () -> Void = {}) {
        self.contactTitle = contactTitle
        self.contactServiceId = contactServiceId
        self.contactPni = contactPni
        self.candidates = candidates
        self.regionCode = regionCode
        self.onAdd = onAdd
        self.onClose = onClose
    }

    /// `filterAndSortConversations` over the group titles.
    var filtered: [AddUserToAnotherGroupCandidate] {
        let byId = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let searchable = candidates.map { SearchableConversation(listItem: ContactListItemData(id: $0.id, title: $0.group.title, type: .group)) }
        return ConversationSearch.filterAndSort(searchable, searchTerm: searchTerm.trimmingCharacters(in: .whitespaces), regionCode: regionCode)
            .compactMap { byId[$0.id] }
    }

    func row(_ c: AddUserToAnotherGroupCandidate) -> GroupListItemData {
        var g = c.group
        if let aci = contactServiceId, c.memberAcis.contains(aci) {
            g.disabledReason = .alreadyMember
        } else if [contactServiceId, contactPni].contains(where: { $0.map(c.pendingServiceIds.contains) ?? false }) {
            g.disabledReason = .pending
        }
        return g
    }

    public var body: some View {
        if let selected {
            AxoConfirmDialog.Root(title: i18n("icu:AddUserToAnotherGroupModal__confirm-title"),
                                  description: i18n("icu:AddUserToAnotherGroupModal__confirm-message",
                                                    ["contact": .string(contactTitle), "group": .string(selected.group.title)])) {
                AxoConfirmDialog.Cancel(i18n("icu:cancel")) { self.selected = nil }
                AxoConfirmDialog.Action(i18n("icu:AddUserToAnotherGroupModal__confirm-add"), variant: .strongPrimary) {
                    onAdd(selected.id)
                    onClose()
                }
            }
        } else {
            ModalHost(onClose: onClose) {
            ModalPage(modalName: "AddUserToAnotherGroupModal", strings: ModalStrings(back: i18n("icu:back"), close: i18n("icu:close")),
                      title: i18n("icu:AddUserToAnotherGroupModal__title"), hasXButton: true, padded: false, onClose: onClose) {
                // __main-body: flex column, min-height 300; the list fills the rest.
                VStack(spacing: 0) {
                    SearchInput(value: $searchTerm, placeholder: i18n("icu:AddUserToAnotherGroupModal__search-placeholder"), focusesOnAppear: true)
                    AxoDialog.AxoScrollContainer {
                        VStack(spacing: 0) {
                            ForEach(filtered) { c in
                                // A plain ListTile is 53px (borders 2, padding 6, 20 + 17); ListView rows are 52.
                                GroupListItem(group: row(c)) { id in self.selected = candidates.first { $0.id == id } }
                                    .frame(height: 53)
                                    .frame(height: 52, alignment: .top)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 300)
            } footer: { EmptyView() }
            .contentTakesFocus()                    // useRestoreFocus: the search input
            }
        }
    }
}
