// The dialogs of a chat's settings, shown over the window: custom disappearing time, mute
// until, add group members, edit the group, a custom chat colour, forward messages.

import Foundation
import SignalCore
import SignalI18n
import SignalUI
import SwiftUI

struct ChatDialogs: View {
    @Bindable var session: SignalSession
    let i18n: Localizer

    var body: some View {
        if let id = session.customTimerFor {
            DisappearingTimeDialog(initialValue: max(60, session.details?.expireTimer ?? 60), onSubmit: { seconds in
                session.customTimerFor = nil
                if id == session.selectedConversationId { session.setDisappearingTimer(seconds) }
            }, onClose: { session.customTimerFor = nil })
        }
        if let id = session.customMuteFor {
            MuteUntilDialog(onSubmit: { date in
                session.customMuteFor = nil
                session.mute(id, until: date)
            }, onClose: { session.customMuteFor = nil })
        }
        if session.isAddingMembers { AddMembersDialog(session: session, i18n: i18n) }
        if session.isEditingGroup, let c = session.selectedConversation { editGroup(c) }
        if let editing = session.customColorEditor {
            CustomColorEditorDialog(initialSolid: editing.editing?.solid, initialGradient: editing.editing?.gradient,
                                    onClose: { session.customColorEditor = nil },
                                    onSave: { session.saveCustomColor($0, editing: editing) })
        }
        if let ids = session.forwardMessageIds { forward(ids) }
    }

    func editGroup(_ c: ConversationSummary) -> some View {
        EditConversationAttributesModal(avatarColor: c.color, avatarImage: session.avatarImage(c.avatar), title: c.title,
                                        groupDescription: session.details?.group?.description ?? "", requestState: session.editGroupState,
                                        makeRequest: { session.updateGroup($0) }, onClose: { session.isEditingGroup = false })
            .photoLoader { await session.loadGroupPhoto($0) }
    }

    func forward(_ ids: [String]) -> some View {
        let drafts = ids.compactMap { id in session.messages.first { $0.id == id } }.map { m in
            MessageForwardDraft(messageBody: m.body, isSticker: m.sticker != nil, hasVoiceMessage: m.content == .voiceMessage,
                                attachmentCount: m.attachments.count, attachmentsDownloaded: m.attachments.allSatisfy(\.attachment.isDownloaded))
        }
        let me = session.ourAci
        let candidates = session.conversations.filter { !$0.isArchived }.map { c in
            let isMe = c.kind == .private && c.serviceId != nil && c.serviceId == me
            let title = isMe ? i18n("icu:noteToSelf") : c.title
            let item = ContactListItemData(id: c.id, title: title, type: c.kind == .group ? .group : .direct, isMe: isMe,
                                           avatar: ConversationAvatarData(title: title, conversationType: c.kind == .group ? .group : .direct, color: c.color,
                                                                          image: isMe ? nil : session.avatarImage(c.avatar)))
            return SearchableConversation(listItem: item, activeAt: c.activeAt.map(Double.init))
        }
        return ForwardMessagesModal(drafts: drafts, candidateConversations: candidates,
                                    doForwardMessages: { targets, edited in session.doForward(to: targets, drafts: edited) },
                                    onClose: { session.forwardMessageIds = nil })
    }
}

/// AddGroupMembersModal over the contacts we can add.
struct AddMembersDialog: View {
    @Bindable var session: SignalSession
    let i18n: Localizer
    @State private var candidates: [ConversationSummary] = []

    var body: some View {
        let members = Set(session.details?.group?.membersV2.map(\.aci) ?? [])
        let inGroup = Set(candidates.filter { $0.serviceId.map(members.contains) ?? false }.map(\.id))
        let contacts = candidates.map { c in
            ContactListItemData(id: c.id, title: c.title, avatar: ConversationAvatarData(title: c.title, conversationType: .direct, color: c.color,
                                                                                         image: session.avatarImage(c.avatar)))
        }
        AddGroupMembersModal(candidateContacts: contacts, conversationIdsAlreadyInGroup: inGroup,
                             groupTitle: session.selectedConversation?.title ?? "", requestState: session.addMembersState,
                             makeRequest: { [candidates] ids in session.addMembers(conversationIds: ids, candidates: candidates) },
                             clearRequestError: { session.addMembersState = .inactive }, onClose: { session.isAddingMembers = false })
            .task { candidates = await session.addMemberCandidates() }
    }
}
