// The value types and enums of ringrtc's Service.ts / CallLinks.ts / CallSummary.ts.

import Foundation

public typealias UserId = String
public typealias DeviceId = UInt32
public typealias CallId = UInt64
public typealias GroupCallClientId = UInt32
public typealias GroupId = Data
public typealias GroupCallUserId = Data
/// Raw (0…32767) and normalised (0…1) audio levels.
public typealias NormalizedAudioLevel = Double

/// `callIdFromEra`
public func callIdFromEra(_ era: String) -> CallId {
    (try? NativeEndpoint.command(0, "callIdFromEra", ["era": .string(era)]).uint64) ?? 0
}

/// `callIdFromRingId`: the ring id's bits as an unsigned call id.
public func callIdFromRingId(_ ringId: Int64) -> CallId { CallId(bitPattern: ringId) }

func normalizeAudioLevel(_ raw: Double) -> NormalizedAudioLevel { raw / 32767 }

public struct PeekDeviceInfo: Sendable, Equatable {
    public var demuxId: UInt32
    public var userId: GroupCallUserId?
}

public struct Reaction: Sendable, Equatable {
    public var demuxId: UInt32
    public var value: String
}

public struct PeekInfo: Sendable, Equatable {
    public var devices: [PeekDeviceInfo] = []
    public var creator: GroupCallUserId?
    public var eraId: String?
    public var maxDevices: Int?
    public var deviceCount: Int = 0
    public var deviceCountIncludingPendingDevices: Int = 0
    public var deviceCountExcludingPendingDevices: Int = 0
    public var pendingUsers: [GroupCallUserId] = []
    public var callLinkState: CallLinkState?

    public init() {}

    init(_ j: JSONValue) {
        devices = j["devices"].array.map { PeekDeviceInfo(demuxId: UInt32(clamping: $0["demuxId"].int ?? 0), userId: $0["userId"].data) }
        creator = j["creator"].data
        eraId = j["eraId"].string
        maxDevices = j["maxDevices"].int
        deviceCountIncludingPendingDevices = j["deviceCountIncludingPendingDevices"].int ?? 0
        deviceCountExcludingPendingDevices = j["deviceCountExcludingPendingDevices"].int ?? 0
        deviceCount = deviceCountIncludingPendingDevices   // "for backwards compatibility"
        pendingUsers = j["pendingUsers"].array.compactMap(\.data)
        callLinkState = j["callLinkState"].isNull ? nil : CallLinkState(j["callLinkState"])
    }
}

public enum PeekStatusCodes: Int, Sendable {
    case expiredCallLink = 703
    case invalidCallLink = 704
}

/// `NetworkAdapterType`
public struct NetworkAdapterType: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let ethernet = Self(rawValue: 1 << 0), wifi = Self(rawValue: 1 << 1), cellular = Self(rawValue: 1 << 2)
    public static let vpn = Self(rawValue: 1 << 3), loopback = Self(rawValue: 1 << 4), `default` = Self(rawValue: 1 << 5)
    public static let cellular2G = Self(rawValue: 1 << 6), cellular3G = Self(rawValue: 1 << 7), cellular4G = Self(rawValue: 1 << 8), cellular5G = Self(rawValue: 1 << 9)
}

public struct NetworkRoute: Sendable, Equatable {
    public var localAdapterType = NetworkAdapterType(rawValue: 0)
}

public struct ReceivedAudioLevel: Sendable, Equatable {
    public var demuxId: UInt32
    public var level: Double
}

/// `CallLinkRootKey`
public struct CallLinkRootKey: Sendable, Hashable {
    public let bytes: Data
    init(unchecked bytes: Data) { self.bytes = bytes }

    public static func parse(_ string: String) throws -> CallLinkRootKey {
        guard let b = try NativeEndpoint.command(0, "callLinkRootKeyParse", ["string": .string(string)]).data else { throw RingRTCError.invalidResponse }
        return CallLinkRootKey(unchecked: b)
    }

    public static func fromBytes(_ bytes: Data) throws -> CallLinkRootKey {
        _ = try NativeEndpoint.command(0, "callLinkRootKeyValidate", ["bytes": .bytes(bytes)])
        return CallLinkRootKey(unchecked: bytes)
    }

    public static func generate() throws -> CallLinkRootKey {
        guard let b = try NativeEndpoint.command(0, "callLinkRootKeyGenerate").data else { throw RingRTCError.invalidResponse }
        return CallLinkRootKey(unchecked: b)
    }

    public static func generateAdminPassKey() throws -> Data {
        guard let b = try NativeEndpoint.command(0, "callLinkRootKeyGenerateAdminPasskey").data else { throw RingRTCError.invalidResponse }
        return b
    }

    /// `toFormattedString`: the consonant base-16 form used in call link URLs (`bcdf-ghkm-…`).
    public func formatted() throws -> String {
        guard let s = try NativeEndpoint.command(0, "callLinkRootKeyToFormattedString", ["bytes": .bytes(bytes)]).string else {
            throw RingRTCError.invalidResponse
        }
        return s
    }

    public func deriveRoomId() throws -> Data {
        guard let b = try NativeEndpoint.command(0, "callLinkRootKeyDeriveRoomId", ["bytes": .bytes(bytes)]).data else { throw RingRTCError.invalidResponse }
        return b
    }

    public func toUnredactedString() throws -> String {
        guard let s = try NativeEndpoint.command(0, "callLinkRootKeyToFormattedString", ["bytes": .bytes(bytes)]).string else { throw RingRTCError.invalidResponse }
        return s
    }

    /// `toString`: redacted, for logs.
    public var redacted: String {
        (try? NativeEndpoint.command(0, "callLinkRootKeyToRedactedString", ["bytes": .bytes(bytes)]).string) ?? "[REDACTED]"
    }
}

public enum CallLinkRestrictions: Int, Sendable {
    case none = 0, adminApproval = 1, unknown = 2
}

public struct CallLinkState: Sendable, Equatable {
    public var name: String
    public var restrictions: CallLinkRestrictions
    public var revoked: Bool
    public var expiration: Date
    public var rootKey: CallLinkRootKey

    init?(_ j: JSONValue) {
        guard let name = j["name"].string, let key = j["rootKey"].data else { return nil }
        self.name = name
        restrictions = switch j["rawRestrictions"].int {
        case 0: .none
        case 1: .adminApproval
        default: .unknown
        }
        revoked = j["revoked"].bool ?? false
        expiration = Date(timeIntervalSince1970: (j["expirationMillis"].double ?? 0) / 1000)
        rootKey = CallLinkRootKey(unchecked: key)
    }
}

public struct MediaQualityStats: Sendable, Equatable {
    public var rttMedianMillis: Double?
    public var jitterMedianSendMillis: Double?
    public var jitterMedianRecvMillis: Double?
    public var packetLossFractionSend: Double?
    public var packetLossFractionRecv: Double?
    init(_ j: JSONValue) {
        rttMedianMillis = j["rttMedianMillis"].double
        jitterMedianSendMillis = j["jitterMedianSendMillis"].double
        jitterMedianRecvMillis = j["jitterMedianRecvMillis"].double
        packetLossFractionSend = j["packetLossFractionSend"].double
        packetLossFractionRecv = j["packetLossFractionRecv"].double
    }
}

public struct QualityStats: Sendable, Equatable {
    public var rttMedianConnectionMillis: Double?
    public var audioStats: MediaQualityStats
    public var videoStats: MediaQualityStats
    init(_ j: JSONValue) {
        rttMedianConnectionMillis = j["rttMedianConnectionMillis"].double
        audioStats = MediaQualityStats(j["audioStats"])
        videoStats = MediaQualityStats(j["videoStats"])
    }
}

public struct CallSummary: Sendable, Equatable {
    public var callIdHash: Data?
    public var startTime: Double
    public var endTime: Double
    public var qualityStats: QualityStats
    public var rawStats: Data?
    public var rawStatsText: String?
    public var callEndReasonText: String
    public var isSurveyCandidate: Bool
    init(_ j: JSONValue) {
        callIdHash = j["callIdHash"].data
        startTime = j["startTime"].double ?? 0
        endTime = j["endTime"].double ?? 0
        qualityStats = QualityStats(j["qualityStats"])
        rawStats = j["rawStats"].data
        rawStatsText = j["rawStatsText"].string
        callEndReasonText = j["callEndReasonText"].string ?? ""
        isSurveyCandidate = j["isSurveyCandidate"].bool ?? false
    }
}

public struct AudioDevice: Sendable, Equatable, Hashable {
    public var name: String
    public var uniqueId: String
    init?(_ j: JSONValue) {
        guard let n = j["name"].string, let u = j["uniqueId"].string else { return nil }
        name = n
        uniqueId = u
    }
    public init(name: String, uniqueId: String) {
        self.name = name
        self.uniqueId = uniqueId
    }
}

public struct AudioDeviceList: Sendable, Equatable {
    public var devices: [AudioDevice]
    /// The system default (macOS: one device).
    public var defaultDevice: AudioDevice?
    init(_ j: JSONValue) {
        devices = j["devices"].array.compactMap(AudioDevice.init)
        defaultDevice = AudioDevice(j["defaults"]["device"])
    }
}

public struct AudioDeviceInitError: Error, Sendable, Equatable {
    public var audioDevice: AudioDevice?
}

/// `truncateForLogging`
public func truncateForLogging(_ name: String?) -> String {
    guard let name else { return "undefined" }
    return name.count <= 4 ? name : "\(name.prefix(2))...\(name.suffix(2))"
}

public enum ConnectionState: Int, Sendable { case notConnected = 0, connecting, connected, reconnecting }
public enum JoinState: Int, Sendable { case notJoined = 0, joining, pending, joined }
public enum SpeechEvent: Int, Sendable { case stoppedSpeaking = 0, lowerHandSuggestion }
public enum CallMessageUrgency: Int, Sendable { case droppable = 0, handleImmediately }
public enum RingUpdate: Int, Sendable {
    case requested = 0, expiredRequest, acceptedOnAnotherDevice, declinedOnAnotherDevice, busyLocally, busyOnAnotherDevice, cancelledByRinger
}
public enum HttpMethod: Int, Sendable { case get = 0, put, post, delete }
public enum OfferType: Int, Sendable { case audioCall = 0, videoCall = 1 }
public enum HangupType: Int, Sendable { case normal = 0, accepted, declined, busy, needPermission }
public enum DataMode: Int, Sendable { case low = 0, normal = 1 }
public enum RingCancelReason: Int, Sendable { case declinedByUser = 0, busy }
public enum GroupCallKind: Sendable { case signalGroup, callLink }
public enum CallLogLevel: Int, Sendable { case off = 0, error, warn, info, debug, trace }

/// ringrtc's call state names.
public enum CallState: String, Sendable {
    case prering = "idle", ringing = "ringing", accepted = "connected", reconnecting = "connecting", ended = "ended"
}

public enum CallEndReason: Int, Sendable {
    case localHangup = 0, remoteHangup, remoteHangupNeedPermission, remoteHangupAccepted, remoteHangupDeclined, remoteHangupBusy, remoteBusy,
         remoteGlare, remoteReCall, timeout, internalFailure, signalingFailure, connectionFailure, appDroppedCall, deviceExplicitlyDisconnected,
         serverExplicitlyDisconnected, deniedRequestToJoinCall, removedFromCall, callManagerIsBusy, sfuClientFailedToJoin,
         failedToCreatePeerConnectionFactory, failedToNegotiatedSrtpKeys, failedToCreatePeerConnection, failedToStartPeerConnection,
         failedToUpdatePeerConnection, failedToSetMaxSendBitrate, iceFailedWhileConnecting, iceFailedAfterConnected, serverChangedDemuxId, hasMaxDevices
}

public enum CallRejectReason: Int, Sendable { case glareHandlingFailure = 0, receivedOfferExpired, receivedOfferWhileActive, receivedOfferWithGlare }

public struct IceServer: Sendable, Equatable {
    public var username: String?
    public var password: String?
    public var hostname: String?
    public var urls: [String]
    public init(username: String? = nil, password: String? = nil, hostname: String? = nil, urls: [String]) {
        self.username = username
        self.password = password
        self.hostname = hostname
        self.urls = urls
    }
}

/// `CallSettings`
public struct CallSettings: Sendable {
    public var iceServers: [IceServer]
    public var hideIp: Bool
    public var dataMode: DataMode
    public var audioLevelsIntervalMillis: Int?
    public var dredDuration: Int?
    public var enableVp9Encode: Bool?
    public var enableVp9Decode: Bool?
    public var statsIntervalSecs: Int?
    public init(iceServers: [IceServer], hideIp: Bool, dataMode: DataMode, audioLevelsIntervalMillis: Int? = nil, dredDuration: Int? = nil,
                enableVp9Encode: Bool? = nil, enableVp9Decode: Bool? = nil, statsIntervalSecs: Int? = nil) {
        self.iceServers = iceServers
        self.hideIp = hideIp
        self.dataMode = dataMode
        self.audioLevelsIntervalMillis = audioLevelsIntervalMillis
        self.dredDuration = dredDuration
        self.enableVp9Encode = enableVp9Encode
        self.enableVp9Decode = enableVp9Decode
        self.statsIntervalSecs = statsIntervalSecs
    }
}

public struct GroupCallSvcConfig: Sendable, Equatable {
    public var mode: String
    public var modeForScreenshare: String
    public var maxBitrateBps: Int?
    public init(mode: String, modeForScreenshare: String, maxBitrateBps: Int? = nil) {
        self.mode = mode
        self.modeForScreenshare = modeForScreenshare
        self.maxBitrateBps = maxBitrateBps
    }
    var json: JSONValue {
        .object(["mode": .string(mode), "modeForScreenshare": .string(modeForScreenshare), "maxBitrateBps": maxBitrateBps.map { .int(Int64($0)) } ?? .null])
    }
}

public struct GroupMemberInfo: Sendable, Equatable {
    public var userId: Data
    public var userIdCipherText: Data
    public init(userId: Data, userIdCipherText: Data) {
        self.userId = userId
        self.userIdCipherText = userIdCipherText
    }
    var json: JSONValue { .object(["userId": .bytes(userId), "userIdCipherText": .bytes(userIdCipherText)]) }
}

public struct VideoRequest: Sendable, Equatable {
    public var demuxId: UInt32
    public var width: Int
    public var height: Int
    public var framerate: Int?
    public init(demuxId: UInt32, width: Int, height: Int, framerate: Int? = nil) {
        self.demuxId = demuxId
        self.width = width
        self.height = height
        self.framerate = framerate
    }
    var json: JSONValue {
        .object(["demuxId": .int(Int64(demuxId)), "width": .int(Int64(width)), "height": .int(Int64(height)), "framerate": framerate.map { .int(Int64($0)) } ?? .null])
    }
}

public struct LocalDeviceState: Sendable, Equatable {
    public var connectionState = ConnectionState.notConnected
    public var joinState = JoinState.notJoined
    public var demuxId: UInt32?
    public var audioMuted = true
    public var videoMuted = true
    public var audioLevel: NormalizedAudioLevel = 0
    public var presenting = false
    public var sharingScreen = false
    public var networkRoute = NetworkRoute()
}

public struct RemoteDeviceState: Sendable, Equatable {
    public var demuxId: UInt32
    public var userId: Data
    public var mediaKeysReceived: Bool
    public var audioMuted: Bool?
    public var videoMuted: Bool?
    public var audioLevel: NormalizedAudioLevel = 0
    public var presenting: Bool?
    public var sharingScreen: Bool?
    public var videoAspectRatio: Double?
    /// Unix milliseconds.
    public var addedTime: UInt64
    /// Unix milliseconds; 0 if they have never spoken.
    public var speakerTime: UInt64
    public var forwardingVideo: Bool?
    public var isHigherResolutionPending: Bool

    init(_ j: JSONValue) {
        demuxId = UInt32(clamping: j["demuxId"].int ?? 0)
        userId = j["userId"].data ?? Data()
        mediaKeysReceived = j["mediaKeysReceived"].bool ?? false
        audioMuted = j["audioMuted"].bool
        videoMuted = j["videoMuted"].bool
        presenting = j["presenting"].bool
        sharingScreen = j["sharingScreen"].bool
        addedTime = j["addedTime"].uint64 ?? 0
        speakerTime = j["speakerTime"].uint64 ?? 0
        forwardingVideo = j["forwardingVideo"].bool
        isHigherResolutionPending = j["isHigherResolutionPending"].bool ?? false
    }
}

/// `HttpResult<T>`
public enum HttpResult<T: Sendable>: Sendable {
    case success(T)
    case failure(errorStatusCode: Int)
}

// MARK: signaling messages (`CallingMessage` and its parts)

public struct OfferMessage: Sendable, Equatable {
    public var callId: CallId
    public var type: OfferType
    public var opaque: Data
    public init(callId: CallId, type: OfferType, opaque: Data) { self.callId = callId; self.type = type; self.opaque = opaque }
}

public struct AnswerMessage: Sendable, Equatable {
    public var callId: CallId
    public var opaque: Data
    public init(callId: CallId, opaque: Data) { self.callId = callId; self.opaque = opaque }
}

public struct IceCandidateMessage: Sendable, Equatable {
    public var callId: CallId
    public var opaque: Data
    public init(callId: CallId, opaque: Data) { self.callId = callId; self.opaque = opaque }
}

public struct BusyMessage: Sendable, Equatable {
    public var callId: CallId
    public init(callId: CallId) { self.callId = callId }
}

public struct HangupMessage: Sendable, Equatable {
    public var callId: CallId
    public var type: HangupType
    public var deviceId: DeviceId
    public init(callId: CallId, type: HangupType, deviceId: DeviceId) { self.callId = callId; self.type = type; self.deviceId = deviceId }
}

public struct OpaqueMessage: Sendable, Equatable {
    public var data: Data?
    public init(data: Data?) { self.data = data }
}

public struct CallingMessage: Sendable, Equatable {
    public var offer: OfferMessage?
    public var answer: AnswerMessage?
    public var iceCandidates: [IceCandidateMessage]?
    public var busy: BusyMessage?
    public var hangup: HangupMessage?
    public var opaque: OpaqueMessage?
    public var destinationDeviceId: DeviceId?
    public init(offer: OfferMessage? = nil, answer: AnswerMessage? = nil, iceCandidates: [IceCandidateMessage]? = nil, busy: BusyMessage? = nil,
                hangup: HangupMessage? = nil, opaque: OpaqueMessage? = nil, destinationDeviceId: DeviceId? = nil) {
        self.offer = offer
        self.answer = answer
        self.iceCandidates = iceCandidates
        self.busy = busy
        self.hangup = hangup
        self.opaque = opaque
        self.destinationDeviceId = destinationDeviceId
    }
}
