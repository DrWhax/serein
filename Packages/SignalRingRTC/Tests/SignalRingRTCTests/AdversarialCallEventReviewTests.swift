import Testing
@testable import SignalRingRTC

@MainActor @Suite struct AdversarialCallEventReviewTests {
    @Test func oldCallEndMustNotEndTheCurrentCall() throws {
        let rtc = try RingRTC()
        let current = Call(endpoint: rtc.endpoint, remoteUserId: "peer", callId: 200,
                           isIncoming: false, isVideoCall: false, state: .ringing)
        rtc.call = current
        rtc.handle(.object(["type": .string("onStartOutgoingCall"), "callId": .id(100), "remoteUserId": .string("peer")]))
        #expect(current.callId == 200, "A delayed start event must not overwrite the current call ID")
        rtc.handle(.object(["type": .string("onCallEnded"), "callId": .id(100),
                            "remoteUserId": .string("peer"), "reason": .int(0)]))
        #expect(current.state == .ringing, "An event for call 100 must not terminate call 200")
        rtc.handle(.object(["type": .string("onCallState"), "callId": .id(100),
                            "remoteUserId": .string("peer"), "state": .string("connected")]))
        #expect(current.state == .ringing)
        rtc.handle(.object(["type": .string("onCallEnded"), "callId": .id(200),
                            "remoteUserId": .string("peer"), "reason": .int(0)]))
        #expect(current.state == .ended)
        rtc.handle(.object(["type": .string("onCallState"), "callId": .id(200),
                            "remoteUserId": .string("peer"), "state": .string("connected")]))
        #expect(current.state == .ended, "An ended call cannot be revived by a late connected event")
    }
}
