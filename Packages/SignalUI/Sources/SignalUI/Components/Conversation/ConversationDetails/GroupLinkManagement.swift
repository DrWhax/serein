// Port of ts/components/conversation/conversation-details/GroupLinkManagement.dom.tsx: the group
// link switch (the link itself copies on click), "Copy link" / "Reset link" (reset confirms),
// and for admins "Require admin approval".

import SignalI18n
import SwiftUI

public struct GroupLinkManagement: View {
    let groupLink: String?
    /// `accessControlAddFromInviteLink`: nil / unsatisfiable means the link is off.
    let addFromInviteLink: AccessControl?
    let isAdmin: Bool
    let changeHasGroupLink: (Bool) -> Void
    let generateNewGroupLink: () -> Void
    let setAccessControlAddFromInviteLinkSetting: (Bool) -> Void
    let copyGroupLink: (String) -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.axoModalStack) var modals

    public init(groupLink: String?, addFromInviteLink: AccessControl?, isAdmin: Bool, changeHasGroupLink: @escaping (Bool) -> Void = { _ in },
                generateNewGroupLink: @escaping () -> Void = {}, setAccessControlAddFromInviteLinkSetting: @escaping (Bool) -> Void = { _ in },
                copyGroupLink: @escaping (String) -> Void = { _ in }) {
        self.groupLink = groupLink
        self.addFromInviteLink = addFromInviteLink
        self.isAdmin = isAdmin
        self.changeHasGroupLink = changeHasGroupLink
        self.generateNewGroupLink = generateNewGroupLink
        self.setAccessControlAddFromInviteLinkSetting = setAccessControlAddFromInviteLinkSetting
        self.copyGroupLink = copyGroupLink
    }

    func confirmReset() {
        guard let modals else { return }
        let id = "group-link-reset"
        modals.present(id: id) {
            AxoConfirmDialog.Root(title: i18n("icu:GroupLinkManagement--confirm-reset"), description: nil) {
                AxoConfirmDialog.Cancel(i18n("icu:cancel")) { modals.dismiss(id: id) }
                AxoConfirmDialog.Action(i18n("icu:GroupLinkManagement--reset"), variant: .strongDestructive) {
                    modals.dismiss(id: id)
                    generateNewGroupLink()
                }
            }
        }
    }

    public var body: some View {
        let hasGroupLink = groupLink != nil && addFromInviteLink != nil
        AxoContainer.Root {
            AxoList.Group {
                ConversationDetailsList {
                    AxoSwitchItem.Root(label: i18n("icu:ConversationDetails--group-link"), description: hasGroupLink ? groupLink : nil,
                                       checked: Binding(get: { hasGroupLink }, set: { changeHasGroupLink($0) }),
                                       onClickDescription: { copyGroupLink(groupLink ?? "") },
                                       descriptionLabel: i18n("icu:GroupLinkManagement__CopyGroupLinkButtonLabel"))
                }
                if hasGroupLink {
                    ConversationDetailsList {
                        AxoClickableItem.Root(symbol: "copy", label: i18n("icu:GroupLinkManagement--share")) {
                            if let groupLink { copyGroupLink(groupLink) }
                        } accessory: { EmptyView() }
                        AxoClickableItem.Root(symbol: "arrow-clockwise", label: i18n("icu:GroupLinkManagement--reset"), onClick: confirmReset) { EmptyView() }
                    }
                }
                if hasGroupLink && isAdmin {
                    ConversationDetailsList {
                        AxoSwitchItem.Root(label: i18n("icu:GroupLinkManagement--approve-label"), description: i18n("icu:GroupLinkManagement--approve-info"),
                                           checked: Binding(get: { addFromInviteLink == .administrator }, set: { setAccessControlAddFromInviteLinkSetting($0) }))
                    }
                }
            }
        }
    }
}
