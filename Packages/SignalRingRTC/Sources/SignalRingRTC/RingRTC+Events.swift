// RingRTCType's event side (the `CallManagerCallbacks` electron.rs's processEvents calls):
// each JSON event from the endpoint, dispatched like Service.ts.

import Foundation

extension RingRTC {
    func process(_ batch: [JSONValue]) {
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
            guard let call, call.remoteUserId == peer, let s = e["state"].string else { return }
            // Upstream maps the native state names through its CallState enum.
            if let state = CallState(rawValue: s) { call.state = state }
        case "onCallRejected":
            onCallRejected(peer, callId: e["callId"].uint64 ?? 0, reason: CallRejectReason(rawValue: e["reason"].int ?? 0) ?? .glareHandlingFailure,
                           ageSec: e["ageSec"].double ?? 0)
        case "onCallEnded":
            let callId = e["callId"].uint64 ?? 0
            callInfoByCallId[callId] = nil
            if let call {
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
            guard let handleSendCallMessage else { logError("RingRTC.handleSendCallMessage is not set!"); return }
            handleSendCallMessage(e["recipientUuid"].data ?? Data(), e["message"].data ?? Data(), CallMessageUrgency(rawValue: e["urgency"].int ?? 0) ?? .droppable)
        case "sendCallMessageToGroup":
            guard let handleSendCallMessageToGroup else { logError("RingRTC.handleSendCallMessageToGroup is not set!"); return }
            handleSendCallMessageToGroup(e["groupId"].data ?? Data(), e["message"].data ?? Data(), CallMessageUrgency(rawValue: e["urgency"].int ?? 0) ?? .droppable,
                                         e["overrideRecipients"].array.compactMap(\.data))
        case "sendCallMessageToAdhocGroup":
            guard let handleSendCallMessageToAdhocGroup else { logError("RingRTC.handleSendCallMessageToAdhocGroup is not set!"); return }
            let pairs = e["recipientsToEndorsements"].array.compactMap { p -> (recipientId: Data, endorsement: Data)? in
                guard let r = p["recipientId"].data, let d = p["endorsement"].data else { return nil }
                return (r, d)
            }
            handleSendCallMessageToAdhocGroup(e["message"].data ?? Data(), CallMessageUrgency(rawValue: e["urgency"].int ?? 0) ?? .droppable,
                                              Date(timeIntervalSince1970: (e["expirationMillis"].double ?? 0) / 1000), pairs)
        case "groupCallRingUpdate":
            guard let handleGroupCallRingUpdate else { logError("RingRTC.handleGroupCallRingUpdate is not set!"); return }
            handleGroupCallRingUpdate(e["groupId"].data ?? Data(), e["ringId"].int64 ?? 0, e["sender"].data ?? Data(), RingUpdate(rawValue: e["update"].int ?? 0) ?? .requested)
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

    func onStartOutgoingCall(_ remoteUserId: UserId, callId: CallId) {
        guard let call, call.remoteUserId == remoteUserId else { return }
        call.callId = callId
        guard let handleStartCall else { call.ignore(); return }
        Task { @MainActor in
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
        let call = Call(endpoint: endpoint, remoteUserId: remoteUserId, callId: callId, isIncoming: true, isVideoCall: isVideoCall, state: .prering)
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
        Task { @MainActor in
            let sent = await self.handleOutgoingSignaling?(remoteUserId, message) ?? false
            _ = try? endpoint.command(sent ? "signalingMessageSent" : "signalingMessageSendFailed", ["callId": .id(callId)])
        }
    }
}
