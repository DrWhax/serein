// Changing groups (ts/groups.preload.ts modifyGroupV2 / createGroupV2 and the operations the
// UI calls): build against the freshest state, PATCH, retry on 409, apply the signed change the
// server returns, and send it to everyone it concerns (a group update DataMessage), with a
// transcript to our other devices.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos

public typealias CredentialProvider = @Sendable (String) async throws -> ExpiringProfileKeyCredential?

extension GroupsService {
    public static let maxModifyAttempts = 5

    /// Wires the member-credential source (ProfileService.expiringCredential) and the sender.
    public func configure(credentials: @escaping CredentialProvider, sender: GroupSender) {
        credentialProvider = credentials
        groupSender = sender
    }

    var serverPublicParams: Data { api.credentials.serverParamsData }

    func builder(_ keys: GroupKeys, _ state: GroupV2State) throws -> GroupActionBuilder {
        try GroupActionBuilder(keys: keys, state: state, ourAci: ourAci, serverPublicParams: serverPublicParams)
    }

    /// `modifyGroupV2`
    @discardableResult
    public func modify(_ keys: GroupKeys, inviteLinkPassword: Data? = nil, knownState: GroupV2State? = nil,
                       build: @escaping @Sendable (GroupActionBuilder) async throws -> GroupActions?) async throws -> [String] {
        try await serialized(keys.groupIdBase64) { try await self.modifyNow(keys, inviteLinkPassword: inviteLinkPassword, knownState: knownState, build: build) }
    }

    func modifyNow(_ keys: GroupKeys, inviteLinkPassword: Data?, knownState: GroupV2State?,
                   build: @escaping @Sendable (GroupActionBuilder) async throws -> GroupActions?) async throws -> [String] {
        for attempt in 0..<Self.maxModifyAttempts {
            if knownState == nil || attempt > 0 { _ = try? await updateNow(keys, newRevision: nil, groupChange: nil, timestamp: nil) }
            let stored = try await database.pool.write { try GroupStore.conversation($0, keys: keys) }
            guard let state = knownState.flatMap({ s in (stored.state?.revision ?? -1) >= s.revision ? nil : s }) ?? stored.state else {
                throw GroupsServiceError.notFound
            }
            guard let actions = try await build(try builder(keys, state)) else { return [] }
            let response: Signalservice_GroupChangeResponse
            do {
                response = try await api.modify(actions, keys: keys, inviteLinkPassword: inviteLinkPassword)
            } catch HTTPError.status(409, _) where attempt + 1 < Self.maxModifyAttempts {
                continue
            }
            return try await applyOwnChange(response, keys: keys, before: state, stored: stored)
        }
        throw GroupsServiceError.badChange("conflict")
    }

    /// Applies the signed change from our own PATCH, then announces it.
    func applyOwnChange(_ response: Signalservice_GroupChangeResponse, keys: GroupKeys, before: GroupV2State, stored: GroupStore.Stored) async throws -> [String] {
        let signed = response.groupChange
        let actions = try GroupCipher(keys).decryptActions(try GroupActions(serializedBytes: signed.actions))
        let timestamp = UInt64(MessageStore.now())
        var withSource = actions
        withSource.sourceServiceId = withSource.sourceServiceId ?? ourAci
        let ids = try await integrate([(withSource, nil)], stored: GroupStore.Stored(conversationId: stored.conversationId, keys: keys, state: before,
                                                                                    left: stored.left),
                                      timestamp: timestamp, endorsements: response.groupSendEndorsementsResponse.isEmpty ? nil : response.groupSendEndorsementsResponse)
        let after = try await database.pool.read { try GroupStore.load($0, conversationId: stored.conversationId)?.state } ?? before
        try await sendUpdate(keys, revision: after.revision, groupChange: try signed.serializedData(), before: before, after: after, timestamp: timestamp)
        return ids
    }

    /// The group update DataMessage (`sendGroupUpdate`): to members before and after, invited
    /// ACIs and requesters affected, and a transcript to our devices.
    func sendUpdate(_ keys: GroupKeys, revision: Int, groupChange: Data?, before: GroupV2State?, after: GroupV2State, timestamp: UInt64) async throws {
        guard let groupSender else { return }
        var context = Signalservice_GroupContextV2()
        context.masterKey = keys.masterKey
        context.revision = UInt32(revision)
        if let groupChange { context.groupChange = groupChange }
        var data = Signalservice_DataMessage()
        data.groupV2 = context
        data.timestamp = timestamp
        if let pk = account.profileKey { data.profileKey = pk }
        var content = Signalservice_Content()
        content.dataMessage = data
        var recipients = Set(after.membersV2.map(\.aci) + (before?.membersV2.map(\.aci) ?? []))
        recipients.formUnion(after.pendingMembersV2.map(\.serviceId).filter { !$0.hasPrefix("PNI:") })
        recipients.formUnion((before?.pendingAdminApprovalV2 ?? []).map(\.aci))
        recipients.remove(ourAci)
        _ = try await groupSender.send(OutgoingPayload(content: content, timestamp: timestamp, contentHint: .resendable), keys: keys,
                                       recipients: Array(recipients))
        var sent = Signalservice_SyncMessage.Sent()
        sent.timestamp = timestamp
        sent.message = data
        var sync = Messenger.syncMessage()
        sync.sent = sent
        var syncContent = Signalservice_Content()
        syncContent.syncMessage = sync
        _ = try? await groupSender.sender.send(OutgoingPayload(content: syncContent, timestamp: timestamp), to: ourAci)
    }

    func credential(_ aci: String) async throws -> ExpiringProfileKeyCredential? {
        guard let credentialProvider else { return nil }
        return try await credentialProvider(aci)
    }

    // MARK: create

    /// `createGroupV2`: returns the new group's keys.
    public func create(title: String, description: String? = nil, avatar: Data? = nil, expireTimer: Int? = nil, members: [String]) async throws -> GroupKeys {
        let keys = try GroupKeys.generate()
        guard let ours = try await credential(ourAci) else { throw GroupsServiceError.badChange("no profile key credential for us") }
        let creator = try builder(keys, GroupV2State()).presentation(ours)
        var others: [(String, Data?)] = []
        for aci in members where aci != ourAci {
            let c = try? await credential(aci)
            others.append((aci, try c.map { try builder(keys, GroupV2State()).presentation($0) }))
        }
        var uploadedKey: String? = nil
        if let avatar {
            var blob = Signalservice_GroupAttributeBlob()
            blob.avatar = avatar
            uploadedKey = try await api.uploadAvatar(try GroupCipher(keys).encryptAttribute(blob), keys: keys)
        }
        let avatarKey = uploadedKey
        let proto = try GroupActionBuilder.newGroup(keys: keys, title: title, description: description, avatarKey: avatarKey, expireTimer: expireTimer,
                                                    creator: creator, members: others, ourAci: ourAci, now: MessageStore.now())
        let response = try await api.create(proto, keys: keys)
        let (state, profileKeys) = try GroupCipher(keys).decryptState(response.hasGroup ? response.group : proto)
        let ourAci = self.ourAci, ourPni = self.ourPni, timestamp = UInt64(MessageStore.now())
        let conversationId = try await database.pool.write { db -> String in
            let stored = try GroupStore.conversation(db, keys: keys)
            try GroupStore.save(db, conversationId: stored.conversationId, state: state, ourAci: ourAci)
            try GroupStore.saveProfileKeys(db, profileKeys, ourAci: ourAci)
            let messages = GroupDiff.extract(old: nil, current: state, ourAci: ourAci, ourPni: ourPni, source: ourAci)
            try GroupStore.appendChangeMessages(db, conversationId: stored.conversationId, messages, timestamp: timestamp)
            return stored.conversationId
        }
        if !response.groupSendEndorsementsResponse.isEmpty {
            try await saveEndorsements(response.groupSendEndorsementsResponse, keys: keys, members: state.membersV2.map(\.aci))
        }
        if let avatar, let store {
            let saved = try store.storeLocally(avatar)
            try await database.pool.write { db in
                try MessageStore.updateConversationJSON(db, conversationId: conversationId) { json in
                    json["avatar"] = ["url": avatarKey ?? "", "path": saved.path, "localKey": saved.localKey.base64EncodedString(), "hash": saved.plaintextHash]
                }
            }
        }
        try await sendUpdate(keys, revision: 0, groupChange: nil, before: nil, after: state, timestamp: timestamp)
        return keys
    }

    // MARK: operations

    public func addMembers(_ keys: GroupKeys, _ acis: [String]) async throws {
        var credentials: [(String, ExpiringProfileKeyCredential?)] = []
        for aci in acis { credentials.append((aci, try? await credential(aci))) }
        let list = credentials
        try await modify(keys) { b in try b.addMembers(list, now: MessageStore.now()) }
    }

    public func removeMember(_ keys: GroupKeys, _ aci: String) async throws { try await modify(keys) { try $0.deleteMember(aci) } }

    /// Leaving: as an admin with other members, upstream requires promoting someone first.
    public func leave(_ keys: GroupKeys) async throws {
        let ourAci = self.ourAci
        try await modify(keys) { b in
            if b.state.isMember(ourAci) { return try b.deleteMember(ourAci) }
            if b.state.isPending(ourAci) { return try b.deletePending([ourAci]) }
            if b.state.isPendingApproval(ourAci) { return try b.denyRequest(ourAci) }
            return nil
        }
    }

    public func setTitle(_ keys: GroupKeys, _ title: String) async throws { try await modify(keys) { try $0.updateAttributes(title: title) } }
    public func setDescription(_ keys: GroupKeys, _ text: String) async throws { try await modify(keys) { try $0.updateAttributes(description: text) } }

    public func setAvatar(_ keys: GroupKeys, _ image: Data?) async throws {
        var key: String? = nil
        if let image {
            var blob = Signalservice_GroupAttributeBlob()
            blob.avatar = image
            key = try await api.uploadAvatar(try GroupCipher(keys).encryptAttribute(blob), keys: keys)
        }
        let avatarKey = key
        try await modify(keys) { try $0.updateAttributes(avatarKey: .some(avatarKey)) }
    }

    public func setDisappearingMessagesTimer(_ keys: GroupKeys, seconds: Int) async throws { try await modify(keys) { try $0.disappearingMessagesTimer(seconds) } }
    public func setAnnouncementsOnly(_ keys: GroupKeys, _ on: Bool) async throws { try await modify(keys) { $0.announcementsOnly(on) } }
    public func setAttributesAccess(_ keys: GroupKeys, _ access: Int) async throws { try await modify(keys) { $0.attributesAccess(access) } }
    public func setMembersAccess(_ keys: GroupKeys, _ access: Int) async throws { try await modify(keys) { $0.membersAccess(access) } }
    public func setMemberLabelAccess(_ keys: GroupKeys, _ access: Int) async throws { try await modify(keys) { $0.memberLabelAccess(access) } }
    public func setRole(_ keys: GroupKeys, _ aci: String, role: Int) async throws { try await modify(keys) { try $0.modifyRole(aci, role: role) } }
    public func setMemberLabel(_ keys: GroupKeys, _ aci: String, emoji: String?, label: String?) async throws {
        try await modify(keys) { try $0.modifyLabel(aci, emoji: emoji, label: label) }
    }
    public func approveRequest(_ keys: GroupKeys, _ aci: String) async throws { try await modify(keys) { try $0.approveRequest(aci) } }
    public func denyRequest(_ keys: GroupKeys, _ aci: String) async throws { try await modify(keys) { try $0.denyRequest(aci) } }
    public func revokeInvites(_ keys: GroupKeys, _ serviceIds: [String]) async throws { try await modify(keys) { try $0.deletePending(serviceIds) } }
    public func ban(_ keys: GroupKeys, _ serviceId: String) async throws { try await modify(keys) { try $0.ban(serviceId) } }
    public func unban(_ keys: GroupKeys, _ serviceId: String) async throws { try await modify(keys) { try $0.unban(serviceId) } }
    public func terminate(_ keys: GroupKeys) async throws { try await modify(keys) { $0.terminate() } }

    /// Turns the link on (ANY, or ADMINISTRATOR when joins need approval), keeping its password.
    public func setInviteLink(_ keys: GroupKeys, access: Int) async throws {
        try await modify(keys) { b in
            if b.state.groupInviteLinkPassword == nil {
                return b.newGroupLink(password: GroupActionBuilder.newInviteLinkPassword(), access: access)
            }
            return b.addFromInviteLinkAccess(access)
        }
    }

    public func resetInviteLink(_ keys: GroupKeys) async throws { try await modify(keys) { $0.inviteLinkPassword(GroupActionBuilder.newInviteLinkPassword()) } }
    public func disableInviteLink(_ keys: GroupKeys) async throws { try await modify(keys) { $0.addFromInviteLinkAccess(GroupAccess.unsatisfiable) } }

    /// Accept an invite to our ACI or PNI (`buildPromoteMemberChange`).
    public func acceptInvite(_ keys: GroupKeys) async throws {
        guard let ours = try await credential(ourAci) else { throw GroupsServiceError.badChange("no profile key credential for us") }
        let ourAci = self.ourAci, ourPni = self.ourPni
        try await modify(keys) { b in
            if b.state.isPending(ourAci) { return try b.acceptInvite(ours, invitedPni: nil) }
            if let ourPni, b.state.isPending(ourPni) { return try b.acceptInvite(ours, invitedPni: ourPni) }
            return nil
        }
    }

    /// Our new profile key for every group we are in (`buildModifyMemberProfileKeyChange`).
    public func shareProfileKey(_ keys: GroupKeys) async throws {
        guard let ours = try await credential(ourAci) else { return }
        try await modify(keys) { try $0.modifyOurProfileKey(ours) }
    }
}
