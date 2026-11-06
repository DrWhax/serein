// Group changes: decryption of GroupChange.Actions (decryptGroupChange), their application to
// the stored state (applyGroupChange), and the timeline details a change produces
// (extractDiffs → `group-v2-change` messages with upstream's GroupV2ChangeDetail shape).

import Foundation
import LibSignalClient
import SignalProtos

/// `DecryptedGroupChangeActions`: the actions with every id, key and blob decrypted.
public struct DecryptedGroupActions: Sendable, Equatable {
    public struct AddMember: Sendable, Equatable { var aci: String; var role: Int; var profileKey: Data?; var joinFromInviteLink: Bool }
    public struct PromotePending: Sendable, Equatable { var aci: String; var pni: String?; var profileKey: Data }
    public struct AddPendingApproval: Sendable, Equatable { var aci: String; var timestamp: Int64; var profileKey: Data? }

    public var sourceServiceId: String?
    public var version: Int
    public var addMembers: [AddMember] = []
    public var deleteMembers: [String] = []
    public var modifyMemberRoles: [(aci: String, role: Int)] = []
    public var modifyMemberLabels: [(aci: String, emoji: String?, label: String?)] = []
    public var modifyMemberProfileKeys: [(aci: String, profileKey: Data)] = []
    public var addMembersPendingProfileKey: [GroupPendingMember] = []
    public var deleteMembersPendingProfileKey: [String] = []
    public var promoteMembersPendingProfileKey: [PromotePending] = []
    public var promoteMembersPendingPniAciProfileKey: [PromotePending] = []
    /// nil: unchanged; .some(nil): cleared.
    public var modifyTitle: String??
    public var modifyAvatar: String??
    public var modifyTimer: Int??
    public var modifyDescription: String??
    public var modifyAttributesAccess: Int?
    public var modifyMemberAccess: Int?
    public var modifyAddFromInviteLinkAccess: Int?
    public var modifyMemberLabelAccess: Int?
    public var addMembersPendingAdminApproval: [AddPendingApproval] = []
    public var deleteMembersPendingAdminApproval: [String] = []
    public var promoteMembersPendingAdminApproval: [(aci: String, role: Int)] = []
    public var modifyInviteLinkPassword: String??
    public var modifyAnnouncementsOnly: Bool?
    public var addMembersBanned: [GroupBannedMember] = []
    public var deleteMembersBanned: [String] = []
    public var terminate = false

    public static func == (a: Self, b: Self) -> Bool { a.version == b.version && a.sourceServiceId == b.sourceServiceId }
}

extension GroupCipher {
    /// A member submitted as a ProfileKeyCredentialPresentation (client-built adds/promotes).
    func idAndKey(presentation: Data) throws -> (aci: String, profileKey: Data) {
        let p = try ProfileKeyCredentialPresentation(contents: presentation)
        let aci = try decryptAci(try p.getUuidCiphertext().serialize())
        return (aci, try decryptProfileKey(try p.getProfileKeyCiphertext().serialize(), aci: aci))
    }

    func idAndKey(userId: Data, profileKey: Data, presentation: Data) throws -> (aci: String, profileKey: Data) {
        if !presentation.isEmpty { return try idAndKey(presentation: presentation) }
        let aci = try decryptAci(userId)
        return (aci, try decryptProfileKey(profileKey, aci: aci))
    }

    /// `decryptGroupChange`: undecryptable entries are dropped, as upstream does.
    public func decryptActions(_ a: Signalservice_GroupChange.Actions) throws -> DecryptedGroupActions {
        var d = DecryptedGroupActions(version: Int(a.version))
        if !a.sourceUserID.isEmpty { d.sourceServiceId = try? decryptServiceId(a.sourceUserID) }
        for add in a.addMembers where add.hasAdded {
            let m = add.added
            guard let (aci, key) = try? idAndKey(userId: m.userID, profileKey: m.profileKey, presentation: m.presentation) else { continue }
            d.addMembers.append(.init(aci: aci, role: GroupRole.isValid(m.role.rawValue) ? m.role.rawValue : GroupRole.default, profileKey: key,
                                      joinFromInviteLink: add.joinFromInviteLink))
        }
        d.deleteMembers = a.deleteMembers.compactMap { try? decryptAci($0.deletedUserID) }
        d.modifyMemberRoles = a.modifyMemberRoles.compactMap { m in
            guard let aci = try? decryptAci(m.userID), GroupRole.isValid(m.role.rawValue) else { return nil }
            return (aci, m.role.rawValue)
        }
        d.modifyMemberLabels = a.modifyMemberLabels.compactMap { m in
            guard let aci = try? decryptAci(m.userID) else { return nil }
            func text(_ b: Data) -> String? { b.isEmpty ? nil : (try? decryptBlob(b)).flatMap { String(data: $0, encoding: .utf8) } }
            return (aci, text(m.labelEmoji), text(m.labelString))
        }
        d.modifyMemberProfileKeys = a.modifyMemberProfileKeys.compactMap { m in
            try? idAndKey(userId: m.userID, profileKey: m.profileKey, presentation: m.presentation)
        }
        d.addMembersPendingProfileKey = a.addMembersPendingProfileKey.compactMap { p in p.hasAdded ? (try? decryptPending(p.added)) ?? nil : nil }
        d.deleteMembersPendingProfileKey = a.deleteMembersPendingProfileKey.compactMap { try? decryptServiceId($0.deletedUserID) }
        d.promoteMembersPendingProfileKey = a.promoteMembersPendingProfileKey.compactMap { m in
            guard let (aci, key) = try? idAndKey(userId: m.userID, profileKey: m.profileKey, presentation: m.presentation) else { return nil }
            return .init(aci: aci, pni: nil, profileKey: key)
        }
        d.promoteMembersPendingPniAciProfileKey = a.promoteMembersPendingPniAciProfileKey.compactMap { m in
            guard let aci = try? decryptAci(m.userID), let pni = try? decryptServiceId(m.pni), let key = try? decryptProfileKey(m.profileKey, aci: aci)
            else { return nil }
            return .init(aci: aci, pni: pni, profileKey: key)
        }
        if a.hasModifyTitle {
            if let b = try? decryptAttribute(a.modifyTitle.title), case .title(let t)? = b.content { d.modifyTitle = .some(t) } else { d.modifyTitle = .some(nil) }
        }
        if a.hasModifyAvatar { d.modifyAvatar = .some(a.modifyAvatar.avatar.isEmpty ? nil : a.modifyAvatar.avatar) }
        if a.hasModifyDisappearingMessageTimer {
            if let b = try? decryptAttribute(a.modifyDisappearingMessageTimer.timer), case .disappearingMessagesDuration(let s)? = b.content {
                d.modifyTimer = .some(s == 0 ? nil : Int(s))
            } else { d.modifyTimer = .some(nil) }
        }
        if a.hasModifyDescription {
            if let b = try? decryptAttribute(a.modifyDescription.description_p), case .descriptionText(let t)? = b.content {
                d.modifyDescription = .some(t)
            } else { d.modifyDescription = .some(nil) }
        }
        if a.hasModifyAttributesAccess { d.modifyAttributesAccess = a.modifyAttributesAccess.attributesAccess.rawValue }
        if a.hasModifyMemberAccess { d.modifyMemberAccess = a.modifyMemberAccess.membersAccess.rawValue }
        if a.hasModifyAddFromInviteLinkAccess { d.modifyAddFromInviteLinkAccess = a.modifyAddFromInviteLinkAccess.addFromInviteLinkAccess.rawValue }
        if a.hasModifyMemberLabelAccess { d.modifyMemberLabelAccess = a.modifyMemberLabelAccess.memberLabelAccess.rawValue }
        d.addMembersPendingAdminApproval = a.addMembersPendingAdminApproval.compactMap { p in
            guard p.hasAdded else { return nil }
            let m = p.added
            if !m.presentation.isEmpty, let (aci, key) = try? idAndKey(presentation: m.presentation) {
                return .init(aci: aci, timestamp: Int64(m.timestamp), profileKey: key)
            }
            guard let (approval, key) = (try? decryptPendingApproval(m)) ?? nil else { return nil }
            return .init(aci: approval.aci, timestamp: approval.timestamp, profileKey: key)
        }
        d.deleteMembersPendingAdminApproval = a.deleteMembersPendingAdminApproval.compactMap { try? decryptAci($0.deletedUserID) }
        d.promoteMembersPendingAdminApproval = a.promoteMembersPendingAdminApproval.compactMap { m in
            guard let aci = try? decryptAci(m.userID) else { return nil }
            return (aci, GroupRole.isValid(m.role.rawValue) ? m.role.rawValue : GroupRole.default)
        }
        if a.hasModifyInviteLinkPassword {
            d.modifyInviteLinkPassword = .some(a.modifyInviteLinkPassword.inviteLinkPassword.isEmpty ? nil : a.modifyInviteLinkPassword.inviteLinkPassword.base64EncodedString())
        }
        if a.hasModifyAnnouncementsOnly { d.modifyAnnouncementsOnly = a.modifyAnnouncementsOnly.announcementsOnly }
        d.addMembersBanned = a.addMembersBanned.compactMap { b in
            guard b.hasAdded, let id = try? decryptServiceId(b.added.userID) else { return nil }
            return GroupBannedMember(serviceId: id, timestamp: Int64(b.added.timestamp))
        }
        d.deleteMembersBanned = a.deleteMembersBanned.compactMap { try? decryptServiceId($0.deletedUserID) }
        d.terminate = a.hasTerminateGroup
        return d
    }
}

/// The result of applying one change.
public struct GroupChangeResult: Sendable {
    public var state: GroupV2State
    /// Profile keys learnt from the change (members' own keys).
    public var profileKeys: [String: Data]
    public var promotedAciToPni: [String: String]
}

public enum GroupChangeApply {
    /// `applyGroupChange`
    public static func apply(_ d: DecryptedGroupActions, to old: GroupV2State, ourAci: String,
                             hasProfileKey: (String) -> Bool = { _ in false }) -> GroupChangeResult {
        var s = old
        var keys: [String: Data] = [:]
        var promoted: [String: String] = [:]
        var members = Dictionary(old.membersV2.map { ($0.aci, $0) }, uniquingKeysWith: { a, _ in a })
        var order = old.membersV2.map(\.aci)
        var pending = Dictionary(old.pendingMembersV2.map { ($0.serviceId, $0) }, uniquingKeysWith: { a, _ in a })
        var pendingOrder = old.pendingMembersV2.map(\.serviceId)
        var approvals = Dictionary(old.pendingAdminApprovalV2.map { ($0.aci, $0) }, uniquingKeysWith: { a, _ in a })
        var approvalOrder = old.pendingAdminApprovalV2.map(\.aci)
        var banned = Dictionary(old.bannedMembersV2.map { ($0.serviceId, $0) }, uniquingKeysWith: { a, _ in a })
        var bannedOrder = old.bannedMembersV2.map(\.serviceId)
        func addMember(_ m: GroupMember) {
            if members[m.aci] == nil { order.append(m.aci) }
            members[m.aci] = m
        }
        let version = d.version
        s.revision = version
        for add in d.addMembers where members[add.aci] == nil {
            addMember(GroupMember(aci: add.aci, role: add.role, joinedAtVersion: version, joinedFromLink: add.joinFromInviteLink))
            pending[add.aci] = nil
            approvals[add.aci] = nil
            if let k = add.profileKey { keys[add.aci] = k }
        }
        for aci in d.deleteMembers { members[aci] = nil }
        for (aci, role) in d.modifyMemberRoles where members[aci] != nil { members[aci]!.role = role }
        for (aci, emoji, label) in d.modifyMemberLabels where members[aci] != nil {
            members[aci]!.labelEmoji = emoji
            members[aci]!.labelString = label
        }
        for (aci, key) in d.modifyMemberProfileKeys where aci == d.sourceServiceId || !hasProfileKey(aci) { keys[aci] = key }
        for p in d.addMembersPendingProfileKey where pending[p.serviceId] == nil && members[p.serviceId] == nil {
            pending[p.serviceId] = p
            pendingOrder.append(p.serviceId)
        }
        for id in d.deleteMembersPendingProfileKey { pending[id] = nil }
        for p in d.promoteMembersPendingProfileKey {
            guard let previous = pending.removeValue(forKey: p.aci), members[p.aci] == nil else { continue }
            addMember(GroupMember(aci: p.aci, role: previous.role, joinedAtVersion: version))
            keys[p.aci] = p.profileKey
        }
        for p in d.promoteMembersPendingPniAciProfileKey {
            let previous = p.pni.flatMap { pending.removeValue(forKey: $0) }
            if let pni = p.pni { promoted[p.aci] = pni }
            guard members[p.aci] == nil else { continue }
            addMember(GroupMember(aci: p.aci, role: previous?.role ?? GroupRole.default, joinedAtVersion: version))
            keys[p.aci] = p.profileKey
        }
        if let title = d.modifyTitle { s.name = title?.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let avatar = d.modifyAvatar { s.avatarUrl = avatar }
        if let timer = d.modifyTimer { s.expireTimer = timer }
        if let a = d.modifyAttributesAccess { s.accessControl.attributes = GroupAccess.isValid(a) ? a : GroupAccess.member }
        if let a = d.modifyMemberAccess { s.accessControl.members = GroupAccess.isValid(a) ? a : GroupAccess.member }
        if let a = d.modifyAddFromInviteLinkAccess { s.accessControl.addFromInviteLink = GroupAccess.isValidLink(a) ? a : GroupAccess.unsatisfiable }
        if let a = d.modifyMemberLabelAccess { s.accessControl.memberLabel = GroupAccess.isValid(a) ? a : GroupAccess.member }
        for p in d.addMembersPendingAdminApproval where members[p.aci] == nil && pending[p.aci] == nil && approvals[p.aci] == nil {
            approvals[p.aci] = GroupPendingAdminApproval(aci: p.aci, timestamp: p.timestamp)
            approvalOrder.append(p.aci)
            if let k = p.profileKey { keys[p.aci] = k }
        }
        for aci in d.deleteMembersPendingAdminApproval { approvals[aci] = nil }
        for (aci, role) in d.promoteMembersPendingAdminApproval {
            guard approvals.removeValue(forKey: aci) != nil, members[aci] == nil else { continue }
            addMember(GroupMember(aci: aci, role: role, joinedAtVersion: version, approvedByAdmin: true))
        }
        if let pw = d.modifyInviteLinkPassword { s.groupInviteLinkPassword = pw }
        if let text = d.modifyDescription { s.description = text?.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let a = d.modifyAnnouncementsOnly { s.announcementsOnly = a }
        if d.terminate { s.terminated = true }
        for b in d.addMembersBanned where banned[b.serviceId] == nil {
            banned[b.serviceId] = b
            bannedOrder.append(b.serviceId)
        }
        for id in d.deleteMembersBanned { banned[id] = nil }
        s.membersV2 = order.compactMap { members[$0] }.reduce(into: [GroupMember]()) { acc, m in if !acc.contains(where: { $0.aci == m.aci }) { acc.append(m) } }
        s.pendingMembersV2 = pendingOrder.compactMap { pending[$0] }.reduce(into: []) { acc, m in if !acc.contains(m) { acc.append(m) } }
        s.pendingAdminApprovalV2 = approvalOrder.compactMap { approvals[$0] }.reduce(into: []) { acc, m in if !acc.contains(m) { acc.append(m) } }
        s.bannedMembersV2 = bannedOrder.compactMap { banned[$0] }.reduce(into: []) { acc, m in if !acc.contains(m) { acc.append(m) } }
        return GroupChangeResult(state: s, profileKeys: keys, promotedAciToPni: promoted)
    }
}

/// `GroupV2ChangeDetailType` (the same JSON SignalUI's GroupChangeRenderer reads).
public struct GroupChangeDetail: Codable, Equatable, Sendable {
    public var type: String
    public var aci: String?
    public var pni: String?
    public var inviter: String?
    public var serviceId: String?
    public var newTitle: String?
    public var removed: Bool?
    public var newPrivilege: Int?
    public var privilege: Int?
    public var count: Int?
    public var description: String?
    public var announcementsOnly: Bool?

    public init(_ type: String) { self.type = type }
}

/// A timeline item a change produces (`GroupChangeMessageType`).
public struct GroupChangeMessage: Sendable, Equatable {
    public var from: String?
    public var details: [GroupChangeDetail]
    public var read: Bool
    /// The expire-timer notification (seconds; 0 = off), when the timer changed.
    public var timer: Int?
}

public enum GroupDiff {
    static func normalized(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty ?? true) ? nil : t
    }

    static func linkEnabled(_ a: Int?) -> Bool { a == GroupAccess.any || a == GroupAccess.administrator }

    /// `extractDiffs`. `old` is nil for the first update of a group we did not have.
    public static func extract(old: GroupV2State?, current: GroupV2State, ourAci: String, ourPni: String?, source: String?,
                               promotedAciToPni: [String: String] = [:], dropInitialJoinMessage: Bool = false) -> [GroupChangeMessage] {
        var details: [GroupChangeDetail] = []
        let o = old ?? GroupV2State()
        func isUs(_ id: String) -> Bool { id == ourAci || (ourPni != nil && id == ourPni) }
        if let old {
            if old.accessControl.attributes != current.accessControl.attributes {
                var d = GroupChangeDetail("access-attributes"); d.newPrivilege = current.accessControl.attributes; details.append(d)
            }
            if old.accessControl.members != current.accessControl.members {
                var d = GroupChangeDetail("access-members"); d.newPrivilege = current.accessControl.members; details.append(d)
            }
            if old.accessControl.memberLabel != GroupAccess.unknown, old.accessControl.memberLabel != current.accessControl.memberLabel {
                var d = GroupChangeDetail("access-member-label"); d.newPrivilege = current.accessControl.memberLabel; details.append(d)
            }
        }
        let wasLink = linkEnabled(old?.accessControl.addFromInviteLink), isLink = linkEnabled(current.accessControl.addFromInviteLink)
        if !wasLink && isLink {
            var d = GroupChangeDetail("group-link-add"); d.privilege = current.accessControl.addFromInviteLink; details.append(d)
        } else if wasLink && !isLink {
            details.append(GroupChangeDetail("group-link-remove"))
        } else if wasLink && isLink && o.accessControl.addFromInviteLink != current.accessControl.addFromInviteLink {
            var d = GroupChangeDetail("access-invite-link"); d.newPrivilege = current.accessControl.addFromInviteLink; details.append(d)
        }
        if o.avatarUrl != current.avatarUrl {
            var d = GroupChangeDetail("avatar"); d.removed = current.avatarUrl == nil; details.append(d)
        }
        if normalized(o.name) != normalized(current.name) {
            var d = GroupChangeDetail("title"); d.newTitle = normalized(current.name); details.append(d)
        }
        if let a = o.groupInviteLinkPassword, let b = current.groupInviteLinkPassword, a != b { details.append(GroupChangeDetail("group-link-reset")) }
        if normalized(o.description) != normalized(current.description) {
            var d = GroupChangeDetail("description"); d.removed = normalized(current.description) == nil; d.description = normalized(current.description)
            details.append(d)
        }
        var oldMembers = Dictionary(o.membersV2.map { ($0.aci, $0) }, uniquingKeysWith: { a, _ in a })
        let didWeStartInGroup = oldMembers[ourAci] != nil
        var oldPending = Dictionary(o.pendingMembersV2.map { ($0.serviceId, $0) }, uniquingKeysWith: { a, _ in a })
        var oldApprovals = Dictionary(o.pendingAdminApprovalV2.map { ($0.aci, $0) }, uniquingKeysWith: { a, _ in a })
        let currentPending = Set(current.pendingMembersV2.map(\.serviceId))
        var aciToPni = promotedAciToPni
        if let ourPni { aciToPni[ourAci] = ourPni }
        var areWeInGroup = false, areWePendingApproval = false
        var invitedKind: String? = nil, whoInvitedUs: String? = nil
        for m in current.membersV2 {
            if isUs(m.aci) { areWeInGroup = true }
            if let previous = oldMembers[m.aci] {
                if previous.role != m.role {
                    var d = GroupChangeDetail("member-privilege"); d.aci = m.aci; d.newPrivilege = m.role; details.append(d)
                }
            } else {
                var pendingMember = oldPending[m.aci]
                let pni = aciToPni[m.aci]
                if pendingMember == nil, let pni {
                    pendingMember = oldPending[pni]
                    if pendingMember != nil, !currentPending.contains(pni) { oldPending[pni] = nil }
                }
                var d: GroupChangeDetail
                if let pendingMember {
                    d = GroupChangeDetail("member-add-from-invite"); d.pni = pni; d.inviter = pendingMember.addedByUserId
                } else if m.joinedFromLink == true {
                    d = GroupChangeDetail("member-add-from-link")
                } else if m.approvedByAdmin == true {
                    d = GroupChangeDetail("member-add-from-admin-approval")
                } else {
                    d = GroupChangeDetail("member-add")
                }
                d.aci = m.aci
                details.append(d)
            }
            oldApprovals[m.aci] = nil
            oldPending[m.aci] = nil
            oldMembers[m.aci] = nil
        }
        for aci in o.membersV2.map(\.aci) where oldMembers[aci] != nil {
            var d = GroupChangeDetail("member-remove"); d.aci = aci; details.append(d)
        }
        var lastPending: String? = nil, pendingCount = 0
        for p in current.pendingMembersV2 {
            if isUs(p.serviceId) {
                if p.serviceId == ourAci { invitedKind = "aci" } else if invitedKind == nil { invitedKind = "pni" }
                whoInvitedUs = p.addedByUserId
            }
            if oldPending[p.serviceId] == nil, !(o.pendingMembersV2.contains { $0.serviceId == p.serviceId }) {
                lastPending = p.serviceId
                pendingCount += 1
            }
            oldPending[p.serviceId] = nil
        }
        if pendingCount > 1 {
            var d = GroupChangeDetail("pending-add-many"); d.count = pendingCount; details.append(d)
        } else if pendingCount == 1, let lastPending {
            var d = GroupChangeDetail("pending-add-one"); d.serviceId = lastPending; details.append(d)
        }
        let removedPending = o.pendingMembersV2.map(\.serviceId).filter { oldPending[$0] != nil }
        if removedPending.count > 1 {
            let inviter = oldPending[removedPending[0]]!.addedByUserId
            var d = GroupChangeDetail("pending-remove-many"); d.count = removedPending.count
            d.inviter = removedPending.allSatisfy { oldPending[$0]?.addedByUserId == inviter } ? inviter : nil
            details.append(d)
        } else if removedPending.count == 1 {
            var d = GroupChangeDetail("pending-remove-one"); d.serviceId = removedPending[0]; d.inviter = oldPending[removedPending[0]]!.addedByUserId
            details.append(d)
        }
        for p in current.pendingAdminApprovalV2 {
            if p.aci == ourAci { areWePendingApproval = true }
            if oldApprovals[p.aci] == nil, !(o.pendingAdminApprovalV2.contains { $0.aci == p.aci }) {
                var d = GroupChangeDetail("admin-approval-add-one"); d.aci = p.aci; details.append(d)
            }
            oldApprovals[p.aci] = nil
        }
        for aci in o.pendingAdminApprovalV2.map(\.aci) where oldApprovals[aci] != nil {
            var d = GroupChangeDetail("admin-approval-remove-one"); d.aci = aci; details.append(d)
        }
        if o.announcementsOnly != current.announcementsOnly {
            var d = GroupChangeDetail("announcements-only"); d.announcementsOnly = current.announcementsOnly; details.append(d)
        }
        if !o.terminated && current.terminated { details.append(GroupChangeDetail("terminated")) }

        let firstUpdate = old == nil
        let isFromUs = source == ourAci
        let justJoined = !firstUpdate && !didWeStartInGroup && areWeInGroup
        let from = source.flatMap { s in s.hasPrefix("PNI:") ? aciToPni.first { $0.value == s }?.key ?? s : s }
        func ourAdds() -> [GroupChangeDetail] {
            details.filter { ["member-add-from-invite", "member-add-from-link", "member-add-from-admin-approval", "member-add"].contains($0.type) && isUs($0.aci ?? "") }
        }
        var out: [GroupChangeMessage] = []
        if firstUpdate, let invitedKind {
            var d = GroupChangeDetail("pending-add-one")
            d.serviceId = invitedKind == "aci" ? ourAci : ourPni
            out.append(GroupChangeMessage(from: whoInvitedUs ?? from, details: [d], read: true))
        } else if firstUpdate && areWePendingApproval {
            var d = GroupChangeDetail("admin-approval-add-one"); d.aci = ourAci
            out.append(GroupChangeMessage(from: ourAci, details: [d], read: true))
        } else if firstUpdate && dropInitialJoinMessage {
        } else if firstUpdate && current.revision == 0 && source == ourAci {
            out.append(GroupChangeMessage(from: from, details: [GroupChangeDetail("create")], read: true))
        } else if firstUpdate && areWeInGroup {
            out.append(GroupChangeMessage(from: from, details: ourAdds(), read: true))
        } else if firstUpdate && current.revision == 0 {
            out.append(GroupChangeMessage(from: from, details: [GroupChangeDetail("create")], read: true))
        } else if justJoined {
            var adds = ourAdds()
            if details.count > 1 { adds.append(GroupChangeDetail("summary")) }
            out.append(GroupChangeMessage(from: from, details: adds, read: true))
        } else if !details.isEmpty {
            let unread = !isFromUs && details.contains { $0.type == "terminated" }
            out.append(GroupChangeMessage(from: from, details: details, read: !unread))
        }
        if (o.expireTimer ?? 0) != (current.expireTimer ?? 0) {
            out.append(GroupChangeMessage(from: from, details: [], read: true, timer: current.expireTimer ?? 0))
        }
        return out
    }
}
