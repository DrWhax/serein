// Groups v2 state as upstream keeps it on the conversation (ts/model-types.d.ts group
// attributes: membersV2, pendingMembersV2, pendingAdminApprovalV2, bannedMembersV2, accessControl,
// revision, …) and its decryption from the server's Group proto (decryptGroupState,
// decryptMember, decryptMemberPendingProfileKey, decryptMemberPendingAdminApproval).

import Foundation
import LibSignalClient
import SignalProtos

/// The keys of one group (`deriveGroupFields`).
public struct GroupKeys: Sendable, Equatable {
    public let masterKey: Data
    public let secretParams: Data
    public let publicParams: Data
    public let groupId: Data

    public init(masterKey: Data) throws {
        let secret = try GroupSecretParams.deriveFromMasterKey(groupMasterKey: GroupMasterKey(contents: masterKey))
        self.masterKey = masterKey
        secretParams = secret.serialize()
        let pub = try secret.getPublicParams()
        publicParams = pub.serialize()
        groupId = try pub.getGroupIdentifier().serialize()
    }

    /// A fresh group (`createGroupV2`).
    public static func generate() throws -> GroupKeys {
        try GroupKeys(masterKey: GroupSecretParams.generate().getMasterKey().serialize())
    }

    public func secret() throws -> GroupSecretParams { try GroupSecretParams(contents: secretParams) }
    public func cipher() throws -> ClientZkGroupCipher { ClientZkGroupCipher(groupSecretParams: try secret()) }
    public var groupIdBase64: String { groupId.base64EncodedString() }
}

/// Member.Role
public enum GroupRole {
    public static let `default` = 1
    public static let administrator = 2
    static func isValid(_ r: Int) -> Bool { r == 1 || r == 2 }
}

/// AccessControl.AccessRequired
public enum GroupAccess {
    public static let unknown = 0, any = 1, member = 2, administrator = 3, unsatisfiable = 4
    /// `isValidAccess`: members and attributes take MEMBER or ADMINISTRATOR.
    static func isValid(_ a: Int) -> Bool { a == member || a == administrator }
    /// `isValidLinkAccess`: ANY, ADMINISTRATOR or UNSATISFIABLE.
    static func isValidLink(_ a: Int) -> Bool { a == any || a == administrator || a == unsatisfiable }
}

public struct GroupMember: Codable, Equatable, Sendable {
    public var aci: String
    public var role: Int
    public var joinedAtVersion: Int
    public var labelEmoji: String?
    public var labelString: String?
    /// Set by a change that added the member (`applyGroupChange`), read by `extractDiffs`.
    public var joinedFromLink: Bool?
    public var approvedByAdmin: Bool?
}

public struct GroupPendingMember: Codable, Equatable, Sendable {
    public var serviceId: String
    public var addedByUserId: String
    public var timestamp: Int64
    public var role: Int
}

public struct GroupPendingAdminApproval: Codable, Equatable, Sendable {
    public var aci: String
    public var timestamp: Int64
}

public struct GroupBannedMember: Codable, Equatable, Sendable {
    public var serviceId: String
    public var timestamp: Int64
}

public struct GroupAccessControl: Codable, Equatable, Sendable {
    public var attributes: Int
    public var members: Int
    public var addFromInviteLink: Int
    public var memberLabel: Int

    public init(attributes: Int, members: Int, addFromInviteLink: Int, memberLabel: Int) {
        self.attributes = attributes
        self.members = members
        self.addFromInviteLink = addFromInviteLink
        self.memberLabel = memberLabel
    }

    enum CodingKeys: String, CodingKey { case attributes, members, addFromInviteLink, memberLabel }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attributes = try c.decodeIfPresent(Int.self, forKey: .attributes) ?? GroupAccess.member
        members = try c.decodeIfPresent(Int.self, forKey: .members) ?? GroupAccess.member
        addFromInviteLink = try c.decodeIfPresent(Int.self, forKey: .addFromInviteLink) ?? GroupAccess.unsatisfiable
        memberLabel = try c.decodeIfPresent(Int.self, forKey: .memberLabel) ?? GroupAccess.member
    }
}

/// The decrypted group, in the conversation attribute names upstream stores.
public struct GroupV2State: Codable, Equatable, Sendable {
    public var revision: Int = 0
    public var name: String?
    public var description: String?
    public var avatarUrl: String?
    /// Seconds (`expireTimer`).
    public var expireTimer: Int?
    public var accessControl = GroupAccessControl(attributes: GroupAccess.member, members: GroupAccess.member,
                                                  addFromInviteLink: GroupAccess.unsatisfiable, memberLabel: GroupAccess.member)
    public var membersV2: [GroupMember] = []
    public var pendingMembersV2: [GroupPendingMember] = []
    public var pendingAdminApprovalV2: [GroupPendingAdminApproval] = []
    public var bannedMembersV2: [GroupBannedMember] = []
    /// Base64.
    public var groupInviteLinkPassword: String?
    public var announcementsOnly = false
    public var terminated = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case revision, name, description, avatarUrl, expireTimer, accessControl, membersV2, pendingMembersV2, pendingAdminApprovalV2,
             bannedMembersV2, groupInviteLinkPassword, announcementsOnly, terminated
    }

    /// Missing keys take their defaults (upstream leaves unset attributes out).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        expireTimer = try c.decodeIfPresent(Int.self, forKey: .expireTimer)
        if let ac = try c.decodeIfPresent(GroupAccessControl.self, forKey: .accessControl) { accessControl = ac }
        membersV2 = try c.decodeIfPresent([GroupMember].self, forKey: .membersV2) ?? []
        pendingMembersV2 = try c.decodeIfPresent([GroupPendingMember].self, forKey: .pendingMembersV2) ?? []
        pendingAdminApprovalV2 = try c.decodeIfPresent([GroupPendingAdminApproval].self, forKey: .pendingAdminApprovalV2) ?? []
        bannedMembersV2 = try c.decodeIfPresent([GroupBannedMember].self, forKey: .bannedMembersV2) ?? []
        groupInviteLinkPassword = try c.decodeIfPresent(String.self, forKey: .groupInviteLinkPassword)
        announcementsOnly = try c.decodeIfPresent(Bool.self, forKey: .announcementsOnly) ?? false
        terminated = try c.decodeIfPresent(Bool.self, forKey: .terminated) ?? false
    }

    public func member(_ aci: String) -> GroupMember? { membersV2.first { $0.aci == aci } }
    public func isMember(_ aci: String) -> Bool { member(aci) != nil }
    public func isAdmin(_ aci: String) -> Bool { member(aci)?.role == GroupRole.administrator }
    public func isPending(_ serviceId: String) -> Bool { pendingMembersV2.contains { $0.serviceId == serviceId } }
    public func isPendingApproval(_ aci: String) -> Bool { pendingAdminApprovalV2.contains { $0.aci == aci } }
    public func isBanned(_ serviceId: String) -> Bool { bannedMembersV2.contains { $0.serviceId == serviceId } }
}

public enum GroupDecryptError: Error, Equatable {
    case invalid(String)
}

/// Decryption helpers over ClientZkGroupCipher (ts/util/zkgroup.node.ts).
public struct GroupCipher: Sendable {
    let keys: GroupKeys
    public init(_ keys: GroupKeys) throws {
        self.keys = keys
        _ = try keys.secret()
    }

    func zk() throws -> ClientZkGroupCipher { try keys.cipher() }

    /// A service id string as upstream writes them: ACIs bare, PNIs "PNI:…".
    static func string(_ s: ServiceId) -> String {
        if s is Aci { return s.serviceIdString.lowercased() }
        return s.serviceIdString.uppercased().hasPrefix("PNI:") ? "PNI:" + s.serviceIdString.dropFirst(4).lowercased() : s.serviceIdString
    }

    public func decryptServiceId(_ ciphertext: Data) throws -> String { Self.string(try zk().decrypt(UuidCiphertext(contents: ciphertext))) }

    public func decryptAci(_ ciphertext: Data) throws -> String {
        let s = try zk().decrypt(UuidCiphertext(contents: ciphertext))
        guard s is Aci else { throw GroupDecryptError.invalid("userId is not an ACI") }
        return Self.string(s)
    }

    public func encryptServiceId(_ serviceId: String) throws -> Data { try zk().encrypt(ServiceId.parseFrom(serviceIdString: serviceId)).serialize() }

    public func decryptProfileKey(_ ciphertext: Data, aci: String) throws -> Data {
        try zk().decryptProfileKey(profileKeyCiphertext: ProfileKeyCiphertext(contents: ciphertext), userId: Aci.parseFrom(serviceIdString: aci)).serialize()
    }

    public func decryptBlob(_ ciphertext: Data) throws -> Data { try zk().decryptBlob(blobCiphertext: ciphertext) }
    public func encryptBlob(_ plaintext: Data) throws -> Data { try zk().encryptBlob(plaintext: plaintext) }

    /// GroupAttributeBlob helpers (title, description, timer).
    public func decryptAttribute(_ ciphertext: Data) throws -> Signalservice_GroupAttributeBlob {
        try Signalservice_GroupAttributeBlob(serializedBytes: decryptBlob(ciphertext))
    }

    public func encryptAttribute(_ blob: Signalservice_GroupAttributeBlob) throws -> Data { try encryptBlob(blob.serializedData()) }

    public func encryptTitle(_ title: String) throws -> Data {
        var b = Signalservice_GroupAttributeBlob()
        b.title = title
        return try encryptAttribute(b)
    }

    public func encryptDescription(_ text: String) throws -> Data {
        var b = Signalservice_GroupAttributeBlob()
        b.descriptionText = text
        return try encryptAttribute(b)
    }

    public func encryptTimer(_ seconds: Int) throws -> Data {
        var b = Signalservice_GroupAttributeBlob()
        b.disappearingMessagesDuration = UInt32(seconds)
        return try encryptAttribute(b)
    }

    // MARK: members

    /// `decryptMember`: nil if the user id is undecryptable; throws on invalid profile key/role.
    public func decryptMember(_ m: Signalservice_Member) throws -> (GroupMember, profileKey: Data)? {
        guard !m.userID.isEmpty else { throw GroupDecryptError.invalid("member without userId") }
        guard let aci = try? decryptAci(m.userID) else { return nil }
        guard !m.profileKey.isEmpty else { throw GroupDecryptError.invalid("member without profileKey") }
        let profileKey = try decryptProfileKey(m.profileKey, aci: aci)
        guard profileKey.count == 32 else { throw GroupDecryptError.invalid("invalid profile key") }
        guard GroupRole.isValid(m.role.rawValue) else { throw GroupDecryptError.invalid("invalid role \(m.role.rawValue)") }
        let emoji = m.labelEmoji.isEmpty ? nil : (try? decryptBlob(m.labelEmoji)).flatMap { String(data: $0, encoding: .utf8) }
        let label = m.labelString.isEmpty ? nil : (try? decryptBlob(m.labelString)).flatMap { String(data: $0, encoding: .utf8) }
        return (GroupMember(aci: aci, role: m.role.rawValue, joinedAtVersion: Int(m.joinedAtVersion), labelEmoji: emoji, labelString: label,
                            joinedFromLink: nil, approvedByAdmin: nil), profileKey)
    }

    public func decryptPending(_ p: Signalservice_MemberPendingProfileKey) throws -> GroupPendingMember? {
        guard !p.addedByUserID.isEmpty else { throw GroupDecryptError.invalid("pending member without addedByUserId") }
        guard let addedBy = try? decryptAci(p.addedByUserID), p.hasMember else { return nil }
        guard p.member.profileKey.isEmpty else { throw GroupDecryptError.invalid("pending member has a profile key") }
        guard !p.member.userID.isEmpty else { throw GroupDecryptError.invalid("pending member without userId") }
        guard let serviceId = try? decryptServiceId(p.member.userID) else { return nil }
        guard GroupRole.isValid(p.member.role.rawValue) else { throw GroupDecryptError.invalid("invalid role") }
        return GroupPendingMember(serviceId: serviceId, addedByUserId: addedBy, timestamp: Int64(p.timestamp), role: p.member.role.rawValue)
    }

    public func decryptPendingApproval(_ p: Signalservice_MemberPendingAdminApproval) throws -> (GroupPendingAdminApproval, profileKey: Data?)? {
        guard !p.userID.isEmpty else { throw GroupDecryptError.invalid("pending approval without userId") }
        guard let aci = try? decryptAci(p.userID) else { return nil }
        var key: Data? = nil
        if !p.profileKey.isEmpty, let k = try? decryptProfileKey(p.profileKey, aci: aci), k.count == 32 { key = k }
        return (GroupPendingAdminApproval(aci: aci, timestamp: Int64(p.timestamp)), key)
    }

    /// `decryptGroupState` into the stored shape; profile keys of members and requesters
    /// come back alongside (upstream applies them to the contacts).
    public func decryptState(_ g: Signalservice_Group) throws -> (GroupV2State, profileKeys: [String: Data]) {
        var s = GroupV2State()
        var keys: [String: Data] = [:]
        if !g.title.isEmpty, let b = try? decryptAttribute(g.title), case .title(let t)? = b.content { s.name = t }
        if !g.disappearingMessagesTimer.isEmpty, let b = try? decryptAttribute(g.disappearingMessagesTimer),
           case .disappearingMessagesDuration(let d)? = b.content { s.expireTimer = d == 0 ? nil : Int(d) }
        guard g.hasAccessControl else { throw GroupDecryptError.invalid("no accessControl") }
        let ac = g.accessControl
        let a = GroupAccessControl(attributes: ac.attributes.rawValue, members: ac.members.rawValue, addFromInviteLink: ac.addFromInviteLink.rawValue,
                                   memberLabel: ac.memberLabel.rawValue)
        guard GroupAccess.isValid(a.attributes), GroupAccess.isValid(a.members), GroupAccess.isValidLink(a.addFromInviteLink),
              GroupAccess.isValid(a.memberLabel) || a.memberLabel == GroupAccess.unknown
        else { throw GroupDecryptError.invalid("invalid access control") }
        s.accessControl = a
        s.revision = Int(g.version)
        for m in g.members { if let (member, key) = try decryptMember(m) { s.membersV2.append(member); keys[member.aci] = key } }
        for p in g.membersPendingProfileKey { if let pending = try decryptPending(p) { s.pendingMembersV2.append(pending) } }
        for p in g.membersPendingAdminApproval {
            if let (approval, key) = try decryptPendingApproval(p) {
                s.pendingAdminApprovalV2.append(approval)
                if let key { keys[approval.aci] = key }
            }
        }
        if !g.inviteLinkPassword.isEmpty { s.groupInviteLinkPassword = g.inviteLinkPassword.base64EncodedString() }
        if !g.description_p.isEmpty, let b = try? decryptAttribute(g.description_p), case .descriptionText(let t)? = b.content { s.description = t }
        s.announcementsOnly = g.announcementsOnly
        s.terminated = g.terminated
        s.bannedMembersV2 = g.membersBanned.compactMap { b in
            guard !b.userID.isEmpty, let id = try? decryptServiceId(b.userID) else { return nil }
            return GroupBannedMember(serviceId: id, timestamp: Int64(b.timestamp))
        }
        s.avatarUrl = g.avatarURL.isEmpty ? nil : g.avatarURL
        return (s, keys)
    }
}
