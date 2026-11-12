// What opens from a contact (upstream's global modals for them): AboutContactModal, and from it
// or the contact modal the Signal connections explainer, the profile-name warning, the note,
// the safety tips, the nickname and note editor, "Add to a group", calls, and their avatar shown
// large.

import AppKit
import Foundation
import SignalCore
import SignalI18n
import SignalUI
import SwiftUI

/// A contact dialog on screen (`contactDialog`).
enum ContactDialog: Equatable {
    case signalConnections
    case profileNameWarning(isGroup: Bool)
    case notePreview(String)
    case safetyTips
    /// The nickname and note editor for a 1:1 conversation.
    case nickname(conversationId: String, serviceId: String)
    /// "Add to a group" for a contact (`addToGroupCandidates`).
    case addToGroup(serviceId: String)
    /// A contact's avatar, large.
    case avatar(serviceId: String)
    /// What a group member label is (from a label in the contact modal).
    case memberLabelInfo
    /// The timeline notices' "Learn more" (`ChatSessionRefreshedDialog`, `DeliveryIssueDialog`).
    case chatSessionRefreshed
    case deliveryIssue(senderTitle: String, inGroup: Bool)
    /// A poll's voters (`PollVotesModal`), from the bubble's "View votes".
    case pollVotes(messageId: String)
    /// View-once media that can no longer be opened: "Learn more" (`TapToViewNotAvailableModal`).
    case tapToViewNotAvailable(expired: Bool, name: String)
}

@MainActor extension SignalSession {
    /// `toggleAboutContactModal`: the contact's details, kept up to date while open.
    func showAboutContact(_ serviceId: String) {
        aboutContactTask?.cancel()
        guard let db = clientDatabase else { return }
        let me = ourAci
        aboutContactTask = Task { [weak self] in
            do {
                for try await info in db.contactAboutUpdates(serviceId: serviceId, ourAci: me) { self?.aboutContact = info }
            } catch {}
        }
    }

    func closeAboutContact() {
        aboutContactTask?.cancel()
        aboutContactTask = nil
        aboutContact = nil
    }

    /// `onOutgoingVideoCallInConversation` / `…Audio…` for a contact: the lobby of their 1:1 chat.
    func callContact(_ serviceId: String, video: Bool) {
        guard let session else { return }
        Task {
            guard let id = try? await session.messenger.directConversation(serviceId: serviceId) else { return Self.trace("call contact failed") }
            if conversation(id) == nil { await openNew(id) }
            openCallLobby(id, video: video)
        }
    }

    /// `onOpenEditNicknameAndNoteModal` for a contact (their 1:1 chat holds the nickname and note).
    func editNickname(_ serviceId: String) {
        guard let session else { return }
        Task {
            guard let id = try? await session.messenger.directConversation(serviceId: serviceId) else { return }
            nicknameContact = nil
            contactDialog = .nickname(conversationId: id, serviceId: serviceId)
            loadNicknameContact(serviceId)
        }
    }

    /// The contact's saved nickname and note, for the editor.
    private func loadNicknameContact(_ serviceId: String) {
        guard let db = clientDatabase else { return }
        let me = ourAci
        Task { [weak self] in
            let info = try? await db.pool.read { try ConversationQueries.contactAbout($0, serviceId: serviceId, ourAci: me) }
            if case .nickname(_, serviceId)? = self?.contactDialog { self?.nicknameContact = info }
        }
    }

    func saveNickname(_ conversationId: String, _ value: NicknameAndNote) {
        guard let session else { return }
        contactDialog = nil
        Task {
            do {
                try await session.messenger.setNickname(conversationId, given: value.givenName, family: value.familyName)
                try await session.messenger.setNote(conversationId, value.note)
            } catch {
                Self.trace("nickname change failed: \(error)")
            }
        }
    }

    /// `onDeleteNicknameAndNote`
    func deleteNickname(_ conversationId: String) {
        saveNickname(conversationId, NicknameAndNote())
    }

    /// `toggleAddUserToAnotherGroupModal`: the groups we may add people to (`canAddNewMembers`:
    /// we are a member, the group is not ended, and everyone or we as an admin may add).
    func showAddToGroup(_ serviceId: String) {
        guard let db = clientDatabase, let me = ourAci else { return }
        Task {
            let groups = (try? await db.pool.read { db -> [(ConversationSummary, GroupV2State)] in
                try ConversationQueries.composable(db).filter { $0.kind == .group }.compactMap { c in
                    guard let g = try ConversationQueries.details(db, conversationId: c.id)?.group else { return nil }
                    return (c, g)
                }
            }) ?? []
            addToGroupCandidates = groups.compactMap { c, g in
                guard !g.terminated, g.member(me) != nil, g.accessControl.members == GroupAccess.member || g.isAdmin(me) else { return nil }
                let avatar = ConversationAvatarData(title: c.title, conversationType: .group, color: c.color, image: avatarImage(c.avatar),
                                                    hasAvatar: c.avatar != nil)
                return AddUserToAnotherGroupCandidate(group: GroupListItemData(id: c.id, title: c.title, membersCount: c.membersCount, avatar: avatar),
                                                      memberAcis: Set(g.membersV2.map(\.aci)),
                                                      pendingServiceIds: Set(g.pendingMembersV2.map(\.serviceId) + g.pendingAdminApprovalV2.map(\.aci)))
            }
            contactDialog = .addToGroup(serviceId: serviceId)
        }
    }

    /// `addMembersToGroup` from "Add to a group", with its toasts.
    func addContact(_ serviceId: String, toGroup conversationId: String) {
        guard let session, let db = clientDatabase else { return }
        let name = contactTitle(serviceId)
        contactDialog = nil
        toast = .addingUserToGroup(contact: name)
        Task {
            do {
                guard let key = try await db.pool.read({ try ConversationQueries.details($0, conversationId: conversationId) })?.masterKey else { return }
                try await session.groups.addMembers(try GroupKeys(masterKey: key), [serviceId])
                toast = .userAddedToGroup(contact: name, group: conversation(conversationId)?.title ?? "")
            } catch {
                Self.trace("add to group failed: \(error)")
                toast = nil
                composeError = ComposeError(key: "icu:error", args: [:])
            }
        }
    }
}

/// The contact dialogs over the window (RootView).
struct ContactSurfaceDialogs: View {
    @Bindable var session: SignalSession
    let model: AppModel
    let i18n: Localizer

    var body: some View {
        if let info = session.aboutContact {
            AxoBaseDialog.Host { aboutModal(info) }
        }
        if let d = session.contactDialog {
            if case .avatar = d { dialog(d) } else { AxoBaseDialog.Host { dialog(d) } }
        }
    }

    func aboutModal(_ info: ContactAboutInfo) -> some View {
        let me = session.ourAci
        let isMe = info.serviceId == me
        var c = AboutContactModal.Contact(id: info.serviceId, title: isMe ? i18n("icu:you") : info.title)
        c.titleNoNickname = info.titleNoNickname
        c.isMe = isMe
        c.color = session.contactColor(info.serviceId)
        c.avatar = session.avatarImage(session.contacts[info.serviceId]?.avatar)
        c.hasAvatar = c.avatar != nil
        c.about = [info.aboutEmoji, info.about].compactMap { $0 }.joined(separator: " ")
        c.isVerified = info.isVerified
        c.isBlocked = info.isBlocked
        c.acceptedMessageRequest = info.acceptedMessageRequest
        c.hasMessages = info.hasMessages
        c.profileSharing = info.profileSharing
        c.isInSystemContacts = info.isInSystemContacts
        c.systemGivenName = info.systemGivenName
        c.firstName = info.profileName
        c.phoneNumber = info.e164
        c.username = isMe ? session.accountSettings.username : nil
        c.note = info.note
        // In a group chat: their member label there.
        let member = session.details?.group?.member(info.serviceId)
        let label = member?.labelString.flatMap { $0.isEmpty ? nil : $0 }
        var a = AboutContactModal.Actions()
        a.onClose = { session.closeAboutContact() }
        a.toggleSafetyNumberModal = { id in
            session.closeAboutContact()
            session.showSafetyNumber(id)
        }
        a.toggleSignalConnectionsModal = { session.contactDialog = .signalConnections }
        a.toggleProfileNameWarningModal = { session.contactDialog = .profileNameWarning(isGroup: false) }
        a.onOpenNotePreviewModal = { if let note = info.note { session.contactDialog = .notePreview(note) } }
        a.showProfileEditor = {
            session.closeAboutContact()
            session.contactModalId = nil
            model.settingsPage = .profile
            model.selectedTab = .settings
        }
        a.showQRCodeScreen = {
            session.closeAboutContact()
            session.contactModalId = nil
            model.settingsPage = .profile
            model.selectedTab = .settings
        }
        a.showEditMemberLabelScreen = {
            session.closeAboutContact()
            session.contactModalId = nil
            session.pushPanel("GroupMemberLabelEditor")
        }
        return AboutContactModal(contact: c, isSignalConnection: !isMe && info.isSignalConnection, sharedGroupNames: info.sharedGroupNames,
                                 fromOrAddedByTrustedContact: isMe || info.isTrusted,
                                 canAddLabel: isMe && member != nil, contactLabelEmoji: member?.labelEmoji, contactLabelString: label,
                                 contactNameColor: label != nil ? ContactNameColors.colors(session.details?.group)[info.serviceId] : nil, actions: a)
    }

    /// Each option's voters, by their chats' titles (us as "You").
    func voters(_ poll: TimelinePoll) -> [Int: [PollVoter]] {
        var out: [Int: [PollVoter]] = [:]
        for v in poll.votes {
            let c = session.conversation(v.fromConversationId)
            let isMe = c?.serviceId != nil && c?.serviceId == session.ourAci
            let voter = PollVoter(id: v.fromConversationId, title: isMe ? i18n("icu:you") : c?.title ?? i18n("icu:unknownContact"),
                                  color: c?.color ?? "A200", avatar: session.avatarImage(c?.avatar))
            for i in v.optionIndexes where poll.options.indices.contains(i) { out[i, default: []].append(voter) }
        }
        return out
    }

    @ViewBuilder func dialog(_ d: ContactDialog) -> some View {
        let close = { session.contactDialog = nil }
        switch d {
        case .signalConnections:
            SignalConnectionsModal(onClose: close)
        case .profileNameWarning(let isGroup):
            ProfileNameWarningModal(conversationType: isGroup ? .group : .direct, onClose: close)
        case .notePreview(let note):
            NotePreviewModal(note: note, onClose: close)
        case .safetyTips:
            SafetyTipsModal(onClose: close)
        case .nickname(let conversationId, let serviceId):
            let info = session.nicknameContact
            let avatar = ConversationAvatarData(title: session.contactTitle(serviceId), conversationType: .direct, color: session.contactColor(serviceId),
                                                image: session.avatarImage(session.contacts[serviceId]?.avatar),
                                                hasAvatar: session.contacts[serviceId]?.avatar != nil)
            EditNicknameAndNoteModal(avatar: avatar, nicknameAndNote: NicknameAndNote(givenName: info?.nicknameGivenName, familyName: info?.nicknameFamilyName,
                                                                                      note: info?.note),
                                     onSave: { session.saveNickname(conversationId, $0) }, onClose: close)
                .id(info?.serviceId ?? "")     // the saved values, once read
        case .addToGroup(let serviceId):
            AddUserToAnotherGroupModal(contactTitle: session.contactTitle(serviceId), contactServiceId: serviceId, candidates: session.addToGroupCandidates,
                                       onAdd: { session.addContact(serviceId, toGroup: $0) }, onClose: close)
        case .memberLabelInfo:
            let group = session.details?.group
            let me = session.ourAci ?? ""
            let mine = group?.member(me)
            GroupMemberLabelInfoModal(canAddLabel: mine != nil && (group?.accessControl.memberLabel == GroupAccess.member || group?.isAdmin(me) == true),
                                      hasLabel: !(mine?.labelString ?? "").isEmpty, isEditMemberLabelEnabled: true, onClose: close,
                                      showEditMemberLabelScreen: {
                                          close()
                                          session.contactModalId = nil
                                          session.pushPanel("GroupMemberLabelEditor")
                                      })
        case .chatSessionRefreshed:
            ChatSessionRefreshedDialog(onClose: close)
        case .deliveryIssue(let sender, let inGroup):
            DeliveryIssueDialog(senderTitle: sender, inGroup: inGroup, onClose: close)
        case .pollVotes(let messageId):
            if let m = session.messages.first(where: { $0.id == messageId }), let poll = m.poll {
                PollVotesModal(question: poll.question, options: poll.options, votersByOption: voters(poll),
                               totalNumVotes: poll.votes.reduce(0) { $0 + $1.optionIndexes.filter(poll.options.indices.contains).count },
                               terminated: poll.terminated,
                               canEndPoll: m.direction == .outgoing && !poll.terminated && session.details?.group?.terminated != true,
                               endPoll: { session.endPoll(messageId) }, onClose: close)
            }
        case .tapToViewNotAvailable(let expired, let name):
            TapToViewNotAvailableModal(type: expired ? .expired : .error, name: name, onClose: close)
        case .avatar(let serviceId):
            let contact = session.contacts[serviceId]
            AvatarLightbox(avatarColor: session.contactColor(serviceId), avatarImage: session.avatarImage(contact?.avatar),
                           conversationTitle: session.contactTitle(serviceId), hasAvatar: contact?.avatar != nil, isGroup: false, onClose: close)
        }
    }
}
