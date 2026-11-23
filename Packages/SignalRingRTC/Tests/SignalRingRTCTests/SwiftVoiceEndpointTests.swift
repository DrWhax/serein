import CryptoKit
import Foundation
import SignalRingRTC
import SwiftCalling
import SwiftCallingServiceAdapter
import Testing

struct SwiftVoiceEndpointTests {
    private actor Microphone: VoiceCallMicrophone {
        var starts = 0
        func start() async throws -> AsyncStream<[Int16]> {
            starts += 1
            return AsyncStream { $0.finish() }
        }
        func stop() {}
    }

    private actor Speaker: VoiceCallSpeaker {
        var starts = 0
        func start() throws { starts += 1 }
        func enqueue(_ samples: [Int16], timestamp: UInt32) throws {}
        func stop() {}
    }

    private let mic = Microphone()
    private let speaker = Speaker()

    private func make() throws -> any LocalCallEndpoint {
        try SwiftVoiceEndpoint.factory(devices: { [mic, speaker] in VoiceCallDevices(microphone: mic, speaker: speaker) })("")
    }

    private func events(_ endpoint: any LocalCallEndpoint) throws -> [JSONValue] {
        try JSONDecoder().decode([JSONValue].self, from: Data(endpoint.waitEventsJSON(timeoutMs: 0)))
    }

    private let peer: [String: JSONValue] = ["peerId": .string("alice"), "senderDeviceId": .int(2)]

    private func description(_ id: UInt64) -> [String: JSONValue] {
        var params = DirectCallParameters()
        params.publicKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        params.iceUfrag = "test"
        params.icePassword = "secret"
        params.encoders = [8]
        params.decoders = [8]
        return peer.merging(["callId": .id(id), "receiverDeviceId": .int(1), "ageSec": .int(0),
                             "opaque": .bytes(params.envelope()), "offerType": .int(0),
                             "senderIdentityKey": .bytes(Data(repeating: 0x11, count: 32)),
                             "receiverIdentityKey": .bytes(Data(repeating: 0x22, count: 32))]) { $1 }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_DRED_WEIGHTS"] != nil))
    func registersPinnedModelThroughBothAssetHandles() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SEREIN_DRED_WEIGHTS"])
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        var corrupted = original
        corrupted[corrupted.startIndex] ^= 128
        for handle: [String: JSONValue] in [["content": .bytes(original + Data([0, 0]))], ["filePath": .string(path)]] {
            let endpoint = try make()
            defer { endpoint.close() }
            let group = ["assetGroup": JSONValue.string("opus-dred")]
            #expect(throws: (any Error).self) {
                try endpoint.command("addAsset", group.merging(["content": .bytes(corrupted)]) { $1 })
            }
            let command = try JSONValue.command("addAsset", group.merging(handle) { $1 })
            let reply = try endpoint.commandJSON(command)
            #expect(try JSONDecoder().decode(JSONValue.self, from: Data(reply)) == .null)
            #expect(throws: (any Error).self) { try endpoint.commandJSON(command) }
        }
    }

    @Test func incomingUsesAppApprovalBeforeAnswerAndIgnoresOtherDevices() async throws {
        let endpoint = try make()
        defer { endpoint.close() }
        let id = UInt64.max - 2
        let offer = description(id)
        let reply = try endpoint.commandJSON(JSONValue.command("receivedOffer", offer))
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(reply)) == .null)
        let invitation = try #require(events(endpoint).only)
        #expect(invitation["type"].string == "onStartIncomingCall")
        #expect(invitation["callId"].uint64 == id && invitation["remoteUserId"].string == "alice")
        _ = try endpoint.command("proceed", ["callId": .id(id), "iceServers": .array([]), "hideIp": .bool(false)])
        let answer = try #require(events(endpoint).only)
        #expect(answer["type"].string == "onSendAnswer")
        #expect(answer["remoteDeviceId"].int == 2 && answer["broadcast"].bool == false)
        let description = try DirectCallParameters(envelope: #require(answer["opaque"].data))
        #expect(description.publicKey?.count == 32)
        #expect(description.publicKey != (try DirectCallParameters(envelope: #require(offer["opaque"]?.data))).publicKey)
        for field in ["peerId", "senderDeviceId", "callId"] {
            var wrong = offer
            wrong[field] = field == "peerId" ? .string("different") : .int(5)
            wrong["hangupType"] = .int(0)
            _ = try endpoint.command("receivedHangup", wrong)
        }
        _ = try endpoint.command("setOutgoingAudioEnabled", ["callId": .id(id), "enabled": .bool(true)])
        #expect(try events(endpoint).isEmpty)
        _ = try endpoint.command("hangup", ["callId": .id(id)])
        #expect(try events(endpoint).map { $0["type"].string } == ["onSendHangup", "onCallEnded"])
        #expect(await mic.starts == 0)
        #expect(await speaker.starts == 0)
    }

    @Test func outgoingBindsAnswerAndPreAnswerCandidatesToPeerDevice() throws {
        let endpoint = try make()
        defer { endpoint.close() }
        let outgoing: [String: JSONValue] = ["peerId": .string("alice"), "localDeviceId": .int(1), "videoEnabled": .bool(false)]
        let id = try #require(endpoint.command("createOutgoingCall", outgoing).uint64)
        #expect(try events(endpoint).only?["type"].string == "onStartOutgoingCall")
        _ = try endpoint.command("proceed", ["callId": .id(id), "iceServers": .array([]), "hideIp": .bool(false)])
        let offer = try #require(events(endpoint).only)
        #expect(offer["type"].string == "onSendOffer" && offer["broadcast"].bool == true)
        var answer = description(id)
        let otherICE = IceCandidateUpdate(addedSDP: "unsupported candidate on another device")
        _ = try endpoint.command("receivedIceCandidates", ["peerId": .string("alice"), "callId": .id(id), "senderDeviceId": .int(3),
                                                          "candidates": .array([.bytes(otherICE.envelope())])])
        answer["peerId"] = .string("different")
        _ = try endpoint.command("receivedAnswer", answer)
        answer["peerId"] = .string("alice")
        _ = try endpoint.command("receivedAnswer", answer)
        answer["senderDeviceId"] = .int(3)
        _ = try endpoint.command("receivedBusy", answer)
        #expect(try events(endpoint).isEmpty)
        answer["senderDeviceId"] = .int(2)
        _ = try endpoint.command("receivedBusy", answer)
        let ended = try #require(events(endpoint).last)
        #expect(ended["reason"].int == CallEndReason.remoteBusy.rawValue)
        let next = try #require(endpoint.command("createOutgoingCall", outgoing).uint64)
        #expect(next != id)
        _ = try events(endpoint)
        for stale in ["hangup", "ignore", "signalingMessageSendFailed"] { _ = try endpoint.command(stale, ["callId": .id(id)]) }
        #expect(try events(endpoint).isEmpty)
        _ = try endpoint.command("ignore", ["callId": .id(next)])
        #expect(try events(endpoint).only?["reason"].int == CallEndReason.appDroppedCall.rawValue)
    }

    @Test func handlesExpiredBusyAndUnsupportedCallsAndClose() async throws {
        let endpoint = try make()
        var offer = description(75)
        offer["ageSec"] = .int(61)
        _ = try endpoint.command("receivedOffer", offer)
        #expect(try events(endpoint).only?["reason"].int == CallRejectReason.receivedOfferExpired.rawValue)
        offer["ageSec"] = .int(60)
        _ = try endpoint.command("receivedOffer", offer)
        #expect(try events(endpoint).only?["type"].string == "onStartIncomingCall")
        var second = offer
        second["peerId"] = .string("another peer")
        _ = try endpoint.command("receivedOffer", second)
        #expect(try events(endpoint).isEmpty)
        second["callId"] = .id(76)
        second["senderDeviceId"] = .int(5)
        _ = try endpoint.command("receivedOffer", second)
        let denied = try events(endpoint)
        #expect(denied.map { $0["type"].string } == ["onSendBusy", "onCallRejected"])
        #expect(denied.first?["callId"].uint64 == 76 && denied.first?["remoteDeviceId"].uint64 == 5)
        _ = try endpoint.command("accept", ["callId": .id(75)])
        _ = try endpoint.command("setOutgoingAudioEnabled", ["callId": .id(75), "enabled": .bool(true)])
        #expect(throws: RingRTCError.self) { try endpoint.command("createGroupCallClient", [:]) }
        endpoint.close()
        endpoint.close()
        #expect(!endpoint.isLive)
        #expect(endpoint.waitEvents(timeoutMs: 0) == .lost(generation: 0))
        #expect(throws: RingRTCError.lost) { try endpoint.command("proceed", ["callId": .id(75), "hideIp": .bool(false), "iceServers": .array([])]) }
        #expect(await mic.starts == 0)
        #expect(await speaker.starts == 0)
    }

    @Test func simultaneousOffersChooseHigherIDAndKeepCodecDirectionsIndependent() throws {
        let endpoint = try make()
        defer { endpoint.close() }
        _ = try endpoint.command("receivedOffer", description(50))
        _ = try events(endpoint)
        _ = try endpoint.command("receivedOffer", description(45))
        #expect(try events(endpoint).only?["reason"].int == CallRejectReason.receivedOfferWithGlare.rawValue)
        _ = try endpoint.command("receivedOffer", description(60))
        let changed = try events(endpoint)
        #expect(changed.contains { $0["type"].string == "onCallEnded" && $0["reason"].int == CallEndReason.remoteGlare.rawValue })
        #expect(changed.last?["callId"].uint64 == 60)
        _ = try endpoint.command("proceed", ["callId": .id(60), "iceServers": .array([]), "hideIp": .bool(false),
            "callConfig": .object(["dataMode": .int(Int64(DataMode.low.rawValue)), "enableVp9Encode": .bool(false), "enableVp9Decode": .bool(true)])])
        let bytes = try #require(events(endpoint).first { $0["type"].string == "onSendAnswer" }?["opaque"].data)
        let answer = try DirectCallParameters(envelope: bytes)
        #expect(answer.encoders == [8] && answer.decoders == [9,8])
        #expect(answer.maxBitrateBps == LiveVoiceSession.maxBitrate(lowDataMode: true))
    }

    @Test func videoSignalingAndMalformedKeysCannotStartDevices() async throws {
        let endpoint = try make()
        defer { endpoint.close() }
        let id = try endpoint.command("createOutgoingCall", ["peerId": .string("alice"), "localDeviceId": .int(1), "videoEnabled": .bool(true)])
        #expect(try events(endpoint).only?["isVideoCall"].bool == true)
        _ = try endpoint.command("proceed", ["callId": id, "iceServers": .array([]), "hideIp": .bool(false)])
        #expect(try events(endpoint).only?["offerType"].int == 1)
        _ = try endpoint.command("ignore", ["callId": id])
        _ = try events(endpoint)
        var offer = description(5)
        offer["offerType"] = .int(1)
        _ = try endpoint.command("receivedOffer", offer)
        #expect(try events(endpoint).only?["isVideoCall"].bool == true)
        #expect(!endpoint.sendVideoFrame(width: 2, height: 2, format: .rgba, data: [UInt8](repeating: 0, count: 16), generation: nil))
        _ = try endpoint.command("ignore", ["callId": .id(5)])
        _ = try events(endpoint)
        offer["receiverIdentityKey"] = .bytes(Data(repeating: 0, count: 31))
        #expect(throws: RingRTCError.self) { try endpoint.command("receivedOffer", offer) }
        #expect(try events(endpoint).isEmpty)
        #expect(await mic.starts == 0)
        #expect(await speaker.starts == 0)
    }
}

private extension Array where Element == JSONValue {
    var only: JSONValue? { count == 1 ? first : nil }
}
