// Port of ts/components/conversation/AboutContactModal.dom.tsx: the "About" sheet for a
// contact (or "You"). A small AxoDialog with a floating header, the 216px avatar (blurred
// with click-to-view until downloaded), then one list: name (nickname with the profile name
// muted), about, verified, Signal Connection, system contact, the profile-name warning, the
// member label (yours), your QR code, phone, shared groups, note, and a status row (blocked,
// message request, no direct messages).

import SignalI18n
import SwiftUI

public struct AboutContactModal: View {
    public struct Contact: Sendable {
        public var id: String
        public var title: String
        public var titleNoNickname: String?
        public var isMe = false
        public var color = "A200"
        public var avatar: RGBAImage?
        public var hasAvatar = false
        public var about: String?
        public var isVerified = false
        public var isBlocked = false
        public var acceptedMessageRequest = true
        public var hasMessages = true
        public var profileSharing = false
        public var isInSystemContacts = false
        public var systemGivenName: String?
        public var firstName: String?
        public var phoneNumber: String?
        public var username: String?
        public var note: String?
        public var isGroup = false
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    let contact: Contact
    let isSignalConnection: Bool
    let sharedGroupNames: [String]
    let fromOrAddedByTrustedContact: Bool
    let canAddLabel: Bool
    let isEditMemberLabelEnabled: Bool
    let contactLabelEmoji: String?
    let contactLabelString: String?
    let contactNameColor: String?
    let pendingAvatarDownload: Bool
    let actions: Actions

    /// The modal's callbacks.
    public struct Actions {
        public var onClose: () -> Void = {}
        public var showProfileEditor: () -> Void = {}
        public var showQRCodeScreen: () -> Void = {}
        public var showEditMemberLabelScreen: () -> Void = {}
        public var startAvatarDownload: (String) -> Void = { _ in }
        public var toggleProfileNameWarningModal: () -> Void = {}
        public var toggleSafetyNumberModal: (String) -> Void = { _ in }
        public var toggleSignalConnectionsModal: () -> Void = {}
        public var onOpenNotePreviewModal: () -> Void = {}
        public init() {}
    }

    @Environment(\.i18n) var i18n

    public init(contact: Contact, isSignalConnection: Bool = false, sharedGroupNames: [String] = [], fromOrAddedByTrustedContact: Bool = false,
                canAddLabel: Bool = false, isEditMemberLabelEnabled: Bool = true, contactLabelEmoji: String? = nil, contactLabelString: String? = nil,
                contactNameColor: String? = nil, pendingAvatarDownload: Bool = false, actions: Actions = Actions()) {
        self.contact = contact
        self.isSignalConnection = isSignalConnection
        self.sharedGroupNames = sharedGroupNames
        self.fromOrAddedByTrustedContact = fromOrAddedByTrustedContact
        self.canAddLabel = canAddLabel
        self.isEditMemberLabelEnabled = isEditMemberLabelEnabled
        self.contactLabelEmoji = contactLabelEmoji
        self.contactLabelString = contactLabelString
        self.contactNameColor = contactNameColor
        self.pendingAvatarDownload = pendingAvatarDownload
        self.actions = actions
    }

    var labelStyle: CSSTextStyle { CSSTextStyle(AxoType.bodyMedium) }

    public var body: some View {
        // With a known avatar that isn't downloaded, it shows blurred with click-to-view.
        let clickToLoad = contact.avatar == nil && !contact.isMe && contact.hasAvatar
        AxoDialog.Content(size: .sm, hasHeader: false, hasFooter: false) {
            AxoDialog.Body(padding: .md) {
                Avatar(strings: AvatarStrings(i18n: i18n), title: contact.title, size: 216, conversationType: .direct, color: contact.color,
                       image: contact.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: contact.hasAvatar,
                       loading: pendingAvatarDownload && contact.avatar == nil, blur: clickToLoad ? .blurPictureWithClickToView : .noBlur,
                       onClick: clickToLoad ? {
                           if !pendingAvatarDownload { actions.startAvatarDownload(contact.id) }
                       } : nil)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 14)
                AxoList.Group {
                    AxoList.Root {
                        AxoList.Body {
                            AxoItem.Group(spacing: .sm) { rows }
                        }
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            AxoDialog.Header(floating: true) {
                AxoDialog.Title(i18n(contact.isMe ? "icu:AboutContactModal__title--myself" : "icu:AboutContactModal__title"))
                AxoDialog.Close(action: actions.onClose)
            }
        }
    }

    func text(_ runs: [CSSTextRun], wrap: CSSTextWrap = .wrap) -> some View {
        CSSText(runs: runs, style: labelStyle, wrap: wrap)
    }

    /// The name, or "{nickname} ({titleNoNickname})" when a nickname hides the profile name.
    @ViewBuilder var nameLabel: some View {
        if !contact.isMe, let profile = contact.titleNoNickname, profile != contact.title {
            text(CSSTextRun.runs(i18n.richText("icu:AboutContactModal__TitleAndTitleWithoutNickname",
                                               ["nickname": .element("nickname"), "titleNoNickname": .element("titleNoNickname")]),
                                 elements: ["nickname": Emojify.run(contact.title), "titleNoNickname": Emojify.run(profile)]))
                .help(i18n.richText("icu:AboutContactModal__TitleWithoutNickname__Tooltip", ["title": .element("title")]).plain(["title": profile]))
        } else {
            text([Emojify.run(contact.title)])
        }
    }

    @ViewBuilder var rows: some View {
        let isMe = contact.isMe
        let hasLabel = contactNameColor != nil && contactLabelString != nil
        if isMe {
            AxoClickableItem.Root(symbol: "person", accessibilityLabel: contact.title, arrow: .next, onClick: actions.showProfileEditor) { nameLabel }
        } else {
            AxoTextItem.Root(symbol: "person", accessibilityLabel: contact.title) { nameLabel }
        }
        if !isMe, let about = contact.about, !about.isEmpty {
            AxoTextItem.Root(symbol: "pencil", accessibilityLabel: about) { About(text: about) }
        }
        if !isMe && contact.isVerified {
            AxoClickableItem.Root(symbol: "shield-check", label: i18n("icu:AboutContactModal__verified")) { actions.toggleSafetyNumberModal(contact.id) }
        }
        if !isMe && isSignalConnection {
            AxoClickableItem.Root(symbol: "connections", label: i18n("icu:AboutContactModal__signal-connection"), arrow: .next,
                                  onClick: actions.toggleSignalConnectionsModal)
        }
        if !isMe && contact.isInSystemContacts {
            AxoTextItem.Root(symbol: "person-circle", label: i18n("icu:AboutContactModal__system-contact",
                                                                   ["name": .string(contact.systemGivenName ?? contact.firstName ?? contact.title)]))
        }
        if !isMe && !fromOrAddedByTrustedContact {
            let key = contact.isGroup ? "icu:ConversationHero--group-names" : "icu:ConversationHero--profile-names"
            AxoClickableItem.Root(symbol: contact.isGroup ? "group-question" : "person-question",
                                  label: i18n.richText(key).plain([:]), arrow: .next, onClick: actions.toggleProfileNameWarningModal)
        }
        if isMe && hasLabel, let string = contactLabelString {
            AxoClickableItem.Root(symbol: "label", accessibilityLabel: string, disabled: !canAddLabel, onClick: actions.showEditMemberLabelScreen) {
                memberLabel(string)
            }
        }
        if isMe && !hasLabel && canAddLabel && isEditMemberLabelEnabled {
            AxoClickableItem.Root(symbol: "label", label: i18n("icu:AboutContactModal__add-member-label"), arrow: .next,
                                  onClick: actions.showEditMemberLabelScreen)
        }
        if isMe && contact.username != nil {
            AxoClickableItem.Root(symbol: "qrcode", label: i18n("icu:AboutContactModal__your-qr-code"), onClick: actions.showQRCodeScreen)
        }
        if !isMe, let phone = contact.phoneNumber {
            AxoTextItem.Root(symbol: "phone", accessibilityLabel: phone) { text([Emojify.run(phone)]) }
        }
        if !isMe {
            AxoTextItem.Root(symbol: "group", accessibilityLabel: sharedGroupNames.joined(separator: ", ")) {
                text(SharedGroupNames.runs(sharedGroupNames, i18n))
            }
        }
        if let note = contact.note, !note.isEmpty {
            AxoClickableItem.Root(symbol: "note", accessibilityLabel: note, onClick: actions.onOpenNotePreviewModal) { text([Emojify.run(note)]) }
        }
        if !isMe {
            if contact.isBlocked {
                AxoTextItem.Root(symbol: "block", label: i18n("icu:AboutContactModal__blocked", ["name": .string(contact.title)]))
            } else if !contact.acceptedMessageRequest {
                AxoTextItem.Root(symbol: "message-badge", label: i18n("icu:AboutContactModal__message-request"))
            } else if !contact.hasMessages && !contact.profileSharing {
                AxoTextItem.Root(symbol: "message-x", label: i18n("icu:AboutContactModal__no-dms", ["name": .string(contact.title)]))
            }
        }
    }

    /// The label emoji (14px; ⍰ when it isn't an emoji), a no-break space, and the label with
    /// 14px emoji, truncated.
    func memberLabel(_ string: String) -> some View {
        var runs: [CSSTextRun] = []
        if let emoji = contactLabelEmoji {
            runs.append(emoji.count == 1 && CSSTextLayout.isEmoji(Character(emoji)) ? Emojify.run(emoji, fontSizeOverride: 14) : CSSTextRun("⍰"))
            runs.append(CSSTextRun("\u{00A0}"))
        }
        runs.append(Emojify.run(string, fontSizeOverride: 14))
        return text(runs, wrap: .truncate)
    }
}

