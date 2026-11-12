// `RingRTCType` (Service.ts): the app's entry point to ringrtc. It owns the endpoint, the
// current 1:1 call and the group calls by client id, turns events into the handler calls
// Signal Desktop's CallingClass implements, and settles request/response pairs (peek, call
// links, audio devices) as async results. Everything runs on the main actor, as upstream
// runs on Node's event loop.
//
// The endpoint lives in the calling service (Endpoint.swift), a process that reads what remote
// peers send, so what it asks of the app is checked here before it reaches a handler (stricter
// than upstream, where ringrtc shares the app's process): call signalling only to the peer of a
// call it has or an offer we passed it, call messages only to ourselves, the members of a
// group call it runs (or a call link's participants), group messages only to a group with a
// call, a new incoming call only for an offer we passed it, a group ring only from someone whose
// call message we passed it. Verification/CallBoundary models and proves these.

import Foundation

@MainActor
public final class RingRTC {
    /// Field trials upstream always sets (NativeCallManager.createCallEndpoint).
    public static let defaultFieldTrials: [String: String] = [
        "RingRTC-AnyAddressPortsKillSwitch": "Enabled",
        "RingRTC-PruneTurnPorts": "Enabled",
        "WebRTC-Audio-NetEqSmartFlushing": "enabled:false",
        "WebRTC-Bwe-ProbingConfiguration": "skip_if_est_larger_than_fraction_of_max:0.99,probe_max_allocation_without_alr:false",
        "WebRTC-IncreaseIceCandidatePriorityHostSrflx": "Enabled",
    ]

    var endpoint: any RingRTCEndpoint
    let makeEndpoint: RingRTCEndpointFactory
    var pump = EventPump()
    public internal(set) var call: Call?
    var groupCallByClientId: [GroupCallClientId: GroupCall] = [:]
    var peekRequests = Requests<HttpResult<PeekInfo>>()
    var callLinkRequests = Requests<HttpResult<CallLinkState>>()
    var emptyRequests = Requests<HttpResult<Bool>>()
    var audioDeviceRequests = Requests<AudioDevice?>()
    struct CallInfo { var isVideoCall: Bool; var receivedAtCounter: Int; var receivedAtDate: Int64; var peer: UserId }
    var callInfoByCallId: [CallId: CallInfo] = [:]
    /// Groups we cancelled a ring for, and when: the cancel goes out to the group after its
    /// call client may be gone.
    var cancelledRings: [GroupId: Date] = [:]
    /// Senders of the call messages passed to ringrtc, and when (group rings come from them).
    var callMessageSenders: [Data: Date] = [:]
    /// Our own uuid (`setSelfUuid`): ringrtc tells our other devices about rings and keys.
    public internal(set) var selfUuid: Data?
    static let recentWindow: TimeInterval = 120

    // Handlers (Service.ts `handle*`).
    public var handleOutgoingSignaling: ((UserId, CallingMessage) async -> Bool)?
    public var handleIncomingCall: ((Call) async -> Bool)?
    public var handleStartCall: ((Call) async -> Bool)?
    public var handleOutputDeviceChanged: ((AudioDeviceList) -> Void)?
    public var handleInputDeviceChanged: ((AudioDeviceList) -> Void)?
    public var handleSettleStartPlayback: ((Bool, AudioDevice?) -> Void)?
    public var handleSettleStartRecording: ((Bool, AudioDevice?) -> Void)?
    public var handleRejectedIncomingCallRequest: ((_ callId: CallId, _ remoteUserId: UserId, _ reason: CallRejectReason, _ ageSec: Double,
                                                    _ wasVideoCall: Bool, _ receivedAtCounter: Int?, _ receivedAtDate: Int64?) -> Void)?
    public var handleLogMessage: ((CallLogLevel, String, Int, String) -> Void)?
    public var handleSendHttpRequest: ((_ requestId: UInt32, _ url: String, _ method: HttpMethod, _ headers: [String: String], _ body: Data?) -> Void)?
    public var handleSendCallMessage: ((_ recipientUuid: Data, _ message: Data, _ urgency: CallMessageUrgency) -> Void)?
    public var handleSendCallMessageToGroup: ((_ groupId: GroupId, _ message: Data, _ urgency: CallMessageUrgency, _ overrideRecipients: [Data]) -> Void)?
    public var handleSendCallMessageToAdhocGroup: ((_ message: Data, _ urgency: CallMessageUrgency, _ expiration: Date,
                                                    _ recipientsAndEndorsements: [(recipientId: Data, endorsement: Data)]) -> Void)?
    public var handleGroupCallRingUpdate: ((_ groupId: GroupId, _ ringId: Int64, _ sender: GroupCallUserId, _ update: RingUpdate) -> Void)?
    public var handleRtcStatsReport: ((String) -> Void)?

    /// `endpoint`: where the endpoint runs (the calling service in the app; RingRTCNative's
    /// `NativeEndpoint.factory` in process).
    public init(fieldTrials: [String: String] = [:], endpoint: @escaping RingRTCEndpointFactory) throws {
        makeEndpoint = endpoint
        self.endpoint = try endpoint(Self.fieldTrialString(fieldTrials))
        startPump()
    }

    isolated deinit {
        pump.stop()
        endpoint.close()
    }

    static func fieldTrialString(_ extra: [String: String]) -> String {
        let trials = defaultFieldTrials.merging(extra) { $1 }
        return trials.sorted { $0.key < $1.key }.map { "\($0.key)/\($0.value)" }.joined(separator: "/") + "/"
    }

    func startPump() {
        let p = EventPump()
        pump = p
        p.start(endpoint) { [weak self] found in
            MainActor.assumeIsolated {
                switch found {
                case .events(let batch): self?.process(batch)
                case .lost(let generation): self?.endpointLost(generation)
                }
            }
        }
    }

    /// `setConfig`: a new endpoint with these field trials.
    public func setConfig(fieldTrials: [String: String]) throws {
        pump.stop()
        endpoint.close()
        endpoint = try makeEndpoint(Self.fieldTrialString(fieldTrials))
        startPump()
    }

    /// The endpoint's process ended: the calls made on it (generations up to `generation`) end
    /// as failed, and the requests waiting on its answers fail. Nothing more is sent for them:
    /// their commands are refused (`Call.generation`).
    func endpointLost(_ generation: UInt64) {
        logError("the calling service ended; its calls end")
        if let call, call.generation <= generation, call.state != .ended {
            callInfoByCallId[call.callId] = nil
            call.endedReason = .internalFailure
            call.state = .ended
        }
        for id in groupCallByClientId.keys.sorted() {
            guard let g = groupCallByClientId[id], g.generation <= generation else { continue }
            groupCallByClientId[id] = nil
            g.observer?.onEnded(g, reason: .internalFailure, summary: CallSummary(.null))
        }
        peekRequests.failAll(.failure(errorStatusCode: -1))
        callLinkRequests.failAll(.failure(errorStatusCode: -1))
        emptyRequests.failAll(.failure(errorStatusCode: -1))
        audioDeviceRequests.failAll(RingRTCError.lost)
    }

    func run(_ name: String, _ fields: [String: JSONValue] = [:]) throws -> JSONValue { try endpoint.command(name, fields) }

    public func setSelfUuid(_ uuid: Data) throws {
        selfUuid = uuid
        _ = try run("setSelfUuid", ["uuid": .bytes(uuid)])
    }

    /// `addAsset` (the Opus DRED weights: group "opus-dred").
    public func addAsset(_ assetGroup: String, content: Data) throws { _ = try run("addAsset", ["assetGroup": .string(assetGroup), "content": .bytes(content)]) }
    public func addAsset(_ assetGroup: String, filePath: String) throws { _ = try run("addAsset", ["assetGroup": .string(assetGroup), "filePath": .string(filePath)]) }

    // MARK: 1:1 calls

    public func startOutgoingCall(remoteUserId: UserId, isVideoCall: Bool, localDeviceId: DeviceId) throws -> Call {
        let id = try run("createOutgoingCall", ["peerId": .string(remoteUserId), "videoEnabled": .bool(isVideoCall), "localDeviceId": .int(Int64(localDeviceId))])
        let call = Call(endpoint: endpoint, remoteUserId: remoteUserId, callId: id.uint64 ?? 0, isIncoming: false, isVideoCall: isVideoCall, state: .prering,
                        generation: endpoint.generation)
        self.call = call
        return call
    }

    public func cancelGroupRing(groupId: GroupId, ringId: Int64, reason: RingCancelReason?) {
        cancelledRings[groupId] = Date()
        _ = try? run("cancelGroupRing", ["groupId": .bytes(groupId), "ringId": .string(String(ringId)), "reason": reason.map { .int(Int64($0.rawValue)) } ?? .null])
    }

    public func proceed(callId: CallId, settings: CallSettings) {
        _ = try? run("proceed", [
            "callId": .id(callId),
            "iceServers": .array(settings.iceServers.map {
                .object(["username": .string($0.username ?? ""), "password": .string($0.password ?? ""), "hostname": .string($0.hostname ?? ""), "urls": .array($0.urls.map { .string($0) })])
            }),
            "hideIp": .bool(settings.hideIp),
            "callConfig": .object([
                "dataMode": .int(Int64(settings.dataMode.rawValue)),
                "dredDuration": .int(Int64(settings.dredDuration ?? 0)),
                "enableVp9Encode": .bool(settings.enableVp9Encode ?? true),
                "enableVp9Decode": .bool(settings.enableVp9Decode ?? true),
                "statsIntervalSecs": settings.statsIntervalSecs.map { .int(Int64($0)) } ?? .null,
            ]),
            "audioLevelsIntervalMillis": .int(Int64(settings.audioLevelsIntervalMillis ?? 0)),
        ])
    }

    public func getCall(_ callId: CallId) -> Call? { call?.callId == callId ? call : nil }
    public func accept(_ callId: CallId) { getCall(callId)?.accept() }
    public func decline(_ callId: CallId) { getCall(callId)?.decline() }
    public func ignore(_ callId: CallId) { getCall(callId)?.ignore() }
    public func hangup(_ callId: CallId) { getCall(callId)?.hangup() }

    // MARK: incoming signaling

    public struct CallingMessageOptions: Sendable {
        public var remoteUserId: UserId
        public var remoteUuid: Data?
        public var remoteDeviceId: DeviceId
        public var localDeviceId: DeviceId
        public var ageSec: Int
        public var receivedAtCounter: Int
        public var receivedAtDate: Int64
        public var senderIdentityKey: Data
        public var receiverIdentityKey: Data
        public init(remoteUserId: UserId, remoteUuid: Data?, remoteDeviceId: DeviceId, localDeviceId: DeviceId, ageSec: Int, receivedAtCounter: Int,
                    receivedAtDate: Int64, senderIdentityKey: Data, receiverIdentityKey: Data) {
            self.remoteUserId = remoteUserId
            self.remoteUuid = remoteUuid
            self.remoteDeviceId = remoteDeviceId
            self.localDeviceId = localDeviceId
            self.ageSec = ageSec
            self.receivedAtCounter = receivedAtCounter
            self.receivedAtDate = receivedAtDate
            self.senderIdentityKey = senderIdentityKey
            self.receiverIdentityKey = receiverIdentityKey
        }
    }

    /// `handleCallingMessage`: a CallMessage from the receive pipeline.
    public func handleCallingMessage(_ message: CallingMessage, _ o: CallingMessageOptions) {
        if let d = message.destinationDeviceId, d != 0, d != o.localDeviceId { return }
        let peer: [String: JSONValue] = ["peerId": .string(o.remoteUserId), "senderDeviceId": .int(Int64(o.remoteDeviceId))]
        if let offer = message.offer, offer.callId != 0 {
            guard !offer.opaque.isEmpty else { logError("handleCallingMessage(): opaque not received for offer, remote should update"); return }
            callInfoByCallId[offer.callId] = CallInfo(isVideoCall: offer.type == .videoCall, receivedAtCounter: o.receivedAtCounter, receivedAtDate: o.receivedAtDate,
                                                      peer: o.remoteUserId)
            _ = try? run("receivedOffer", peer.merging([
                "receiverDeviceId": .int(Int64(o.localDeviceId)), "ageSec": .int(Int64(o.ageSec)), "callId": .id(offer.callId),
                "offerType": .int(Int64(offer.type.rawValue)), "opaque": .bytes(offer.opaque),
                "senderIdentityKey": .bytes(o.senderIdentityKey), "receiverIdentityKey": .bytes(o.receiverIdentityKey),
            ]) { $1 })
        }
        if let answer = message.answer, answer.callId != 0 {
            guard !answer.opaque.isEmpty else { logError("handleCallingMessage(): opaque not received for answer, remote should update"); return }
            _ = try? run("receivedAnswer", peer.merging([
                "callId": .id(answer.callId), "opaque": .bytes(answer.opaque),
                "senderIdentityKey": .bytes(o.senderIdentityKey), "receiverIdentityKey": .bytes(o.receiverIdentityKey),
            ]) { $1 })
        }
        if let ice = message.iceCandidates, let first = ice.first {
            let candidates = ice.compactMap { $0.opaque.isEmpty ? nil : $0.opaque }
            if candidates.count < ice.count { logError("handleCallingMessage(): opaque not received for ice candidate, remote should update") }
            guard !candidates.isEmpty else { logWarn("handleCallingMessage(): No ice candidates in ice message, remote should update"); return }
            guard first.callId != 0 else { logWarn("handleCallingMessage(): No call ID in ice message"); return }
            _ = try? run("receivedIceCandidates", peer.merging(["callId": .id(first.callId), "candidates": .array(candidates.map { .bytes($0) })]) { $1 })
        }
        if let hangup = message.hangup, hangup.callId != 0 {
            _ = try? run("receivedHangup", peer.merging([
                "callId": .id(hangup.callId), "hangupType": .int(Int64(hangup.type.rawValue)),
                "hangupDeviceId": hangup.deviceId == 0 ? .null : .int(Int64(hangup.deviceId)),
            ]) { $1 })
        }
        if let busy = message.busy, busy.callId != 0 {
            _ = try? run("receivedBusy", peer.merging(["callId": .id(busy.callId)]) { $1 })
        }
        if let opaque = message.opaque {
            guard let uuid = o.remoteUuid else { logError("handleCallingMessage(): opaque message received without UUID!"); return }
            guard let data = opaque.data else { logError("handleCallingMessage(): opaque message received without data!"); return }
            noteRecent(&callMessageSenders, uuid)
            _ = try? run("receivedCallMessage", [
                "remoteUserId": .bytes(uuid), "remoteDeviceId": .int(Int64(o.remoteDeviceId)), "localDeviceId": .int(Int64(o.localDeviceId)),
                "data": .bytes(data), "messageAgeSec": .int(Int64(o.ageSec)),
            ])
        }
    }

    // MARK: HTTP (group calls, call links)

    public func receivedHttpResponse(requestId: UInt32, status: Int, body: Data) {
        _ = try? run("receivedHttpResponse", ["requestId": .int(Int64(requestId)), "statusCode": .int(Int64(status)), "body": .bytes(body)])
    }

    public func httpRequestFailed(requestId: UInt32, debugInfo: String?) {
        _ = try? run("httpRequestFailed", ["requestId": .int(Int64(requestId)), "debugInfo": debugInfo.map { .string($0) } ?? .null])
    }

    // MARK: group calls

    public func getGroupCall(groupId: GroupId, sfuUrl: String, hkdfExtraInfo: Data, audioLevelsIntervalMillis: Int?, dredDuration: Int?,
                             svcConfig: GroupCallSvcConfig?, observer: any GroupCallObserver) -> GroupCall? {
        guard let id = (try? run("createGroupCallClient", [
            "groupId": .bytes(groupId), "sfuUrl": .string(sfuUrl), "hkdfExtraInfo": .bytes(hkdfExtraInfo),
            "audioLevelsIntervalMillis": .int(Int64(audioLevelsIntervalMillis ?? 0)), "dredDuration": .int(Int64(dredDuration ?? 0)),
            "svcConfig": svcConfig?.json ?? .null,
        ]))?.int, id != 0 else { return nil }
        let g = GroupCall(kind: .signalGroup, endpoint: endpoint, observer: observer, clientId: GroupCallClientId(id), groupId: groupId)
        groupCallByClientId[g.clientId] = g
        return g
    }

    public func getCallLinkCall(sfuUrl: String, endorsementPublicKey: Data, authCredentialPresentation: Data, rootKey: CallLinkRootKey, adminPasskey: Data?,
                                hkdfExtraInfo: Data, audioLevelsIntervalMillis: Int?, dredDuration: Int?, svcConfig: GroupCallSvcConfig?,
                                observer: any GroupCallObserver) -> GroupCall? {
        guard let id = (try? run("createCallLinkCallClient", [
            "sfuUrl": .string(sfuUrl), "endorsementPublicKey": .bytes(endorsementPublicKey), "authPresentation": .bytes(authCredentialPresentation),
            "rootKey": .bytes(rootKey.bytes), "adminPasskey": .bytes(adminPasskey), "hkdfExtraInfo": .bytes(hkdfExtraInfo),
            "audioLevelsIntervalMillis": .int(Int64(audioLevelsIntervalMillis ?? 0)), "dredDuration": .int(Int64(dredDuration ?? 0)),
            "svcConfig": svcConfig?.json ?? .null,
        ]))?.int, id != 0 else { return nil }
        let g = GroupCall(kind: .callLink, endpoint: endpoint, observer: observer, clientId: GroupCallClientId(id))
        groupCallByClientId[g.clientId] = g
        return g
    }

    /// `peekGroupCall` (an empty PeekInfo on failure, as upstream).
    public func peekGroupCall(sfuUrl: String, membershipProof: Data, groupMembers: [GroupMemberInfo]) async -> PeekInfo {
        let (id, result) = peekRequests.add()
        do {
            _ = try run("peekGroupCall", ["requestId": .int(Int64(id)), "sfuUrl": .string(sfuUrl), "membershipProof": .bytes(membershipProof),
                                          "members": .array(groupMembers.map(\.json))])
        } catch {
            peekRequests.resolve(id, .failure(errorStatusCode: -1))
        }
        if case .success(let info) = await result.value { return info }
        return PeekInfo()
    }

    public func peekCallLinkCall(sfuUrl: String, authCredentialPresentation: Data, rootKey: CallLinkRootKey) async -> HttpResult<PeekInfo> {
        let (id, result) = peekRequests.add()
        do {
            _ = try run("peekCallLinkCall", ["requestId": .int(Int64(id)), "sfuUrl": .string(sfuUrl), "authPresentation": .bytes(authCredentialPresentation),
                                             "rootKey": .bytes(rootKey.bytes)])
        } catch {
            peekRequests.resolve(id, .failure(errorStatusCode: -1))
        }
        return await result.value
    }

    func callLinkRequest(_ name: String, _ fields: [String: JSONValue]) async -> HttpResult<CallLinkState> {
        let (id, result) = callLinkRequests.add()
        var f = fields
        f["requestId"] = .int(Int64(id))
        do { _ = try run(name, f) } catch { callLinkRequests.resolve(id, .failure(errorStatusCode: -1)) }
        return await result.value
    }

    public func readCallLink(sfuUrl: String, authCredentialPresentation: Data, linkRootKey: CallLinkRootKey) async -> HttpResult<CallLinkState> {
        await callLinkRequest("readCallLink", ["sfuUrl": .string(sfuUrl), "authPresentation": .bytes(authCredentialPresentation), "rootKey": .bytes(linkRootKey.bytes)])
    }

    public func createCallLink(sfuUrl: String, createCredentialPresentation: Data, linkRootKey: CallLinkRootKey, adminPasskey: Data,
                               callLinkPublicParams: Data, restrictions: CallLinkRestrictions) async -> HttpResult<CallLinkState> {
        await callLinkRequest("createCallLink", [
            "sfuUrl": .string(sfuUrl), "createPresentation": .bytes(createCredentialPresentation), "rootKey": .bytes(linkRootKey.bytes),
            "adminPasskey": .bytes(adminPasskey), "publicZkparams": .bytes(callLinkPublicParams), "restrictions": .int(Int64(restrictions.rawValue)),
        ])
    }

    public func updateCallLinkName(sfuUrl: String, authCredentialPresentation: Data, linkRootKey: CallLinkRootKey, adminPasskey: Data, newName: String) async
        -> HttpResult<CallLinkState>
    {
        await callLinkRequest("updateCallLink", [
            "sfuUrl": .string(sfuUrl), "authPresentation": .bytes(authCredentialPresentation), "rootKey": .bytes(linkRootKey.bytes),
            "adminPasskey": .bytes(adminPasskey), "newName": .string(newName),
        ])
    }

    public func updateCallLinkRestrictions(sfuUrl: String, authCredentialPresentation: Data, linkRootKey: CallLinkRootKey, adminPasskey: Data,
                                           restrictions: CallLinkRestrictions) async -> HttpResult<CallLinkState> {
        await callLinkRequest("updateCallLink", [
            "sfuUrl": .string(sfuUrl), "authPresentation": .bytes(authCredentialPresentation), "rootKey": .bytes(linkRootKey.bytes),
            "adminPasskey": .bytes(adminPasskey), "newRestrictions": .int(Int64(restrictions.rawValue)),
        ])
    }

    public func deleteCallLink(sfuUrl: String, authCredentialPresentation: Data, linkRootKey: CallLinkRootKey, adminPasskey: Data) async -> HttpResult<Bool> {
        let (id, result) = emptyRequests.add()
        do {
            _ = try run("deleteCallLink", ["requestId": .int(Int64(id)), "sfuUrl": .string(sfuUrl), "authPresentation": .bytes(authCredentialPresentation),
                                           "rootKey": .bytes(linkRootKey.bytes), "adminPasskey": .bytes(adminPasskey)])
        } catch {
            emptyRequests.resolve(id, .failure(errorStatusCode: -1))
        }
        return await result.value
    }

    // MARK: audio devices (cubeb)

    public func getAudioInputs() -> AudioDeviceList? { (try? run("getAudioInputs")).flatMap { $0.isNull ? nil : AudioDeviceList($0) } }
    public func getAudioOutputs() -> AudioDeviceList? { (try? run("getAudioOutputs")).flatMap { $0.isNull ? nil : AudioDeviceList($0) } }

    func audioRequest(_ name: String, _ fields: [String: JSONValue]) async throws -> AudioDevice? {
        let (id, result) = audioDeviceRequests.add()
        var f = fields
        f["requestId"] = .int(Int64(id))
        do { _ = try run(name, f) } catch { audioDeviceRequests.fail(id, error) }
        return try await result.result()
    }

    public func setAudioInputById(_ id: String) async throws -> AudioDevice? { try await audioRequest("setAudioInputById", ["id": .string(id)]) }
    public func setAudioOutputById(_ id: String) async throws -> AudioDevice? { try await audioRequest("setAudioOutputById", ["id": .string(id)]) }
    public func setVoiceProcessingEnabled(_ enabled: Bool) async throws -> AudioDevice? { try await audioRequest("setVoiceProcessingEnabled", ["enabled": .bool(enabled)]) }

    public func setMicrophoneWarmupEnabled(_ warmup: Bool) async throws -> AudioDevice? {
        if warmup { return try await audioRequest("setMicrophoneWarmupEnabled", ["enabled": .bool(true)]) }
        stopMicrophoneWarmup()
        return nil
    }

    /// Stops microphone warmup (which records) now, without waiting: the request is queued to
    /// the audio module before this returns, behind any earlier start.
    public func stopMicrophoneWarmup() {
        do { _ = try run("setMicrophoneWarmupEnabled", ["enabled": .bool(false), "requestId": .int(0)]) } catch { logWarn("Failed to stop microphone warmup: \(error)") }
    }

    // MARK: what the endpoint may ask for

    func noteRecent(_ map: inout [Data: Date], _ key: Data) {
        let now = Date()
        map = map.filter { now.timeIntervalSince($0.value) < Self.recentWindow }
        if map.count < 256 { map[key] = now }
    }

    func isRecent(_ map: [Data: Date], _ key: Data) -> Bool {
        map[key].map { Date().timeIntervalSince($0) < Self.recentWindow } ?? false
    }

    /// 1:1 signalling: to the peer of the current call, or of an offer we passed in.
    func maySignal(_ remoteUserId: UserId, callId: CallId) -> Bool {
        if let call, call.remoteUserId == remoteUserId, call.callId == callId { return true }
        return callInfoByCallId[callId]?.peer == remoteUserId
    }

    /// A call message (group call media keys, ring answers): to ourselves (our other devices),
    /// a member of a Signal group call ringrtc runs (the members are the app's own list,
    /// `setGroupMembers`; ringrtc can name no one else in such a call), or a participant of a
    /// call-link call ringrtc runs. A call link has no list of the app's own: its participants
    /// are the service's word (Verification/CallBoundary proves this limit).
    func mayMessage(_ recipient: Data) -> Bool {
        if let selfUuid, recipient == selfUuid { return true }
        return groupCallByClientId.values.contains { g in
            switch g.kind {
            case .signalGroup: g.members.contains { $0.userId == recipient }
            case .callLink:
                (g.remoteDeviceStates ?? []).contains { $0.userId == recipient } || (g.peekInfo?.devices ?? []).contains { $0.userId == recipient }
            }
        }
    }

    /// A group message (rings, their cancellation): to a group with a call client, or one we
    /// just cancelled a ring for.
    func mayMessageGroup(_ groupId: GroupId) -> Bool {
        groupCallByClientId.values.contains { $0.groupId == groupId } || isRecent(cancelledRings, groupId)
    }

    // MARK: logging

    func log(_ level: CallLogLevel, _ message: String) { handleLogMessage?(level, "RingRTC.swift", 0, message) }
    func logError(_ m: String) { log(.error, m) }
    func logWarn(_ m: String) { log(.warn, m) }
    func logInfo(_ m: String) { log(.info, m) }
}

/// `Requests<T>`: pending request ids and their results.
@MainActor
struct Requests<T: Sendable> {
    final class Pending: Sendable {
        let stream: AsyncStream<Result<T, any Error>>
        let continuation: AsyncStream<Result<T, any Error>>.Continuation
        init() { (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }
        var value: T {
            get async {
                for await r in stream { if case .success(let v) = r { return v } }
                fatalError("request finished without a value")
            }
        }
        func result() async throws -> T {
            for await r in stream { return try r.get() }
            throw RingRTCError.invalidResponse
        }
    }
    var nextId: UInt32 = 1
    var pending: [UInt32: Pending] = [:]

    mutating func add() -> (UInt32, Pending) {
        let id = nextId
        nextId &+= 1
        let p = Pending()
        pending[id] = p
        return (id, p)
    }

    @discardableResult
    mutating func resolve(_ id: UInt32, _ value: T) -> Bool {
        guard let p = pending.removeValue(forKey: id) else { return false }
        p.continuation.yield(.success(value))
        p.continuation.finish()
        return true
    }

    /// Every pending request settles with `value` (the endpoint that would answer is gone).
    mutating func failAll(_ value: T) {
        for id in Array(pending.keys) { resolve(id, value) }
    }

    /// Every pending request fails with `error`.
    mutating func failAll(_ error: any Error) {
        for id in Array(pending.keys) { fail(id, error) }
    }

    @discardableResult
    mutating func fail(_ id: UInt32, _ error: any Error) -> Bool {
        guard let p = pending.removeValue(forKey: id) else { return false }
        p.continuation.yield(.failure(error))
        p.continuation.finish()
        return true
    }
}
