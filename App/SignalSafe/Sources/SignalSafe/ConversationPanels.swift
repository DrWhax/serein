// The panels pushed over a conversation (upstream ConversationPanel + PanelType): the chat's
// details, notification settings (and what notifies while muted), all media, and for groups
// the invite link, member labels, requests and invites, and permissions. Each is
// SignalUI's port; this maps SignalCore's state into it and its callbacks to the session.

import AppKit
import Foundation
import SignalCore
import SignalI18n
import SignalUI
import SwiftUI

/// `ContactNameColors` (ts/types/ContactNameColor.std.ts): group members by ACI order.
enum ContactNameColors {
    static let all = ["200", "120", "300", "010", "210", "330", "230", "180", "030", "340", "270", "090", "000", "150", "240", "040", "160", "280",
                      "080", "320", "020", "140", "260", "060", "350", "100", "290", "130", "220", "050", "170", "250", "070", "190", "310", "110"]

    /// `getContactNameColor`: the member's colour in the group (the first colour for 1:1 chats).
    static func colors(_ group: GroupV2State?) -> [String: String] {
        guard let group else { return [:] }
        var out: [String: String] = [:]
        for (i, m) in group.membersV2.sorted(by: { $0.aci < $1.aci }).enumerated() { out[m.aci] = all[i % all.count] }
        return out
    }
}

struct ConversationPanelView: View {
    @Bindable var session: SignalSession
    let conversation: ConversationSummary
    let i18n: Localizer
    let name: String
    let title: (ConversationSummary) -> String
    let avatar: (ConversationSummary) -> ConversationAvatarData
    @State private var mediaTab = MediaGalleryTab.media
    @State private var mediaSort = MediaSortOrder.date

    var details: ConversationDetailsInfo? { session.details }
    var group: GroupV2State? { details?.group }
    var me: String { session.ourAci ?? "" }
    var areWeAdmin: Bool { group?.isAdmin(me) ?? false }

    var body: some View {
        ConversationPanel(onBack: { session.popPanel() }) {
            if name == "AllMedia" {
                MediaGalleryPanelHeader(tab: $mediaTab, sortOrder: $mediaSort)
            } else {
                EmptyView()
            }
        } content: {
            content
        }
    }

    @ViewBuilder var content: some View {
        switch name {
        case "ConversationDetails": ScrollView { ConversationDetails(model: detailsModel, callbacks: detailsCallbacks) }
        case "NotificationSettings": notificationSettings
        case "WhileMuted":
            WhileMutedSettings(isGroup: conversation.kind == .group, notifyWhileMuted: notifyWhileMuted,
                               setNotifyWhileMuted: { session.setNotifyWhileMuted($0, $1) })
        case "AllMedia": allMedia
        case "GroupLinkManagement":
            ScrollView {
                GroupLinkManagement(groupLink: session.groupLinkURL, addFromInviteLink: group.flatMap { AccessControl(rawValue: $0.accessControl.addFromInviteLink) },
                                    isAdmin: areWeAdmin, changeHasGroupLink: { session.setGroupLink(enabled: $0) }, generateNewGroupLink: { session.resetGroupLink() },
                                    setAccessControlAddFromInviteLinkSetting: { session.setGroupLinkApproval($0) }, copyGroupLink: { session.copyToPasteboard($0) })
            }
        case "GroupMemberLabelEditor": labelEditor
        case "GroupInvites": invites
        case "ChatColorEditor": chatColorEditor
        case "GroupPermissions":
            ScrollView {
                GroupV2Permissions(accessControlMembers: group.flatMap { AccessControl(rawValue: $0.accessControl.members) },
                                   accessControlAttributes: group.flatMap { AccessControl(rawValue: $0.accessControl.attributes) },
                                   accessControlMemberLabel: group.flatMap { AccessControl(rawValue: $0.accessControl.memberLabel) },
                                   announcementsOnly: group?.announcementsOnly ?? false, announcementsOnlyReady: true, areWeAdmin: areWeAdmin,
                                   nonAdminsHaveLabels: group?.membersV2.contains { $0.role != GroupRole.administrator && !($0.labelString ?? "").isEmpty } ?? false,
                                   callbacks: {
                                       var c = GroupV2Permissions.Callbacks()
                                       c.setAccessControlAttributesSetting = { session.setAttributesAccess($0) }
                                       c.setAccessControlMembersSetting = { session.setMembersAccess($0) }
                                       c.setAccessControlMemberLabelSetting = { session.setMemberLabelAccess($0) }
                                       c.setAnnouncementsOnly = { session.setAnnouncementsOnly($0) }
                                       return c
                                   }())
            }
        default: EmptyView()
        }
    }

    // MARK: details

    func memberAvatar(_ aci: String) -> ConversationAvatarData {
        let isMe = aci == me
        return ConversationAvatarData(title: isMe ? i18n("icu:you") : session.contactTitle(aci), conversationType: .direct, color: session.contactColor(aci),
                                      image: session.avatarImage(session.contacts[aci]?.avatar))
    }

    func label(_ m: GroupMember) -> ContactLabel? {
        guard let s = m.labelString, !s.isEmpty else { return nil }
        return ContactLabel(labelString: s, labelEmoji: m.labelEmoji)
    }

    var memberships: [GroupV2Membership] {
        guard let group else { return [] }
        let colors = ContactNameColors.colors(group)
        return group.membersV2.map { m in
            GroupV2Membership(id: m.aci, avatar: memberAvatar(m.aci), isMe: m.aci == me, isAdmin: m.role == GroupRole.administrator,
                              isInSystemContacts: false, label: label(m), contactNameColor: colors[m.aci])
        }
        .sorted { a, b in a.isMe != b.isMe ? a.isMe : a.isAdmin != b.isAdmin ? a.isAdmin : a.avatar.title.localizedCompare(b.avatar.title) == .orderedAscending }
    }

    /// `canEditGroupInfo` etc.: the access a member needs (admin-only settings need us to be one).
    func allowed(_ access: Int?) -> Bool { access == GroupAccess.administrator ? areWeAdmin : (group?.isMember(me) ?? false) }

    var detailsModel: ConversationDetailsModel {
        var m = ConversationDetailsModel(conversationId: conversation.id, title: title(conversation), avatar: avatar(conversation), isGroup: conversation.kind == .group)
        let d = details
        m.groupDescription = group?.description
        m.about = d?.about.map { a in d?.aboutEmoji.map { "\($0) \(a)" } ?? a }
        m.isMe = conversation.kind == .private && conversation.serviceId == session.ourAci
        m.isArchived = d?.isArchived ?? conversation.isArchived
        m.isBlocked = d?.isBlocked ?? false
        m.left = d?.left ?? false
        m.terminated = group?.terminated ?? false
        m.muteExpiresAt = d?.muteExpiresAt.map(Double.init)
        m.expireTimer = d?.expireTimer
        m.membersCount = group?.membersV2.count
        m.canEditGroupInfo = allowed(group?.accessControl.attributes)
        m.canAddNewMembers = allowed(group?.accessControl.members)
        m.canAddLabel = allowed(group?.accessControl.memberLabel)
        m.isAdmin = areWeAdmin
        m.hasGroupLink = session.groupLinkURL != nil
        m.hasMedia = d?.hasMedia ?? false
        m.memberships = memberships
        m.invitesCount = (group?.pendingMembersV2.count ?? 0) + (group?.pendingAdminApprovalV2.count ?? 0)
        // canHaveNicknameAndNote: a 1:1 chat with someone else.
        m.canHaveNicknameAndNote = conversation.kind == .private && !m.isMe && conversation.serviceId != nil
        // Ending a group is behind upstream's version-gated remote config
        // (`desktop.groupTerminate.send`), which has no meaning for Serein: not offered.
        m.isTerminateGroupEnabled = false
        m.hasActiveCall = session.activeCall != nil && session.activeCall?.conversationId != conversation.id
        m.groupsInCommon = (d?.groupsInCommon ?? []).compactMap { id in session.conversation(id).map { avatar($0) } }
        m.bubbleColor = session.bubbleColor(session.conversationColor)
        return m
    }

    var detailsCallbacks: ConversationDetailsCallbacks {
        var c = ConversationDetailsCallbacks()
        c.pushPanel = { name in
            // Panels this port has: the rest (chat colour…) are not offered yet.
            if ["NotificationSettings", "AllMedia", "GroupLinkManagement", "GroupMemberLabelEditor", "GroupInvites", "GroupPermissions",
                "ChatColorEditor"].contains(name) {
                session.pushPanel(name)
            }
        }
        c.showContactModal = { session.contactModalId = $0 }
        c.showConversation = { id in session.open(conversationId: id) }
        c.setDisappearingMessages = { session.setDisappearingTimer($0) }
        c.setupCustomDisappearingTimeout = { [id = conversation.id] in session.customTimerFor = id }
        c.addMembers = {
            session.addMembersState = .inactive
            session.isAddingMembers = true
        }
        // The avatar: straight to the avatar editor when we may edit the group (a photo or a
        // preset), else shown large as upstream does.
        let canEdit = conversation.kind == .group && detailsModel.canEditGroupInfo
        c.showAvatar = { [id = conversation.id] in
            if canEdit {
                session.editGroupState = .inactive
                session.pendingGroupPhoto = nil
                session.editGroupStartsWithAvatar = true
                session.isEditingGroup = true
            } else {
                session.avatarLightboxFor = id
            }
        }
        c.editGroup = {
            session.editGroupStartsWithAvatar = false
            session.editGroupState = .inactive
            session.pendingGroupPhoto = nil
            session.isEditingGroup = true
        }
        c.setMuteExpiration = { session.setMute($0) }
        c.openLink = { NSWorkspace.shared.open($0) }
        let id = conversation.id, serviceId = conversation.kind == .private ? conversation.serviceId : nil
        c.searchInConversation = { session.startConversationSearch() }
        c.onOutgoingVideoCall = { session.openCallLobby(id, video: true) }
        c.onOutgoingAudioCall = { session.openCallLobby(id, video: false) }
        c.toggleSafetyNumberModal = { session.showSafetyNumber(serviceId) }
        c.toggleAboutContactModal = { if let serviceId { session.showAboutContact(serviceId) } }
        c.toggleAddUserToAnotherGroupModal = { if let serviceId { session.showAddToGroup(serviceId) } }
        c.onOpenEditNicknameAndNote = { if let serviceId { session.editNickname(serviceId) } }
        c.onDeleteNicknameAndNote = { session.deleteNickname(id) }
        c.actions.blockConversation = { session.setBlocked(true) }
        c.actions.onArchive = { session.setArchived(true) }
        c.actions.onUnarchive = { session.setArchived(false) }
        c.actions.onDelete = { session.deleteChat() }
        c.actions.onLeave = { session.leaveGroup() }
        c.actions.onReportSpam = { session.reportSpam(block: false) }
        c.actions.onReportSpamAndBlock = { session.reportSpam(block: true) }
        c.actions.acceptConversation = { session.respond(conversation.id, .accept) }
        return c
    }

    // MARK: notifications

    var notifyWhileMuted: NotifyWhileMuted {
        let defaults = session.notificationSettings
        return NotifyWhileMuted(calls: details?.notifyForCallsIfMuted ?? defaults.notifyForCallsIfMuted,
                                mentions: details?.notifyForMentionsIfMuted ?? defaults.notifyForMentionsIfMuted,
                                replies: details?.notifyForRepliesIfMuted ?? defaults.notifyForRepliesIfMuted)
    }

    var notificationSettings: some View {
        ScrollView {
            ConversationNotificationsSettings(isGroup: conversation.kind == .group, muteExpiresAt: details?.muteExpiresAt.map(Double.init),
                                              notifyWhileMuted: notifyWhileMuted,
                                              // DEFAULT_SHOW_UNREAD_REMINDERS: off unless the chat says otherwise.
                                              showUnreadReminders: details?.showUnreadReminders ?? false,
                                              onOpenWhileMutedSettings: { session.pushPanel("WhileMuted") },
                                              setMuteExpiration: { session.setMute($0) },
                                              setShowUnreadReminders: { [id = conversation.id] on in session.setShowUnreadReminders(id, on) })
        }
    }

    // MARK: all media

    var allMedia: some View {
        let items: [GalleryMediaItem] = session.mediaItems.compactMap { item in
            let a = item.attachment
            var out = SignalUI.MessageAttachment(contentType: a.contentType, fileName: a.fileName, size: a.size, width: a.width, height: a.height)
            out.isDownloaded = a.isDownloaded
            out.pending = a.pending ?? false
            out.image = AttachmentPolicy.isVideo(a.contentType) ? session.posterImage(for: a) : session.image(for: a)
            out.screenshot = AttachmentPolicy.isVideo(a.contentType) ? out.image : nil
            let visual = AttachmentPolicy.isImage(a.contentType) || AttachmentPolicy.isVideo(a.contentType)
            let kind: GalleryMediaItem.Kind
            if visual { kind = .media(out) } else if AttachmentPolicy.isAudio(a.contentType) {
                kind = .audio(out, duration: 0, peaks: nil, isVoiceMessage: (a.flags ?? 0) & 1 != 0, isPlayed: true)
            } else { kind = .document(out) }
            let message = MediaItemMessage(id: item.messageId, receivedAt: Date(milliseconds: item.receivedAt))
            let author = item.outgoing ? i18n("icu:you") : session.contactTitle(item.author)
            return GalleryMediaItem(id: "\(item.messageId)/\(a.path ?? a.contentType)", kind: kind, message: message, authorTitle: author)
        }
        let shown = items.filter { item in
            switch (mediaTab, item.kind) {
            case (.media, .media), (.documents, .document), (.audio, .audio), (.links, .link): true
            default: false
            }
        }
        return MediaGallery(items: shown, tab: mediaTab, sortOrder: mediaSort, onItemClick: { item in
            if let m = session.messages.first(where: { $0.id == item.message.id }) {
                session.openLightbox(m, index: 0)
            }
        }, showMessage: { item in
            session.panels = []
            session.goToMessage(item.message.id)
        })
    }

    // MARK: chat colour

    var chatColorEditor: some View {
        let colors = session.chatColors.customColors
        let mine = session.conversationColor
        var preset: String?
        var custom: Int?
        switch mine {
        case .preset(let p)?: preset = p
        case .custom(let id)?: custom = Int(id)
        case nil: break
        }
        return ScrollView {
            ChatColorPicker(conversationId: conversation.id,
                            customChatColors: colors.map { SignalUI.CustomChatColor(id: Int($0.id), color: SignalSession.bubble($0)) },
                            selectedPreset: preset, selectedCustomColorId: custom, defaultBubbleColor: session.bubbleColor(nil),
                            onSelectPreset: { session.setConversationColor(.preset($0)) },
                            onSelectCustomColor: { session.setConversationColor(.custom(Int64($0))) },
                            onAddCustomColor: { session.customColorEditor = CustomColorEditing() },
                            onEditCustomColor: { c in session.customColorEditor = CustomColorEditing(editing: colors.first { $0.id == Int64(c.id) }) },
                            onDuplicateCustomColor: { c in session.customColorEditor = CustomColorEditing(editing: colors.first { $0.id == Int64(c.id) }, duplicate: true) },
                            onRemoveCustomColor: { c in session.removeCustomColor(Int64(c.id)) },
                            onResetChatColor: { session.setConversationColor(nil) },
                            onResetAll: { session.resetAllChatColors() })
        }
    }

    // MARK: groups

    func pending(_ serviceId: String) -> PendingMember { PendingMember(id: serviceId, avatar: memberAvatar(serviceId)) }

    var invites: some View {
        let g = group
        let requests = (g?.pendingAdminApprovalV2 ?? []).map { pending($0.aci) }
        let invited = g?.pendingMembersV2 ?? []
        let byUs = invited.filter { $0.addedByUserId == me }.map { pending($0.serviceId) }
        let byOthers = Dictionary(grouping: invited.filter { $0.addedByUserId != me }, by: \.addedByUserId)
            .map { (inviter: pending($0.key), invitees: $0.value.map { pending($0.serviceId) }) }
            .sorted { $0.inviter.avatar.title < $1.inviter.avatar.title }
        return PendingInvites(groupTitle: title(conversation), areWeAdmin: areWeAdmin, groupLinkEnabled: session.groupLinkURL != nil,
                              pendingApprovalMemberships: requests, invitedByUs: byUs, invitedByOthers: byOthers,
                              approvePendingMembership: { session.approveRequest($0) }, revokePendingMemberships: { session.revokePending($0) })
            .banned((g?.bannedMembersV2 ?? []).map { pending($0.serviceId) }, unban: { session.unban($0) })
    }

    var labelEditor: some View {
        let colors = ContactNameColors.colors(group)
        var author = MessageProps.Author(id: me, title: i18n("icu:you"))
        author.isMe = true
        let mine = group?.member(me)
        let labelled = (group?.membersV2 ?? []).compactMap { m -> LabelledGroupMember? in
            guard let l = label(m) else { return nil }
            return LabelledGroupMember(id: m.aci, avatar: memberAvatar(m.aci), isMe: m.aci == me, isAdmin: m.role == GroupRole.administrator, label: l,
                                       contactNameColor: colors[m.aci] ?? ContactNameColors.all[0])
        }
        return GroupMemberLabelEditor(me: author, ourColor: colors[me] ?? ContactNameColors.all[0], canAddLabel: allowed(group?.accessControl.memberLabel),
                                      existingLabelEmoji: mine?.labelEmoji, existingLabelString: mine?.labelString, membersWithLabel: labelled,
                                      popPanel: { session.popPanel() },
                                      updateGroupMemberLabel: { emoji, label, done in session.setOurMemberLabel(emoji: emoji, label: label, done: done) })
    }
}

/// ContactModal for a group member (or a 1:1 contact): message, admin, remove, block.
struct MemberContactModal: View {
    @Bindable var session: SignalSession
    let serviceId: String
    let i18n: Localizer

    var body: some View {
        let group = session.details?.group
        let me = session.ourAci ?? ""
        var contact = ContactModal.Contact(id: serviceId, title: serviceId == me ? i18n("icu:you") : session.contactTitle(serviceId))
        contact.isMe = serviceId == me
        contact.color = session.contactColor(serviceId)
        contact.avatar = session.avatarImage(session.contacts[serviceId]?.avatar)
        contact.hasAvatar = contact.avatar != nil
        contact.isBlocked = session.blockedConversationIds.contains { session.conversation($0)?.serviceId == serviceId }
        // canHaveNicknameAndNote: anyone but ourselves.
        contact.canHaveNicknameAndNote = serviceId != me
        let conversation: ContactModal.Group? = group.map { g in
            var c = ContactModal.Group(id: session.selectedConversationId ?? "")
            c.terminated = g.terminated
            c.attributesAdminOnly = g.accessControl.attributes == GroupAccess.administrator
            return c
        }
        let member = group?.member(serviceId)
        let label = member.flatMap { m -> ContactLabel? in
            guard let s = m.labelString, !s.isEmpty else { return nil }
            return ContactLabel(labelString: s, labelEmoji: m.labelEmoji)
        }
        var actions = ContactModal.Actions()
        actions.hideContactModal = { session.contactModalId = nil }
        actions.showConversation = { _ in
            session.contactModalId = nil
            session.openDirect(serviceId: serviceId)
        }
        actions.toggleAdmin = { _, _ in session.toggleAdmin(serviceId) }
        actions.removeMemberFromGroup = { _, _ in
            session.contactModalId = nil
            session.removeMember(serviceId)
        }
        actions.blockConversation = { _ in session.blockContact(serviceId) }
        actions.onOutgoingVideoCall = { _ in session.callContact(serviceId, video: true) }
        actions.onOutgoingAudioCall = { _ in session.callContact(serviceId, video: false) }
        actions.toggleAboutContactModal = { session.showAboutContact($0) }
        actions.toggleSafetyNumberModal = { session.showSafetyNumber($0) }
        actions.toggleAddUserToAnotherGroupModal = { session.showAddToGroup($0) }
        actions.onOpenEditNicknameAndNoteModal = {
            session.contactModalId = nil
            session.editNickname(serviceId)
        }
        actions.showAvatar = {
            if contact.avatar != nil {
                session.contactModalId = nil
                session.contactDialog = .avatar(serviceId: serviceId)
            }
        }
        actions.toggleGroupMemberLabelInfoModal = { _ in session.contactDialog = .memberLabelInfo }
        return ContactModal(contact: contact, conversation: conversation, areWeAdmin: group?.isAdmin(me) ?? false, isAdmin: member?.role == GroupRole.administrator,
                            isMember: member != nil, hasActiveCall: session.activeCall != nil, contactLabel: label,
                            contactNameColor: label != nil ? ContactNameColors.colors(group)[serviceId] : nil, actions: actions)
    }
}
