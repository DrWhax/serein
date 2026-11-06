// CallingClass group calls and call links: peeking, connecting and joining through the SFU,
// the GroupCallObserver, ring updates, group-call update messages, call-link CRUD and the
// "call link refresh" job.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos
public import SignalRingRTC

extension CallingService {
    // MARK: group members and proofs

    struct GroupInfo: Sendable {
        var conversationId: String
        var keys: GroupKeys
        var state: GroupV2State
        var left: Bool
        var blocked: Bool
        var accepted: Bool
        var mutedForCalls: Bool
    }

    func groupInfo(conversationId: String) async throws -> GroupInfo {
        let ourAci = account.aci
        guard let info = try await database.pool.read({ db -> GroupInfo? in
            guard let g = try GroupStore.load(db, conversationId: conversationId), let state = g.state else { return nil }
            return GroupInfo(conversationId: g.conversationId, keys: g.keys, state: state, left: g.left,
                             blocked: try BlockedList.groups.blockedAt(db, g.keys.groupIdBase64).blocked,
                             accepted: try ConversationState.isAccepted(db, conversationId: conversationId, ourAci: ourAci, ignoreEmptyConvo: true),
                             mutedForCalls: try Self.isMutedForCalls(db, conversationId: conversationId))
        }) else { throw CallingError.notAGroup }
        return info
    }

    func groupInfo(groupId: Data) async throws -> GroupInfo {
        guard let id = try await database.pool.read({ db in try GroupStore.find(db, groupId: groupId)?.conversationId }) else { throw CallingError.notAGroup }
        return try await groupInfo(conversationId: id)
    }

    /// `getMembershipList` → `GroupMemberInfo(uuidToBytes(aci), encryptServiceId(aci))`.
    static func members(_ info: GroupInfo) -> [GroupMemberInfo] {
        guard let zk = try? GroupCipher(info.keys) else { return [] }
        return info.state.membersV2.compactMap { m in
            guard let cipher = try? zk.encryptServiceId(m.aci) else { return nil }
            return GroupMemberInfo(userId: uuidBytes(m.aci), userIdCipherText: cipher)
        }
    }

    // MARK: peeking

    /// `peekGroupCall`: the connected call's peek info, or a stateless peek.
    public func peekGroupCall(conversationId: String) async throws -> PeekInfo? {
        if let p = groupCall(for: conversationId)?.peekInfo { return p }
        let info = try await groupInfo(conversationId: conversationId)
        if info.state.terminated { return nil }
        let proof = try await groups.membershipProof(info.keys)
        let peek = await rtc.peekGroupCall(sfuUrl: config.sfuURL.absoluteString, membershipProof: proof, groupMembers: Self.members(info))
        await updateCallHistoryOnPeek(conversationId: conversationId, info: info, joinState: nil, peekInfo: peek)
        emit(.peekResult(conversationId: conversationId, peekInfo: peek))
        return peek
    }

    /// `peekCallLinkCall`
    public func peekCallLinkCall(roomId: String, rootKey: CallLinkRootKey) async throws -> PeekInfo {
        if let p = groupCall(for: roomId)?.peekInfo { return p }
        let presentation = try await credentials.callLinkAuthPresentation(rootKey: rootKey.bytes)
        switch await rtc.peekCallLinkCall(sfuUrl: config.sfuURL.absoluteString, authCredentialPresentation: presentation, rootKey: rootKey) {
        case .success(let p): return p
        case .failure(let code): throw CallingError.callLinkRequestFailed(status: code)
        }
    }

    // MARK: connecting and joining

    var svcConfig: GroupCallSvcConfig? { config.groupSvc }

    /// `connectGroupCall` (idempotent).
    @discardableResult
    public func connectGroupCall(conversationId: String) async throws -> GroupCall {
        if let existing = groupCall(for: conversationId) {
            if existing.localDeviceState.connectionState == .notConnected { existing.connect() }
            return existing
        }
        let info = try await groupInfo(conversationId: conversationId)
        let observer = GroupObserver(service: self, conversationId: conversationId, mode: .group, keys: info.keys)
        guard let call = rtc.getGroupCall(groupId: info.keys.groupId, sfuUrl: config.sfuURL.absoluteString, hkdfExtraInfo: Data(),
                                          audioLevelsIntervalMillis: Self.audioLevelIntervalMillis, dredDuration: config.dredDuration,
                                          svcConfig: svcConfig, observer: observer) else { throw CallingError.noConversation }
        observers[conversationId] = observer
        callsLookup[conversationId] = .group(call)
        call.connect()
        emit(.groupCallChanged(conversationId: conversationId, mode: .group))
        return call
    }

    /// `joinGroupCall`
    public func joinGroupCall(conversationId: String, hasLocalAudio: Bool, hasLocalVideo: Bool, shouldRing: Bool) async throws {
        let call = try await connectGroupCall(conversationId: conversationId)
        cameraEnabled = hasLocalVideo
        call.setOutgoingAudioMuted(!hasLocalAudio)
        call.setOutgoingVideoMuted(!hasLocalVideo)
        onCameraNeeded?(hasLocalVideo)
        if shouldRing { call.ringAll() }
        call.join()
    }

    /// `connectCallLinkCall`
    @discardableResult
    public func connectCallLinkCall(roomId: String, rootKey: CallLinkRootKey, adminPasskey: Data?) async throws -> GroupCall {
        if let existing = groupCall(for: roomId) {
            if existing.localDeviceState.connectionState == .notConnected { existing.connect() }
            return existing
        }
        let presentation = try await credentials.callLinkAuthPresentation(rootKey: rootKey.bytes)
        let endorsementKey = try credentials.serverParams().endorsementPublicKey
        let observer = GroupObserver(service: self, conversationId: roomId, mode: .adhoc, keys: nil)
        guard let call = rtc.getCallLinkCall(sfuUrl: config.sfuURL.absoluteString, endorsementPublicKey: endorsementKey,
                                             authCredentialPresentation: presentation, rootKey: rootKey, adminPasskey: adminPasskey, hkdfExtraInfo: Data(),
                                             audioLevelsIntervalMillis: Self.audioLevelIntervalMillis, dredDuration: config.dredDuration,
                                             svcConfig: svcConfig, observer: observer) else { throw CallingError.noConversation }
        observers[roomId] = observer
        callsLookup[roomId] = .group(call)
        call.connect()
        emit(.groupCallChanged(conversationId: roomId, mode: .adhoc))
        return call
    }

    /// `joinCallLinkCall`
    public func joinCallLinkCall(roomId: String, rootKey: CallLinkRootKey, adminPasskey: Data?, hasLocalAudio: Bool, hasLocalVideo: Bool) async throws {
        let call = try await connectCallLinkCall(roomId: roomId, rootKey: rootKey, adminPasskey: adminPasskey)
        cameraEnabled = hasLocalVideo
        call.setOutgoingAudioMuted(!hasLocalAudio)
        call.setOutgoingVideoMuted(!hasLocalVideo)
        onCameraNeeded?(hasLocalVideo)
        call.join()
    }

    /// `groupMembersChanged`: a group's roster changed while connected.
    public func groupMembersChanged(conversationId: String) async {
        guard let call = groupCall(for: conversationId), let info = try? await groupInfo(conversationId: conversationId) else { return }
        call.setGroupMembers(Self.members(info))
    }

    public func approveUser(conversationId: String, aci: String) { groupCall(for: conversationId)?.approveUser(Self.uuidBytes(aci)) }
    public func denyUser(conversationId: String, aci: String) { groupCall(for: conversationId)?.denyUser(Self.uuidBytes(aci)) }
    public func removeClient(conversationId: String, demuxId: UInt32) { groupCall(for: conversationId)?.removeClient(demuxId) }
    public func blockClient(conversationId: String, demuxId: UInt32) { groupCall(for: conversationId)?.blockClient(demuxId) }
    public func sendRemoteMute(conversationId: String, demuxId: UInt32) { groupCall(for: conversationId)?.sendRemoteMuteRequest(target: demuxId) }
    public func raiseHand(conversationId: String, _ raise: Bool) { groupCall(for: conversationId)?.raiseHand(raise) }
    public func react(conversationId: String, _ value: String) { groupCall(for: conversationId)?.react(value) }
    public func requestVideo(conversationId: String, _ resolutions: [VideoRequest], speakerHeight: Int) {
        groupCall(for: conversationId)?.requestVideo(resolutions, activeSpeakerHeight: speakerHeight)
    }

    /// `declineGroupCall`
    public func declineGroupCall(conversationId: String, ringId: Int64) async {
        guard let info = try? await groupInfo(conversationId: conversationId) else { return }
        rtc.cancelGroupRing(groupId: info.keys.groupId, ringId: ringId, reason: .declinedByUser)
    }

    // MARK: ringing

    /// `#handleGroupCallRingUpdate`
    func handleGroupCallRingUpdate(groupId: Data, ringId: Int64, ringer: Data, update: RingUpdate) async {
        guard let ringerAci = Self.uuidString(ringer), let info = try? await groupInfo(groupId: groupId) else { return }
        let conversationId = info.conversationId
        if update == .requested { _ = try? await peekGroupCall(conversationId: conversationId) }
        let ourAci = account.aci
        if info.blocked || !info.accepted || info.left || !info.state.isMember(ourAci) || !info.state.isMember(ringerAci) || info.state.terminated { return }
        if info.state.announcementsOnly, !info.state.isAdmin(ringerAci) { return }
        var shouldRing = false
        if update == .requested {
            if (try? await database.pool.read({ db in try GroupRings.wasCanceled(db, ringId: ringId) })) == true {
                rtc.cancelGroupRing(groupId: groupId, ringId: ringId, reason: nil)
            } else if callsLookup.values.contains(where: Self.isActiveOrRinging) {
                rtc.cancelGroupRing(groupId: groupId, ringId: ringId, reason: .busy)
            } else if info.mutedForCalls {
                // Not notifying for calls while muted.
            } else if config.incomingCallNotification {
                shouldRing = true
            }
        } else {
            try? await database.pool.write { db in try GroupRings.markCanceled(db, ringId: ringId) }
        }
        if shouldRing {
            emit(.incomingGroupRing(conversationId: conversationId, ringId: ringId, ringerAci: ringerAci))
        } else {
            emit(.cancelGroupRing(conversationId: conversationId, ringId: ringId))
        }
        let local = CallHistoryTransitions.eventForRingUpdate(update.rawValue)
        let event: LocalCallEvent = local == .missed ? .missed : shouldRing ? .ringing : .started
        let now = MessageStore.now()
        await updateCallHistory(CallEventDetails(
            details: CallDetails(callId: String(callIdFromRingId(ringId)), peerId: info.keys.groupIdBase64, ringerId: ringerAci, startedById: ringerAci,
                                 mode: .group, type: .group, direction: ringerAci == ourAci ? .outgoing : .incoming, timestamp: now),
            event: .local(event), eventSource: "CallingClass.handleGroupCallRingUpdate", eventTimestamp: now))
    }

    static func isActiveOrRinging(_ c: ActiveCall) -> Bool {
        switch c {
        case .direct(let call): call.state != .ended
        case .group(let g): g.localDeviceState.connectionState != .notConnected
        }
    }

    // MARK: group-call history and update messages

    /// `getGroupCallMeta` → call id (from the era) and ringer (the creator).
    static func groupCallMeta(_ peek: PeekInfo?) -> (callId: String, ringerId: String)? {
        guard let peek, let era = peek.eraId, let creator = peek.creator, let ringer = uuidString(creator) else { return nil }
        return (String(callIdFromEra(era)), ringer)
    }

    func groupEvent(_ info: GroupInfo, meta: (callId: String, ringerId: String), joinState: JoinState?, source: String) -> CallEventDetails {
        let outgoing = meta.ringerId == account.aci
        let local = CallHistoryTransitions.eventForJoinState(joinState?.rawValue, outgoing: outgoing)
        let now = MessageStore.now()
        return CallEventDetails(details: CallDetails(callId: meta.callId, peerId: info.keys.groupIdBase64, ringerId: meta.ringerId, startedById: meta.ringerId,
                                                     mode: .group, type: .group, direction: outgoing ? .outgoing : .incoming, timestamp: now),
                                event: .local(local), eventSource: source, eventTimestamp: now)
    }

    /// `updateCallHistoryForGroupCallOnLocalChanged`
    func updateCallHistoryOnLocalChanged(conversationId: String, joinState: JoinState, peekInfo: PeekInfo?) async {
        guard let meta = Self.groupCallMeta(peekInfo), let info = try? await groupInfo(conversationId: conversationId) else { return }
        await updateCallHistory(groupEvent(info, meta: meta, joinState: joinState, source: "CallingClass.updateCallHistoryForGroupCallOnLocalChanged"))
    }

    /// `updateCallHistoryForGroupCallOnPeek`: only a call we have not seen is recorded.
    func updateCallHistoryOnPeek(conversationId: String, info: GroupInfo? = nil, joinState: JoinState?, peekInfo: PeekInfo?) async {
        guard let meta = Self.groupCallMeta(peekInfo) else { return }
        var resolved = info
        if resolved == nil { resolved = try? await groupInfo(conversationId: conversationId) }
        guard let info = resolved else { return }
        let peerId = info.keys.groupIdBase64
        let known = (try? await database.pool.read { db in try CallHistoryStore.get(db, callId: meta.callId, peerId: peerId) }) ?? nil
        guard known == nil else { return }
        await updateCallHistory(groupEvent(info, meta: meta, joinState: joinState, source: "CallingClass.updateCallHistoryForGroupCallOnPeek"))
    }

    /// `updateCallHistoryForAdhocCall`
    func updateCallHistoryForAdhoc(roomId: String, joinState: JoinState?, peekInfo: PeekInfo?) async {
        guard let era = peekInfo?.eraId else { return }
        let local: LocalCallEvent
        if joinState == .joined { local = .accepted } else if let p = peekInfo, !p.devices.isEmpty { local = .started } else { return }
        let now = MessageStore.now()
        await updateCallHistory(CallEventDetails(
            details: CallDetails(callId: String(callIdFromEra(era)), peerId: roomId, ringerId: nil, startedById: nil, mode: .adhoc, type: .adhoc,
                                 direction: .unknown, timestamp: now),
            event: .local(local), eventSource: "CallingClass.updateCallHistoryForAdhocCall", eventTimestamp: now))
    }

    /// `#sendGroupCallUpdateMessage`: a DataMessage with groupCallUpdate{eraId} to the group
    /// (and our other devices).
    func sendGroupCallUpdate(conversationId: String, eraId: String) async {
        guard let info = try? await groupInfo(conversationId: conversationId) else { return }
        var data = Signalservice_DataMessage()
        data.timestamp = UInt64(MessageStore.now())
        if let pk = account.profileKey { data.profileKey = pk }
        var ctx = Signalservice_GroupContextV2()
        ctx.masterKey = info.keys.masterKey
        ctx.revision = UInt32(info.state.revision)
        data.groupV2 = ctx
        var update = Signalservice_DataMessage.GroupCallUpdate()
        update.eraID = eraId
        data.groupCallUpdate = update
        var content = Signalservice_Content()
        content.dataMessage = data
        guard let bytes: Data = try? content.serializedData() else { return }
        let timestamp = data.timestamp
        try? await database.pool.write { db in
            _ = try JobQueue.insert(db, queueType: ConversationJob.queueType,
                                    payload: ConversationJob.modifierSend(conversationId: conversationId, content: bytes, timestamp: timestamp))
        }
        messenger.jobs.poke()
    }

    /// `#sendProfileKeysForAdhocCall`: everyone in a call link call gets our profile key once.
    func sendProfileKeysForAdhoc(peekInfo: PeekInfo?) async {
        guard let peekInfo else { return }
        let ourAci = account.aci
        for device in peekInfo.devices {
            guard let id = device.userId, let aci = Self.uuidString(id), aci != ourAci, !adhocProfileKeysSent.contains(aci) else { continue }
            let blocked = (try? await database.pool.read { db in try BlockedList.serviceIds.blockedAt(db, aci).blocked }) ?? false
            if blocked { continue }
            adhocProfileKeysSent.insert(aci)
            sendProfileKey(to: aci)
        }
    }

    // MARK: call links

    /// `createCallLink`: a new admin-approval link; saved, synced to our devices and uploaded
    /// to the storage service.
    public func createCallLink() async throws -> CallLinkRecord {
        let rootKey = try CallLinkRootKey.generate()
        let roomIdBytes = try rootKey.deriveRoomId()
        let adminKey = try CallLinkRootKey.generateAdminPassKey()
        let presentation = try await credentials.createCallLinkPresentation(roomId: roomIdBytes, rootKey: rootKey.bytes)
        let publicParams = CallLinkSecretParams.deriveFromRootKey(rootKey.bytes).getPublicParams().serialize() as Data
        let state: CallLinkState
        switch await rtc.createCallLink(sfuUrl: config.sfuURL.absoluteString, createCredentialPresentation: presentation, linkRootKey: rootKey,
                                        adminPasskey: adminKey, callLinkPublicParams: publicParams, restrictions: .adminApproval) {
        case .success(let s): state = s
        case .failure(let code): throw CallingError.callLinkRequestFailed(status: code)
        }
        let record = CallLinkRecord(roomId: roomIdBytes.hexString, rootKey: state.rootKey.bytes, adminKey: adminKey, name: state.name,
                                    restrictions: state.restrictions.rawValue, revoked: state.revoked,
                                    expiration: Int64(state.expiration.timeIntervalSince1970 * 1000))
        let now = MessageStore.now()
        try await database.pool.write { db in
            try CallLinkStore.insert(db, record)
            try CallHistoryStore.save(db, CallLinkStore.placeholderHistory(roomId: record.roomId, now: now))
        }
        emit(.historyChanged)
        await sendCallLinkUpdateSync(record)
        return record
    }

    func adminContext(_ link: CallLinkRecord) async throws -> (CallLinkRootKey, Data, Data) {
        guard let admin = link.adminKey else { throw CallingError.missingAdminKey }
        let key = try CallLinkRootKey.fromBytes(link.rootKey)
        return (key, admin, try await credentials.callLinkAuthPresentation(rootKey: link.rootKey))
    }

    func saveState(_ result: HttpResult<CallLinkState>, roomId: String) async throws -> CallLinkState {
        switch result {
        case .success(let s):
            try await database.pool.write { db in
                try CallLinkStore.updateState(db, roomId: roomId, name: s.name, restrictions: s.restrictions.rawValue, revoked: s.revoked,
                                              expiration: Int64(s.expiration.timeIntervalSince1970 * 1000))
            }
            emit(.historyChanged)
            return s
        case .failure(let code): throw CallingError.callLinkRequestFailed(status: code)
        }
    }

    /// `updateCallLinkName`
    public func updateCallLinkName(_ link: CallLinkRecord, name: String) async throws -> CallLinkState {
        let (key, admin, presentation) = try await adminContext(link)
        let s = try await saveState(await rtc.updateCallLinkName(sfuUrl: config.sfuURL.absoluteString, authCredentialPresentation: presentation,
                                                                 linkRootKey: key, adminPasskey: admin, newName: name), roomId: link.roomId)
        await sendCallLinkUpdateSync(link)
        return s
    }

    /// `updateCallLinkRestrictions`
    public func updateCallLinkRestrictions(_ link: CallLinkRecord, restrictions: CallLinkRestrictions) async throws -> CallLinkState {
        let (key, admin, presentation) = try await adminContext(link)
        let s = try await saveState(await rtc.updateCallLinkRestrictions(sfuUrl: config.sfuURL.absoluteString, authCredentialPresentation: presentation,
                                                                         linkRootKey: key, adminPasskey: admin, restrictions: restrictions),
                                    roomId: link.roomId)
        await sendCallLinkUpdateSync(link)
        return s
    }

    /// `deleteCallLink` (on the SFU; 404 = already gone), then the local tombstone.
    public func deleteCallLink(_ link: CallLinkRecord) async throws {
        let (key, admin, presentation) = try await adminContext(link)
        switch await rtc.deleteCallLink(sfuUrl: config.sfuURL.absoluteString, authCredentialPresentation: presentation, linkRootKey: key, adminPasskey: admin) {
        case .success, .failure(errorStatusCode: 404): break
        case .failure(let code): throw CallingError.callLinkRequestFailed(status: code)
        }
        let now = MessageStore.now()
        try await database.pool.write { db in
            try CallLinkStore.markDeleted(db, roomId: link.roomId, at: now)
            try CallLinkStore.finalizeDeleted(db, roomId: link.roomId)
        }
        emit(.historyChanged)
    }

    /// `readCallLink`: nil when the SFU no longer has the link.
    public func readCallLink(rootKey: CallLinkRootKey) async throws -> CallLinkState? {
        let presentation = try await credentials.callLinkAuthPresentation(rootKey: rootKey.bytes)
        switch await rtc.readCallLink(sfuUrl: config.sfuURL.absoluteString, authCredentialPresentation: presentation, linkRootKey: rootKey) {
        case .success(let s): return s
        case .failure(404): return nil
        case .failure(let code): throw CallingError.callLinkRequestFailed(status: code)
        }
    }

    /// `sendCallLinkUpdateSync`
    func sendCallLinkUpdateSync(_ link: CallLinkRecord) async {
        var update = Signalservice_SyncMessage.CallLinkUpdate()
        update.type = .update
        update.rootKey = link.rootKey
        if let admin = link.adminKey { update.adminPasskey = admin }
        var sync = Messenger.syncMessage()
        sync.callLinkUpdate = update
        try? await messenger.sendToSelf(sync, timestamp: UInt64(MessageStore.now()), urgent: false, messageIds: [])
    }

    /// The "call link refresh" job (callLinkRefreshJobQueue.run): the SFU's state for a link
    /// from a sync or the storage service — saved, recorded as defunct, or ignored.
    func refreshCallLink(_ job: CallLinkRefreshJob) async throws {
        guard let rootKeyBytes = Data(base64Encoded: job.rootKey) else { throw JobError.permanent("bad root key") }
        let rootKey = try CallLinkRootKey.fromBytes(rootKeyBytes)
        let roomId = try CallLinkStore.roomId(rootKey: rootKeyBytes)
        let fresh = try await readCallLink(rootKey: rootKey)
        let adminKey = job.adminKey.flatMap { Data(base64Encoded: $0) }
        let now = MessageStore.now()
        try await database.pool.write { db in
            let existing = try CallLinkStore.get(db, roomId: roomId)
            if let fresh {
                let expiration = Int64(fresh.expiration.timeIntervalSince1970 * 1000)
                if existing != nil {
                    try CallLinkStore.updateState(db, roomId: roomId, name: fresh.name, restrictions: fresh.restrictions.rawValue, revoked: fresh.revoked,
                                                  expiration: expiration)
                } else {
                    try db.execute(sql: """
                        INSERT INTO callLinks (roomId, rootKey, adminKey, name, restrictions, revoked, expiration, deleted, storageID, storageVersion,
                          storageUnknownFields, storageNeedsSync)
                        VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, 0)
                        """, arguments: [roomId, rootKeyBytes, adminKey, fresh.name, fresh.restrictions.rawValue, fresh.revoked ? 1 : 0, expiration,
                                         job.storageID, job.storageVersion.map { Int64($0) }, job.storageUnknownFields.flatMap { Data(base64Encoded: $0) }])
                    try CallHistoryStore.save(db, CallLinkStore.placeholderHistory(roomId: roomId, now: now))
                }
            } else if existing == nil {
                try db.execute(sql: """
                    INSERT INTO defunctCallLinks (roomId, rootKey, adminKey, addedAt, storageID, storageVersion, storageUnknownFields, storageNeedsSync)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 1) ON CONFLICT(roomId) DO NOTHING
                    """, arguments: [roomId, rootKeyBytes, adminKey, now, job.storageID, job.storageVersion.map { Int64($0) },
                                     job.storageUnknownFields.flatMap { Data(base64Encoded: $0) }])
                try StorageService.scheduleUpload(db)
            }
        }
        emit(.historyChanged)
    }
}

// MARK: - GroupCallObserver

/// `#getGroupCallObserver`: one per connected group or call-link call.
@MainActor
final class GroupObserver: GroupCallObserver {
    enum UpdateMessageState { case sentNothing, sentJoin, sentLeft }

    weak var service: CallingService?
    let conversationId: String
    let mode: CallMode
    let keys: GroupKeys?
    var updateMessageState = UpdateMessageState.sentNothing
    var requestingProof = false

    init(service: CallingService, conversationId: String, mode: CallMode, keys: GroupKeys?) {
        self.service = service
        self.conversationId = conversationId
        self.mode = mode
        self.keys = keys
    }

    func requestMembershipProof(_ groupCall: GroupCall) {
        guard mode == .group, let keys, let service, !requestingProof else { return }
        requestingProof = true
        Task { @MainActor in
            defer { self.requestingProof = false }
            if let proof = try? await service.groups.membershipProof(keys) { groupCall.setMembershipProof(proof) }
        }
    }

    func requestGroupMembers(_ groupCall: GroupCall) {
        guard mode == .group, let service else { return }
        Task { @MainActor in
            if let info = try? await service.groupInfo(conversationId: self.conversationId) { groupCall.setGroupMembers(CallingService.members(info)) }
        }
    }

    func updateHistory(_ groupCall: GroupCall, onPeek: Bool) {
        guard let service else { return }
        let id = conversationId
        let join = groupCall.localDeviceState.joinState
        let peek = groupCall.peekInfo
        Task { @MainActor in
            if self.mode == .adhoc {
                await service.updateCallHistoryForAdhoc(roomId: id, joinState: join, peekInfo: peek)
            } else if onPeek {
                await service.updateCallHistoryOnPeek(conversationId: id, joinState: join, peekInfo: peek)
            } else {
                await service.updateCallHistoryOnLocalChanged(conversationId: id, joinState: join, peekInfo: peek)
            }
        }
    }

    /// `#onGroupCallJoined`
    func joined(_ groupCall: GroupCall, eraId: String) {
        guard let service else { return }
        updateMessageState = .sentJoin
        let id = conversationId
        Task { @MainActor in
            if self.mode == .group {
                await service.sendGroupCallUpdate(conversationId: id, eraId: eraId)
            } else {
                service.emit(.joinedAdhocCall(roomId: id))
                await service.sendProfileKeysForAdhoc(peekInfo: groupCall.peekInfo)
            }
            // Alone in the call: warm up the microphone.
            if groupCall.remoteDeviceStates?.isEmpty ?? true {
                _ = try? await service.rtc.setMicrophoneWarmupEnabled(!groupCall.localDeviceState.audioMuted)
            }
        }
    }

    func onLocalDeviceStateChanged(_ groupCall: GroupCall) {
        guard let service else { return }
        let local = groupCall.localDeviceState
        let era = groupCall.peekInfo?.eraId
        updateHistory(groupCall, onPeek: false)
        if local.connectionState == .notConnected {
            service.onCameraNeeded?(false)
            service.callsLookup[conversationId] = nil
            service.observers[conversationId] = nil
            if updateMessageState == .sentJoin, let era {
                updateMessageState = .sentLeft
                if mode == .group {
                    let id = conversationId
                    Task { @MainActor in await service.sendGroupCallUpdate(conversationId: id, eraId: era) }
                }
            }
        } else {
            service.callsLookup[conversationId] = .group(groupCall)
            if !local.sharingScreen { service.onCameraNeeded?(!local.videoMuted) }
            if updateMessageState == .sentNothing, local.joinState == .joined, let era { joined(groupCall, eraId: era) }
        }
        service.emit(.groupCallChanged(conversationId: conversationId, mode: mode))
    }

    func onRemoteDeviceStatesChanged(_ groupCall: GroupCall) {
        guard let service else { return }
        service.emit(.groupCallChanged(conversationId: conversationId, mode: mode))
        if mode == .adhoc {
            let peek = groupCall.peekInfo
            Task { @MainActor in await service.sendProfileKeysForAdhoc(peekInfo: peek) }
        }
    }

    func onAudioLevels(_ groupCall: GroupCall) { service?.emit(.groupCallAudioLevels(conversationId: conversationId)) }
    func onLowBandwidthForVideo(_ groupCall: GroupCall, recovered: Bool) {}
    func onReactions(_ groupCall: GroupCall, reactions: [Reaction]) {
        service?.emit(.groupCallReactions(conversationId: conversationId, reactions: reactions))
    }
    func onRaisedHands(_ groupCall: GroupCall, raisedHands: [UInt32]) {
        service?.emit(.groupCallRaisedHands(conversationId: conversationId, raisedHands: raisedHands))
    }

    func onPeekChanged(_ groupCall: GroupCall) {
        let local = groupCall.localDeviceState
        if updateMessageState == .sentNothing, local.connectionState != .notConnected, local.joinState == .joined, let era = groupCall.peekInfo?.eraId {
            joined(groupCall, eraId: era)
        }
        updateHistory(groupCall, onPeek: true)
        service?.emit(.groupCallChanged(conversationId: conversationId, mode: mode))
    }

    func onEnded(_ groupCall: GroupCall, reason: CallEndReason, summary: CallSummary) {
        service?.emit(.groupCallEnded(conversationId: conversationId, reason: reason))
    }

    func onSpeechEvent(_ groupCall: GroupCall, event: SpeechEvent) { service?.emit(.suggestLowerHand(event == .lowerHandSuggestion)) }
    func onRemoteMute(_ groupCall: GroupCall, demuxId: UInt32) { service?.emit(.mutedBy(demuxId: demuxId)) }
    func onObservedRemoteMute(_ groupCall: GroupCall, sourceDemuxId: UInt32, targetDemuxId: UInt32) {
        service?.emit(.observedRemoteMute(source: sourceDemuxId, target: targetDemuxId))
    }
}

// MARK: - canceled group rings (`groupCallRingCancellations`)

enum GroupRings {
    /// `wasGroupCallRingPreviouslyCanceled`
    static func wasCanceled(_ db: Database, ringId: Int64) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM groupCallRingCancellations WHERE ringId = ?)", arguments: [ringId]) ?? false
    }

    /// `processGroupCallRingCancellation`
    static func markCanceled(_ db: Database, ringId: Int64) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO groupCallRingCancellations (ringId, createdAt) VALUES (?, ?)", arguments: [ringId, MessageStore.now()])
    }
}
