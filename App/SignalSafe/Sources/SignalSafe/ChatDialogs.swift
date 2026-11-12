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
        if let review = session.identityReview { IdentityReviewDialog(session: session, review: review) }
        if let sheet = session.safetyNumberSheet { SafetyNumberSheetDialog(session: session, sheet: sheet, i18n: i18n) }
        if let id = session.customTimerFor {
            AxoBaseDialog.Host {
                DisappearingTimeDialog(initialValue: max(60, session.details?.expireTimer ?? 60), onSubmit: { seconds in
                    session.customTimerFor = nil
                    if id == session.selectedConversationId { session.setDisappearingTimer(seconds) }
                }, onClose: { session.customTimerFor = nil })
            }
        }
        if let id = session.customMuteFor {
            AxoBaseDialog.Host {
                MuteUntilDialog(onSubmit: { date in
                    session.customMuteFor = nil
                    session.mute(id, until: date)
                }, onClose: { session.customMuteFor = nil })
            }
        }
        if session.isAddingMembers { AddMembersDialog(session: session, i18n: i18n) }
        if session.isEditingGroup, let c = session.selectedConversation { AxoBaseDialog.Host { editGroup(c) } }
        if let editing = session.customColorEditor {
            AxoBaseDialog.Host {
                CustomColorEditorDialog(initialSolid: editing.editing?.solid, initialGradient: editing.editing?.gradient,
                                        onClose: { session.customColorEditor = nil },
                                        onSave: { session.saveCustomColor($0, editing: editing) })
            }
        }
        if let ids = session.forwardMessageIds { forward(ids) }
        if let text = session.shareText {
            ForwardMessagesModal(drafts: [MessageForwardDraft(messageBody: text, isSticker: false, hasVoiceMessage: false, attachmentCount: 0,
                                                              attachmentsDownloaded: true)],
                                 candidateConversations: Self.forwardCandidates(session, i18n),
                                 doForwardMessages: { targets, edited in
                                     session.shareText = nil
                                     session.sendText(edited.first?.messageBody ?? text, to: targets)
                                 },
                                 onClose: { session.shareText = nil }, showCannotForwardEmptyToast: { session.toast = .cannotForwardEmptyMessage })
        }
        if session.isEditingNewGroupAvatar { AxoBaseDialog.Host { newGroupAvatar } }
        if let id = session.avatarLightboxFor, let c = session.conversation(id) {
            AvatarLightbox(avatarColor: c.color, avatarImage: session.avatarImage(c.avatar), conversationTitle: c.title, hasAvatar: c.avatar != nil,
                           isGroup: c.kind == .group, onClose: { session.avatarLightboxFor = nil })
        }
        if session.isCreatingPoll {
            AxoBaseDialog.Host {
                PollCreateModal(onClose: { session.isCreatingPoll = false }, onSendPoll: { session.createPoll($0) })
            }
        }
        if let id = session.editHistoryMessageId, let m = session.messages.first(where: { $0.id == id }) { AxoBaseDialog.Host { editHistory(m) } }
        if session.isChoosingCountry {
            AxoBaseDialog.Host {
                ChooseCountryCodeModal(countries: CountryDataSource.countries(locale: i18n.locale), onChange: { session.composeSelectedRegion = $0 },
                                       onClose: { session.isChoosingCountry = false })
            }
        }
    }

    /// `EditHistoryMessagesModal`: each version of the message, newest first.
    func editHistory(_ m: TimelineMessage) -> some View {
        let outgoing = m.direction == .outgoing
        var author = MessageProps.Author(id: outgoing ? (session.ourAci ?? "me") : (m.author ?? "unknown"),
                                         title: outgoing ? i18n("icu:you") : session.contactTitle(m.author))
        author.isMe = outgoing
        author.color = outgoing ? nil : session.contactColor(m.author)
        let group = session.conversation(m.conversationId)?.kind == .group
        let versions = m.editHistory.enumerated().map { i, v in
            var p = MessageProps(id: "\(m.id)-\(i)", direction: outgoing ? .outgoing : .incoming, author: author, text: v.body,
                                 timestamp: Date(milliseconds: v.timestamp))
            p.conversationType = group ? .group : .direct
            if outgoing { p.bubbleColor = session.bubbleColor(session.conversationColor) }
            return p
        }
        return EditHistoryMessagesModal(editHistoryMessages: versions, onClose: { session.editHistoryMessageId = nil })
    }

    /// The compose flow's avatar dialog (`LeftPaneSetGroupMetadataHelper__avatar-modal-title`).
    var newGroupAvatar: some View {
        AxoDialog.Content(size: .md) {
            AxoDialog.Header {
                AxoDialog.Title(i18n("icu:LeftPaneSetGroupMetadataHelper__avatar-modal-title"))
            }
            AvatarEditor(avatarColor: AxoTokens.Avatar.allColorNames[0], avatarImage: session.newGroupAvatar?.image, conversationTitle: session.newGroupName,
                         isGroup: true, isInsideDialog: true, userAvatarData: AvatarEditor.defaultAvatars(isGroup: true), callbacks: {
                var c = AvatarEditor.Callbacks()
                c.onCancel = { session.isEditingNewGroupAvatar = false }
                c.onSave = { new in
                    session.newGroupAvatar = new
                    session.newGroupAvatarPreview = new.flatMap { $0.image ?? SignalSession.renderAvatarImage($0) }
                    if new?.image == nil { session.newGroupPhoto = nil }
                    session.isEditingNewGroupAvatar = false
                }
                c.onPhotoPicked = { url in
                    Task { @MainActor in
                        guard let image = await session.loadNewGroupPhoto(url) else { return }
                        session.newGroupAvatar = AvatarData(id: url.path, image: image)
                        session.newGroupAvatarPreview = image
                        session.isEditingNewGroupAvatar = false
                    }
                }
                return c
            }())
        }
    }

    func editGroup(_ c: ConversationSummary) -> some View {
        EditConversationAttributesModal(avatarColor: c.color, avatarImage: session.avatarImage(c.avatar), title: c.title,
                                        groupDescription: session.details?.group?.description ?? "", initiallyEditingAvatar: session.editGroupStartsWithAvatar,
                                        requestState: session.editGroupState, userAvatarData: AvatarEditor.defaultAvatars(isGroup: true),
                                        makeRequest: { session.updateGroup($0) }, onClose: { session.isEditingGroup = false })
            .photoLoader { await session.loadGroupPhoto($0) }
    }

    /// The chats a message (or story) can be forwarded to: the unarchived ones, Note to Self titled.
    static func forwardCandidates(_ session: SignalSession, _ i18n: Localizer) -> [SearchableConversation] {
        let me = session.ourAci
        return session.conversations.filter { !$0.isArchived }.map { c in
            let isMe = c.kind == .private && c.serviceId != nil && c.serviceId == me
            let title = isMe ? i18n("icu:noteToSelf") : c.title
            let item = ContactListItemData(id: c.id, title: title, type: c.kind == .group ? .group : .direct, isMe: isMe,
                                           avatar: ConversationAvatarData(title: title, conversationType: c.kind == .group ? .group : .direct, color: c.color,
                                                                          image: isMe ? nil : session.avatarImage(c.avatar)))
            return SearchableConversation(listItem: item, activeAt: c.activeAt.map(Double.init))
        }
    }

    func forward(_ ids: [String]) -> some View {
        let drafts = ids.compactMap { id in session.messages.first { $0.id == id } }.map { m in
            MessageForwardDraft(messageBody: m.body, isSticker: m.sticker != nil, hasVoiceMessage: m.content == .voiceMessage,
                                attachmentCount: m.attachments.count, attachmentsDownloaded: m.attachments.allSatisfy(\.attachment.isDownloaded))
        }
        return ForwardMessagesModal(drafts: drafts, candidateConversations: Self.forwardCandidates(session, i18n),
                                    doForwardMessages: { targets, edited in session.doForward(to: targets, drafts: edited) },
                                    onClose: { session.forwardMessageIds = nil }, showCannotForwardEmptyToast: { session.toast = .cannotForwardEmptyMessage })
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
