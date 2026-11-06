// The GroupChange.Actions upstream builds (ts/groups.preload.ts build*Change), each for
// revision + 1 of the given state. Members enter with a ProfileKeyCredentialPresentation; one
// whose credential we cannot get is invited (pending profile key) instead.

import Foundation
import LibSignalClient
import SignalProtos

public typealias GroupActions = Signalservice_GroupChange.Actions

public struct GroupActionBuilder: Sendable {
    public let keys: GroupKeys
    public let state: GroupV2State
    public let ourAci: String
    let cipher: GroupCipher
    let serverPublicParams: Data
    /// The group size hard limit (`global.groupsv2.groupSizeHardLimit`), bounding the ban list.
    let hardLimit: Int

    public init(keys: GroupKeys, state: GroupV2State, ourAci: String, serverPublicParams: Data, hardLimit: Int = 1001) throws {
        self.keys = keys
        self.state = state
        self.ourAci = ourAci
        self.serverPublicParams = serverPublicParams
        self.hardLimit = hardLimit
        cipher = try GroupCipher(keys)
    }

    var nextVersion: UInt32 { UInt32(state.revision + 1) }

    func actions(_ fill: (inout GroupActions) throws -> Void) rethrows -> GroupActions {
        var a = GroupActions()
        a.version = nextVersion
        try fill(&a)
        return a
    }

    public func presentation(_ credential: ExpiringProfileKeyCredential) throws -> Data {
        try ClientZkProfileOperations(serverPublicParams: ServerPublicParams(contents: serverPublicParams))
            .createProfileKeyCredentialPresentation(groupSecretParams: keys.secret(), profileKeyCredential: credential).serialize()
    }

    func encrypt(_ serviceId: String) throws -> Data { try cipher.encryptServiceId(serviceId) }

    /// `buildAddMembersChange`: credentials by ACI (nil: invite as pending).
    public func addMembers(_ members: [(aci: String, credential: ExpiringProfileKeyCredential?)], now: Int64) throws -> GroupActions? {
        let fresh = members.filter { !state.isMember($0.aci) }
        guard !fresh.isEmpty else { return nil }
        return try actions { a in
            for (aci, credential) in fresh {
                var member = Signalservice_Member()
                member.role = .default
                member.joinedAtVersion = nextVersion
                if let credential {
                    member.presentation = try presentation(credential)
                    var add = GroupActions.AddMemberAction()
                    add.added = member
                    a.addMembers.append(add)
                } else {
                    member.userID = try encrypt(aci)
                    var pending = Signalservice_MemberPendingProfileKey()
                    pending.member = member
                    pending.addedByUserID = try encrypt(ourAci)
                    pending.timestamp = UInt64(now)
                    var add = GroupActions.AddMemberPendingProfileKeyAction()
                    add.added = pending
                    a.addMembersPendingProfileKey.append(add)
                }
                if state.isBanned(aci) {
                    var unban = GroupActions.DeleteMemberBannedAction()
                    unban.deletedUserID = try encrypt(aci)
                    a.deleteMembersBanned.append(unban)
                }
            }
        }
    }

    /// `buildUpdateAttributesChange` (nil: unchanged; an empty string clears).
    public func updateAttributes(title: String? = nil, description: String? = nil, avatarKey: String?? = nil) throws -> GroupActions? {
        guard title != nil || description != nil || avatarKey != nil else { return nil }
        return try actions { a in
            if let title {
                var t = GroupActions.ModifyTitleAction()
                t.title = try cipher.encryptTitle(title)
                a.modifyTitle = t
            }
            if let description {
                var d = GroupActions.ModifyDescriptionAction()
                d.description_p = try cipher.encryptDescription(description)
                a.modifyDescription = d
            }
            if let avatarKey {
                var m = GroupActions.ModifyAvatarAction()
                m.avatar = avatarKey ?? ""
                a.modifyAvatar = m
            }
        }
    }

    /// `buildDisappearingMessagesTimerChange` (seconds; 0 turns it off).
    public func disappearingMessagesTimer(_ seconds: Int) throws -> GroupActions {
        try actions { a in
            var t = GroupActions.ModifyDisappearingMessageTimerAction()
            t.timer = try cipher.encryptTimer(seconds)
            a.modifyDisappearingMessageTimer = t
        }
    }

    /// `generateGroupInviteLinkPassword`
    public static func newInviteLinkPassword() -> Data { SignalCrypto.randomBytes(16) }

    /// `buildInviteLinkPasswordChange` (reset the link).
    public func inviteLinkPassword(_ password: Data) -> GroupActions {
        actions { a in
            var p = GroupActions.ModifyInviteLinkPasswordAction()
            p.inviteLinkPassword = password
            a.modifyInviteLinkPassword = p
        }
    }

    /// `buildNewGroupLinkChange`: a password and link access (ANY, or ADMINISTRATOR for approval).
    public func newGroupLink(password: Data, access: Int) -> GroupActions {
        actions { a in
            var p = GroupActions.ModifyInviteLinkPasswordAction()
            p.inviteLinkPassword = password
            a.modifyInviteLinkPassword = p
            var l = GroupActions.ModifyAddFromInviteLinkAccessControlAction()
            l.addFromInviteLinkAccess = .init(rawValue: access) ?? .unsatisfiable
            a.modifyAddFromInviteLinkAccess = l
        }
    }

    /// `buildAccessControlAddFromInviteLinkChange` (UNSATISFIABLE turns the link off).
    public func addFromInviteLinkAccess(_ access: Int) -> GroupActions {
        actions { a in
            var l = GroupActions.ModifyAddFromInviteLinkAccessControlAction()
            l.addFromInviteLinkAccess = .init(rawValue: access) ?? .unsatisfiable
            a.modifyAddFromInviteLinkAccess = l
        }
    }

    public func announcementsOnly(_ on: Bool) -> GroupActions {
        actions { a in
            var m = GroupActions.ModifyAnnouncementsOnlyAction()
            m.announcementsOnly = on
            a.modifyAnnouncementsOnly = m
        }
    }

    public func attributesAccess(_ access: Int) -> GroupActions {
        actions { a in
            var m = GroupActions.ModifyAttributesAccessControlAction()
            m.attributesAccess = .init(rawValue: access) ?? .member
            a.modifyAttributesAccess = m
        }
    }

    public func membersAccess(_ access: Int) -> GroupActions {
        actions { a in
            var m = GroupActions.ModifyMembersAccessControlAction()
            m.membersAccess = .init(rawValue: access) ?? .member
            a.modifyMemberAccess = m
        }
    }

    public func memberLabelAccess(_ access: Int) -> GroupActions {
        actions { a in
            var m = GroupActions.ModifyMemberLabelAccessControlAction()
            m.memberLabelAccess = .init(rawValue: access) ?? .member
            a.modifyMemberLabelAccess = m
        }
    }

    /// `buildModifyMemberProfileKeyChange`: our new profile key, as a presentation.
    public func modifyOurProfileKey(_ credential: ExpiringProfileKeyCredential) throws -> GroupActions {
        try actions { a in
            var m = GroupActions.ModifyMemberProfileKeyAction()
            m.presentation = try presentation(credential)
            a.modifyMemberProfileKeys.append(m)
        }
    }

    /// `_maybeBuildAddBannedMemberActions`: ban, dropping the oldest bans past the hard limit.
    func banActions(_ serviceId: String, into a: inout GroupActions) throws {
        guard !state.isBanned(serviceId), serviceId != ourAci else { return }
        let sorted = state.bannedMembersV2.sorted { $0.timestamp > $1.timestamp }
        for old in sorted.dropFirst(max(0, hardLimit - 1)) {
            var d = GroupActions.DeleteMemberBannedAction()
            d.deletedUserID = try encrypt(old.serviceId)
            a.deleteMembersBanned.append(d)
        }
        var add = GroupActions.AddMemberBannedAction()
        var banned = Signalservice_MemberBanned()
        banned.userID = try encrypt(serviceId)
        add.added = banned
        a.addMembersBanned.append(add)
    }

    /// `buildDeletePendingAdminApprovalMemberChange`: deny a request (and ban, as upstream does
    /// unless the requester is cancelling their own request).
    public func denyRequest(_ aci: String) throws -> GroupActions {
        try actions { a in
            var d = GroupActions.DeleteMemberPendingAdminApprovalAction()
            d.deletedUserID = try encrypt(aci)
            a.deleteMembersPendingAdminApproval.append(d)
            if aci != ourAci { try banActions(aci, into: &a) }
        }
    }

    /// `buildAddPendingAdminApprovalMemberChange`: ask to join through a link.
    public func requestToJoin(_ credential: ExpiringProfileKeyCredential) throws -> GroupActions {
        try actions { a in
            var p = Signalservice_MemberPendingAdminApproval()
            p.presentation = try presentation(credential)
            var add = GroupActions.AddMemberPendingAdminApprovalAction()
            add.added = p
            a.addMembersPendingAdminApproval.append(add)
        }
    }

    /// `buildAddMember`: join through a link that needs no approval.
    public func joinFromLink(_ credential: ExpiringProfileKeyCredential) throws -> GroupActions {
        try actions { a in
            var member = Signalservice_Member()
            member.role = .default
            member.presentation = try presentation(credential)
            var add = GroupActions.AddMemberAction()
            add.added = member
            add.joinFromInviteLink = true
            a.addMembers.append(add)
        }
    }

    /// `buildDeletePendingMemberChange`: revoke invites, or decline ours.
    public func deletePending(_ serviceIds: [String]) throws -> GroupActions {
        try actions { a in
            for id in serviceIds {
                var d = GroupActions.DeleteMemberPendingProfileKeyAction()
                d.deletedUserID = try encrypt(id)
                a.deleteMembersPendingProfileKey.append(d)
            }
        }
    }

    /// `buildDeleteMemberChange`: remove a member (banned unless it is us leaving).
    public func deleteMember(_ aci: String) throws -> GroupActions {
        try actions { a in
            var d = GroupActions.DeleteMemberAction()
            d.deletedUserID = try encrypt(aci)
            a.deleteMembers.append(d)
            if aci != ourAci { try banActions(aci, into: &a) }
        }
    }

    /// `buildAddBannedMemberChange`: ban someone who is not a member (also dropping a request or
    /// an invite they have).
    public func ban(_ serviceId: String) throws -> GroupActions {
        try actions { a in
            try banActions(serviceId, into: &a)
            if state.isPendingApproval(serviceId) {
                var d = GroupActions.DeleteMemberPendingAdminApprovalAction()
                d.deletedUserID = try encrypt(serviceId)
                a.deleteMembersPendingAdminApproval.append(d)
            } else if state.isPending(serviceId) {
                var d = GroupActions.DeleteMemberPendingProfileKeyAction()
                d.deletedUserID = try encrypt(serviceId)
                a.deleteMembersPendingProfileKey.append(d)
            }
        }
    }

    public func unban(_ serviceId: String) throws -> GroupActions {
        try actions { a in
            var d = GroupActions.DeleteMemberBannedAction()
            d.deletedUserID = try encrypt(serviceId)
            a.deleteMembersBanned.append(d)
        }
    }

    /// `buildModifyMemberRoleChange`
    public func modifyRole(_ aci: String, role: Int) throws -> GroupActions {
        try actions { a in
            var m = GroupActions.ModifyMemberRoleAction()
            m.userID = try encrypt(aci)
            m.role = .init(rawValue: role) ?? .default
            a.modifyMemberRoles.append(m)
        }
    }

    /// `buildModifyMemberLabelChange` (nil clears).
    public func modifyLabel(_ aci: String, emoji: String?, label: String?) throws -> GroupActions {
        try actions { a in
            var m = GroupActions.ModifyMemberLabelAction()
            m.userID = try encrypt(aci)
            if let emoji, !emoji.isEmpty { m.labelEmoji = try cipher.encryptBlob(Data(emoji.utf8)) }
            if let label, !label.isEmpty { m.labelString = try cipher.encryptBlob(Data(label.utf8)) }
            a.modifyMemberLabels.append(m)
        }
    }

    /// `buildPromotePendingAdminApprovalMemberChange`: approve a request.
    public func approveRequest(_ aci: String) throws -> GroupActions {
        try actions { a in
            var m = GroupActions.PromoteMemberPendingAdminApprovalAction()
            m.userID = try encrypt(aci)
            m.role = .default
            a.promoteMembersPendingAdminApproval.append(m)
        }
    }

    /// `buildPromoteMemberChange`: accept our invite (to our ACI, or to our PNI).
    public func acceptInvite(_ credential: ExpiringProfileKeyCredential, invitedPni: String?) throws -> GroupActions {
        try actions { a in
            let p = try presentation(credential)
            if invitedPni != nil {
                var m = GroupActions.PromoteMemberPendingPniAciProfileKeyAction()
                m.presentation = p
                a.promoteMembersPendingPniAciProfileKey.append(m)
            } else {
                var m = GroupActions.PromoteMemberPendingProfileKeyAction()
                m.presentation = p
                a.promoteMembersPendingProfileKey.append(m)
            }
        }
    }

    /// `buildTerminateChange`
    public func terminate() -> GroupActions {
        actions { a in a.terminateGroup = GroupActions.TerminateGroupAction() }
    }

    /// `buildGroupProto` for `createGroupV2`: revision 0, us as the administrator.
    public static func newGroup(keys: GroupKeys, title: String, description: String?, avatarKey: String?, expireTimer: Int?,
                                creator: Data, members: [(aci: String, presentation: Data?)], ourAci: String, now: Int64) throws -> Signalservice_Group {
        let cipher = try GroupCipher(keys)
        var g = Signalservice_Group()
        g.publicKey = keys.publicParams
        g.version = 0
        g.title = try cipher.encryptTitle(title)
        if let description, !description.isEmpty { g.description_p = try cipher.encryptDescription(description) }
        if let avatarKey { g.avatarURL = avatarKey }
        if let expireTimer, expireTimer > 0 { g.disappearingMessagesTimer = try cipher.encryptTimer(expireTimer) }
        var ac = Signalservice_AccessControl()
        ac.attributes = .member
        ac.members = .member
        ac.addFromInviteLink = .unsatisfiable
        ac.memberLabel = .member
        g.accessControl = ac
        var us = Signalservice_Member()
        us.role = .administrator
        us.presentation = creator
        us.joinedAtVersion = 0
        g.members = [us]
        let ourCiphertext = try cipher.encryptServiceId(ourAci)
        for (aci, presentation) in members where aci != ourAci {
            var m = Signalservice_Member()
            m.role = .default
            m.joinedAtVersion = 0
            if let presentation {
                m.presentation = presentation
                g.members.append(m)
            } else {
                m.userID = try cipher.encryptServiceId(aci)
                var p = Signalservice_MemberPendingProfileKey()
                p.member = m
                p.addedByUserID = ourCiphertext
                p.timestamp = UInt64(now)
                g.membersPendingProfileKey.append(p)
            }
        }
        return g
    }
}
