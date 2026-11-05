// Port of ts/components/AnnouncementsOnlyGroupBannerAdminsDialog.dom.tsx: "Message an admin",
// a small AxoDialog listing the group's admins. Each row is a button (p-2) with a 36px avatar
// (pe-3) and the name over the member label pill; clicking it opens that conversation.

import SignalI18n
import SwiftUI

/// `AdminMembershipType` with the member colour from `memberColors`.
public struct GroupAdmin: Identifiable {
    public var id: String
    public var avatar: ConversationAvatarData
    public var isMe = false
    public var label: ContactLabel?
    public var contactNameColor: String?
    public init(id: String, avatar: ConversationAvatarData, isMe: Bool = false, label: ContactLabel? = nil, contactNameColor: String? = nil) {
        self.id = id
        self.avatar = avatar
        self.isMe = isMe
        self.label = label
        self.contactNameColor = contactNameColor
    }
}

public struct AnnouncementsOnlyGroupBannerAdminsDialog: View {
    let groupAdmins: [GroupAdmin]
    let showConversation: (String) -> Void
    let onClose: () -> Void
    @Environment(\.i18n) var i18n

    public init(groupAdmins: [GroupAdmin], showConversation: @escaping (String) -> Void, onClose: @escaping () -> Void = {}) {
        self.groupAdmins = groupAdmins
        self.showConversation = showConversation
        self.onClose = onClose
    }

    public var body: some View {
        AxoDialog.Content(size: .sm, hasFooter: false) {
            AxoDialog.Header {
                AxoDialog.Title(i18n("icu:AnnouncementsOnlyGroupBanner--modal"))
                AxoDialog.Close(action: onClose)
            }
            AxoDialog.Body {
                ForEach(groupAdmins) { admin in
                    GroupAdminItem(admin: admin) { showConversation(admin.id) }
                }
            }
        }
    }
}

/// `GroupAdminItem`
struct GroupAdminItem: View {
    let admin: GroupAdmin
    let onClick: () -> Void
    @Environment(\.i18n) var i18n
    var body: some View {
        SwiftUI.Button(action: onClick) {
            HStack(alignment: .center, spacing: 0) {
                ListAvatar(data: admin.avatar, size: 36).padding(.trailing, 12)
                VStack(alignment: .leading, spacing: 0) {
                    CSSText(runs: [Emojify.run(admin.isMe ? i18n("icu:you") : admin.avatar.title)], style: CSSTextStyle(AxoType.bodyMedium),
                            wrap: .wrap, color: .labelPrimary)
                    if let label = admin.label, let color = admin.contactNameColor {
                        // span.block.type-body-small: the inline pill in a 16px line box.
                        GroupMemberLabel(contactLabel: label, contactNameColor: color, context: .list)
                            .frame(height: 22, alignment: .top)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
