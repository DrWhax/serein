// `Call` (Service.ts): a 1:1 call. Outgoing media starts when the call is accepted and
// stops when it ends; mute changes before that are remembered.

import Foundation

@MainActor
public final class Call {
    let endpoint: NativeEndpoint
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

    init(endpoint: NativeEndpoint, remoteUserId: UserId, callId: CallId, isIncoming: Bool, isVideoCall: Bool, state: CallState) {
        self.endpoint = endpoint
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
                    _ = try? endpoint.command("setOutgoingAudioEnabled", ["enabled": .bool(outgoingAudioEnabled)])
                    if outgoingVideoIsScreenShare {
                        _ = try? endpoint.command("setOutgoingVideoIsScreenShare", ["isScreenshare": .bool(true)])
                        _ = try? endpoint.command("setOutgoingVideoEnabled", ["enabled": .bool(true)])
                    } else if outgoingVideoEnabled {
                        _ = try? endpoint.command("setOutgoingVideoEnabled", ["enabled": .bool(true)])
                    }
                    mediaSessionStarted = true
                }
            } else if newValue == .ended {
                _ = try? endpoint.command("setOutgoingAudioEnabled", ["enabled": .bool(false)])
                _ = try? endpoint.command("setOutgoingVideoEnabled", ["enabled": .bool(false)])
                _ = try? endpoint.command("setMicrophoneWarmupEnabled", ["enabled": .bool(false), "requestId": .int(0)])
                outgoingAudioEnabled = false
                outgoingVideoEnabled = false
                outgoingVideoIsScreenShare = false
                mediaSessionStarted = false
            }
            handleStateChanged?()
        }
    }

    public func setCallEnded() { _state = .ended }

    public func accept() { _ = try? endpoint.command("accept", ["callId": .id(callId)]) }
    public func decline() { hangup() }
    public func ignore() { _ = try? endpoint.command("ignore", ["callId": .id(callId)]) }
    public func hangup() { _ = try? endpoint.command("hangup") }

    public func setOutgoingAudioMuted(_ muted: Bool) {
        let enabled = !muted
        if mediaSessionStarted && outgoingAudioEnabled != enabled {
            outgoingAudioEnabled = enabled
            _ = try? endpoint.command("setOutgoingAudioEnabled", ["enabled": .bool(enabled)])
        } else {
            outgoingAudioEnabled = enabled
        }
    }

    public func setOutgoingVideoMuted(_ muted: Bool) {
        let enabled = !muted
        if mediaSessionStarted && outgoingVideoEnabled != enabled {
            outgoingVideoEnabled = enabled
            _ = try? endpoint.command("setOutgoingVideoEnabled", ["enabled": .bool(enabled)])
        } else {
            outgoingVideoEnabled = enabled
        }
    }

    public func setOutgoingVideoIsScreenShare(_ isScreenShare: Bool) {
        if mediaSessionStarted && outgoingVideoIsScreenShare != isScreenShare {
            outgoingVideoIsScreenShare = isScreenShare
            _ = try? endpoint.command("setOutgoingVideoIsScreenShare", ["isScreenshare": .bool(isScreenShare)])
        } else {
            outgoingVideoIsScreenShare = isScreenShare
        }
    }

    /// `VideoFrameSender`
    @discardableResult
    public func sendVideoFrame(width: Int, height: Int, format: VideoPixelFormat, buffer: [UInt8]) -> Bool {
        endpoint.sendVideoFrame(width: width, height: height, format: format, data: buffer)
    }

    /// `VideoFrameSource`: the latest remote frame as RGBA.
    public func receiveVideoFrame(into buffer: inout [UInt8], maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int)? {
        endpoint.receiveVideoFrame(demuxId: 0, maxWidth: maxWidth, maxHeight: maxHeight, into: &buffer)
    }

    public func updateDataMode(_ mode: DataMode) {
        _ = try? endpoint.command("updateDataMode", ["dataMode": .int(Int64(mode.rawValue))])
    }
}
