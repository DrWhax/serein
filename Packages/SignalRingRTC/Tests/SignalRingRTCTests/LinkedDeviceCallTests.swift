import Foundation
import SignalRingRTC
import SwiftCallingServiceAdapter
import Testing

@MainActor @Suite struct LinkedDeviceCallTests {
    @Test func secondLinkedRingRTCDeviceCanAccept() async throws {
        let caller = try LoopbackCallTests.Side("caller", .overXPC, backend: SwiftVoiceEndpoint.factory)
        let first = try LoopbackCallTests.Side("callee", .overXPC)
        let second = try LoopbackCallTests.Side("callee", .overXPC)
        let key = Data(repeating: 0x17, count: 32)
        func deliver(_ message: CallingMessage, to side: LoopbackCallTests.Side, from sender: String, source: UInt32, destination: UInt32) {
            side.rtc.handleCallingMessage(message, .init(remoteUserId: sender, remoteUuid: nil, remoteDeviceId: source, localDeviceId: destination,
                                                         ageSec: 0, receivedAtCounter: 0, receivedAtDate: 0, senderIdentityKey: key, receiverIdentityKey: key))
        }
        var queued: [CallingMessage] = []
        var releaseSecond = false
        var answers: [UInt32] = []
        caller.rtc.handleOutgoingSignaling = { _, message in
            if message.destinationDeviceId == nil || message.destinationDeviceId == 2 {
                deliver(message, to: first, from: "caller", source: 1, destination: 2)
            }
            if message.destinationDeviceId == nil || message.destinationDeviceId == 3 {
                if releaseSecond { deliver(message, to: second, from: "caller", source: 1, destination: 3) }
                else { queued.append(message) }
            }
            return true
        }
        for (callee, device) in [(first, UInt32(2)), (second, UInt32(3))] {
            callee.rtc.handleOutgoingSignaling = { _, message in
                deliver(message, to: caller, from: "callee", source: device, destination: 1)
                if message.answer != nil { answers.append(device) }
                return true
            }
            callee.rtc.handleIncomingCall = { callee.incoming = $0; return true }
        }
        for peer in [caller, first, second] {
            peer.rtc.handleStartCall = { call in
                call.handleStateChanged = { peer.states.append(call.state) }
                peer.rtc.proceed(callId: call.callId, settings: .init(iceServers: [], hideIp: false, dataMode: .normal))
                return true
            }
        }
        defer {
            for peer in [caller, first, second] {
                peer.rtc.handleOutgoingSignaling = nil
                peer.rtc.handleStartCall = nil
                peer.rtc.handleIncomingCall = nil
                peer.incoming?.handleStateChanged = nil
            }
        }
        let call = try caller.rtc.startOutgoingCall(remoteUserId: "callee", isVideoCall: false, localDeviceId: 1)
        defer { call.hangup(); call.handleStateChanged = nil }
        await LoopbackCallTests.wait { answers == [2] && first.states.contains(.ringing) }
        try #require(answers == [2] && first.states.contains(.ringing))
        releaseSecond = true
        for message in queued { deliver(message, to: second, from: "caller", source: 1, destination: 3) }
        await LoopbackCallTests.wait { second.states.contains(.ringing) }
        try #require(answers == [2, 3] && second.states.contains(.ringing))
        try #require(second.incoming).accept()
        await LoopbackCallTests.wait { call.state == .accepted && first.states.last == .ended }
        #expect(call.state == .accepted && second.incoming?.state == .accepted)
        #expect(first.incoming?.endedReason == .remoteHangupAccepted)
        call.hangup()
        await LoopbackCallTests.wait { second.states.last == .ended }
        #expect(second.incoming?.endedReason == .remoteHangup)
        let summary = try #require(call.summary)
        let remote = try #require(second.incoming?.summary)
        #expect(summary.startTime > 0 && summary.endTime >= summary.startTime)
        #expect(summary.callEndReasonText == "LocalHangup" && summary.isSurveyCandidate)
        #expect(summary.callIdHash?.count == 32 && summary.callIdHash == remote.callIdHash)
        #expect(summary.rawStats?.isEmpty == false && summary.rawStatsText?.contains("connect_time") == true)
    }
}
