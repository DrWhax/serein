// Port of ts/components/conversation/ContactModal.dom.tsx (+ stylesheets/components/
// ContactModal.scss): the sheet for a group member or contact. An 80px avatar (story ring),
// the name (title-1 regular, the in-contacts icon, a chevron to About), the member label,
// Message / Video / Voice, a rule, then the actions (nickname, block, safety number, add to
// another group, make / remove admin, remove from group, mute in call, remove from call).
// Each confirmation replaces the sheet while it is shown.
//
// Badges (donor badges, BadgeDialog) are out of scope. Clicking the avatar opens the avatar
// lightbox through `showAvatar` (the lightbox is ported in step 7).

import SignalI18n
import SwiftUI

public struct ContactModal: View {
    public struct Contact: Sendable {
        public var id: String
        public var title: String
        public var isMe = false
        public var color = "A200"
        public var avatar: RGBAImage?
        public var hasAvatar = false
        public var isBlocked = false
        public var isInSystemContacts = false
        /// `canHaveNicknameAndNote`: a direct conversation that isn't us or the Signal chat.
        public var canHaveNicknameAndNote = true
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public struct Group: Sendable {
        public var id: String
        public var terminated = false
        /// `accessControlAttributes == ADMINISTRATOR`
        public var attributesAdminOnly = false
        public init(id: String) { self.id = id }
    }

    public struct Actions {
        public var hideContactModal: () -> Void = {}
        public var showConversation: (String) -> Void = { _ in }
        public var onOutgoingVideoCall: (String) -> Void = { _ in }
        public var onOutgoingAudioCall: (String) -> Void = { _ in }
        public var toggleAboutContactModal: (String) -> Void = { _ in }
        public var toggleGroupMemberLabelInfoModal: (String) -> Void = { _ in }
        public var onOpenEditNicknameAndNoteModal: () -> Void = {}
        public var blockConversation: (String) -> Void = { _ in }
        public var toggleSafetyNumberModal: (String) -> Void = { _ in }
        public var toggleAddUserToAnotherGroupModal: (String) -> Void = { _ in }
        public var toggleAdmin: (String, String) -> Void = { _, _ in }
        public var removeMemberFromGroup: (String, String) -> Void = { _, _ in }
        public var sendRemoteMute: (Int) -> Void = { _ in }
        public var blockClientFromCall: (Int) -> Void = { _ in }
        public var removeClientFromCall: (Int) -> Void = { _ in }
        public var viewUserStories: (String) -> Void = { _ in }
        public var startAvatarDownload: () -> Void = {}
        public var showAvatar: () -> Void = {}
        public init() {}
    }

    enum SubModal { case toggleAdmin, memberRemove, confirmingBlock, confirmingMute, removeFromCall }

    let contact: Contact
    let conversation: Group?
    let areWeAdmin: Bool
    let isAdmin: Bool
    let isMember: Bool
    let hasActiveCall: Bool
    let activeCallDemuxId: Int?
    let isMuted: Bool
    let isRemoteMuteVisible: Bool
    let isRemoveFromCallVisible: Bool
    let hasStories: HasStories?
    let contactLabel: ContactLabel?
    let contactNameColor: String?
    let actions: Actions
    @State private var subModal: SubModal?
    @Environment(\.i18n) var i18n

    public init(contact: Contact, conversation: Group?, areWeAdmin: Bool = false, isAdmin: Bool = false, isMember: Bool = true,
                hasActiveCall: Bool = false, activeCallDemuxId: Int? = nil, isMuted: Bool = false, isRemoteMuteVisible: Bool = false,
                isRemoveFromCallVisible: Bool = false, hasStories: HasStories? = nil, contactLabel: ContactLabel? = nil,
                contactNameColor: String? = nil, actions: Actions = Actions()) {
        self.contact = contact
        self.conversation = conversation
        self.areWeAdmin = areWeAdmin
        self.isAdmin = isAdmin
        self.isMember = isMember
        self.hasActiveCall = hasActiveCall
        self.activeCallDemuxId = activeCallDemuxId
        self.isMuted = isMuted
        self.isRemoteMuteVisible = isRemoteMuteVisible
        self.isRemoveFromCallVisible = isRemoveFromCallVisible
        self.hasStories = hasStories
        self.contactLabel = contactLabel
        self.contactNameColor = contactNameColor
        self.actions = actions
    }

    public var body: some View {
        if let subModal {
            confirmation(subModal)
        } else {
            sheet
        }
    }

    // MARK: Confirmations

    var cancel: some View { AxoConfirmDialog.Cancel(i18n("icu:cancel")) { subModal = nil } }

    @ViewBuilder func confirmation(_ m: SubModal) -> some View {
        let name = contact.title
        switch m {
        case .toggleAdmin:
            if let conversation {
                if isAdmin, contactLabel != nil, conversation.attributesAdminOnly {
                    AxoConfirmDialog.Root(title: i18n("icu:ContactModal--rm-admin-info", ["contact": .string(name)]),
                                          description: i18n("icu:ContactModal--rm-admin--clear-label")) {
                        cancel
                        AxoConfirmDialog.Action(i18n("icu:ContactModal--rm-admin"), variant: .strongDestructive) {
                            subModal = nil; actions.toggleAdmin(conversation.id, contact.id)
                        }
                    }
                } else {
                    AxoConfirmDialog.Root(title: nil, description: i18n(isAdmin ? "icu:ContactModal--rm-admin-info" : "icu:ContactModal--make-admin-info",
                                                                         ["contact": .string(name)])) {
                        cancel
                        AxoConfirmDialog.Action(i18n(isAdmin ? "icu:ContactModal--rm-admin" : "icu:ContactModal--make-admin"),
                                                variant: isAdmin ? .strongDestructive : .strongPrimary) {
                            subModal = nil; actions.toggleAdmin(conversation.id, contact.id)
                        }
                    }
                }
            }
        case .memberRemove:
            if let conversation {
                AxoConfirmDialog.Root(title: i18n.richText("icu:RemoveGroupMemberConfirmation__description", ["name": .element("name")]).plain(["name": name]),
                                      description: nil) {
                    cancel
                    AxoConfirmDialog.Action(i18n("icu:RemoveGroupMemberConfirmation__remove-button"), variant: .strongDestructive) {
                        subModal = nil; actions.removeMemberFromGroup(conversation.id, contact.id)
                    }
                }
            }
        case .confirmingBlock:
            AxoConfirmDialog.Root(title: i18n("icu:MessageRequests--block-direct-confirm-title", ["title": .string(name)]),
                                  description: i18n("icu:MessageRequests--block-direct-confirm-body")) {
                cancel
                AxoConfirmDialog.Action(i18n("icu:MessageRequests--block"), variant: .strongDestructive) {
                    subModal = nil; actions.blockConversation(contact.id)
                }
            }
        case .confirmingMute:
            AxoConfirmDialog.Root(title: nil, description: i18n("icu:ContactModal--confirm-mute-body", ["contact": .string(name)])) {
                cancel
                AxoConfirmDialog.Action(i18n("icu:ContactModal--confirm-mute-primary-button"), variant: .strongPrimary) {
                    actions.hideContactModal()
                    if let id = activeCallDemuxId { actions.sendRemoteMute(id) }
                }
            }
        case .removeFromCall:
            AxoConfirmDialog.Root(title: nil, description: i18n("icu:CallingAdhocCallInfo__RemoveClientDialogBody", ["name": .string(name)])) {
                cancel
                AxoConfirmDialog.Action(i18n("icu:CallingAdhocCallInfo__RemoveClientDialogButton--block"), variant: .strongDestructive) {
                    actions.hideContactModal()
                    if let id = activeCallDemuxId { actions.blockClientFromCall(id) }
                }
                AxoConfirmDialog.Action(i18n("icu:CallingAdhocCallInfo__RemoveClientDialogButton--remove"), variant: .strongDestructive) {
                    actions.hideContactModal()
                    if let id = activeCallDemuxId { actions.removeClientFromCall(id) }
                }
            }
        }
    }

    // MARK: The sheet

    var sheet: some View {
        AxoDialog.Content(size: .sm, hasHeader: false, hasFooter: false) {
            AxoDialog.Body(maxHeight: 560) {
                VStack(spacing: 0) {
                    avatar
                    name.padding(.top, 12)
                    if let contactLabel, let contactNameColor {
                        SwiftUI.Button { if let id = conversation?.id { actions.toggleGroupMemberLabelInfoModal(id) } } label: {
                            GroupMemberLabel(contactLabel: contactLabel, contactNameColor: contactNameColor, context: .contactModal, emojiSize: 14)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                        .padding(.bottom, 4)
                    }
                    if !contact.isMe { quickActions.padding(.vertical, 16) }
                    Rectangle().fill(AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray75)).frame(height: 1)
                        .padding(.top, 8).padding(.bottom, 5)
                    buttons.padding(.top, 12)
                }
                .frame(maxWidth: .infinity)
                .cssTextColor(.labelPrimary)
            }
        }
        .overlay(alignment: .top) {
            AxoDialog.Header(floating: true) {
                AxoDialog.Title(contact.title)
                AxoDialog.Close(action: actions.hideContactModal)
            }
        }
    }

    var avatar: some View {
        let clickToLoad = contact.avatar == nil && !contact.isMe && contact.hasAvatar
        return Avatar(strings: AvatarStrings(i18n: i18n), title: contact.title, size: 80, conversationType: .direct, color: contact.color,
                      image: contact.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: contact.hasAvatar, storyRing: hasStories,
                      blur: clickToLoad ? .blurPictureWithClickToView : .noBlur) {
            if conversation != nil && hasStories != nil {
                actions.viewUserStories(contact.id)
                actions.hideContactModal()
            } else if clickToLoad {
                actions.startAvatarDownload()
            } else {
                actions.showAvatar()
            }
        }
    }

    /// `.ContactModal__name`: title-1 at weight 400, truncated, baseline-aligned with the
    /// chevron (20px, its bottom on the baseline, 2px lower).
    var name: some View {
        let style = LegacyType.title1(weight: 400)
        var runs = [Emojify.run(contact.title)]
        if contact.isInSystemContacts {
            runs.append(CSSTextRun(" "))
            runs.append(.inlineBlock("", CSSInlineBlock(paddingInline: 11)))
        }
        return SwiftUI.Button { actions.toggleAboutContactModal(contact.id) } label: {
            HStack(alignment: .top, spacing: 0) {
                CSSText(runs: runs, style: style, wrap: .truncate)
                    .overlay(alignment: .trailing) {
                        if contact.isInSystemContacts {
                            // InContactsIcon at 22px in currentColor, vertical-align middle.
                            SignalIcon("v3/person/person-circle-compact", size: 22, color: .labelPrimary, mask: true)
                                .offset(y: -1)
                        }
                    }
                SignalIcon("v3/chevron/chevron-right-bold", size: 20, color: AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05), mask: true)
                    // align-items: baseline puts its bottom on the text's baseline (25px down
                    // in the 32px line); inset-block-start 2px.
                    .padding(.top, 25 - 20 + 2)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    var quickActions: some View {
        AxoStackedButton.Row(spacing: .md) {
            AxoStackedButton.Root(symbol: "message", label: i18n("icu:ConversationDetails__HeaderButton--Message")) {
                actions.hideContactModal()
                actions.showConversation(contact.id)
            }
            AxoStackedButton.Root(symbol: "videocamera", label: i18n("icu:video"), discouraged: hasActiveCall) {
                actions.hideContactModal()
                actions.onOutgoingVideoCall(contact.id)
            }
            .help(hasActiveCall ? i18n("icu:calling__in-another-call-tooltip") : "")
            AxoStackedButton.Root(symbol: "phone", label: i18n("icu:ContactModal--voice"), discouraged: hasActiveCall) {
                actions.hideContactModal()
                actions.onOutgoingAudioCall(contact.id)
            }
            .help(hasActiveCall ? i18n("icu:calling__in-another-call-tooltip") : "")
        }
    }

    @ViewBuilder var buttons: some View {
        let canDoAdmin = !contact.isMe && areWeAdmin && isMember && conversation != nil && !(conversation?.terminated ?? false)
        VStack(alignment: .leading, spacing: 0) {
            if contact.canHaveNicknameAndNote {
                ContactModalButton(icon: "v3/edit/edit", label: i18n("icu:ContactModal--nickname"), action: actions.onOpenEditNicknameAndNoteModal)
            }
            if !contact.isMe {
                if contact.isBlocked {
                    ContactModalButton(icon: "v3/block/block", label: i18n("icu:AboutContactModal__blocked", ["name": .string(contact.title)]), action: nil)
                } else {
                    ContactModalButton(icon: "v3/block/block", label: i18n("icu:MessageRequests--block")) { subModal = .confirmingBlock }
                }
                ContactModalButton(icon: "v3/safety_number/safety_number", label: i18n("icu:showSafetyNumber")) {
                    actions.hideContactModal()
                    actions.toggleSafetyNumberModal(contact.id)
                }
            }
            if !contact.isMe && isMember && conversation != nil {
                ContactModalButton(icon: "v3/plus/plus-circle", label: i18n("icu:ContactModal--add-to-group")) {
                    actions.hideContactModal()
                    actions.toggleAddUserToAnotherGroupModal(contact.id)
                }
            }
            if canDoAdmin {
                ContactModalButton(icon: "v3/key/key", label: i18n(isAdmin ? "icu:ContactModal--rm-admin" : "icu:ContactModal--make-admin")) {
                    subModal = .toggleAdmin
                }
                ContactModalButton(icon: "v3/leave/leave", label: i18n("icu:ContactModal--remove-from-group")) { subModal = .memberRemove }
            }
            if isRemoteMuteVisible {
                ContactModalButton(symbol: "mic-slash", label: i18n("icu:ContactModal--mute-audio"), disabled: isMuted) { subModal = .confirmingMute }
            }
            if isRemoveFromCallVisible {
                ContactModalButton(symbol: "minus-circle", label: i18n("icu:ContactModal--remove-from-call")) { subModal = .removeFromCall }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `.ContactModal__button`: a full-width row, 6px above and below, the 20px icon (gray-75 /
/// gray-15, or an AxoSymbol in the text colour) 12px before the label; gray-02 (gray-80) on
/// hover and keyboard focus; disabled at 50%.
struct ContactModalButton: View {
    var icon: String?
    var symbol: AxoSymbol.Name?
    let label: String
    var disabled = false
    let action: (() -> Void)?
    @State private var hovered = false
    @FocusState private var focused: Bool

    init(icon: String, label: String, disabled: Bool = false, action: (() -> Void)?) {
        self.icon = icon
        self.label = label
        self.disabled = disabled
        self.action = action
    }

    init(symbol: AxoSymbol.Name, label: String, disabled: Bool = false, action: (() -> Void)?) {
        self.symbol = symbol
        self.label = label
        self.disabled = disabled
        self.action = action
    }

    var row: some View {
        HStack(spacing: 0) {
            Group {
                if let icon {
                    SignalIcon(icon, size: 20, color: AxoColor(light: LegacyColor.gray75, dark: LegacyColor.gray15), mask: true)
                } else if let symbol {
                    AxoSymbol.Icon(symbol, size: 20, label: nil)
                }
            }
            .frame(width: 20)
            .padding(.trailing, 12)
            CSSText(label, style: CSSTextStyle(AxoType.bodyMedium), color: .labelPrimary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((hovered || focused) && action != nil && !disabled ? AxoColor(light: LegacyColor.gray02, dark: LegacyColor.gray80) : AxoColor(RGBA(0, 0, 0, 0)))
        .opacity(disabled ? 0.5 : 1)
        .contentShape(Rectangle())
    }

    var body: some View {
        if let action {
            SwiftUI.Button(action: action) { row }
                .buttonStyle(.plain)
                .disabled(disabled)
                .onHover { hovered = $0 }
                .focused($focused)
        } else {
            row
        }
    }
}
