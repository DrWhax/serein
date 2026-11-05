// Port of ts/components/conversation/ContactSpoofingReviewDialog.dom.tsx (+ the
// RemoveGroupMemberConfirmationDialog it opens): review contacts whose names collide.
// - A direct conversation with the same title as a contact: the request ("possibly
//   unsafe", with Delete and Block) above a rule, then "Your contact".
// - Group members sharing a title: each with Remove from group (admins), Unblock (blocked) or
//   Block (not a system contact), separated by rules.
// Delete / Block open MessageRequestActionsConfirmation; Remove opens the remove-member
// confirmation; either replaces the review dialog while it is shown.

import SignalI18n
import SwiftUI

public struct ContactSpoofingReviewDialog: View {
    public typealias Person = ContactSpoofingPerson

    public struct Candidate: Sendable {
        public var id: String
        public var conversation: Person
        public var isSignalConnection = false
        public var sharedGroupNames: [String] = []
        public var oldName: String?
        public var isBlocked = false
        public var isReported = false
        public var isInSystemContacts = false
        public init(id: String, conversation: Person, isSignalConnection: Bool = false, sharedGroupNames: [String] = [], oldName: String? = nil) {
            self.id = id
            self.conversation = conversation
            self.isSignalConnection = isSignalConnection
            self.sharedGroupNames = sharedGroupNames
            self.oldName = oldName
        }
    }

    /// `ContactSpoofingType`
    public enum Kind: Sendable {
        case directConversationWithSameTitle(possiblyUnsafe: Candidate, safe: Candidate)
        /// `collisionInfoByTitle`, in title order; `addFromInviteLinkNeedsApproval`: the group
        /// link requires admin approval (changes the remove confirmation's text).
        case multipleGroupMembersWithSameTitle(areWeAdmin: Bool, addFromInviteLinkNeedsApproval: Bool, collisions: [(title: String, members: [Candidate])])
    }

    enum Confirmation { case delete(Candidate), block(Candidate), remove(Candidate) }

    let kind: Kind
    let acceptConversation: (String) -> Void
    let reportSpam: (String) -> Void
    let blockAndReportSpam: (String) -> Void
    let blockConversation: (String) -> Void
    let deleteConversation: (String) -> Void
    let removeMember: (String) -> Void
    let showContactModal: (String) -> Void
    let toggleSignalConnectionsModal: () -> Void
    let onClose: () -> Void
    @State private var confirmation: Confirmation?
    @Environment(\.i18n) var i18n

    public init(kind: Kind, acceptConversation: @escaping (String) -> Void = { _ in }, reportSpam: @escaping (String) -> Void = { _ in },
                blockAndReportSpam: @escaping (String) -> Void = { _ in }, blockConversation: @escaping (String) -> Void = { _ in },
                deleteConversation: @escaping (String) -> Void = { _ in }, removeMember: @escaping (String) -> Void = { _ in },
                showContactModal: @escaping (String) -> Void = { _ in }, toggleSignalConnectionsModal: @escaping () -> Void = {},
                onClose: @escaping () -> Void = {}) {
        self.kind = kind
        self.acceptConversation = acceptConversation
        self.reportSpam = reportSpam
        self.blockAndReportSpam = blockAndReportSpam
        self.blockConversation = blockConversation
        self.deleteConversation = deleteConversation
        self.removeMember = removeMember
        self.showContactModal = showContactModal
        self.toggleSignalConnectionsModal = toggleSignalConnectionsModal
        self.onClose = onClose
    }

    public var body: some View {
        switch confirmation {
        case .delete(let c), .block(let c):
            let isDelete: Bool = if case .delete = confirmation { true } else { false }
            MessageRequestActionsConfirmation(model: requestModel(c), state: isDelete ? .deleting : .blocking) { state in
                switch state {
                case .blocking: confirmation = .block(c)
                case .deleting: confirmation = .delete(c)
                default: confirmation = nil
                }
            }
        case .remove(let c):
            removeConfirmation(c)
        case nil:
            dialog
        }
    }

    func requestModel(_ c: Candidate) -> MessageRequestModel {
        var m = MessageRequestModel(conversationId: c.id, conversationType: .direct, conversationName: c.conversation.title,
                                    addedByName: c.conversation.title)
        m.isBlocked = c.isBlocked
        m.isReported = c.isReported
        m.acceptConversation = { acceptConversation(c.id) }
        m.reportSpam = { reportSpam(c.id) }
        m.blockAndReportSpam = { blockAndReportSpam(c.id) }
        m.blockConversation = { blockConversation(c.id) }
        m.deleteConversation = { deleteConversation(c.id) }
        return m
    }

    /// RemoveGroupMemberConfirmationDialog
    func removeConfirmation(_ c: Candidate) -> some View {
        let needsApproval: Bool = if case .multipleGroupMembersWithSameTitle(_, let a, _) = kind { a } else { false }
        let key = needsApproval ? "icu:RemoveGroupMemberConfirmation__description__with-link" : "icu:RemoveGroupMemberConfirmation__description"
        return AxoConfirmDialog.Root(title: i18n.richText(key, ["name": .element("name")]).plain(["name": c.conversation.title]), description: nil) {
            AxoConfirmDialog.Cancel(i18n("icu:cancel")) { confirmation = nil }
            AxoConfirmDialog.Action(i18n("icu:RemoveGroupMemberConfirmation__remove-button"), variant: .strongDestructive) {
                confirmation = nil
                removeMember(c.id)
            }
        }
    }

    var title: String {
        switch kind {
        case .directConversationWithSameTitle: i18n("icu:ContactSpoofingReviewDialog__title")
        case .multipleGroupMembersWithSameTitle: i18n("icu:ContactSpoofingReviewDialog__group__title")
        }
    }

    var dialog: some View {
        AxoDialog.Content(size: .md, hasFooter: false) {
            AxoDialog.Header {
                AxoDialog.Title(title)
                AxoDialog.Close(action: onClose)
            }
            AxoDialog.Body {
                switch kind {
                case .directConversationWithSameTitle(let unsafe, let safe): direct(unsafe, safe)
                case .multipleGroupMembersWithSameTitle(let areWeAdmin, _, let collisions): group(areWeAdmin, collisions)
                }
            }
        }
    }

    /// `<hr className="my-2.5 border-0 border-t border-t-secondary">`
    var rule: some View { Rectangle().fill(AxoColor.borderSecondary).frame(height: 1).padding(.vertical, 10) }

    func heading(_ text: String) -> some View {
        CSSText(text, type: AxoType.bodyMedium.weight(600), color: .labelPrimary).accessibilityAddTraits(.isHeader)
    }

    func person(_ c: Candidate, onClick: (() -> Void)?, @ViewBuilder actions: () -> some View) -> some View {
        ContactSpoofingReviewDialogPerson(conversation: c.conversation, oldName: c.oldName, isSignalConnection: c.isSignalConnection,
                                          sharedGroupNames: c.sharedGroupNames, onClick: onClick,
                                          toggleSignalConnectionsModal: toggleSignalConnectionsModal, actions: actions)
    }

    @ViewBuilder func direct(_ unsafe: Candidate, _ safe: Candidate) -> some View {
        AxoDialog.Description(i18n("icu:ContactSpoofingReviewDialog__description")).padding(.bottom, 10)
        heading(i18n("icu:ContactSpoofingReviewDialog__possibly-unsafe-title"))
        person(unsafe, onClick: nil) {
            HStack(spacing: 8) {
                AxoButton.Root(i18n("icu:MessageRequests--delete"), variant: .subtleDestructive, size: .md) { confirmation = .delete(unsafe) }
                AxoButton.Root(i18n("icu:MessageRequests--block"), variant: .subtleDestructive, size: .md) { confirmation = .block(unsafe) }
            }
        }
        rule
        heading(i18n("icu:ContactSpoofingReviewDialog__safe-title"))
        person(safe, onClick: { showContactModal(safe.id) }) { EmptyView() }
    }

    @ViewBuilder func group(_ areWeAdmin: Bool, _ collisions: [(title: String, members: [Candidate])]) -> some View {
        let total = collisions.reduce(0) { $0 + $1.members.count }
        AxoDialog.Description(collisions.count > 1
            ? i18n("icu:ContactSpoofingReviewDialog__group__multiple-conflicts__description", ["count": .number(Double(collisions.count))])
            : i18n("icu:ContactSpoofingReviewDialog__group__description", ["count": .number(Double(total))]))
            .padding(.bottom, 10)
        let flat = collisions.flatMap(\.members)
        ForEach(flat.indices, id: \.self) { i in
            let c = flat[i]
            person(c, onClick: { showContactModal(c.id) }) {
                // .module-ContactSpoofingReviewDialog__buttons: margin-top 4px
                Group {
                if areWeAdmin {
                    AxoButton.Root(i18n("icu:RemoveGroupMemberConfirmation__remove-button"), variant: .subtleDestructive, size: .md) {
                        confirmation = .remove(c)
                    }
                } else if c.isBlocked {
                    AxoButton.Root(i18n("icu:MessageRequests--unblock"), variant: .subtleAffirmative, size: .md) { acceptConversation(c.id) }
                } else if !c.isInSystemContacts {
                    AxoButton.Root(i18n("icu:MessageRequests--block"), variant: .subtleDestructive, size: .md) { confirmation = .block(c) }
                }
                }
                .padding(.top, 4)
            }
            if i < flat.count - 1 { rule }
        }
    }
}
