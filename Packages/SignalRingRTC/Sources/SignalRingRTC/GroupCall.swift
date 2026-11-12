// `GroupCall` (Service.ts): a group or call-link call through the SFU, its local and remote
// device states and peek info, reported to a `GroupCallObserver`.

import Foundation

@MainActor
public protocol GroupCallObserver: AnyObject {
    func requestMembershipProof(_ groupCall: GroupCall)
    func requestGroupMembers(_ groupCall: GroupCall)
    func onLocalDeviceStateChanged(_ groupCall: GroupCall)
    func onRemoteDeviceStatesChanged(_ groupCall: GroupCall)
    func onAudioLevels(_ groupCall: GroupCall)
    func onLowBandwidthForVideo(_ groupCall: GroupCall, recovered: Bool)
    func onReactions(_ groupCall: GroupCall, reactions: [Reaction])
    func onRaisedHands(_ groupCall: GroupCall, raisedHands: [UInt32])
    func onPeekChanged(_ groupCall: GroupCall)
    func onEnded(_ groupCall: GroupCall, reason: CallEndReason, summary: CallSummary)
    func onSpeechEvent(_ groupCall: GroupCall, event: SpeechEvent)
    func onRemoteMute(_ groupCall: GroupCall, demuxId: UInt32)
    func onObservedRemoteMute(_ groupCall: GroupCall, sourceDemuxId: UInt32, targetDemuxId: UInt32)
}

@MainActor
public final class GroupCall {
    public let kind: GroupCallKind
    let endpoint: any RingRTCEndpoint
    /// The endpoint generation the client was made on (as `Call.generation`).
    let generation: UInt64
    /// The group (Signal group calls), for checking what the endpoint asks to send.
    public internal(set) var groupId: GroupId?
    /// The members last given to ringrtc (`setGroupMembers`).
    public internal(set) var members: [GroupMemberInfo] = []
    weak var observer: (any GroupCallObserver)?
    public let clientId: GroupCallClientId
    public private(set) var localDeviceState = LocalDeviceState()
    public private(set) var remoteDeviceStates: [RemoteDeviceState]?
    public private(set) var peekInfo: PeekInfo?

    init(kind: GroupCallKind, endpoint: any RingRTCEndpoint, observer: any GroupCallObserver, clientId: GroupCallClientId, groupId: GroupId? = nil,
         generation: UInt64? = nil) {
        self.kind = kind
        self.endpoint = endpoint
        self.generation = generation ?? endpoint.generation
        self.groupId = groupId
        self.observer = observer
        self.clientId = clientId
    }

    func run(_ name: String, _ fields: [String: JSONValue] = [:]) {
        var f = fields
        f["clientId"] = .int(Int64(clientId))
        _ = try? endpoint.command(name, f, generation: generation)
    }

    public func connect() { run("connect") }
    public func join() { run("join") }
    public func leave() { run("leave") }
    public func disconnect() { run("disconnect") }

    /// The era id as a call id, once the call has one.
    public var callId: CallId? { peekInfo?.eraId.map(callIdFromEra) }

    public func setOutgoingAudioMuted(_ muted: Bool) {
        localDeviceState.audioMuted = muted
        run("setOutgoingAudioMuted", ["muted": .bool(muted)])
        observer?.onLocalDeviceStateChanged(self)
    }

    public func setOutgoingAudioMutedRemotely(source: UInt32) {
        localDeviceState.audioMuted = true
        run("setOutgoingAudioMutedRemotely", ["muteSource": .int(Int64(source))])
        observer?.onLocalDeviceStateChanged(self)
    }

    public func sendRemoteMuteRequest(target: UInt32) { run("sendRemoteMuteRequest", ["muteTarget": .int(Int64(target))]) }
    public func react(_ value: String) { run("groupReact", ["reaction": .string(value)]) }
    public func raiseHand(_ raise: Bool) { run("groupRaiseHand", ["raise": .bool(raise)]) }

    public func setOutgoingVideoMuted(_ muted: Bool) {
        localDeviceState.videoMuted = muted
        run("setOutgoingVideoMuted", ["muted": .bool(muted)])
        observer?.onLocalDeviceStateChanged(self)
    }

    public func setPresenting(_ presenting: Bool) {
        localDeviceState.presenting = presenting
        run("setPresenting", ["presenting": .bool(presenting)])
        observer?.onLocalDeviceStateChanged(self)
    }

    public func setOutgoingVideoIsScreenShare(_ isScreenShare: Bool) {
        localDeviceState.sharingScreen = isScreenShare
        run("setOutgoingGroupCallVideoIsScreenShare", ["isScreenshare": .bool(isScreenShare)])
        observer?.onLocalDeviceStateChanged(self)
    }

    public func ringAll() { run("groupRing") }
    public func resendMediaKeys() { run("resendMediaKeys") }
    public func setDataMode(_ mode: DataMode) { run("setDataMode", ["dataMode": .int(Int64(mode.rawValue))]) }

    public func requestVideo(_ resolutions: [VideoRequest], activeSpeakerHeight: Int) {
        run("requestVideo", ["resolutions": .array(resolutions.map(\.json)), "activeSpeakerHeight": .int(Int64(activeSpeakerHeight))])
    }

    public func approveUser(_ otherUserId: Data) { run("approveUser", ["otherUserId": .bytes(otherUserId)]) }
    public func denyUser(_ otherUserId: Data) { run("denyUser", ["otherUserId": .bytes(otherUserId)]) }
    public func removeClient(_ otherClientDemuxId: UInt32) { run("removeClient", ["otherDemuxId": .int(Int64(otherClientDemuxId))]) }
    public func blockClient(_ otherClientDemuxId: UInt32) { run("blockClient", ["otherDemuxId": .int(Int64(otherClientDemuxId))]) }
    public func setGroupMembers(_ members: [GroupMemberInfo]) {
        self.members = members
        run("setGroupMembers", ["members": .array(members.map(\.json))])
    }
    public func setMembershipProof(_ proof: Data) { run("setMembershipProof", ["proof": .bytes(proof)]) }
    public func setRtcStatsInterval(millis: Int) { run("setRtcStatsInterval", ["intervalMillis": .int(Int64(millis))]) }

    /// `VideoFrameSender`
    @discardableResult
    public func sendVideoFrame(width: Int, height: Int, format: VideoPixelFormat, buffer: [UInt8]) -> Bool {
        endpoint.sendVideoFrame(width: width, height: height, format: format, data: buffer, generation: generation)
    }

    /// `GroupCallVideoFrameSource.receiveVideoFrame`: also records the remote aspect ratio.
    public func receiveVideoFrame(demuxId: UInt32, into buffer: inout [UInt8], maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int)? {
        guard let f = endpoint.receiveVideoFrame(demuxId: demuxId, maxWidth: maxWidth, maxHeight: maxHeight, into: &buffer, generation: generation) else { return nil }
        setRemoteAspectRatio(demuxId: demuxId, Double(f.width) / Double(max(1, f.height)))
        return f
    }

    func setRemoteAspectRatio(demuxId: UInt32, _ aspectRatio: Double) {
        guard let i = remoteDeviceStates?.firstIndex(where: { $0.demuxId == demuxId }), remoteDeviceStates?[i].videoAspectRatio != aspectRatio else { return }
        remoteDeviceStates?[i].videoAspectRatio = aspectRatio
        observer?.onRemoteDeviceStatesChanged(self)
    }

    // MARK: from RingRTC

    func handleConnectionStateChanged(_ s: ConnectionState) {
        localDeviceState.connectionState = s
        observer?.onLocalDeviceStateChanged(self)
    }

    func handleJoinStateChanged(_ s: JoinState, demuxId: UInt32?) {
        localDeviceState.joinState = s
        if let demuxId { localDeviceState.demuxId = demuxId }
        observer?.onLocalDeviceStateChanged(self)
    }

    func handleNetworkRouteChanged(_ type: NetworkAdapterType) {
        localDeviceState.networkRoute.localAdapterType = type
        observer?.onLocalDeviceStateChanged(self)
    }

    func handleAudioLevels(captured: Double, received: [ReceivedAudioLevel]) {
        localDeviceState.audioLevel = normalizeAudioLevel(captured)
        if var states = remoteDeviceStates {
            for r in received {
                for i in states.indices where states[i].demuxId == r.demuxId {
                    states[i].audioLevel = normalizeAudioLevel(r.level)
                }
            }
            remoteDeviceStates = states
        }
        observer?.onAudioLevels(self)
    }

    func handleRemoteDevicesChanged(_ states: [RemoteDeviceState]) {
        var states = states
        for i in states.indices {
            states[i].videoAspectRatio = remoteDeviceStates?.first { $0.demuxId == states[i].demuxId }?.videoAspectRatio
        }
        remoteDeviceStates = states
        observer?.onRemoteDeviceStatesChanged(self)
    }

    func handlePeekChanged(_ info: PeekInfo) {
        peekInfo = info
        observer?.onPeekChanged(self)
    }

    func handleEnded(_ reason: CallEndReason, _ summary: CallSummary) {
        run("deleteGroupCallClient")
        observer?.onEnded(self, reason: reason, summary: summary)
    }
}
