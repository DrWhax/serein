// Port of ts/components/conversation/conversation-details/PendingInvites.dom.tsx: Requests /
// Invites tabs. Requests lists people asking to join via the group link (deny / approve);
// Invites lists those invited by you (revoke each) and, grouped by inviter, those invited by
// others (revoke all of an inviter's). Every action confirms first.

import SignalI18n
import SwiftUI

public struct PendingMember: Identifiable {
    public var id: String
    public var avatar: ConversationAvatarData
    public init(id: String, avatar: ConversationAvatarData) {
        self.id = id
        self.avatar = avatar
    }
}

public struct PendingInvites: View {
    public enum StageType: Sendable { case approveRequest, denyRequest, revokeInvite }

    let groupTitle: String
    let areWeAdmin: Bool
    /// `isAccessControlEnabled(accessControlAddFromInviteLink)`
    let groupLinkEnabled: Bool
    let pendingApprovalMemberships: [PendingMember]
    let invitedByUs: [PendingMember]
    /// Invitees grouped by who invited them.
    let invitedByOthers: [(inviter: PendingMember, invitees: [PendingMember])]
    let approvePendingMembership: (String) -> Void
    let revokePendingMemberships: ([String]) -> Void
    @State private var tab = "requests"
    /// Banned members (not in upstream Desktop, which shows bans only as group changes): shown
    /// under the requests, with Unban for admins. Set with `banned(_:unban:)`.
    var bannedMembers: [PendingMember] = []
    var unban: (String) -> Void = { _ in }
    @Environment(\.i18n) var i18n
    @Environment(\.axoModalStack) var modals

    public init(groupTitle: String, areWeAdmin: Bool, groupLinkEnabled: Bool = false, pendingApprovalMemberships: [PendingMember],
                invitedByUs: [PendingMember], invitedByOthers: [(inviter: PendingMember, invitees: [PendingMember])],
                approvePendingMembership: @escaping (String) -> Void = { _ in }, revokePendingMemberships: @escaping ([String]) -> Void = { _ in }) {
        self.groupTitle = groupTitle
        self.areWeAdmin = areWeAdmin
        self.groupLinkEnabled = groupLinkEnabled
        self.pendingApprovalMemberships = pendingApprovalMemberships
        self.invitedByUs = invitedByUs
        self.invitedByOthers = invitedByOthers
        self.approvePendingMembership = approvePendingMembership
        self.revokePendingMemberships = revokePendingMemberships
    }

    var inviteCount: Int { invitedByUs.count + invitedByOthers.reduce(0) { $0 + $1.invitees.count } }

    /// `MembershipActionConfirmation` with `getConfirmationMessage`.
    func stage(_ type: StageType, _ members: [PendingMember], inviter: PendingMember? = nil) {
        guard let modals, let first = members.first else { return }
        let name = ["name": I18nArgument.string(first.avatar.title)]
        let message: String
        let actionText: String
        switch type {
        case .denyRequest:
            message = i18n(groupLinkEnabled ? "icu:PendingRequests--deny-for--with-link" : "icu:PendingRequests--deny-for", name)
            actionText = i18n("icu:PendingRequests--deny")
        case .approveRequest:
            message = i18n("icu:PendingRequests--approve-for", name)
            actionText = i18n("icu:PendingRequests--approve")
        case .revokeInvite:
            if let inviter {
                message = i18n("icu:PendingInvites--revoke-from", ["number": .number(Double(members.count)), "name": .string(inviter.avatar.title)])
            } else {
                message = i18n("icu:PendingInvites--revoke-for", name)
            }
            actionText = i18n("icu:PendingInvites--revoke")
        }
        let id = "pending-invites-confirm"
        modals.present(id: id) {
            AxoConfirmDialog.Root(title: nil, description: message) {
                AxoConfirmDialog.Cancel(i18n("icu:cancel")) { modals.dismiss(id: id) }
                AxoConfirmDialog.Action(actionText, variant: .strongPrimary) {
                    modals.dismiss(id: id)
                    if type == .approveRequest { approvePendingMembership(first.id) } else { revokePendingMemberships(members.map(\.id)) }
                }
            }
        }
    }

    func row<Trailing: View>(_ m: PendingMember, value: String? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        AxoItem.Root {
            AxoItem.Leading { ListAvatar(data: m.avatar, size: 32) }
            AxoItem.Content {
                AxoItem.Label(m.avatar.title)
                if let value { AxoItem.Value(value) }
                AxoItem.Trailing { trailing() }
            }
        }
    }

    var requests: some View {
        AxoList.Group {
            if !pendingApprovalMemberships.isEmpty {
                AxoList.Root {
                    AxoList.Body {
                        AxoItem.Group {
                            ForEach(pendingApprovalMemberships) { m in
                                row(m) {
                                    AxoItem.IconAction(label: i18n("icu:delete"), variant: .subtleDestructive, symbol: "x") { stage(.denyRequest, [m]) }
                                    AxoItem.IconAction(label: i18n("icu:accept"), variant: .subtleAffirmative, symbol: "check") { stage(.approveRequest, [m]) }
                                }
                            }
                        }
                    }
                    AxoList.Footer { AxoList.FooterDescription(i18n("icu:PendingRequests--info", ["name": .string(groupTitle)])) }
                }
            }
        }
    }

    /// The banned members, with Unban (admins); hidden when there are none.
    public func banned(_ members: [PendingMember], unban: @escaping (String) -> Void) -> PendingInvites {
        var c = self
        c.bannedMembers = members
        c.unban = unban
        return c
    }

    @ViewBuilder var bannedList: some View {
        if !bannedMembers.isEmpty {
            ConversationDetailsList(label: "Banned") {
                ForEach(bannedMembers) { m in
                    row(m) {
                        if areWeAdmin {
                            AxoItem.IconAction(label: "Unban \(m.avatar.title)", variant: .subtleDestructive, symbol: "x") { unban(m.id) }
                        }
                    }
                }
            }
        }
    }

    var invites: some View {
        AxoList.Group {
            if !invitedByUs.isEmpty {
                ConversationDetailsList(label: i18n("icu:PendingInvites--invited-by-you")) {
                    ForEach(invitedByUs) { m in
                        row(m) {
                            if areWeAdmin {
                                AxoItem.IconAction(label: i18n("icu:PendingInvites--revoke-for-label"), variant: .subtleDestructive, symbol: "trash") {
                                    stage(.revokeInvite, [m])
                                }
                            }
                        }
                    }
                }
            }
            if !invitedByOthers.isEmpty {
                AxoList.Root {
                    AxoList.Header { AxoList.Label(i18n("icu:PendingInvites--invited-by-others")) }
                    AxoList.Body {
                        AxoItem.Group {
                            ForEach(invitedByOthers, id: \.inviter.id) { entry in
                                row(entry.inviter, value: i18n("icu:PendingInvites--invited-count", ["number": .number(Double(entry.invitees.count))])) {
                                    if areWeAdmin {
                                        AxoItem.IconAction(label: i18n("icu:PendingInvites--revoke-for-label"), variant: .subtleDestructive, symbol: "trash") {
                                            stage(.revokeInvite, entry.invitees, inviter: entry.inviter)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    AxoList.Footer { AxoList.FooterDescription(i18n("icu:PendingInvites--info")) }
                }
            }
        }
    }

    public var body: some View {
        AxoContainer.Root {
            AxoTabs.Root(value: $tab) {
                AxoTabs.List {
                    AxoTabs.Trigger(value: "requests", i18n("icu:PendingInvites--tab-requests", ["count": .number(Double(pendingApprovalMemberships.count))]))
                    AxoTabs.Trigger(value: "pending", i18n("icu:PendingInvites--tab-invites", ["count": .number(Double(inviteCount))]))
                }
                AxoTabs.Content(value: "requests") {
                    VStack(spacing: 0) {
                        requests
                        bannedList
                    }
                    .padding(.top, 14)
                }
                AxoTabs.Content(value: "pending") { invites.padding(.top, 6) }
            }
        }
    }
}
