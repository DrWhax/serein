// Port of ts/components/preferences/PreferencesBlocked.dom.tsx: the Blocked page — add a
// blocked user or group, then the blocked users and groups (with when they were blocked);
// choosing one asks to unblock it.

import SignalI18n
import SwiftUI

/// `BlockedConversation`
public struct BlockedConversation: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var isGroup: Bool
    public var color: String
    public var avatar: RGBAImage?
    /// `moment(blockedAt).format('ll')`, when known.
    public var blockedOn: String?
    public init(id: String, title: String, isGroup: Bool = false, color: String = "A200", avatar: RGBAImage? = nil, blockedOn: String? = nil) {
        self.id = id
        self.title = title
        self.isGroup = isGroup
        self.color = color
        self.avatar = avatar
        self.blockedOn = blockedOn
    }
}

public struct PreferencesBlocked: View {
    let blockedContacts: [BlockedConversation]
    let blockedGroups: [BlockedConversation]
    let goBack: () -> Void
    let onUnblock: (String) -> Void
    let conversationsNotBlocked: [SearchableConversation]
    let onBlock: (String) -> Void
    @State private var confirmUnblock: BlockedConversation?
    @State private var showBlockChooser = false
    @Environment(\.i18n) var i18n

    public init(blockedContacts: [BlockedConversation], blockedGroups: [BlockedConversation], goBack: @escaping () -> Void = {},
                onUnblock: @escaping (String) -> Void = { _ in }, conversationsNotBlocked: [SearchableConversation] = [],
                onBlock: @escaping (String) -> Void = { _ in }) {
        self.blockedContacts = blockedContacts
        self.blockedGroups = blockedGroups
        self.goBack = goBack
        self.onUnblock = onUnblock
        self.conversationsNotBlocked = conversationsNotBlocked
        self.onBlock = onBlock
    }

    func section(_ title: String, _ items: [BlockedConversation]) -> some View {
        AxoContactList.Root(title: title) {
            ForEach(items) { c in
                AxoContactList.Item(title: c.title, onClick: { confirmUnblock = c }) {
                    Avatar(strings: AvatarStrings(i18n: i18n), title: c.title, size: 36, conversationType: c.isGroup ? .group : .direct, color: c.color,
                           image: c.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: c.avatar != nil)
                } description: {
                    if let on = c.blockedOn { AxoContactList.DescriptionText(i18n("icu:Preferences--blocked--blocked-on", ["blockedAt": .string(on)])) }
                } accessory: {
                    EmptyView()
                }
            }
        }
    }

    public var body: some View {
        AxoPanel.Root {
            AxoPanel.Header {
                AxoPanel.Back(onClick: goBack)
                AxoPanel.Label(i18n("icu:Preferences--blocked"))
            }
            AxoPanel.Content {
                AxoList.Group {
                    PreferencesList(footerDescription: i18n("icu:Preferences--blocked-users--description")) {
                        AxoClickableItem.Root(label: i18n("icu:Preferences--add-blocked"), arrow: .next) { showBlockChooser = true }
                    }
                    if !blockedContacts.isEmpty { section(i18n("icu:Preferences--blocked-users"), blockedContacts) }
                    if !blockedGroups.isEmpty { section(i18n("icu:Preferences--blocked-groups"), blockedGroups) }
                }
            }
        }
        .viewportPortal {
            if showBlockChooser {
                AxoBaseDialog.Host {
                    PreferencesBlockChooserDialog(title: i18n("icu:Preferences--add-blocked"), conversations: conversationsNotBlocked, onBlock: onBlock,
                                                  onClose: { showBlockChooser = false })
                }
            } else if let c = confirmUnblock {
                AxoBaseDialog.Host {
                    MessageRequestActionsConfirmation(model: {
                        var m = MessageRequestModel(conversationId: c.id, conversationType: c.isGroup ? .group : .direct, conversationName: c.title)
                        m.isBlocked = true
                        m.acceptConversation = { onUnblock(c.id) }
                        return m
                    }(), state: .unblocking) { if $0 == .default { confirmUnblock = nil } }
                }
            }
        }
    }
}
