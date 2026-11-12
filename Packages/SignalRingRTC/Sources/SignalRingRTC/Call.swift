// `Call` (Service.ts): a 1:1 call. Outgoing media starts when the call is accepted and
// stops when it ends; mute changes before that are remembered.

import Foundation

@MainActor
public final class Call {
    let endpoint: any RingRTCEndpoint
    /// The endpoint generation the call was made on: once that endpoint is lost, nothing the
    /// call sends reaches its replacement.
    let generation: UInt64
    public let remoteUserId: UserId
    public internal(set) var callId: CallId
    public let isIncoming: Bool
    public let isVideoCall: Bool
    var mediaSessionStarted = false
    var outgoingAudioEnabled = false
    var outgoingVideoEnabled = false
    var outgoingVideoIsScreenShare = false
    public internal(set) var remoteAudioEnabled = false
    public internal(set) var remoteVideoEnabled = false
    public internal(set) var outgoingAudioLevel: NormalizedAudioLevel = 0
    public internal(set) var remoteAudioLevel: NormalizedAudioLevel = 0
    public internal(set) var remoteSharingScreen = false
    public internal(set) var networkRoute = NetworkRoute()
    public internal(set) var endedReason: CallEndReason?
    public internal(set) var summary: CallSummary?

    public var handleStateChanged: (() -> Void)?
    public var handleRemoteAudioEnabled: (() -> Void)?
    public var handleRemoteVideoEnabled: (() -> Void)?
    public var handleRemoteSharingScreen: (() -> Void)?
    public var handleNetworkRouteChanged: (() -> Void)?
    public var handleAudioLevels: (() -> Void)?
    public var handleLowBandwidthForVideo: ((Bool) -> Void)?

    init(endpoint: any RingRTCEndpoint, remoteUserId: UserId, callId: CallId, isIncoming: Bool, isVideoCall: Bool, state: CallState,
         generation: UInt64? = nil) {
        self.endpoint = endpoint
        self.generation = generation ?? endpoint.generation
        self.remoteUserId = remoteUserId
        self.callId = callId
        self.isIncoming = isIncoming
        self.isVideoCall = isVideoCall
        _state = state
    }

    var _state: CallState

    public var state: CallState {
        get { _state }
        set {
            guard newValue != _state else { return }
            _state = newValue
            if newValue == .accepted {
                if !mediaSessionStarted {
                    run("setOutgoingAudioEnabled", ["enabled": .bool(outgoingAudioEnabled)])
                    if outgoingVideoIsScreenShare {
                        run("setOutgoingVideoIsScreenShare", ["isScreenshare": .bool(true)])
                        run("setOutgoingVideoEnabled", ["enabled": .bool(true)])
                    } else if outgoingVideoEnabled {
                        run("setOutgoingVideoEnabled", ["enabled": .bool(true)])
                    }
                    mediaSessionStarted = true
                }
            } else if newValue == .ended {
                run("setOutgoingAudioEnabled", ["enabled": .bool(false)])
                run("setOutgoingVideoEnabled", ["enabled": .bool(false)])
                run("setMicrophoneWarmupEnabled", ["enabled": .bool(false), "requestId": .int(0)])
                outgoingAudioEnabled = false
                outgoingVideoEnabled = false
                outgoingVideoIsScreenShare = false
                mediaSessionStarted = false
            }
            handleStateChanged?()
        }
    }

    public func setCallEnded() { _state = .ended }

    func run(_ name: String, _ fields: [String: JSONValue] = [:]) { _ = try? endpoint.command(name, fields, generation: generation) }

    public func accept() { run("accept", ["callId": .id(callId)]) }
    public func decline() { hangup() }
    public func ignore() { run("ignore", ["callId": .id(callId)]) }
    public func hangup() { run("hangup") }

    public func setOutgoingAudioMuted(_ muted: Bool) {
        let enabled = !muted
        if mediaSessionStarted && outgoingAudioEnabled != enabled {
            outgoingAudioEnabled = enabled
            run("setOutgoingAudioEnabled", ["enabled": .bool(enabled)])
        } else {
            outgoingAudioEnabled = enabled
        }
    }

    public func setOutgoingVideoMuted(_ muted: Bool) {
        let enabled = !muted
        if mediaSessionStarted && outgoingVideoEnabled != enabled {
            outgoingVideoEnabled = enabled
            run("setOutgoingVideoEnabled", ["enabled": .bool(enabled)])
        } else {
            outgoingVideoEnabled = enabled
        }
    }

    public func setOutgoingVideoIsScreenShare(_ isScreenShare: Bool) {
        if mediaSessionStarted && outgoingVideoIsScreenShare != isScreenShare {
            outgoingVideoIsScreenShare = isScreenShare
            run("setOutgoingVideoIsScreenShare", ["isScreenshare": .bool(isScreenShare)])
        } else {
            outgoingVideoIsScreenShare = isScreenShare
        }
    }

    /// `VideoFrameSender`
    @discardableResult
    public func sendVideoFrame(width: Int, height: Int, format: VideoPixelFormat, buffer: [UInt8]) -> Bool {
        endpoint.sendVideoFrame(width: width, height: height, format: format, data: buffer, generation: generation)
    }

    /// `VideoFrameSource`: the latest remote frame as RGBA.
    public func receiveVideoFrame(into buffer: inout [UInt8], maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int)? {
        endpoint.receiveVideoFrame(demuxId: 0, maxWidth: maxWidth, maxHeight: maxHeight, into: &buffer, generation: generation)
    }

    public func updateDataMode(_ mode: DataMode) {
        run("updateDataMode", ["dataMode": .int(Int64(mode.rawValue))])
    }
}
