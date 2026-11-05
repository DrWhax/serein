// ContactListItem and ContactCheckbox (ts/components/conversationList/*.dom.tsx): a contact as
// a ListTile with a 32px avatar, the name (+ in-contacts icon), the About line, and a "more"
// menu or a checkbox.

import SignalI18n
import SwiftUI

public struct ContactListItemData {
    public var id: String
    public var title: String
    public var type: AvatarConversationType
    public var isMe: Bool
    public var isSignalConversation: Bool
    public var about: String?
    /// `isInSystemContacts`: a direct contact with a system name.
    public var isInSystemContacts: Bool
    public var avatar: ConversationAvatarData

    public init(id: String, title: String, type: AvatarConversationType = .direct, isMe: Bool = false, isSignalConversation: Bool = false,
                about: String? = nil, isInSystemContacts: Bool = false, avatar: ConversationAvatarData? = nil) {
        self.id = id
        self.title = title
        self.type = type
        self.isMe = isMe
        self.isSignalConversation = isSignalConversation
        self.about = about
        self.isInSystemContacts = isInSystemContacts
        self.avatar = avatar ?? ConversationAvatarData(title: title, conversationType: type, noteToSelf: isMe)
    }
}

/// `ContactCheckboxDisabledReason`
public enum ContactCheckboxDisabledReason: Sendable { case alreadyAdded, maximumContactsSelected }

public struct ContactListItem: View {
    let data: ContactListItemData
    let hasContextMenu: Bool
    let onClick: ((String) -> Void)?
    @Environment(\.i18n) var i18n
    @State private var hovered = false

    public init(_ data: ContactListItemData, hasContextMenu: Bool = false, onClick: ((String) -> Void)? = nil) {
        self.data = data
        self.hasContextMenu = hasContextMenu
        self.onClick = onClick
    }

    public var body: some View {
        ListTile(subtitleMaxLines: 1, onClick: onClick.map { f in { f(data.id) } }) {
            ListAvatar(data: data.avatar, size: 32)
        } title: {
            HStack(spacing: 0) {
                ContactName(title: data.isMe ? i18n("icu:noteToSelf") : data.title, isMe: data.isMe,
                            isSignalConversation: data.isSignalConversation, style: ListTile<EmptyView, EmptyView, EmptyView, EmptyView>.titleStyle, wrap: .clamp(1))
                if data.isInSystemContacts && data.type == .direct {
                    CSSText(" ", style: ListTile<EmptyView, EmptyView, EmptyView, EmptyView>.titleStyle, wrap: .nowrap)
                    InContactsIcon()
                }
            }
        } subtitle: {
            if let about = data.about, !data.isMe { ListTileSubtitle(about, emojify: true) }
        } trailing: {
            if hasContextMenu {
                AxoIconButton.Root(label: i18n("icu:ContactListItem__menu"), variant: .impliedSecondary, size: .sm, symbol: "more")
                    .opacity(hovered ? 1 : 0)
            }
        }
        .onHover { hovered = $0 }
    }
}

public struct ContactCheckbox: View {
    let data: ContactListItemData
    let isChecked: Bool
    let disabledReason: ContactCheckboxDisabledReason?
    let onClick: (String, ContactCheckboxDisabledReason?) -> Void
    @Environment(\.i18n) var i18n

    public init(_ data: ContactListItemData, isChecked: Bool, disabledReason: ContactCheckboxDisabledReason? = nil,
                onClick: @escaping (String, ContactCheckboxDisabledReason?) -> Void = { _, _ in }) {
        self.data = data
        self.isChecked = isChecked
        self.disabledReason = disabledReason
        self.onClick = onClick
    }

    public var body: some View {
        ListTileCheckbox(isChecked: isChecked, disabled: disabledReason != nil, subtitleMaxLines: 1, onClick: { onClick(data.id, disabledReason) }) {
            ListAvatar(data: data.avatar, size: 32)
        } title: {
            ContactName(title: data.isMe ? i18n("icu:noteToSelf") : data.title, isMe: data.isMe,
                        style: ListTile<EmptyView, EmptyView, EmptyView, EmptyView>.titleStyle, wrap: .clamp(1))
        } subtitle: {
            if !data.isMe {
                if disabledReason == .alreadyAdded {
                    ListTileSubtitle(i18n("icu:alreadyAMember"))
                } else if let about = data.about {
                    ListTileSubtitle(about, emojify: true)
                }
            }
        }
    }
}

/// InContactsIcon (ts/components/InContactsIcon.dom.tsx): the 14px person-circle glyph marking
/// a contact from the address book, vertical-align middle.
public struct InContactsIcon: View {
    @Environment(\.i18n) var i18n
    public init() {}
    public var body: some View {
        SignalIcon("v3/person/person-circle-compact", size: 14, color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25))
            .frame(width: 14, height: 14)
            .help(i18n("icu:contactInAddressBook"))
            .accessibilityLabel(i18n("icu:contactInAddressBook"))
    }
}
