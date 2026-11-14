// The calling service is kept only while it has work (RingRTC "retiring the endpoint"): it is
// retired once nothing has happened for `idleGrace` and no call, group call client, request or
// microphone warm-up is left; after that, signalling for calls it ran is dropped instead of
// starting a fresh service, while an offer or a group call message starts one.

import Foundation
import Testing
@testable import SignalRingRTC

@MainActor @Suite struct RetireTests {
    let fake = FakeEndpoint()
    let rtc: RingRTC
    var logs: [(CallLogLevel, String)] = []
    let key = Data(repeating: 5, count: 33)
    let group = Data(repeating: 0x42, count: 32)

    init() throws {
        let fake = fake
        rtc = try RingRTC(endpoint: { _ in fake })
        rtc.idleGrace = .milliseconds(150)
    }

    func retired() -> Int { fake.sent.filter { $0 == "retire" }.count }
    func event(_ type: String, _ fields: [String: JSONValue]) { rtc.process([.object(fields.merging(["type": .string(type)]) { $1 })]) }
    func options(_ peer: UserId) -> RingRTC.CallingMessageOptions {
        .init(remoteUserId: peer, remoteUuid: Data(repeating: 0xA1, count: 16), remoteDeviceId: 2, localDeviceId: 1, ageSec: 0, receivedAtCounter: 0,
              receivedAtDate: 0, senderIdentityKey: key, receiverIdentityKey: key)
    }
    static func wait(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    @Test func idleIsRetiredAfterTheGrace() async throws {
        try rtc.setSelfUuid(Data(repeating: 1, count: 16))
        await Self.wait(60)
        #expect(retired() == 0)
        await Self.wait(400)
        #expect(retired() == 1 && !fake.isLive)
        // Its loss report is ours: noted, not an error.
        var levels: [CallLogLevel] = []
        rtc.handleLogMessage = { level, _, _, m in if m.contains("calling service") { levels.append(level) } }
        rtc.endpointLost(0)
        #expect(levels == [.info])
    }

    @Test func activityPostponesIt() async throws {
        for _ in 0..<6 {
            _ = rtc.getAudioInputs()
            await Self.wait(60)
        }
        #expect(retired() == 0)
        // Events count too (log lines do not).
        for _ in 0..<4 {
            event("onAudioLevels", ["remoteUserId": .string("bob"), "capturedLevel": .int(0), "receivedLevel": .int(0)])
            await Self.wait(60)
        }
        #expect(retired() == 0)
        await Self.wait(400)
        #expect(retired() == 1)
    }

    @Test func notWhileACallLasts() async throws {
        let call = try rtc.startOutgoingCall(remoteUserId: "bob", isVideoCall: false, localDeviceId: 1)
        await Self.wait(450)
        #expect(retired() == 0 && fake.isLive)
        event("onCallEnded", ["remoteUserId": .string("bob"), "callId": .string(String(call.callId)), "reason": .int(0)])
        #expect(call.state == .ended)
        await Self.wait(450)
        #expect(retired() == 1)
    }

    @Test func notWhileAGroupCallClientOrARequestOrWarmUpIsLeft() async throws {
        let observer = Observer()
        _ = try #require(rtc.getGroupCall(groupId: group, sfuUrl: "https://sfu.example", hkdfExtraInfo: Data(), audioLevelsIntervalMillis: nil,
                                          dredDuration: nil, svcConfig: nil, observer: observer))
        await Self.wait(450)
        #expect(retired() == 0)
        event("handleEnded", ["clientId": .int(7), "reason": .int(0)])
        #expect(rtc.groupCallByClientId.isEmpty)

        // A peek waiting for its answer.
        let root = try CallLinkRootKey.generate(), rtc = rtc
        let peek = Task { await rtc.peekCallLinkCall(sfuUrl: "https://sfu.example", authCredentialPresentation: Data(), rootKey: root) }
        await Self.wait(450)
        #expect(retired() == 0)
        let requestId = try #require(rtc.peekRequests.pending.keys.first)
        event("handlePeekResponse", ["requestId": .int(Int64(requestId)), "info": .object([:])])
        _ = await peek.value

        // Microphone warm-up (it records).
        Task { _ = try? await rtc.setMicrophoneWarmupEnabled(true) }
        await Self.wait(20)
        let warm = try #require(rtc.audioDeviceRequests.pending.keys.first)
        event("onSettleAudioPromise", ["requestId": .int(Int64(warm)), "success": .bool(true), "device": .null])
        await Self.wait(450)
        #expect(retired() == 0)
        rtc.stopMicrophoneWarmup()
        await Self.wait(450)
        #expect(retired() == 1)
    }

    @Test func afterwardsOnlyOffersAndGroupMessagesStartAService() async throws {
        try rtc.setSelfUuid(Data(repeating: 1, count: 16))
        await Self.wait(450)
        #expect(retired() == 1 && !fake.isLive)
        let before = fake.sent.count
        // Signalling for a call the ended service had, and an HTTP answer for it: dropped.
        var m = CallingMessage()
        m.answer = .init(callId: 9, opaque: Data([1]))
        rtc.handleCallingMessage(m, options("bob"))
        m = CallingMessage()
        m.iceCandidates = [.init(callId: 9, opaque: Data([1]))]
        rtc.handleCallingMessage(m, options("bob"))
        m = CallingMessage()
        m.hangup = .init(callId: 9, type: .normal, deviceId: 0)
        rtc.handleCallingMessage(m, options("bob"))
        m = CallingMessage()
        m.busy = .init(callId: 9)
        rtc.handleCallingMessage(m, options("bob"))
        rtc.receivedHttpResponse(requestId: 3, status: 200, body: Data())
        rtc.httpRequestFailed(requestId: 3, debugInfo: nil)
        #expect(fake.sent.count == before && !fake.isLive)
        // An offer starts one.
        m = CallingMessage()
        m.offer = .init(callId: 10, type: .audioCall, opaque: Data([1]))
        rtc.handleCallingMessage(m, options("carol"))
        #expect(fake.sent.last == "receivedOffer" && fake.isLive)
        // So does a group call message, once retired again.
        await Self.wait(450)
        #expect(retired() == 2)
        m = CallingMessage()
        m.opaque = .init(data: Data([7]))
        rtc.handleCallingMessage(m, options("dave"))
        #expect(fake.sent.last == "receivedCallMessage")
    }
}
