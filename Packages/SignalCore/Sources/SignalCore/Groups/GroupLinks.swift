// Group invite links (ts/groups.preload.ts buildGroupLink / parseGroupLink, groupInvitesRoute)
// and joining through one (ts/groups/joinViaLink.preload.ts, getPreJoinGroupInfo,
// joinGroupV2ViaLink): `https://signal.group/#<base64url GroupInviteLink>`; joining is a request
// for admin approval when the link's access is ADMINISTRATOR, else a direct add.

import Foundation
import SignalProtos

public enum GroupLinkError: Error, Equatable {
    case invalid(String)
    case linkDisabled
}

public struct GroupLink: Sendable, Equatable {
    public var masterKey: Data
    public var inviteLinkPassword: Data

    public init(masterKey: Data, inviteLinkPassword: Data) {
        self.masterKey = masterKey
        self.inviteLinkPassword = inviteLinkPassword
    }

    public var url: String {
        var v1 = Signalservice_GroupInviteLink.GroupInviteLinkContentsV1()
        v1.groupMasterKey = masterKey
        v1.inviteLinkPassword = inviteLinkPassword
        var link = Signalservice_GroupInviteLink()
        link.contentsV1 = v1
        return "https://signal.group/#" + GroupsAPI.webSafe((try? link.serializedData()) ?? Data())
    }

    /// Accepts https://signal.group/#…, sgnl://signal.group/#… and sgnl://joingroup/#….
    public init(url: String) throws {
        guard let u = URLComponents(string: url), let code = u.fragment, !code.isEmpty, !code.contains("/") else { throw GroupLinkError.invalid("no invite code") }
        let valid = (u.scheme == "https" && u.host == "signal.group") || (u.scheme == "sgnl" && (u.host == "signal.group" || u.host == "joingroup"))
        guard valid, (u.path.isEmpty || u.path == "/") else { throw GroupLinkError.invalid("not a group link") }
        try self.init(code: code)
    }

    /// `parseGroupLink`
    public init(code: String) throws {
        var b64 = code.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let bytes = Data(base64Encoded: b64), let link = try? Signalservice_GroupInviteLink(serializedBytes: bytes) else {
            throw GroupLinkError.invalid("undecodable")
        }
        guard case .contentsV1(let v1)? = link.contents else { throw GroupLinkError.invalid("missing contentsV1") }
        guard v1.groupMasterKey.count == 32 else { throw GroupLinkError.invalid("master key length") }
        guard !v1.inviteLinkPassword.isEmpty else { throw GroupLinkError.invalid("no password") }
        self.init(masterKey: v1.groupMasterKey, inviteLinkPassword: v1.inviteLinkPassword)
    }
}

/// What a link shows before joining (`GroupJoinInfo`, decrypted).
public struct PreJoinGroupInfo: Sendable, Equatable {
    public var title: String?
    public var description: String?
    public var avatarKey: String?
    public var memberCount: Int
    public var addFromInviteLink: Int
    public var revision: Int
    public var pendingAdminApproval: Bool
    public var approvalRequired: Bool { addFromInviteLink == GroupAccess.administrator }
}

extension GroupsService {
    public func groupLink(_ keys: GroupKeys) async throws -> GroupLink? {
        let state = try await database.pool.read { try GroupStore.find($0, groupId: keys.groupId)?.state }
        guard let pw = state?.groupInviteLinkPassword.flatMap({ Data(base64Encoded: $0) }) else { return nil }
        return GroupLink(masterKey: keys.masterKey, inviteLinkPassword: pw)
    }

    /// `getPreJoinGroupInfo`
    public func preJoinInfo(_ link: GroupLink) async throws -> PreJoinGroupInfo {
        let keys = try GroupKeys(masterKey: link.masterKey)
        let info = try await api.joinInfo(keys, inviteLinkPassword: link.inviteLinkPassword)
        let cipher = try GroupCipher(keys)
        var title: String? = nil, description: String? = nil
        if !info.title.isEmpty, case .title(let t)? = try? cipher.decryptAttribute(info.title).content { title = t }
        if !info.description_p.isEmpty, case .descriptionText(let d)? = try? cipher.decryptAttribute(info.description_p).content { description = d }
        return PreJoinGroupInfo(title: title, description: description, avatarKey: info.avatar.isEmpty ? nil : info.avatar,
                                memberCount: Int(info.memberCount), addFromInviteLink: info.addFromInviteLink.rawValue, revision: Int(info.version),
                                pendingAdminApproval: info.pendingAdminApproval)
    }

    /// `joinGroupV2ViaLink`: join, or ask to.
    public func join(_ link: GroupLink) async throws -> GroupKeys {
        let keys = try GroupKeys(masterKey: link.masterKey)
        let info = try await preJoinInfo(link)
        guard info.addFromInviteLink == GroupAccess.any || info.addFromInviteLink == GroupAccess.administrator else { throw GroupLinkError.linkDisabled }
        guard let ours = try await credential(ourAci) else { throw GroupsServiceError.badChange("no profile key credential for us") }
        var known = GroupV2State()
        known.revision = info.revision
        known.name = info.title
        known.description = info.description
        known.accessControl.addFromInviteLink = info.addFromInviteLink
        let approval = info.approvalRequired
        try await database.pool.write { db in
            let stored = try GroupStore.conversation(db, keys: keys)
            try MessageStore.updateConversationJSON(db, conversationId: stored.conversationId) { json in
                if json["name"] == nil { json["name"] = info.title }
                json["groupInviteLinkPassword"] = link.inviteLinkPassword.base64EncodedString()
            }
        }
        try await modify(keys, inviteLinkPassword: link.inviteLinkPassword, knownState: known) { b in
            approval ? try b.requestToJoin(ours) : try b.joinFromLink(ours)
        }
        if !approval {
            try await resync(keys)
        }
        return keys
    }
}
