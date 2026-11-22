// RingRTCType's event side (the `CallManagerCallbacks` electron.rs's processEvents calls):
// each JSON event from the endpoint, dispatched like Service.ts.

import Foundation
import CallingWire

extension RingRTC {
    func process(_ batch: [JSONValue]) {
        // Anything but a log line is work: the endpoint is kept a while longer.
        if batch.contains(where: { $0["type"].string != "onLogMessage" }) { noteActivity() }
        for e in batch { handle(e) }
    }

    func handle(_ e: JSONValue) {
        let type = e["type"].string ?? ""
        let peer = e["remoteUserId"].string ?? ""
        switch type {
        case "onLogMessage":
            handleLogMessage?(CallLogLevel(rawValue: e["level"].int ?? 3) ?? .info, e["file"].string ?? "", e["line"].int ?? 0, e["message"].string ?? "")
        case "onStartOutgoingCall":
            onStartOutgoingCall(peer, callId: e["callId"].uint64 ?? 0)
        case "onStartIncomingCall":
            onStartIncomingCall(peer, callId: e["callId"].uint64 ?? 0, isVideoCall: e["isVideoCall"].bool ?? false)
        case "onCallState":
            guard let call, call.remoteUserId == peer, call.callId == e["callId"].uint64, call.state != .ended,
                  let s = e["state"].string else { return }
            // Upstream maps the native state names through its CallState enum.
            if let state = CallState(rawValue: s) { call.state = state }
        case "onCallRejected":
            onCallRejected(peer, callId: e["callId"].uint64 ?? 0, reason: CallRejectReason(rawValue: e["reason"].int ?? 0) ?? .glareHandlingFailure,
                           ageSec: e["ageSec"].double ?? 0)
        case "onCallEnded":
            let callId = e["callId"].uint64 ?? 0
            callInfoByCallId[callId] = nil
            if let call, call.callId == callId {
                call.endedReason = CallEndReason(rawValue: e["reason"].int ?? 0)
                call.summary = CallSummary(e["summary"])
                call.state = .ended
            }
        case "onRemoteAudioEnabled":
            guard let call, call.remoteUserId == peer else { return }
            call.remoteAudioEnabled = e["enabled"].bool ?? false
            call.handleRemoteAudioEnabled?()
        case "onRemoteVideoEnabled":
            guard let call, call.remoteUserId == peer else { return }
            call.remoteVideoEnabled = e["enabled"].bool ?? false
            call.handleRemoteVideoEnabled?()
        case "onRemoteSharingScreen":
            guard let call, call.remoteUserId == peer else { return }
            call.remoteSharingScreen = e["enabled"].bool ?? false
            call.handleRemoteSharingScreen?()
        case "onNetworkRouteChanged":
            guard let call, call.remoteUserId == peer else { return }
            call.networkRoute.localAdapterType = NetworkAdapterType(rawValue: e["localNetworkAdapterType"].int ?? 0)
            call.handleNetworkRouteChanged?()
        case "onAudioLevels":
            guard let call, call.remoteUserId == peer else { return }
            call.outgoingAudioLevel = normalizeAudioLevel(e["capturedLevel"].double ?? 0)
            call.remoteAudioLevel = normalizeAudioLevel(e["receivedLevel"].double ?? 0)
            call.handleAudioLevels?()
        case "onLowBandwidthForVideo":
            guard let call, call.remoteUserId == peer else { return }
            call.handleLowBandwidthForVideo?(e["recovered"].bool ?? false)
        case "onSendOffer", "onSendAnswer", "onSendIceCandidates", "onSendHangup", "onSendBusy":
            onSendSignaling(type, e)
        case "sendHttpRequest":
            guard let handleSendHttpRequest else { logError("RingRTC.handleSendHttpRequest is not set!"); return }
            var headers: [String: String] = [:]
            if case .object(let o) = e["headers"] { for (k, v) in o { headers[k] = v.string } }
            handleSendHttpRequest(UInt32(clamping: e["requestId"].int ?? 0), e["url"].string ?? "", HttpMethod(rawValue: e["method"].int ?? 0) ?? .get, headers, e["body"].data)
        case "sendCallMessage":
            let recipient = e["recipientUuid"].data ?? Data()
            let message = e["message"].data ?? Data()
            let urgency = CallMessageUrgency(rawValue: e["urgency"].int ?? 0) ?? .droppable
            if recipient != selfUuid, let id = try? Self.signalingRoom(in: message) {
                let links = groupCallByClientId.values.filter { $0.linkRoomId == id }
                if !links.isEmpty {
                    guard links.count == 1, let link = links.first, link.callLinkAuthorization(for: [recipient]) != nil else { return }
                    deliverLinkMessage(link, message: message, urgency: urgency, recipients: [recipient], proofs: [], expiration: nil)
                    return
                }
                guard groupCallByClientId.values.contains(where: { $0.groupId == id && $0.members.contains { $0.userId == recipient } }) else { return }
            }
            guard let handleSendCallMessage else { logError("RingRTC.handleSendCallMessage is not set!"); return }
            guard mayMessage(recipient) else { logError("sendCallMessage: not a member or participant of a group call; dropped"); return }
            handleSendCallMessage(recipient, message, urgency)
        case "sendCallMessageToGroup":
            guard let handleSendCallMessageToGroup else { logError("RingRTC.handleSendCallMessageToGroup is not set!"); return }
            let groupId = e["groupId"].data ?? Data(), recipients = e["overrideRecipients"].array.compactMap(\.data)
            guard mayMessageGroup(groupId), recipients.allSatisfy(mayMessage) else { logError("sendCallMessageToGroup: not a group with a call; dropped"); return }
            handleSendCallMessageToGroup(groupId, e["message"].data ?? Data(), CallMessageUrgency(rawValue: e["urgency"].int ?? 0) ?? .droppable, recipients)
        case "sendCallMessageToAdhocGroup":
            let rows = e["recipientsToEndorsements"].array
            guard (1...4096).contains(rows.count), let message = e["message"].data, message.count <= 8192 else { return }
            let recipients = rows.compactMap { $0["recipientId"].data }
            guard recipients.count == rows.count, recipients.allSatisfy({ $0.count == 16 && $0 != selfUuid }) else { return }
            // Native RingRTC supplies no clientId on this callback. Only one joined link
            // may vouch for the whole recipient set. A union across rooms could leak keys.
            guard let room = try? Self.signalingRoom(in: message) else { return }
            let rooms = groupCallByClientId.values.filter { $0.linkRoomId == room && $0.callLinkAuthorization(for: recipients) != nil }
            guard rooms.count == 1, let g = rooms.first else { return }
            let proofs = rows.compactMap { $0["endorsement"].data }
            let expiration = e["expirationMillis"].double.map { Date(timeIntervalSince1970: $0 / 1000) }
            deliverLinkMessage(g, message: message, urgency: CallMessageUrgency(rawValue: e["urgency"].int ?? 0) ?? .droppable,
                               recipients: recipients, proofs: proofs, expiration: expiration)
        case "groupCallRingUpdate":
            guard let handleGroupCallRingUpdate else { logError("RingRTC.handleGroupCallRingUpdate is not set!"); return }
            let sender = e["sender"].data ?? Data()
            guard isRecent(callMessageSenders, sender) else { logError("groupCallRingUpdate: from no one whose call message we passed in; dropped"); return }
            handleGroupCallRingUpdate(e["groupId"].data ?? Data(), e["ringId"].int64 ?? 0, sender, RingUpdate(rawValue: e["update"].int ?? 0) ?? .requested)
        case "handleRtcStatsReportComplete":
            handleRtcStatsReport?(e["reportJson"].string ?? "")
        case "handlePeekResponse":
            let status = e["status"].int ?? 0
            let result: HttpResult<PeekInfo> = e["info"].isNull ? .failure(errorStatusCode: status) : .success(PeekInfo(e["info"]))
            if !peekRequests.resolve(UInt32(clamping: e["requestId"].int ?? 0), result) { logWarn("Invalid request ID for handlePeekResponse") }
        case "handleCallLinkResponse":
            let status = e["status"].int ?? 0
            let result: HttpResult<CallLinkState> = CallLinkState(e["state"]).map { .success($0) } ?? .failure(errorStatusCode: status)
            if !callLinkRequests.resolve(UInt32(clamping: e["requestId"].int ?? 0), result) { logWarn("Invalid request ID for handleCallLinkResponse") }
        case "handleEmptyResponse":
            let status = e["status"].int ?? 0
            let result: HttpResult<Bool> = status == 200 ? .success(true) : .failure(errorStatusCode: status)
            if !emptyRequests.resolve(UInt32(clamping: e["requestId"].int ?? 0), result) { logWarn("Invalid request ID for handleEmptyResponse") }
        case "onOutputDeviceChanged":
            handleOutputDeviceChanged?(AudioDeviceList(e["devices"]))
        case "onInputDeviceChanged":
            handleInputDeviceChanged?(AudioDeviceList(e["devices"]))
        case "onSettleStartPlayback":
            handleSettleStartPlayback?(e["success"].bool ?? false, AudioDevice(e["device"]))
        case "onSettleStartRecording":
            handleSettleStartRecording?(e["success"].bool ?? false, AudioDevice(e["device"]))
        case "onSettleAudioPromise":
            let id = UInt32(clamping: e["requestId"].int ?? 0), device = AudioDevice(e["device"])
            let ok = (e["success"].bool ?? false) ? audioDeviceRequests.resolve(id, device) : audioDeviceRequests.fail(id, AudioDeviceInitError(audioDevice: device))
            if !ok { logWarn("Invalid request ID for onSettleAudioPromise") }
        default:
            groupEvent(type, e)
        }
    }

    func groupEvent(_ type: String, _ e: JSONValue) {
        let clientId = GroupCallClientId(clamping: e["clientId"].int ?? 0)
        guard let g = groupCallByClientId[clientId] else {
            if ["requestMembershipProof", "requestGroupMembers", "handleConnectionStateChanged", "handleJoinStateChanged", "handleNetworkRouteChanged",
                "handleRemoteDevicesChanged", "handlePeekChanged", "handleEnded"].contains(type) {
                logError("\(type)(): GroupCall not found in map!")
            }
            return
        }
        switch type {
        case "receiveCallLinkEndorsements":
            guard g.kind == .callLink, let receive = g.receiveLinkEndorsements else { return }
            let rows = e["memberCiphertexts"].array
            guard rows.count <= 4096 else { receive(nil, []); return }
            let members = rows.compactMap(\.data)
            receive(members.count == rows.count ? e["serialized"].data : nil, members)
        case "sendCallLinkMessage":
            let rows = e["recipientIds"].array
            guard (1...4096).contains(rows.count), let message = e["message"].data, message.count <= 8192 else { return }
            let recipients = rows.compactMap(\.data)
            guard recipients.count == rows.count, recipients.allSatisfy({ $0.count == 16 && $0 != selfUuid }),
                  g.callLinkAuthorization(for: recipients) != nil else { return }
            guard let room = try? Self.signalingRoom(in: message), room == g.linkRoomId else { return }
            let proofs = g.linkEndorsements?(recipients)
            deliverLinkMessage(g, message: message, urgency: CallMessageUrgency(rawValue: e["urgency"].int ?? 0) ?? .droppable,
                               recipients: recipients, proofs: proofs?.1 ?? [], expiration: proofs?.0)
        case "resolveCallLinkMembers":
            guard g.kind == .callLink, let decrypt = g.resolveLinkMember, e["ciphertexts"].array.count <= 4096 else { return }
            let members: [JSONValue] = e["ciphertexts"].array.compactMap { value in
                guard let opaque = value.string, let bytes = PeekInfo.ciphertext(opaque) else { return nil }
                return .object(["opaqueUserId": value, "userId": .bytes(decrypt(bytes))])
            }
            g.run("setCallLinkMembers", ["members": .array(members)])
        case "requestMembershipProof": g.observer?.requestMembershipProof(g)
        case "requestGroupMembers": g.observer?.requestGroupMembers(g)
        case "handleConnectionStateChanged": g.handleConnectionStateChanged(ConnectionState(rawValue: e["connectionState"].int ?? 0) ?? .notConnected)
        case "handleJoinStateChanged":
            g.handleJoinStateChanged(JoinState(rawValue: e["joinState"].int ?? 0) ?? .notJoined, demuxId: e["demuxId"].int.map { UInt32(clamping: $0) })
        case "handleNetworkRouteChanged": g.handleNetworkRouteChanged(NetworkAdapterType(rawValue: e["localNetworkAdapterType"].int ?? 0))
        case "handleAudioLevels":
            g.handleAudioLevels(captured: e["capturedLevel"].double ?? 0, received: e["receivedLevels"].array.map {
                ReceivedAudioLevel(demuxId: UInt32(clamping: $0["demuxId"].int ?? 0), level: $0["level"].double ?? 0)
            })
        case "handleLowBandwidthForVideo": g.observer?.onLowBandwidthForVideo(g, recovered: e["recovered"].bool ?? false)
        case "handleReactions":
            g.observer?.onReactions(g, reactions: e["reactions"].array.map { Reaction(demuxId: UInt32(clamping: $0["demuxId"].int ?? 0), value: $0["value"].string ?? "") })
        case "handleRaisedHands": g.observer?.onRaisedHands(g, raisedHands: e["raisedHands"].array.compactMap { $0.int.map { UInt32(clamping: $0) } })
        case "handleRemoteDevicesChanged": g.handleRemoteDevicesChanged(e["remoteDeviceStates"].array.map(RemoteDeviceState.init))
        case "handlePeekChanged": g.handlePeekChanged(PeekInfo(e["info"]))
        case "handleEnded":
            groupCallByClientId[clientId] = nil
            g.handleEnded(CallEndReason(rawValue: e["reason"].int ?? 0) ?? .internalFailure, CallSummary(e["summary"]))
        case "handleSpeechEvent": g.observer?.onSpeechEvent(g, event: SpeechEvent(rawValue: e["event"].int ?? 0) ?? .stoppedSpeaking)
        case "onRemoteMute": g.observer?.onRemoteMute(g, demuxId: UInt32(clamping: e["demuxId"].int ?? 0))
        case "onObservedRemoteMute":
            g.observer?.onObservedRemoteMute(g, sourceDemuxId: UInt32(clamping: e["sourceDemuxId"].int ?? 0), targetDemuxId: UInt32(clamping: e["targetDemuxId"].int ?? 0))
        default:
            logWarn("unknown ringrtc event \(type)")
        }
    }

    /// The native callback has no room parameter. Recover it from the authenticated audience's
    /// signaling.CallMessage.group_call_message.group_id, rejecting ambiguous duplicate fields.
    private static func signalingRoom(in message: Data) throws -> Data? {
        var reader = try CallingProtoReader(message, limit: 8192)
        var room: Data?
        var seenGroup = false
        while let tag = try reader.next() {
            guard tag.number == 1 else { try reader.skip(tag); continue }
            guard !seenGroup else { return nil }
            seenGroup = true
            try reader.message(tag) { field, group in
                guard field.number == 1 else { try group.skip(field); return }
                guard room == nil else { throw CallingWireError.malformed }
                room = Data(try group.bytes(field))
            }
        }
        return room
    }

    private func deliverLinkMessage(_ g: GroupCall, message: Data, urgency: CallMessageUrgency, recipients: [Data], proofs: [Data], expiration: Date?) {
        let eligible = proofs.count == recipients.count && proofs.allSatisfy { !$0.isEmpty && $0.count <= 512 }
            && (expiration ?? .distantPast) > Date()
        if let send = g.sendLinkMessage {
            send(message, urgency, recipients, eligible ? proofs : [], eligible ? expiration : nil)
        } else if eligible, let expiration, let handleSendCallMessageToAdhocGroup {
            handleSendCallMessageToAdhocGroup(message, urgency, expiration, Array(zip(recipients, proofs)))
        } else {
            for recipient in recipients { handleSendCallMessage?(recipient, message, urgency) }
        }
    }

    func onStartOutgoingCall(_ remoteUserId: UserId, callId: CallId) {
        guard let call, call.remoteUserId == remoteUserId, call.callId == callId, call.state != .ended else { return }
        guard let handleStartCall else { call.ignore(); return }
        Task { @MainActor in
            guard self.call === call, call.state != .ended else { return }
            if !(await handleStartCall(call)) {
                self.logWarn("RingRTC.handleStartCall failed for outgoing call. Call ignored.")
                call.ignore()
            }
        }
    }

    func onStartIncomingCall(_ remoteUserId: UserId, callId: CallId, isVideoCall: Bool) {
        // A call ended by glare or re-call: retry once its state has settled.
        if let call, call.endedReason == .remoteGlare || call.endedReason == .remoteReCall {
            call.endedReason = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                self.onStartIncomingCall(remoteUserId, callId: callId, isVideoCall: isVideoCall)
            }
            return
        }
        // Only for an offer we passed in, from that peer.
        guard callInfoByCallId[callId]?.peer == remoteUserId else { logError("onStartIncomingCall: no offer for this call; ignored"); return }
        let call = Call(endpoint: endpoint, remoteUserId: remoteUserId, callId: callId, isIncoming: true, isVideoCall: isVideoCall, state: .prering,
                        generation: endpoint.generation)
        guard let handleIncomingCall, let handleStartCall else { call.ignore(); return }
        self.call = call
        Task { @MainActor in
            guard await handleIncomingCall(call) else {
                self.logWarn("RingRTC.handleIncomingCall failed for incoming call. Call ignored.")
                call.ignore()
                return
            }
            if !(await handleStartCall(call)) {
                self.logWarn("RingRTC.handleStartCall failed for incoming call. Call ignored.")
                call.ignore()
            }
        }
    }

    func onCallRejected(_ remoteUserId: UserId, callId: CallId, reason: CallRejectReason, ageSec: Double) {
        let info = callInfoByCallId[callId]
        if call != nil && reason == .receivedOfferWithGlare { return }
        if call == nil || call?.remoteUserId != remoteUserId || reason == .receivedOfferWhileActive || reason == .receivedOfferExpired
            || (call?.state == .prering && call?.isIncoming == true) {
            handleRejectedIncomingCallRequest?(callId, remoteUserId, reason, ageSec, info?.isVideoCall ?? false, info?.receivedAtCounter, info?.receivedAtDate)
        }
    }

    func onSendSignaling(_ type: String, _ e: JSONValue) {
        let remoteUserId = e["remoteUserId"].string ?? ""
        let callId = e["callId"].uint64 ?? 0
        var message = CallingMessage()
        switch type {
        case "onSendOffer":
            message.offer = OfferMessage(callId: callId, type: OfferType(rawValue: e["offerType"].int ?? 0) ?? .audioCall, opaque: e["opaque"].data ?? Data())
        case "onSendAnswer":
            message.answer = AnswerMessage(callId: callId, opaque: e["opaque"].data ?? Data())
        case "onSendIceCandidates":
            message.iceCandidates = e["candidates"].array.compactMap(\.data).map { IceCandidateMessage(callId: callId, opaque: $0) }
        case "onSendHangup":
            message.hangup = HangupMessage(callId: callId, type: HangupType(rawValue: e["hangupType"].int ?? 0) ?? .normal, deviceId: DeviceId(clamping: e["hangupDeviceId"].int ?? 0))
        default:
            message.busy = BusyMessage(callId: callId)
        }
        if e["broadcast"].bool != true { message.destinationDeviceId = DeviceId(clamping: e["remoteDeviceId"].int ?? 0) }
        let endpoint = self.endpoint
        guard maySignal(remoteUserId, callId: callId) else {
            logError("\(type): not the peer of a call or an offer; dropped")
            _ = try? endpoint.command("signalingMessageSendFailed", ["callId": .id(callId)])
            return
        }
        Task { @MainActor in
            let sent = await self.handleOutgoingSignaling?(remoteUserId, message) ?? false
            _ = try? endpoint.command(sent ? "signalingMessageSent" : "signalingMessageSendFailed", ["callId": .id(callId)])
        }
    }
}
