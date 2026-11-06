// CallingClass (ts/services/calling.preload.ts): owns the RingRTC instance and connects it to
// the rest of the client — signalling through the message pipeline, SFU HTTP through our
// HTTPS client, ICE relays, group membership proofs, peeking and ringing, call links, and
// call history (with its CallEvent syncs). UI state is reported through `onEvent`.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos
public import SignalRingRTC

/// What the calling UI needs to hear about (the calling redux actions CallingClass dispatches).
public enum CallingEvent: Sendable {
    case outgoingCall(conversationId: String, hasLocalAudio: Bool, hasLocalVideo: Bool)
    case incomingDirectCall(conversationId: String, isVideoCall: Bool)
    case callStateChange(conversationId: String, state: CallState, endedReason: CallEndReason?, acceptedTime: Int64?)
    case remoteAudioChange(conversationId: String, hasAudio: Bool)
    case remoteVideoChange(conversationId: String, hasVideo: Bool)
    case remoteSharingScreenChange(conversationId: String, isSharingScreen: Bool)
    case directCallAudioLevels(conversationId: String, local: Double, remote: Double)
    /// A group or call-link call changed (local/remote device states or peek info): read it
    /// from `groupCall(for:)`.
    case groupCallChanged(conversationId: String, mode: CallMode)
    case groupCallEnded(conversationId: String, reason: CallEndReason)
    case groupCallAudioLevels(conversationId: String)
    case groupCallReactions(conversationId: String, reactions: [Reaction])
    case groupCallRaisedHands(conversationId: String, raisedHands: [UInt32])
    case suggestLowerHand(Bool)
    case mutedBy(demuxId: UInt32)
    case observedRemoteMute(source: UInt32, target: UInt32)
    /// A stateless peek finished (`peekNotConnectedGroupCall`).
    case peekResult(conversationId: String, peekInfo: PeekInfo?)
    case incomingGroupRing(conversationId: String, ringId: Int64, ringerAci: String)
    case cancelGroupRing(conversationId: String, ringId: Int64)
    case joinedAdhocCall(roomId: String)
    /// Call history or call links changed in the database.
    case historyChanged
}

public struct CallingConfig: Sendable {
    /// The calling SFU (`sfuUrl`, e.g. https://sfu.voip.signal.org).
    public var sfuURL: URL
    /// Settings → Calls "Always relay calls".
    public var alwaysRelayCalls = false
    /// Settings → Notifications "Incoming calls".
    public var incomingCallNotification = true
    /// `desktop.calling.dredDuration.*` (remote config) or the local override.
    public var dredDuration: Int? = nil
    /// `desktop.calling.enableSvc` and friends.
    public var groupSvc: GroupCallSvcConfig? = nil
    public var callStatsIntervalSecs: Int? = nil
    public init(sfuURL: URL) { self.sfuURL = sfuURL }
}

public enum CallingError: Error, Equatable {
    case noConversation
    case notAGroup
    case noRecipient
    case callLinkRequestFailed(status: Int)
    case missingAdminKey
}

@MainActor
public final class CallingService {
    /// `AUDIO_LEVEL_INTERVAL_MS`
    public static let audioLevelIntervalMillis = 200
    /// `OUTGOING_SIGNALING_WAIT`
    static let outgoingSignalingWait: Duration = .seconds(15)
    /// SVC defaults (`SVC_DEFAULT_MODE`, `…_FOR_SCREENSHARE`, ts/calling/constants).
    public static let svcDefaultMode = "L3T3_KEY"
    public static let svcDefaultModeForScreenshare = "L1T3"

    public let rtc: RingRTC
    public var config: CallingConfig
    public var onEvent: ((CallingEvent) -> Void)?

    let account: Account
    let database: SignalDatabase
    let socket: SocketManager
    let http: HTTPClient
    let messenger: Messenger
    let groups: GroupsAPI
    let credentials: GroupCredentials

    enum ActiveCall {
        case direct(Call)
        case group(GroupCall)
    }

    /// `#callsLookup`: conversation id (or room id for call links) → its call.
    var callsLookup: [String: ActiveCall] = [:]
    /// GroupCall keeps its observer weakly.
    var observers: [String: GroupObserver] = [:]
    var iceServersCache: (servers: [IceServer], expires: Date)?
    var adhocProfileKeysSent = Set<String>()
    /// Upstream `#cameraEnabled`: whether the camera should send once a call is accepted.
    public internal(set) var cameraEnabled = false
    /// Called when a call should start or stop sending camera frames (Phase 6 step 3).
    public var onCameraNeeded: ((Bool) -> Void)?

    public init(account: Account, database: SignalDatabase, socket: SocketManager, http: HTTPClient, messenger: Messenger, groups: GroupsAPI,
                credentials: GroupCredentials, config: CallingConfig, fieldTrials: [String: String] = [:]) throws {
        self.account = account
        self.database = database
        self.socket = socket
        self.http = http
        self.messenger = messenger
        self.groups = groups
        self.credentials = credentials
        self.config = config
        rtc = try RingRTC(fieldTrials: fieldTrials)
        try rtc.setSelfUuid(Self.uuidBytes(account.aci))
        wire()
    }

    /// Registers the "call link refresh" job; call before `jobs.start()`.
    public func register() async {
        await messenger.jobs.register(CallLinkRefreshJob.queueType, handler: { [weak self] job in
            let data = try job.decode(CallLinkRefreshJob.self)
            guard let self else { throw JobError.permanent("calling stopped") }
            try await self.refreshCallLink(data)
        })
    }

    func emit(_ e: CallingEvent) { onEvent?(e) }

    // MARK: wiring

    func wire() {
        rtc.handleOutgoingSignaling = { [weak self] userId, message in
            await self?.handleOutgoingSignaling(userId, message, urgency: nil) ?? false
        }
        rtc.handleIncomingCall = { [weak self] call in await self?.handleIncomingCall(call) ?? false }
        rtc.handleStartCall = { [weak self] call in await self?.handleStartCall(call) ?? false }
        rtc.handleRejectedIncomingCallRequest = { [weak self] callId, remoteUserId, reason, age, wasVideo, _, _ in
            self?.handleRejectedIncomingCallRequest(callId: callId, remoteUserId: remoteUserId, reason: reason, ageSec: age, wasVideoCall: wasVideo)
        }
        rtc.handleSendHttpRequest = { [weak self] requestId, url, method, headers, body in
            self?.handleSendHttpRequest(requestId: requestId, url: url, method: method, headers: headers, body: body)
        }
        rtc.handleSendCallMessage = { [weak self] recipient, data, urgency in
            guard let self, let userId = Self.uuidString(recipient) else { return }
            Task { @MainActor in
                _ = await self.handleOutgoingSignaling(userId, CallingMessage(opaque: OpaqueMessage(data: data)), urgency: urgency)
            }
        }
        rtc.handleSendCallMessageToGroup = { [weak self] groupId, data, urgency, overrideRecipients in
            guard let self else { return }
            Task { @MainActor in await self.handleSendCallMessageToGroup(groupId: groupId, data: data, urgency: urgency, overrideRecipients: overrideRecipients) }
        }
        rtc.handleGroupCallRingUpdate = { [weak self] groupId, ringId, ringer, update in
            guard let self else { return }
            Task { @MainActor in await self.handleGroupCallRingUpdate(groupId: groupId, ringId: ringId, ringer: ringer, update: update) }
        }
    }

    // MARK: identifiers

    static func uuidBytes(_ serviceId: String) -> Data {
        let raw = serviceId.hasPrefix("ACI:") ? String(serviceId.dropFirst(4)) : serviceId
        return UUID(uuidString: raw)?.data ?? Data()
    }

    static func uuidString(_ bytes: Data) -> String? {
        guard bytes.count == 16 else { return nil }
        return UUID(uuid: bytes.uuidTuple).uuidString.lowercased()
    }

    var localDeviceId: SignalRingRTC.DeviceId { account.deviceId }

    func conversation(serviceId: String) async throws -> String {
        try await database.pool.write { db in try MessageStore.privateConversation(db, serviceId: serviceId) }
    }

    // MARK: outgoing signalling

    /// `#handleOutgoingSignaling`: 1:1 call messages go to every device of the peer. Offers and
    /// urgent opaque messages wake the recipient; the send must finish within 15 s.
    func handleOutgoingSignaling(_ remoteUserId: UserId, _ message: CallingMessage, urgency: CallMessageUrgency?) async -> Bool {
        let urgent = urgency == .handleImmediately || message.offer != nil
        var content = Signalservice_Content()
        content.callMessage = Self.proto(message, urgency: urgency)
        let payload = OutgoingPayload(content: content, timestamp: UInt64(MessageStore.now()), contentHint: .default, urgent: urgent)
        let sender = messenger.sender
        let send = Task { () -> Bool in
            do {
                _ = try await sender.send(payload, to: remoteUserId)
                return true
            } catch {
                return false
            }
        }
        let timeout = Task { () -> Bool in
            try? await Task.sleep(for: Self.outgoingSignalingWait)
            send.cancel()
            return false
        }
        let ok = await send.value
        timeout.cancel()
        return ok
    }

    /// `#handleSendCallMessageToGroup`: opaque group-call messages (the first one rings).
    func handleSendCallMessageToGroup(groupId: Data, data: Data, urgency: CallMessageUrgency, overrideRecipients: [Data]) async {
        guard let stored = try? await database.pool.read({ db in try GroupStore.find(db, groupId: groupId) }), let state = stored.state else { return }
        let recipients = overrideRecipients.isEmpty ? state.membersV2.map(\.aci) : overrideRecipients.compactMap(Self.uuidString)
        var content = Signalservice_Content()
        content.callMessage = Self.proto(CallingMessage(opaque: OpaqueMessage(data: data)), urgency: urgency)
        let payload = OutgoingPayload(content: content, timestamp: UInt64(MessageStore.now()), contentHint: .default, urgent: urgency == .handleImmediately)
        _ = try? await messenger.groupSender.send(payload, keys: stored.keys, recipients: recipients)
    }

    // MARK: incoming signalling

    /// `handleCallingMessage`: a CallMessage from the receive pipeline.
    public func handleCallingMessage(_ e: CallMessageEnvelope) async {
        let m = e.message
        if m.hasOffer, !config.incomingCallNotification { return }
        let ourAci = account.aci
        let info = try? await database.pool.write { db -> (senderKey: Data?, conversationId: String, accepted: Bool) in
            let conversationId = try MessageStore.privateConversation(db, serviceId: e.sender)
            return (try ProtocolStore.identityKeyBytes(db, serviceId: e.sender), conversationId,
                    try ConversationState.isAccepted(db, conversationId: conversationId, ourAci: ourAci, ignoreEmptyConvo: true))
        }
        guard let info, let senderKey = info.senderKey, senderKey.count == 33 else { return }
        if m.hasOffer, !info.accepted {
            // Calls on our PNI are dropped; on our ACI the caller is told we need to accept first.
            if e.destinationIsPni { return }
            let callId = m.offer.id
            _ = await handleOutgoingSignaling(e.sender, CallingMessage(hangup: HangupMessage(callId: callId, type: .needPermission, deviceId: e.senderDevice)),
                                              urgency: nil)
            let event = CallEventDetails(details: CallDetails(callId: String(callId), peerId: e.sender, ringerId: e.sender, startedById: nil, mode: .direct,
                                                              type: m.offer.type == .offerVideoCall ? .video : .audio, direction: .incoming,
                                                              timestamp: Int64(e.timestamp)),
                                         event: .local(.missed), eventSource: "CallingClass.handleCallingMessage", eventTimestamp: Int64(e.timestamp))
            await updateCallHistory(event)
            return
        }
        let ageSec = max(0, (e.receivedAt - Int64(e.serverTimestamp)) / 1000)
        rtc.handleCallingMessage(Self.callingMessage(m), RingRTC.CallingMessageOptions(
            remoteUserId: e.sender, remoteUuid: Self.uuidBytes(e.sender), remoteDeviceId: e.senderDevice, localDeviceId: localDeviceId,
            ageSec: Int(ageSec), receivedAtCounter: 0, receivedAtDate: e.receivedAt,
            senderIdentityKey: senderKey.dropFirst(), receiverIdentityKey: account.aciIdentity.publicKey.serialize().dropFirst()))
    }

    /// `#handleIncomingCall`: blocked → ignore; muted (without notify-for-calls) or a peer
    /// whose safety number changed → a missed call; otherwise ring.
    func handleIncomingCall(_ call: Call) async -> Bool {
        let peer = call.remoteUserId
        guard let state = try? await database.pool.write({ db -> (conversationId: String, blocked: Bool, muted: Bool, verified: VerifiedStatus) in
            let id = try MessageStore.privateConversation(db, serviceId: peer)
            return (id, try MessageModifiers.isBlocked(db, conversationId: id, sender: peer), try Self.isMutedForCalls(db, conversationId: id),
                    try ProtocolStore.verifiedStatus(db, serviceId: peer))
        }) else { return false }
        if state.blocked { return false }
        if state.muted || state.verified == .unverified {
            await updateCallHistory(directEvent(call, .missed, timestamp: MessageStore.now(), source: "CallingClass.handleIncomingCall"))
            return false
        }
        if call.endedReason != nil { return false }
        attach(call, conversationId: state.conversationId)
        emit(.incomingDirectCall(conversationId: state.conversationId, isVideoCall: call.isVideoCall))
        return true
    }

    /// Muted with calls not allowed through (`getNotifyWhileMutedForConversation(…).calls`).
    nonisolated static func isMutedForCalls(_ db: Database, conversationId: String) throws -> Bool {
        let json = try String.fetchOne(db, sql: "SELECT json FROM conversations WHERE id = ?", arguments: [conversationId]).map(MessageStore.jsonObject) ?? [:]
        let until = (json["muteExpiresAt"] as? NSNumber)?.int64Value ?? 0
        guard until > MessageStore.now() else { return false }
        let global: Bool? = try Items.get(db, "notifyForCallsIfMuted")
        let notify = json["notifyForCallsIfMuted"] as? Bool ?? global ?? false
        return !notify
    }

    /// `#handleRejectedIncomingCallRequest`: every rejection is a missed call, dated by the
    /// offer's age.
    func handleRejectedIncomingCallRequest(callId: CallId, remoteUserId: UserId, reason: CallRejectReason, ageSec: Double, wasVideoCall: Bool) {
        let ageMs = ageSec.isFinite && ageSec >= 0 ? Int64(ageSec * 1000) : 0
        let timestamp = MessageStore.now() - ageMs
        let event = CallEventDetails(details: CallDetails(callId: String(callId), peerId: remoteUserId, ringerId: remoteUserId, startedById: nil,
                                                          mode: .direct, type: wasVideoCall ? .video : .audio, direction: .incoming, timestamp: timestamp),
                                     event: .local(.missed), eventSource: "CallingClass.handleRejectedIncomingCallRequest", eventTimestamp: timestamp)
        Task { @MainActor in
            if reason != .receivedOfferWhileActive, let id = try? await self.conversation(serviceId: remoteUserId) {
                self.emit(.callStateChange(conversationId: id, state: .ended, endedReason: nil, acceptedTime: nil))
            }
            await self.updateCallHistory(event)
        }
    }

    /// `#handleStartCall`: ICE servers and settings; IP hiding for non-connections.
    func handleStartCall(_ call: Call) async -> Bool {
        if call.endedReason != nil { return false }
        let servers = await iceServers()
        if call.endedReason != nil { return false }
        let peer = call.remoteUserId
        let ourAci = account.aci
        let connection = (try? await database.pool.read { db -> Bool in
            guard let row = try Row.fetchOne(db, sql: "SELECT serviceId, json FROM conversations WHERE serviceId = ? AND type = 'private'", arguments: [peer]) else {
                return false
            }
            let json = try MessageStore.jsonObject(row["json"])
            return json["removalStage"] == nil && ConversationState.isTrusted(db, privateConversation: json, serviceId: row["serviceId"], ourAci: ourAci)
                && (try? MessageModifiers.isBlocked(db, conversationId: "", sender: peer)) != true
        }) ?? false
        rtc.proceed(callId: call.callId, settings: CallSettings(
            iceServers: servers, hideIp: config.alwaysRelayCalls || !connection, dataMode: .normal,
            audioLevelsIntervalMillis: Self.audioLevelIntervalMillis, dredDuration: config.dredDuration,
            statsIntervalSecs: config.callStatsIntervalSecs))
        return true
    }

    // MARK: ICE relays

    nonisolated struct RelaysResponse: Decodable, Sendable {
        struct Relay: Decodable, Sendable {
            var urls: [String]?
            var urlsWithIps: [String]?
            var hostname: String?
            var username: String?
            var password: String?
            var ttl: Int?
        }
        var relays: [Relay]?
    }

    /// `#getIceServers`: `/v2/calling/relays`, two entries per relay (IP URLs with the
    /// hostname first, then the named URLs), cached for the shortest TTL.
    func iceServers() async -> [IceServer] {
        if let cache = iceServersCache, Date() < cache.expires { return cache.servers }
        guard let data = try? await socket.authenticatedRequest("GET", "/v2/calling/relays"),
              let response = try? JSONDecoder().decode(RelaysResponse.self, from: data) else { return [] }
        let servers = Self.iceServers(response)
        let minTTL = (response.relays ?? []).map { $0.ttl ?? 0 }.min() ?? 0
        if !servers.isEmpty { iceServersCache = (servers, Date().addingTimeInterval(TimeInterval(minTTL))) }
        return servers
    }

    nonisolated static func iceServers(_ r: RelaysResponse) -> [IceServer] {
        (r.relays ?? []).flatMap { relay in
            [IceServer(username: relay.username, password: relay.password, hostname: relay.hostname ?? "", urls: relay.urlsWithIps ?? []),
             IceServer(username: relay.username, password: relay.password, hostname: "", urls: relay.urls ?? [])]
        }
    }

    // MARK: SFU HTTP

    /// `#handleSendHttpRequest`: ringrtc's SFU requests over our HTTPS client. Error statuses
    /// reach ringrtc with an empty body; transport failures as failures.
    func handleSendHttpRequest(requestId: UInt32, url: String, method: HttpMethod, headers: [String: String], body: Data?) {
        guard let u = URL(string: url), u.scheme == "https" || u.scheme == "http" else {
            rtc.httpRequestFailed(requestId: requestId, debugInfo: "bad url")
            return
        }
        let name = switch method {
        case .get: "GET"
        case .put: "PUT"
        case .post: "POST"
        case .delete: "DELETE"
        }
        let http = self.http
        Task { @MainActor in
            do {
                let r = try await http.send(name, u, body: body, headers: headers)
                self.rtc.receivedHttpResponse(requestId: requestId, status: r.status, body: r.body)
            } catch HTTPError.status(let code, _) {
                self.rtc.receivedHttpResponse(requestId: requestId, status: code, body: Data())
            } catch {
                self.rtc.httpRequestFailed(requestId: requestId, debugInfo: "\(error)")
            }
        }
    }

    // MARK: direct calls

    /// `startOutgoingDirectCall`
    public func startOutgoingDirectCall(conversationId: String, hasLocalAudio: Bool, hasLocalVideo: Bool) async throws {
        guard let peer = try await database.pool.read({ db in
            try String.fetchOne(db, sql: "SELECT serviceId FROM conversations WHERE id = ? AND type = 'private'", arguments: [conversationId])
        }) else { throw CallingError.noRecipient }
        if let call = rtc.call, call.state != .ended { return }
        let call = try rtc.startOutgoingCall(remoteUserId: peer, isVideoCall: hasLocalVideo, localDeviceId: localDeviceId)
        // Call messages carry no profile key: share it now (`ProfileKeyForCall`).
        try await database.pool.write { db in
            try MessageStore.updateConversationJSON(db, conversationId: conversationId) { $0["profileSharing"] = true }
        }
        sendProfileKey(to: peer)
        cameraEnabled = hasLocalVideo
        call.setOutgoingAudioMuted(!hasLocalAudio)
        call.setOutgoingVideoMuted(!hasLocalVideo)
        attach(call, conversationId: conversationId)
        emit(.outgoingCall(conversationId: conversationId, hasLocalAudio: hasLocalAudio, hasLocalVideo: hasLocalVideo))
    }

    /// `ProfileKeyForCall`: a profile-key update DataMessage to one contact.
    func sendProfileKey(to serviceId: String) {
        guard let profileKey = account.profileKey else { return }
        var data = Signalservice_DataMessage()
        data.timestamp = UInt64(MessageStore.now())
        data.profileKey = profileKey
        data.flags = ConversationState.profileKeyUpdateFlag
        var content = Signalservice_Content()
        content.dataMessage = data
        let payload = OutgoingPayload(content: content, timestamp: data.timestamp, contentHint: .resendable, urgent: false)
        let sender = messenger.sender
        Task { _ = try? await sender.send(payload, to: serviceId) }
    }

    public func acceptDirectCall(conversationId: String, asVideoCall: Bool) {
        guard case .direct(let call)? = callsLookup[conversationId] else { return }
        cameraEnabled = asVideoCall
        call.setOutgoingAudioMuted(false)
        call.setOutgoingVideoMuted(!asVideoCall)
        rtc.accept(call.callId)
    }

    public func declineDirectCall(conversationId: String) {
        guard case .direct(let call)? = callsLookup[conversationId] else { return }
        rtc.decline(call.callId)
    }

    public func directCall(for conversationId: String) -> Call? {
        if case .direct(let c)? = callsLookup[conversationId] { return c }
        return nil
    }

    public func groupCall(for conversationId: String) -> GroupCall? {
        if case .group(let g)? = callsLookup[conversationId] { return g }
        return nil
    }

    public var activeConversationIds: Set<String> { Set(callsLookup.keys) }

    /// `#attachToCall`: state changes become call history and UI events.
    func attach(_ call: Call, conversationId: String) {
        callsLookup[conversationId] = .direct(call)
        var acceptedTime: Int64? = nil
        call.handleStateChanged = { [weak self, weak call] in
            guard let self, let call else { return }
            if call.state == .accepted {
                acceptedTime = acceptedTime ?? MessageStore.now()
                if self.cameraEnabled { self.onCameraNeeded?(true) }
            }
            if call.state == .ended {
                self.onCameraNeeded?(false)
                self.callsLookup[conversationId] = nil
            }
            if let local = Self.localEvent(call) {
                let event = self.directEvent(call, local, timestamp: MessageStore.now(), source: "call.handleStateChanged")
                Task { @MainActor in await self.updateCallHistory(event) }
            }
            self.emit(.callStateChange(conversationId: conversationId, state: call.state, endedReason: call.endedReason, acceptedTime: acceptedTime))
        }
        call.handleRemoteAudioEnabled = { [weak self, weak call] in
            guard let call else { return }
            self?.emit(.remoteAudioChange(conversationId: conversationId, hasAudio: call.remoteAudioEnabled))
        }
        call.handleRemoteVideoEnabled = { [weak self, weak call] in
            guard let call else { return }
            self?.emit(.remoteVideoChange(conversationId: conversationId, hasVideo: call.remoteVideoEnabled))
        }
        call.handleRemoteSharingScreen = { [weak self, weak call] in
            guard let call else { return }
            self?.emit(.remoteSharingScreenChange(conversationId: conversationId, isSharingScreen: call.remoteSharingScreen))
        }
        call.handleAudioLevels = { [weak self, weak call] in
            guard let call else { return }
            self?.emit(.directCallAudioLevels(conversationId: conversationId, local: Double(call.outgoingAudioLevel), remote: Double(call.remoteAudioLevel)))
        }
    }

    /// `getLocalCallEventFromDirectCall`
    static func localEvent(_ call: Call) -> LocalCallEvent? {
        switch call.state {
        case .accepted: .accepted
        case .ringing: .ringing
        case .ended: CallHistoryTransitions.eventForEndedReason(endedReasonName(call.endedReason))
        default: nil
        }
    }

    /// `#convertRingRtcDirectCallEndReason` (as the CallEndedReason name).
    static func endedReasonName(_ r: CallEndReason?) -> String {
        switch r {
        case .localHangup: "LocalHangup"
        case .remoteHangup: "RemoteHangup"
        case .remoteHangupNeedPermission: "RemoteHangupNeedPermission"
        case .remoteHangupAccepted: "AcceptedOnAnotherDevice"
        case .remoteHangupDeclined: "DeclinedOnAnotherDevice"
        case .remoteHangupBusy: "BusyOnAnotherDevice"
        case .remoteBusy: "Busy"
        case .remoteGlare: "Glare"
        case .remoteReCall: "ReCall"
        case .timeout: "Timeout"
        case .internalFailure: "InternalFailure"
        case .signalingFailure: "SignalingFailure"
        case .connectionFailure: "ConnectionFailure"
        default: "UnexpectedReason"
        }
    }

    /// `getCallDetailsFromDirectCall` + `getCallEventDetails`
    func directEvent(_ call: Call, _ event: LocalCallEvent, timestamp: Int64, source: String) -> CallEventDetails {
        CallEventDetails(details: CallDetails(callId: String(call.callId), peerId: call.remoteUserId,
                                              ringerId: call.isIncoming ? call.remoteUserId : account.aci, startedById: nil, mode: .direct,
                                              type: call.isVideoCall ? .video : .audio, direction: call.isIncoming ? .incoming : .outgoing,
                                              timestamp: timestamp),
                         event: .local(event), eventSource: source, eventTimestamp: timestamp)
    }

    // MARK: media and hangup

    public func setOutgoingAudio(conversationId: String, enabled: Bool) {
        switch callsLookup[conversationId] {
        case .direct(let c)?: c.setOutgoingAudioMuted(!enabled)
        case .group(let g)?: g.setOutgoingAudioMuted(!enabled)
        case nil: break
        }
    }

    public func setOutgoingVideo(conversationId: String, enabled: Bool) {
        cameraEnabled = enabled
        switch callsLookup[conversationId] {
        case .direct(let c)?: c.setOutgoingVideoMuted(!enabled)
        case .group(let g)?: g.setOutgoingVideoMuted(!enabled)
        case nil: break
        }
        onCameraNeeded?(enabled && callsLookup[conversationId] != nil)
    }

    /// `hangup` / `hangupAllCalls`: upstream ends every call (only one is active at a time).
    public func hangup(excludeRinging: Bool = false) {
        onCameraNeeded?(false)
        for call in callsLookup.values {
            switch call {
            case .direct(let c):
                c.setOutgoingAudioMuted(true)
                c.setOutgoingVideoMuted(true)
                if !(excludeRinging && c.state == .ringing && c.isIncoming) { rtc.hangup(c.callId) }
            case .group(let g):
                g.setOutgoingAudioMuted(true)
                g.setOutgoingVideoMuted(true)
                g.disconnect()
            }
        }
        Task { _ = try? await self.rtc.setMicrophoneWarmupEnabled(false) }
    }

    /// Whether we are presenting (frames are then the screen share's, not the camera's).
    public internal(set) var isPresenting = false

    /// `#startPresenting` / `#stopPresenting`: the call's video becomes the screen share
    /// (ScreenShareCapture's frames, 2880×1800@5) and back to the camera, if it was on.
    public func setPresenting(conversationId: String, _ presenting: Bool) {
        guard let call = callsLookup[conversationId] else { return }
        isPresenting = presenting
        if presenting {
            onCameraNeeded?(false)
            switch call {
            case .direct(let c):
                c.setOutgoingVideoIsScreenShare(true)
                c.setOutgoingVideoMuted(false)
            case .group(let g):
                g.setOutgoingVideoIsScreenShare(true)
                g.setPresenting(true)
                g.setOutgoingVideoMuted(false)
            }
        } else {
            switch call {
            case .direct(let c):
                c.setOutgoingVideoMuted(!cameraEnabled)
                c.setOutgoingVideoIsScreenShare(false)
            case .group(let g):
                g.setOutgoingVideoMuted(!cameraEnabled)
                g.setOutgoingVideoIsScreenShare(false)
                g.setPresenting(false)
            }
            if cameraEnabled { onCameraNeeded?(true) }
        }
    }

    /// The system microphone mute changed (MuteState): every call follows, as upstream's
    /// `muteStateChange.subscribe`.
    public func systemMuteChanged(_ muted: Bool) {
        for call in callsLookup.values {
            switch call {
            case .direct(let c): c.setOutgoingAudioMuted(muted)
            case .group(let g): g.setOutgoingAudioMuted(muted)
            }
        }
    }

    /// The call (direct or group) for sending camera frames.
    public func sendVideoFrame(width: Int, height: Int, format: VideoPixelFormat, buffer: [UInt8]) {
        for call in callsLookup.values {
            switch call {
            case .direct(let c): c.sendVideoFrame(width: width, height: height, format: format, buffer: buffer)
            case .group(let g): g.sendVideoFrame(width: width, height: height, format: format, buffer: buffer)
            }
        }
    }

    // MARK: call history

    /// `updateCallHistoryFromLocalEvent`: apply, then sync the result to our other devices.
    func updateCallHistory(_ event: CallEventDetails) async {
        let active = activeConversationIds
        let isAdhoc = event.details.mode == .adhoc
        let result: CallHistoryDetails?
        do {
            result = try await database.pool.write { db -> CallHistoryDetails? in
            if isAdhoc {
                let prev = try CallHistoryStore.get(db, callId: event.details.callId, peerId: event.details.peerId)
                guard let next = try? CallHistoryTransitions.transition(prev, event), next != prev else { return nil }
                try CallHistoryStore.save(db, next)
                return next
            }
            return try CallHistoryStore.apply(db, event, activeCallConversationIds: active)
            }
        } catch {
            return
        }
        emit(.historyChanged)
        guard let updated = result, let proto = CallHistoryProto.proto(updated) else { return }
        var sync = Messenger.syncMessage()
        sync.callEvent = proto
        try? await messenger.sendToSelf(sync, timestamp: UInt64(MessageStore.now()), urgent: false, messageIds: [])
    }

    /// `clearCallHistoryDataAndSync`
    public func clearCallHistory() async throws {
        guard let latest = try await database.pool.read({ db in try CallHistoryStore.all(db, limit: 1).first }) else { return }
        try await database.pool.write { db in
            try CallHistoryStore.clear(db, before: latest)
            try CallLinkStore.markAllDeleted(db, at: MessageStore.now())
        }
        emit(.historyChanged)
        var sync = Messenger.syncMessage()
        sync.callLogEvent = CallHistoryProto.logEvent(type: .clear, latest: latest)
        try await messenger.sendToSelf(sync, timestamp: UInt64(MessageStore.now()), urgent: false, messageIds: [])
    }

    /// `markAllCallHistoryReadAndSync`
    public func markCallHistoryRead(conversationId: String? = nil) async throws {
        guard let latest = try await database.pool.read({ db in try CallHistoryStore.all(db, limit: 1).first }) else { return }
        _ = try await database.pool.write { db in try CallHistoryStore.markRead(db, before: latest, conversationId: conversationId) }
        emit(.historyChanged)
        var sync = Messenger.syncMessage()
        sync.callLogEvent = CallHistoryProto.logEvent(type: conversationId == nil ? .markedAsRead : .markedAsReadInConversation, latest: latest)
        try await messenger.sendToSelf(sync, timestamp: UInt64(MessageStore.now()), urgent: false, messageIds: [])
    }

    // MARK: calling message conversion (`callingMessageToProto`, `protoToCallingMessage`)

    static func proto(_ m: CallingMessage, urgency: CallMessageUrgency?) -> Signalservice_CallMessage {
        var p = Signalservice_CallMessage()
        if let o = m.offer {
            var x = Signalservice_CallMessage.Offer()
            x.id = o.callId
            x.type = o.type == .videoCall ? .offerVideoCall : .offerAudioCall
            x.opaque = o.opaque
            p.offer = x
        }
        if let a = m.answer {
            var x = Signalservice_CallMessage.Answer()
            x.id = a.callId
            x.opaque = a.opaque
            p.answer = x
        }
        if let ice = m.iceCandidates {
            p.iceUpdate = ice.map { c in
                var x = Signalservice_CallMessage.IceUpdate()
                x.id = c.callId
                x.opaque = c.opaque
                return x
            }
        }
        if let b = m.busy {
            var x = Signalservice_CallMessage.Busy()
            x.id = b.callId
            p.busy = x
        }
        if let h = m.hangup {
            var x = Signalservice_CallMessage.Hangup()
            x.id = h.callId
            x.type = Signalservice_CallMessage.Hangup.TypeEnum(rawValue: h.type.rawValue) ?? .hangupNormal
            x.deviceID = h.deviceId
            p.hangup = x
        }
        if let d = m.destinationDeviceId { p.destinationDeviceID = d }
        if m.opaque != nil || urgency != nil {
            var x = Signalservice_CallMessage.Opaque()
            if let data = m.opaque?.data { x.data = data }
            if let urgency { x.urgency = urgency == .handleImmediately ? .handleImmediately : .droppable }
            p.opaque = x
        }
        return p
    }

    static func callingMessage(_ p: Signalservice_CallMessage) -> CallingMessage {
        var m = CallingMessage()
        if p.hasOffer, p.offer.id != 0, !p.offer.opaque.isEmpty {
            m.offer = OfferMessage(callId: p.offer.id, type: p.offer.type == .offerVideoCall ? .videoCall : .audioCall, opaque: p.offer.opaque)
        }
        if p.hasAnswer, p.answer.id != 0, !p.answer.opaque.isEmpty { m.answer = AnswerMessage(callId: p.answer.id, opaque: p.answer.opaque) }
        let ice = p.iceUpdate.filter { $0.id != 0 && !$0.opaque.isEmpty }.map { IceCandidateMessage(callId: $0.id, opaque: $0.opaque) }
        if !ice.isEmpty { m.iceCandidates = ice }
        if p.hasBusy, p.busy.id != 0 { m.busy = BusyMessage(callId: p.busy.id) }
        if p.hasHangup, p.hangup.id != 0 {
            m.hangup = HangupMessage(callId: p.hangup.id, type: HangupType(rawValue: p.hangup.type.rawValue) ?? .normal, deviceId: p.hangup.deviceID)
        }
        if p.hasDestinationDeviceID { m.destinationDeviceId = p.destinationDeviceID }
        if p.hasOpaque { m.opaque = OpaqueMessage(data: p.opaque.hasData ? p.opaque.data : nil) }
        return m
    }
}

extension ProtocolStore {
    /// The stored identity key (33 bytes, type prefix included).
    static func identityKeyBytes(_ db: Database, serviceId: String) throws -> Data? {
        guard let json = try String.fetchOne(db, sql: "SELECT json FROM identityKeys WHERE id = ?", arguments: [serviceId]) else { return nil }
        return (try MessageStore.jsonObject(json)["publicKey"] as? String).flatMap { Data(base64Encoded: $0) }
    }
}
