import Foundation
import SignalRingRTC
import SwiftCalling
import Synchronization

/// Serein's strict Swift calling endpoint, hosted in the calling service.
public final class SwiftVoiceEndpoint: LocalCallEndpoint {
    public static let factory: LocalCallEndpointFactory = { _ in SwiftVoiceEndpoint() }

    package static func factory(devices: @escaping @Sendable () -> VoiceCallDevices) -> LocalCallEndpointFactory {
        { _ in SwiftVoiceEndpoint(devices: devices) }
    }

    private struct Party: Equatable, Sendable {
        let peer: String
        let id: UInt64

        func event(_ type: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
            var object = fields
            object["type"] = .string(type)
            object["remoteUserId"] = .string(peer)
            object["callId"] = .id(id)
            return .object(object)
        }

        func signaling(_ type: String, to device: UInt32? = nil, _ fields: [String: JSONValue] = [:]) -> JSONValue {
            var object = fields
            object["broadcast"] = .bool(device == nil)
            object["remoteDeviceId"] = .int(Int64(device ?? 0))
            return event(type, object)
        }

        func propagatedHangup(_ type: HangupType, device: UInt32) -> JSONValue {
            signaling("onSendHangup", ["hangupType": .int(Int64(type.rawValue)), "hangupDeviceId": .int(Int64(device))])
        }
    }

    private struct Description: Sendable {
        let parameters: DirectCallParameters
        let callerIdentity: Data
        let calleeIdentity: Data

        init(_ fields: [String: JSONValue], offer: Bool) throws {
            guard let opaque = fields["opaque"]?.data, opaque.count <= 65_536,
                  let sender = fields["senderIdentityKey"]?.data, (32...33).contains(sender.count),
                  let receiver = fields["receiverIdentityKey"]?.data, receiver.count == sender.count else {
                throw RingRTCError.invalidResponse
            }
            parameters = try DirectCallParameters(envelope: opaque)
            guard parameters.publicKey?.count == 32,
                  let ufrag = parameters.iceUfrag, (1...256).contains(ufrag.utf8.count),
                  let password = parameters.icePassword, (1...256).contains(password.utf8.count) else {
                throw RingRTCError.invalidResponse
            }
            callerIdentity = offer ? sender : receiver
            calleeIdentity = offer ? receiver : sender
        }

        func apply(to session: LiveVoiceSession) async throws {
            try await session.setRemote(parameters, callerIdentity: callerIdentity, calleeIdentity: calleeIdentity)
        }
    }

    private struct Call: Sendable {
        let party: Party
        let token: UUID
        let localDevice: UInt32
        let outgoing: Bool
        let offerType: OfferType
        let identity: LiveVoiceSession.Identity
        let deadline: Task<Void, Never>
        var leg: EndpointVoiceLeg
        var branches: [UInt32: EndpointVoiceLeg] = [:]
        var answeredKeys = Set<Data>()
        var answeredDevices = Set<UInt32>()
        var claimed = false
        var configuration: EndpointVoiceLeg.Work?
        var remoteDevice: UInt32?
        var proceeded = false
        var accepted = false
        var signaled = false
        var gathered: [(device: UInt32?, candidate: JSONValue)] = []
        var pendingCandidates: [UInt32: [IceCandidateUpdate]] = [:]
        var timeline = CallTimeline()

        func stop(sendHangup: Bool) {
            deadline.cancel()
            leg.end(sendHangup: sendHangup)
            for other in branches.values where other.id != leg.id { other.end(sendHangup: false) }
        }
    }

    private struct ClientRing: Sendable { var id: Int64? }

    private struct State: Sendable {
        var closed = false
        var dred: DREDModel?
        var call: Call?
        var events: [JSONValue] = []
        var sfu = CallSFURequests()
        var rings = CallGroupRings()
        var nextGroup: UInt32 = 0
        var groups: [UInt32: EndpointGroupRoom] = [:]
        var ringClients: [UInt32: ClientRing] = [:]
        var activeGroup: UInt32?

    }

    private let state = Mutex(State())
    private let groupHTTP = GroupHTTP()
    private let wake = DispatchSemaphore(value: 0)
    private let devices: @Sendable () -> VoiceCallDevices
    private let audio: EndpointAudio
    private init(devices: (@Sendable () -> VoiceCallDevices)? = nil) {
        let audio = EndpointAudio()
        self.audio = audio
        self.devices = devices ?? { audio.devices() }
        audio.start { [weak self] event in self?.handleAudioEvent(event) }
    }

    private func handleAudioEvent(_ event: JSONValue) {
        state.withLock { emit(event, &$0) }
    }

    public let generation: UInt64 = 0
    public var isLive: Bool { state.withLock { !$0.closed } }

    private func emit(_ event: JSONValue, _ s: inout State) {
        guard !s.closed else { return }
        guard s.events.count < 256 else {
            // An event loss also invalidates outstanding app HTTP promises. Report
            // endpoint loss so every request and the active call are settled together.
            s.closed = true
            audio.close()
            s.call?.stop(sendHangup: false)
            s.call = nil
            s.sfu = CallSFURequests()
            s.rings = CallGroupRings()
            groupHTTP.close()
            for group in s.groups.values { group.close() }
            s.groups.removeAll()
            s.ringClients.removeAll()
            s.activeGroup = nil
            s.events.removeAll()
            wake.signal()
            return
        }
        if s.events.isEmpty { wake.signal() }
        s.events.append(event)
    }

    private func finish(_ reason: CallEndReason, _ s: inout State, sendHangup: Bool = false) {
        guard let call = s.call else { return }
        s.call = nil
        if sendHangup {
            emit(call.party.signaling("onSendHangup", ["hangupType": .int(0)]), &s)
        }
        call.stop(sendHangup: sendHangup)
        emit(call.party.event("onCallEnded", ["reason": .int(Int64(reason.rawValue)),
                                             "summary": call.timeline.summary(reason: reason, callID: call.party.id,
                                                                               quality: call.leg.session.measurements.summary())]), &s)
    }

    private func failLeg(_ id: UUID, _ s: inout State) {
        guard let call = s.call else { return }
        if call.outgoing, !call.claimed, let device = call.branches.first(where: { $0.value.id == id })?.key {
            // Another linked device can still accept until the original call deadline.
            s.call?.branches.removeValue(forKey: device)?.end(sendHangup: false)
        } else if call.leg.id == id && (!call.outgoing || call.claimed || call.answeredDevices.isEmpty) {
            finish(.connectionFailure, &s, sendHangup: true)
        }
    }

    /// Reserve media synchronously before a leg can open a device. Two independent
    /// authenticated accept packets may arrive on different actors at the same time.
    private func claim(_ id: UUID) -> Bool {
        state.withLock { s in
            guard var call = s.call, !call.claimed else { return false }
            if call.outgoing {
                guard let (device, winner) = call.branches.first(where: { $0.value.id == id }) else { return false }
                if call.leg.id != id { call.leg.end(sendHangup: false) }
                for other in call.branches.values where other.id != id && other.id != call.leg.id { other.end(sendHangup: false) }
                call.leg = winner
                call.remoteDevice = device
                call.branches.removeAll()
                call.pendingCandidates.removeAll()
                call.gathered.removeAll { $0.device != nil && $0.device != device }
            } else if call.leg.id != id { return false }
            call.claimed = true
            call.deadline.cancel()
            s.call = call
            return true
        }
    }

    private func mediaEvent(_ event: LiveVoiceSession.Event, legID: UUID) {
        state.withLock { s in
            guard let call = s.call else { return }
            let device = call.branches.first(where: { $0.value.id == legID })?.key
            let primaryIsActive = call.leg.id == legID && (!call.outgoing || call.claimed || call.answeredDevices.isEmpty)
            guard device != nil || primaryIsActive else { return }
            switch event {
            case .candidate(let update):
                let candidate = JSONValue.bytes(update.envelope())
                if call.signaled {
                    emit(call.party.signaling("onSendIceCandidates", to: device ?? call.remoteDevice, ["candidates": .array([candidate])]), &s)
                } else if call.gathered.count < 64 {
                    s.call?.gathered.append((device ?? call.remoteDevice, candidate))
                }
            case .networkRoute(let adapter):
                if call.claimed && call.leg.id != legID { return }
                s.call?.timeline.record(.routeChanged)
                if NetworkAdapterType(rawValue: adapter).contains(.cellular) { s.call?.timeline.cellular = true }
                emit(call.party.event("onNetworkRouteChanged", ["localNetworkAdapterType": .int(Int64(adapter))]), &s)
            case .reconnecting, .reconnected:
                guard call.accepted, call.leg.id == legID else { return }
                let state: String
                if case .reconnected = event { state = "connected"; s.call?.timeline.record(.iceConnected) }
                else { state = "connecting"; s.call?.timeline.record(.iceDisconnected) }
                emit(call.party.event("onCallState", ["state": .string(state)]), &s)
            case .ringing:
                s.call?.timeline.record(.iceConnected)
                if !call.accepted { emit(call.party.event("onCallState", ["state": .string("ringing")]), &s) }
            case .accepted:
                guard !call.accepted else { return }
                s.call?.accepted = true
                s.call?.timeline.didConnect()
                if call.outgoing, let device = call.remoteDevice {
                    // Other devices of the callee can stop ringing; the accepting device
                    // recognizes its own ID in the broadcast.
                    emit(call.party.propagatedHangup(.accepted, device: device), &s)
                }
                emit(call.party.event("onCallState", ["state": .string("connected")]), &s)
            case .lowBandwidthForVideo(let recovered):
                guard call.leg.id == legID else { return }
                emit(call.party.event("onLowBandwidthForVideo", ["recovered": .bool(recovered)]), &s)
            case .remoteVideo(let enabled):
                guard call.leg.id == legID else { return }
                emit(call.party.event("onRemoteVideoEnabled", ["enabled": .bool(enabled)]), &s)
            case .remoteScreen(let enabled):
                guard call.leg.id == legID else { return }
                emit(call.party.event("onRemoteSharingScreen", ["enabled": .bool(enabled)]), &s)
            case .remoteAudio(let enabled):
                guard call.leg.id == legID else { return }
                emit(call.party.event("onRemoteAudioEnabled", ["enabled": .bool(enabled)]), &s)
            case .audioLevels(let captured, let received):
                emit(call.party.event("onAudioLevels", ["capturedLevel": .int(Int64(captured)), "receivedLevel": .int(Int64(received))]), &s)
            case .remoteHangup: finish(.remoteHangup, &s)
            case .failed(let message):
                emit(.object(["type": .string("onLogMessage"), "level": .int(Int64(CallLogLevel.error.rawValue)),
                              "file": .string("LiveVoiceSession"), "line": .int(0), "message": .string(message)]), &s)
                failLeg(legID, &s)
            }
        }
    }

    private func makeLeg(_ party: Party, outgoing: Bool, identity: LiveVoiceSession.Identity) -> EndpointVoiceLeg {
        let id = UUID()
        let session = LiveVoiceSession(callID: party.id, outgoing: outgoing, devices: devices(), identity: identity,
                                       claimMedia: { [weak self] in self?.claim(id) ?? false }) { [weak self] event in
            self?.mediaEvent(event, legID: id)
        }
        return EndpointVoiceLeg(id: id, session: session) { [weak self] in
            guard let self else { return }
            self.state.withLock { self.failLeg(id, &$0) }
        }
    }

    private func start(_ party: Party, localDevice: UInt32, remoteDevice: UInt32?, offerType: OfferType, _ s: inout State) {
        let token = UUID()
        let outgoing = remoteDevice == nil
        let identity = LiveVoiceSession.Identity()
        let leg = makeLeg(party, outgoing: outgoing, identity: identity)
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            guard let self else { return }
            self.state.withLock { s in
                if s.call?.token == token && s.call?.claimed == false { self.finish(.timeout, &s, sendHangup: true) }
            }
        }
        s.call = Call(party: party, token: token, localDevice: localDevice, outgoing: outgoing, offerType: offerType,
                      identity: identity, deadline: deadline, leg: leg, remoteDevice: remoteDevice)
        emit(party.event(outgoing ? "onStartOutgoingCall" : "onStartIncomingCall", ["isVideoCall": .bool(offerType == .videoCall)]), &s)
    }

    private func enqueue(_ s: inout State, _ work: @escaping EndpointVoiceLeg.Work) {
        if let call = s.call, !call.leg.enqueue(work) { finish(.internalFailure, &s, sendHangup: true) }
    }

    public func command(_ name: String, _ fields: [String: JSONValue], generation: UInt64?) throws -> JSONValue {
        if name == "addAsset" {
            guard fields["assetGroup"]?.string == "opus-dred" else { throw RingRTCError.invalidResponse }
            let bytes: Data
            if let content = fields["content"]?.data { bytes = content }
            else if let path = fields["filePath"]?.string {
                let url = URL(fileURLWithPath: path)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let size = values.fileSize, size >= DREDModel.assetSize else { throw RingRTCError.invalidResponse }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                bytes = try handle.read(upToCount: DREDModel.assetSize) ?? Data()
            } else { throw RingRTCError.invalidResponse }
            let model = try DREDModel(weights: bytes)
            return try state.withLock { s in
                guard !s.closed, generation == nil || generation == self.generation else { throw RingRTCError.lost }
                guard s.dred == nil else { throw RingRTCError.invalidResponse }
                s.dred = model
                return .null
            }
        }
        return try state.withLock { s in
            guard !s.closed, generation == nil || generation == self.generation else { throw RingRTCError.lost }
            switch name {
            case "createOutgoingCall":
                guard let video = fields["videoEnabled"]?.bool, s.call == nil, s.activeGroup == nil, let peer = fields["peerId"]?.string, (1...256).contains(peer.utf8.count),
                      let device = Self.device(fields["localDeviceId"]) else { throw RingRTCError.invalidResponse }
                let party = Party(peer: peer, id: .random(in: 1...UInt64.max))
                start(party, localDevice: device, remoteDevice: nil, offerType: video ? .videoCall : .audioCall, &s)
                return .id(party.id)
            case "receivedOffer":
                try receiveOffer(fields, &s)
            case "receivedAnswer", "receivedIceCandidates", "receivedHangup", "receivedBusy":
                try receive(name, fields, &s)
            case "proceed", "accept", "hangup", "ignore", "setOutgoingAudioEnabled", "signalingMessageSent", "signalingMessageSendFailed":
                try control(name, fields, &s)
            case "peekGroupCall", "peekCallLinkCall", "readCallLink", "createCallLink", "updateCallLink", "deleteCallLink":
                let event = try s.sfu.start(name, fields)
                emit(event, &s)
            case "receivedHttpResponse", "httpRequestFailed":
                if groupHTTP.complete(name, fields) { break }
                if let event = s.sfu.complete(name, fields) { emit(event, &s) }
            case "setSelfUuid", "receivedCallMessage", "cancelGroupRing":
                let previousUUID = s.rings.selfUUID
                let updates = try s.rings.command(name, fields, busy: s.call != nil || s.activeGroup != nil)
                if let previousUUID, previousUUID != s.rings.selfUUID {
                    for id in s.ringClients.keys { s.ringClients[id]?.id = nil }
                }
                // A NotJoined client keeps its first ring, even if a newer ring becomes
                // the manager's outstanding ring for clients created later.
                for update in updates where update["type"].string == "groupCallRingUpdate" && update["update"].int == RingUpdate.requested.rawValue {
                    for id in s.ringClients.keys where id != s.activeGroup && s.ringClients[id]?.id == nil && s.groups[id]?.group == update["groupId"].data {
                        s.ringClients[id]?.id = update["ringId"].int64
                    }
                }
                if name != "cancelGroupRing" {
                    for group in s.groups.values { _ = group.command(name, fields) }
                }
                for update in updates { emit(update, &s) }
            case "createGroupCallClient", "createCallLinkCallClient":
                return try makeGroup(name, fields, &s)
            case "deleteGroupCallClient":
                if let id = fields["clientId"]?.uint64.flatMap(UInt32.init(exactly:)) {
                    s.ringClients[id] = nil
                    s.groups.removeValue(forKey: id)?.close()
                    if s.activeGroup == id { s.activeGroup = nil }
                }
            case "connect", "join", "leave", "disconnect", "setGroupMembers", "setMembershipProof", "setCallLinkMembers",
                 "setOutgoingAudioMuted", "setOutgoingAudioMutedRemotely", "setOutgoingVideoMuted", "setOutgoingGroupCallVideoIsScreenShare",
                 "setPresenting", "setDataMode", "requestVideo", "groupReact", "groupRaiseHand", "sendRemoteMuteRequest", "groupRing",
                 "resendMediaKeys", "approveUser", "denyUser", "removeClient", "blockClient", "setRtcStatsInterval":
                try groupCommand(name, fields, &s)
            case "getAudioInputs", "getAudioOutputs":
                return try audio.list(input: name == "getAudioInputs")
            case "setAudioInputById", "setAudioOutputById", "setMicrophoneWarmupEnabled", "setVoiceProcessingEnabled":
                try audio.submit(name, fields: fields)
            case "setOutgoingVideoEnabled", "setOutgoingVideoIsScreenShare", "updateDataMode":
                try control(name, fields, &s)
            default:
                throw RingRTCError.native("Unsupported Swift calling command: " + name)
            }
            return .null
        }
    }

    private func makeGroup(_ name: String, _ fields: [String: JSONValue], _ s: inout State) throws -> JSONValue {
        guard s.groups.count < 16, let url = fields["sfuUrl"]?.string, !url.isEmpty, url.utf8.count <= 8192 else { throw RingRTCError.invalidResponse }
        let link = name == "createCallLinkCallClient"
        let group: Data
        if link {
            guard let bytes = fields["rootKey"]?.data, fields["authPresentation"]?.data != nil else { throw RingRTCError.invalidResponse }
            let key = try CallLinkRootKey.fromBytes(bytes)
            guard !key.awaitingEpoch else { throw RingRTCError.invalidResponse }
            group = try key.deriveRoomId()
        } else {
            guard let data = fields["groupId"]?.data, data.count == 32 else { throw RingRTCError.invalidResponse }
            group = data
        }
        repeat { s.nextGroup &+= 1 } while s.nextGroup == 0 || s.groups[s.nextGroup] != nil
        let id = s.nextGroup
        let dred = DREDConfiguration(model: s.dred, duration: fields["dredDuration"]?.uint64 ?? 0)
        let handle = EndpointGroupRoom(id: id, group: group, fields: fields, link: link, http: groupHTTP, dred: dred, devices: devices) { [weak self] event in
            self?.groupEvent(id, event: event)
        }
        s.groups[id] = handle
        if !link { s.ringClients[id] = ClientRing(id: s.rings.outstandingID(for: group)) }
        if let uuid = s.rings.selfUUID { _ = handle.command("setSelfUuid", ["uuid": .bytes(uuid)]) }
        return .int(Int64(id))
    }

    private func groupCommand(_ name: String, _ fields: [String: JSONValue], _ s: inout State) throws {
        guard let id = fields["clientId"]?.uint64.flatMap(UInt32.init(exactly:)), let handle = s.groups[id] else { throw RingRTCError.invalidResponse }
        if name == "join" {
            guard s.call == nil, s.activeGroup == nil || s.activeGroup == id else { _ = handle.command("busy", [:]); return }
            if s.activeGroup == nil, let ring = s.ringClients[id]?.id,
               let accepted = s.rings.response(.accepted, group: handle.group, id: ring) { emit(accepted, &s) }
            s.ringClients[id]?.id = nil
            s.activeGroup = id
        }
        if name == "disconnect" { s.ringClients[id] = nil }
        guard handle.command(name, fields) else {
            s.ringClients[id] = nil
            s.groups[id] = nil
            if s.activeGroup == id { s.activeGroup = nil }
            handle.close()
            emit(.object(["type": .string("handleEnded"), "clientId": .int(Int64(id)), "reason": .int(Int64(CallEndReason.internalFailure.rawValue))]), &s)
            throw RingRTCError.invalidResponse
        }
    }

    private func groupEvent(_ id: UInt32, event: JSONValue) {
        state.withLock { s in
            guard let handle = s.groups[id], !s.closed else { return }
            let ended = event["type"].string == "handleEnded"
            let left = event["type"].string == "handleJoinStateChanged" && event["joinState"].int == JoinState.notJoined.rawValue
            if (ended || left) && s.activeGroup == id { s.activeGroup = nil }
            if ended { s.ringClients[id] = nil; s.groups[id] = nil; handle.close() }
            emit(event, &s)
        }
    }

    private static func device(_ value: JSONValue?) -> UInt32? {
        guard let value = value?.uint64, value > 0 else { return nil }
        return UInt32(exactly: value)
    }

    private func receiveOffer(_ fields: [String: JSONValue], _ s: inout State) throws {
        guard let peer = fields["peerId"]?.string, (1...256).contains(peer.utf8.count), let id = fields["callId"]?.uint64, id != 0,
              let local = Self.device(fields["receiverDeviceId"]), let remote = Self.device(fields["senderDeviceId"]),
              let age = fields["ageSec"]?.int, age >= 0 else { throw RingRTCError.invalidResponse }
        let party = Party(peer: peer, id: id)
        if age > 60 {
            emit(party.event("onCallRejected", ["reason": .int(Int64(CallRejectReason.receivedOfferExpired.rawValue)), "ageSec": .int(Int64(age))]), &s)
            return
        }
        if s.activeGroup != nil {
            emit(party.signaling("onSendBusy", to: remote), &s)
            emit(party.event("onCallRejected", ["reason": .int(Int64(CallRejectReason.receivedOfferWhileActive.rawValue))]), &s)
            return
        }
        guard let value = fields["offerType"]?.int, let offerType = OfferType(rawValue: value) else { throw RingRTCError.invalidResponse }
        if let call = s.call, call.party.id == party.id { return }
        if let call = s.call, call.party.peer != peer || (call.remoteDevice != nil && call.remoteDevice != remote) {
            emit(party.signaling("onSendBusy", to: remote), &s)
            emit(party.event("onCallRejected", ["reason": .int(Int64(CallRejectReason.receivedOfferWhileActive.rawValue))]), &s)
            return
        }
        let description = try Description(fields, offer: true)
        if let call = s.call {
            if call.accepted {
                finish(.remoteReCall, &s)
            } else if call.party.id > party.id {
                emit(party.event("onCallRejected", ["reason": .int(Int64(CallRejectReason.receivedOfferWithGlare.rawValue))]), &s)
                return
            } else { finish(.remoteGlare, &s, sendHangup: true) }
        }
        start(party, localDevice: local, remoteDevice: remote, offerType: offerType, &s)
        enqueue(&s) { try await description.apply(to: $0) }
    }

    private func receive(_ name: String, _ fields: [String: JSONValue], _ s: inout State) throws {
        guard let call = s.call, fields["callId"]?.uint64 == call.party.id, fields["peerId"]?.string == call.party.peer,
              let device = Self.device(fields["senderDeviceId"]) else { return }
        if !call.outgoing || call.claimed {
            guard device == call.remoteDevice else { return }
        }
        switch name {
        case "receivedAnswer":
            guard call.outgoing, !call.claimed, let configure = call.configuration, !call.answeredDevices.contains(device),
                  call.answeredDevices.count < 8 else { return }
            let description = try Description(fields, offer: false)
            guard let key = description.parameters.publicKey, !call.answeredKeys.contains(key) else { return }
            let first = call.answeredDevices.isEmpty
            let leg = first ? call.leg : makeLeg(call.party, outgoing: true, identity: call.identity)
            s.call?.branches[device] = leg
            s.call?.answeredDevices.insert(device)
            if first { s.call?.timeline.answerReceived = CallTimeline.now }
            s.call?.answeredKeys.insert(key)
            let buffered = s.call?.pendingCandidates.removeValue(forKey: device) ?? []
            if !leg.enqueue({ session in
                try await description.apply(to: session)
                if !first { try await configure(session) }
                for update in buffered { await session.addCandidate(update) }
            }) { failLeg(leg.id, &s) }
        case "receivedIceCandidates":
            let candidates = fields["candidates"]?.array ?? []
            guard candidates.count <= 64 else { throw RingRTCError.invalidResponse }
            let updates = try candidates.map { value in
                guard let data = value.data, data.count <= 4096 else { throw RingRTCError.invalidResponse }
                return try IceCandidateUpdate(envelope: data)
            }
            if let leg = call.branches[device] ?? (call.remoteDevice == device ? call.leg : nil) {
                if !leg.enqueue({ session in for update in updates { await session.addCandidate(update) } }) { failLeg(leg.id, &s) }
            } else if !call.claimed && !call.answeredDevices.contains(device) {
                let count = call.pendingCandidates.values.reduce(0) { $0 + $1.count }
                guard !updates.isEmpty, count + updates.count <= 128 else { return }
                s.call?.pendingCandidates[device, default: []].append(contentsOf: updates)
            }
        case "receivedBusy":
            if call.outgoing, !call.claimed, call.answeredDevices.isEmpty || call.answeredDevices.contains(device) {
                emit(call.party.propagatedHangup(.busy, device: device), &s)
                finish(.remoteBusy, &s)
            }
        default:
            guard let type = fields["hangupType"]?.int.flatMap(HangupType.init(rawValue:)) else { throw RingRTCError.invalidResponse }
            if !call.outgoing, Self.device(fields["hangupDeviceId"]) == call.localDevice { return }
            if call.outgoing, type == .normal || type == .needPermission {
                emit(call.party.propagatedHangup(type == .normal ? .declined : .needPermission, device: device), &s)
            }
            let reason: CallEndReason = switch type {
            case .normal: .remoteHangup
            case .accepted: .remoteHangupAccepted
            case .declined: .remoteHangupDeclined
            case .busy: .remoteHangupBusy
            case .needPermission: .remoteHangupNeedPermission
            }
            finish(reason, &s)
        }
    }

    private func control(_ name: String, _ fields: [String: JSONValue], _ s: inout State) throws {
        guard let call = s.call else { return }
        if fields["callId"] == nil {
            // Upstream's original JSON contract has two unscoped call controls. Serein
            // tags both so late commands on an ended Call cannot reach its successor.
            guard name == "hangup" || name == "setOutgoingAudioEnabled" else { return }
        } else if fields["callId"]?.uint64 != call.party.id { return }
        switch name {
        case "proceed":
            guard !call.proceeded else { return }
            guard let relayOnly = fields["hideIp"]?.bool, let raw = fields["iceServers"]?.array, raw.count <= 64 else {
                throw RingRTCError.invalidResponse
            }
            let servers = try raw.map { server in
                let urls = server["urls"].array
                guard urls.count <= 64 else { throw RingRTCError.invalidResponse }
                return VoiceTURNServer(urls: urls.compactMap(\.string), username: server["username"].string ?? "", password: server["password"].string ?? "",
                                       hostname: server["hostname"].string ?? "")
            }
            s.call?.proceeded = true
            let config = fields["callConfig"] ?? .object(fields)
            let low = config["dataMode"].int == DataMode.low.rawValue
            let vp9Encode = config["enableVp9Encode"].bool ?? false
            let vp9Decode = config["enableVp9Decode"].bool ?? false
            var parameters = call.leg.session.localParameters
            parameters.encoders = vp9Encode ? [9, 8] : [8]
            parameters.decoders = vp9Decode ? [9, 8] : [8]
            parameters.maxBitrateBps = LiveVoiceSession.maxBitrate(lowDataMode: low)
            let opaque = JSONValue.bytes(parameters.envelope())
            emit(call.party.signaling(call.outgoing ? "onSendOffer" : "onSendAnswer", to: call.remoteDevice,
                                      ["opaque": opaque, "offerType": .int(Int64(call.offerType.rawValue))]), &s)
            let interval = fields["audioLevelsIntervalMillis"]?.uint64
            let statsSeconds = config["statsIntervalSecs"].uint64 ?? 10
            let dred = DREDConfiguration(model: s.dred, duration: config["dredDuration"].uint64 ?? 0)
            let configure: EndpointVoiceLeg.Work = {
                await $0.setDRED(dred)
                await $0.configureVP9(encode: vp9Encode, decode: vp9Decode)
                await $0.setStatsInterval(seconds: statsSeconds)
                await $0.setLowDataMode(low)
                await $0.configure(relayOnly: relayOnly, servers: servers, audioLevelsIntervalMs: interval)
            }
            s.call?.configuration = configure
            enqueue(&s, configure)
        case "accept":
            guard !call.outgoing else { return }
            enqueue(&s) { await $0.accept() }
        case "setOutgoingVideoEnabled":
            guard call.accepted, let enabled = fields["enabled"]?.bool else { return }
            let revision = call.leg.session.requestVideo(enabled)
            enqueue(&s) { await $0.setVideoEnabled(enabled, revision: revision) }
        case "updateDataMode":
            guard let raw = fields["dataMode"]?.int, let mode = DataMode(rawValue: raw) else { throw RingRTCError.invalidResponse }
            for other in call.branches.values where other.id != call.leg.id {
                if !other.enqueue({ await $0.setLowDataMode(mode == .low) }) { failLeg(other.id, &s) }
            }
            enqueue(&s) { await $0.setLowDataMode(mode == .low) }
        case "setOutgoingVideoIsScreenShare":
            guard call.accepted, let sharing = fields["isScreenshare"]?.bool else { return }
            enqueue(&s) { await $0.setScreenSharing(sharing) }
        case "setOutgoingAudioEnabled":
            guard call.accepted, let enabled = fields["enabled"]?.bool else { return }
            let revision = call.leg.session.requestMicrophone(enabled)
            enqueue(&s) { await $0.setMicrophoneEnabled(enabled, revision: revision) }
        case "hangup": finish(.localHangup, &s, sendHangup: true)
        case "ignore": finish(.appDroppedCall, &s)
        case "signalingMessageSent":
            // Serein sends each event asynchronously. Hold trickled ICE until the offer
            // or answer has been sent so the recipient can associate it with this call.
            guard call.proceeded, !call.signaled else { return }
            s.call?.signaled = true
            if call.outgoing { s.call?.timeline.offerSent = CallTimeline.now }
            else { s.call?.timeline.answerSent = CallTimeline.now }
            s.call?.gathered.removeAll()
            for (device, batch) in Dictionary(grouping: call.gathered, by: \.device) {
                emit(call.party.signaling("onSendIceCandidates", to: device, ["candidates": .array(batch.map(\.candidate))]), &s)
            }
        default: finish(.signalingFailure, &s)
        }
    }

    public func commandJSON(_ input: [UInt8]) throws -> [UInt8] {
        // The pinned DRED model is 1,998,208 bytes before the JSON base64 envelope.
        guard input.count <= 4 << 20, case .object(var fields) = try JSONDecoder().decode(JSONValue.self, from: Data(input)),
              let name = fields.removeValue(forKey: "cmd")?.string,
              input.count <= 1 << 20 || name == "addAsset" else { throw RingRTCError.invalidResponse }
        return try [UInt8](JSONEncoder().encode(command(name, fields, generation: nil)))
    }

    public func waitEvents(timeoutMs: UInt32) -> EndpointEvents {
        let deadline = state.withLock { $0.rings.waitDeadline(timeoutMs: timeoutMs) }
        _ = wake.wait(timeout: deadline)
        return state.withLock { s in
            if s.closed { return .lost(generation: generation) }
            let events = s.events + s.rings.expire()
            s.events.removeAll(keepingCapacity: true)
            return .events(events)
        }
    }

    public func waitEventsJSON(timeoutMs: UInt32) -> [UInt8] {
        guard case .events(let events) = waitEvents(timeoutMs: timeoutMs),
              let json = try? JSONEncoder().encode(events) else { return Array("[]".utf8) }
        return [UInt8](json)
    }

    private func activeGroupVideo(generation: UInt64?) -> GroupCallVideo? {
        state.withLock { s in
            guard !s.closed, generation == nil || generation == self.generation, let id = s.activeGroup else { return nil }
            return s.groups[id]?.room.video.withLock { $0 }
        }
    }

    private func activeVideo(generation: UInt64?) -> DirectCallVideo? {
        state.withLock { s in
            guard !s.closed, generation == nil || generation == self.generation, let call = s.call, call.accepted else { return nil }
            return call.leg.session.video
        }
    }

    public func sendVideoFrame(width: Int, height: Int, format: VideoPixelFormat, data: [UInt8], generation: UInt64?) -> Bool {
        if let group = activeGroupVideo(generation: generation) {
            return group.submit(width: width, height: height, format: Int(format.rawValue), data: data)
        }
        return activeVideo(generation: generation)?.submit(width: width, height: height, format: Int(format.rawValue), data: data) ?? false
    }

    public func receiveVideoFrame(demuxId: UInt32, maxWidth: Int, maxHeight: Int, into buffer: inout [UInt8],
                                  generation: UInt64?) -> (width: Int, height: Int)? {
        if demuxId != 0 {
            return activeGroupVideo(generation: generation)?.receive(demuxID: demuxId, maxWidth: maxWidth, maxHeight: maxHeight, into: &buffer)
        }
        return activeVideo(generation: generation)?.receive(maxWidth: maxWidth, maxHeight: maxHeight, into: &buffer)
    }

    public func close() {
        state.withLock { s in
            guard !s.closed else { return }
            s.closed = true
            audio.close()
            s.call?.stop(sendHangup: false)
            s.call = nil
            s.sfu = CallSFURequests()
            s.rings = CallGroupRings()
            groupHTTP.close()
            for group in s.groups.values { group.close() }
            s.groups.removeAll()
            s.ringClients.removeAll()
            s.activeGroup = nil
            s.events.removeAll()
            wake.signal()
        }
    }

    deinit { close() }
}
