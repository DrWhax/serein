// Port of ts/components/conversation/conversation-details/ConversationDetails.dom.tsx and
// ConversationDetailsGroups.dom.tsx: the conversation's details panel. The header, the
// video / audio / mute / search buttons, then AxoLists: the Signal chat's info and help, the
// settings (disappearing messages, nickname, chat colour, notifications, media, safety number),
// the members, the group's links / labels / invites / permissions, groups in common, and the
// actions. Editing the group and adding members open their dialogs on the modal stack.
//
// Omitted: the "Become a sustainer" row of the Signal chat (donations). Not ported yet: the
// call-history section (Calls tab) and the in-another-call tooltip.

import SignalI18n
import SwiftUI

public struct ConversationDetailsModel {
    public enum NavTab: Sendable { case chats, calls }
    public var conversationId: String
    public var title: String
    public var avatar: ConversationAvatarData
    public var groupDescription: String?
    public var about: String?
    public var isMe = false
    public var isGroup: Bool
    public var isSignalConversation = false
    public var isInSystemContacts = false
    public var terminated = false
    public var isArchived = false
    public var isBlocked = false
    public var left = false
    public var muteExpiresAt: Double?
    public var expireTimer: Int?
    public var membersCount: Int?
    public var bubbleColor: BubbleColor = .default
    public var canEditGroupInfo = false
    public var canAddLabel = true
    public var canAddNewMembers = false
    public var isAdmin = false
    public var hasGroupLink = false
    public var hasMedia = false
    public var hasActiveCall = false
    public var isEditMemberLabelEnabled = true
    public var isTerminateGroupEnabled = true
    /// `canHaveNicknameAndNote(conversation)`
    public var canHaveNicknameAndNote = false
    public var selectedNavTab: NavTab = .chats
    /// The call history group shown (opened from the Calls tab).
    public var callHistoryGroup: CallHistoryGroup?
    public var memberships: [GroupV2Membership] = []
    public var invitesCount = 0
    public var groupsInCommon: [ConversationAvatarData] = []
    public init(conversationId: String, title: String, avatar: ConversationAvatarData, isGroup: Bool) {
        self.conversationId = conversationId
        self.title = title
        self.avatar = avatar
        self.isGroup = isGroup
    }

    /// `getCannotLeaveBecauseYouAreLastAdmin`
    var cannotLeaveBecauseYouAreLastAdmin: Bool {
        let others = memberships.filter { !$0.isMe }
        return isAdmin && !others.isEmpty && !others.contains { $0.isAdmin }
    }
}

public struct ConversationDetailsCallbacks {
    public var pushPanel: (String) -> Void = { _ in }
    public var showContactModal: (String) -> Void = { _ in }
    public var showConversation: (String) -> Void = { _ in }
    public var setDisappearingMessages: (Int) -> Void = { _ in }
    public var setMuteExpiration: (MuteOption?) -> Void = { _ in }
    public var searchInConversation: () -> Void = {}
    public var onOutgoingVideoCall: () -> Void = {}
    public var onOutgoingAudioCall: () -> Void = {}
    public var onOpenEditNicknameAndNote: () -> Void = {}
    public var onDeleteNicknameAndNote: () -> Void = {}
    public var toggleSafetyNumberModal: () -> Void = {}
    public var toggleAboutContactModal: () -> Void = {}
    public var toggleAddUserToAnotherGroupModal: () -> Void = {}
    public var openLink: (URL) -> Void = { _ in }
    public var actions = ConversationDetailsActions.Callbacks()
    public var editGroup: () -> Void = {}
    public var addMembers: () -> Void = {}
    public init() {}
}

public struct ConversationDetails: View {
    let model: ConversationDetailsModel
    let callbacks: ConversationDetailsCallbacks
    @State private var muteMenuOpen = false
    @State private var nicknameMenuOpen = false
    @Environment(\.i18n) var i18n
    @Environment(\.axoModalStack) var modals
    @Environment(\.conversationListNow) var fixedNow
    @Environment(\.timeZone) var timeZone

    public init(model: ConversationDetailsModel, callbacks: ConversationDetailsCallbacks = ConversationDetailsCallbacks()) {
        self.model = model
        self.callbacks = callbacks
    }

    var isMuted: Bool { MuteExpirationTime.isMuted(model.muteExpiresAt, now: fixedNow ?? .now) }

    var headerButtons: some View {
        let m = model
        return AxoStackedButton.Row(spacing: .md) {
            if m.selectedNavTab == .calls {
                AxoStackedButton.Root(symbol: "message", label: i18n("icu:ConversationDetails__HeaderButton--Message")) { callbacks.showConversation(m.conversationId) }
            }
            if !m.isMe && !m.isSignalConversation {
                if !m.terminated {
                    AxoStackedButton.Root(symbol: "videocamera", label: i18n("icu:video"), discouraged: m.hasActiveCall, onClick: callbacks.onOutgoingVideoCall)
                }
                if !m.isGroup {
                    AxoStackedButton.Root(symbol: "phone", label: i18n("icu:audio"), discouraged: m.hasActiveCall, onClick: callbacks.onOutgoingAudioCall)
                }
            }
            AxoDropdownMenu.Root(isOpen: $muteMenuOpen) {
                AxoStackedButton.Root(symbol: isMuted ? "bell-slash" : "bell", label: i18n(isMuted ? "icu:unmute" : "icu:mute"))
            } items: {
                if isMuted, let at = m.muteExpiresAt {
                    AxoDropdownMenu.Label(MuteExpirationTime.mutedUntilText(at, now: fixedNow ?? .now, i18n: i18n, timeZone: timeZone))
                    AxoDropdownMenu.Item(i18n("icu:unmute")) { callbacks.setMuteExpiration(nil) }
                } else {
                    AxoDropdownMenu.Label(i18n("icu:MuteMenu__label"))
                    ForEach(MuteOption.values(i18n), id: \.1) { name, option in AxoDropdownMenu.Item(name) { callbacks.setMuteExpiration(option) } }
                }
            }
            if m.selectedNavTab != .calls {
                AxoStackedButton.Root(symbol: "search", label: i18n("icu:search"), onClick: callbacks.searchInConversation)
            }
        }
        .padding(.bottom, 24)
    }

    @ViewBuilder var signalConversationLists: some View {
        ConversationDetailsList {
            AxoTextItem.Root(symbol: "seal-check", label: i18n("icu:ConversationHero--signal-official-chat"))
            AxoTextItem.Root(symbol: "bell", label: i18n("icu:ConversationHero--release-notes"))
        }
        ConversationDetailsList(label: i18n("icu:ConversationDetails--help-section")) {
            AxoClickableItem.Root(symbol: "question-circle", label: i18n("icu:ConversationDetails--support-center"), arrow: .externalLink) {
                if let u = URL(string: "https://support.signal.org") { callbacks.openLink(u) }
            }
            AxoClickableItem.Root(symbol: "invite", label: i18n("icu:contactUs"), arrow: .externalLink) {
                if let u = URL(string: "https://support.signal.org/hc/requests/new?desktop") { callbacks.openLink(u) }
            }
        }
    }

    /// `.ConversationDetails__chat-color`: the bubble colour in a 32px bubble (4px border, 2px padding).
    var chatColorSwatch: some View {
        BubbleFill(color: model.bubbleColor, shape: UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(topLeading: 10, bottomLeading: 10,
                                                                                                          bottomTrailing: 10, topTrailing: 10)))
            .frame(width: 20, height: 20)
            .padding(6)
    }

    @ViewBuilder var settingsList: some View {
        let m = model
        ConversationDetailsList {
            if !m.isGroup || m.canEditGroupInfo || m.expireTimer != nil {
                AxoItem.Root {
                    AxoItem.Leading { AxoItem.Icon(symbol: "timer-slash") }
                    AxoItem.Content {
                        AxoItem.Label(i18n("icu:ConversationDetails--disappearing-messages-label"))
                        AxoItem.Description(i18n(m.isGroup ? "icu:ConversationDetails--disappearing-messages-info--group"
                                                 : "icu:ConversationDetails--disappearing-messages-info--direct"))
                        AxoItem.Accessory {
                            DisappearingTimerSelect(value: m.expireTimer ?? 0, disabled: m.isGroup && (!m.canEditGroupInfo || m.terminated),
                                                    onChange: callbacks.setDisappearingMessages)
                        }
                    }
                }
            }
            if m.canHaveNicknameAndNote {
                AxoClickableItem.Root(symbol: "pencil", label: i18n("icu:ConversationDetails--nickname-label"), onClick: callbacks.onOpenEditNicknameAndNote) {
                    AxoDropdownMenu.Root(isOpen: $nicknameMenuOpen) {
                        AxoItem.IconAction(label: i18n("icu:ConversationDetails--nickname-actions"), variant: .impliedSecondary, symbol: "more")
                    } items: {
                        AxoDropdownMenu.Item(i18n("icu:ConversationDetails--nickname-actions--delete"), symbol: "trash", action: confirmDeleteNickname)
                    }
                }
            }
            if m.selectedNavTab == .chats {
                AxoClickableItem.Root(symbol: "palette", label: i18n("icu:showChatColorEditor"), onClick: { callbacks.pushPanel("ChatColorEditor") }) {
                    chatColorSwatch
                }
            }
            AxoClickableItem.Root(symbol: "bell", label: i18n("icu:ConversationDetails--notifications"),
                                  value: isMuted ? m.muteExpiresAt.map { MuteExpirationTime.mutedUntilText($0, now: fixedNow ?? .now, i18n: i18n, timeZone: timeZone) } : nil) {
                callbacks.pushPanel("NotificationSettings")
            }
            if m.hasMedia {
                AxoClickableItem.Root(symbol: "album", label: i18n("icu:ConversationDetailsMediaList--title")) { callbacks.pushPanel("AllMedia") }
            }
            if !m.isGroup && !m.isMe {
                AxoClickableItem.Root(symbol: "shield-check", label: i18n("icu:ConversationDetails__viewSafetyNumber"), onClick: callbacks.toggleSafetyNumberModal)
            }
        }
    }

    func confirmDeleteNickname() {
        guard let modals else { return }
        let id = "delete-nickname"
        modals.present(id: id) {
            AxoConfirmDialog.Root(title: i18n("icu:ConversationDetails__ConfirmDeleteNicknameAndNote__Title"),
                                  description: i18n("icu:ConversationDetails__ConfirmDeleteNicknameAndNote__Description")) {
                AxoConfirmDialog.Cancel(i18n("icu:cancel")) { modals.dismiss(id: id) }
                AxoConfirmDialog.Action(i18n("icu:delete"), variant: .strongDestructive) {
                    modals.dismiss(id: id)
                    callbacks.onDeleteNicknameAndNote()
                }
            }
        }
    }

    @ViewBuilder var groupList: some View {
        let m = model
        let areWeMember = m.memberships.contains(where: \.isMe)
        ConversationDetailsList {
            if m.isAdmin || m.hasGroupLink {
                AxoClickableItem.Root(symbol: "link", label: i18n("icu:ConversationDetails--group-link"), value: i18n(m.hasGroupLink ? "icu:on" : "icu:off")) {
                    callbacks.pushPanel("GroupLinkManagement")
                }
            }
            if m.isEditMemberLabelEnabled && areWeMember {
                AxoClickableItem.Root(symbol: "label", label: i18n("icu:ConversationDetails--member-label"), disabled: !m.canAddLabel,
                                      tooltip: m.canAddLabel ? nil : i18n("icu:ToastManager__CannotAddMemberLabel")) {
                    callbacks.pushPanel("GroupMemberLabelEditor")
                }
            }
            AxoClickableItem.Root(symbol: "group", label: i18n("icu:ConversationDetails--requests-and-invites"), value: "\(m.invitesCount)") {
                callbacks.pushPanel("GroupInvites")
            }
            if m.isAdmin {
                AxoClickableItem.Root(symbol: "key", label: i18n("icu:permissions")) { callbacks.pushPanel("GroupPermissions") }
            }
        }
    }

    /// `ConversationDetailsGroups`
    var groupsInCommon: some View {
        let groups = model.groupsInCommon
        let title = groups.isEmpty ? i18n("icu:ConversationDetailsGroups--title--with-zero-groups-in-common")
            : i18n("icu:ConversationDetailsGroups--title", ["count": .number(Double(groups.count))])
        return ConversationDetailsGroups(title: title, groups: groups, addToGroup: callbacks.toggleAddUserToAnotherGroupModal,
                                         showConversation: callbacks.showConversation)
    }

    public var body: some View {
        let m = model
        AxoContainer.Root {
            ConversationDetailsHeader(avatar: m.avatar, title: m.title, canEdit: m.canEditGroupInfo, isGroup: m.isGroup, isMe: m.isMe,
                                      isSignalConversation: m.isSignalConversation, isInSystemContacts: m.isInSystemContacts, terminated: m.terminated,
                                      groupDescription: m.groupDescription, about: m.about, membersCount: m.membersCount,
                                      startEditing: { _ in callbacks.editGroup() }, toggleAboutContactModal: callbacks.toggleAboutContactModal)
            headerButtons
            AxoList.Group {
                if m.isSignalConversation { signalConversationLists }
                if let group = m.callHistoryGroup { CallHistoryGroupPanelSection(callHistoryGroup: group) }
                if !m.isSignalConversation { settingsList }
                if m.isGroup {
                    ConversationDetailsMembershipList(memberships: m.memberships, canAddNewMembers: m.canAddNewMembers, canAddLabel: m.canAddLabel,
                                                      isEditMemberLabelEnabled: m.isEditMemberLabelEnabled, isTerminated: m.terminated,
                                                      showContactModal: callbacks.showContactModal,
                                                      showLabelEditor: { callbacks.pushPanel("GroupMemberLabelEditor") },
                                                      startAddingNewMembers: callbacks.addMembers)
                }
                if m.isGroup && !m.terminated { groupList }
                if !m.isGroup && !m.isMe && !m.isSignalConversation { groupsInCommon }
                if !m.isMe {
                    ConversationDetailsActions(conversationId: m.conversationId, conversationTitle: m.title,
                                               cannotLeaveBecauseYouAreLastAdmin: m.cannotLeaveBecauseYouAreLastAdmin,
                                               canTerminateGroup: m.isTerminateGroupEnabled && !m.terminated && m.isAdmin, isArchived: m.isArchived,
                                               isBlocked: m.isBlocked, isGroup: m.isGroup, isGroupTerminated: m.terminated,
                                               isSignalConversation: m.isSignalConversation, left: m.left, callbacks: callbacks.actions)
                }
            }
        }
    }
}

/// `ConversationDetailsGroups`: "N groups in common", "Add to a group", five groups and "See all".
public struct ConversationDetailsGroups: View {
    let title: String
    let groups: [ConversationAvatarData]
    let addToGroup: () -> Void
    let showConversation: (String) -> Void
    @State private var showAll = false
    @Environment(\.i18n) var i18n
    public init(title: String, groups: [ConversationAvatarData], addToGroup: @escaping () -> Void, showConversation: @escaping (String) -> Void) {
        self.title = title
        self.groups = groups
        self.addToGroup = addToGroup
        self.showConversation = showConversation
    }
    public var body: some View {
        let moreThanMax = groups.count - 5 > 1
        AxoContactList.Root(title: title) {
            AxoContactList.ActionItem(symbol: "plus", title: i18n("icu:ConversationDetailsGroups--add-to-group"), onClick: addToGroup)
            ForEach(Array((showAll ? groups : Array(groups.prefix(5))).enumerated()), id: \.offset) { _, g in
                AxoContactList.Item(title: g.title, onClick: { showConversation(g.title) }) { ListAvatar(data: g, size: 32) }
            }
            if !showAll && moreThanMax {
                AxoContactList.ActionItem(symbol: "chevron-down", title: i18n("icu:ConversationDetailsGroups--show-all")) { showAll = true }
            }
        }
    }
}
