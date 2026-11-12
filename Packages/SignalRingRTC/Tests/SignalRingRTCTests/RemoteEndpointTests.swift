// The endpoint behind XPC (CallXPC) as the app uses it, against the calling service's handler
// in this process: losing the service ends the calls made on it, refuses what they would still
// send, and the next command starts afresh with the configuration replayed. (Calls and frames
// over XPC: LoopbackCallTests.)

import CallXPC
import Foundation
import MediaXPCInterface
import Testing
import XPC
@testable import CallService
@testable import SignalRingRTC

@MainActor @Suite(.serialized) struct RemoteEndpointTests {
    static func wait(_ seconds: Double = 10, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func lossEndsTheCallAndTheNextCommandStartsAfresh() async throws {
        let handler = CallXPCHandler()
        let listener = XPCServer.anonymous(requirement: nil, handler)
        defer { listener.cancel() }
        let channel = XPCChannel(.endpoint(listener.endpoint), peer: nil, timeout: .seconds(20))
        let rtc = try RingRTC(endpoint: { trials in try RemoteCallEndpoint(fieldTrials: trials, channel: channel) })
        try rtc.setSelfUuid(Data(repeating: 1, count: 16))
        let remote = try #require(rtc.endpoint as? RemoteCallEndpoint)
        let call = try rtc.startOutgoingCall(remoteUserId: "bob", isVideoCall: false, localDeviceId: 1)
        var states: [CallState] = []
        call.handleStateChanged = { states.append(call.state) }
        #expect(handler.endpoints.withLock { $0.count } == 1)

        // The service's session ends (as when it crashes): its endpoints go with it.
        channel.reset()
        await Self.wait { states.contains(.ended) }
        #expect(states == [.ended] && call.endedReason == .internalFailure, "\(states)")
        #expect(remote.generation == 1)
        // The call's own commands do not bring the service back (nor reach a new endpoint).
        call.hangup()
        call.setOutgoingAudioMuted(true)
        #expect(handler.endpoints.withLock { $0.count } == 0)
        // The next command does: a new endpoint, `setSelfUuid` replayed onto it first.
        #expect(rtc.getAudioInputs() != nil)
        #expect(handler.endpoints.withLock { $0.count } == 1)
        #expect(remote.generation == 1)
    }

    @Test func framesAreCheckedAgainstWhatWasAskedFor() {
        let want = FrameWant(demuxId: 3, maxWidth: 640, maxHeight: 480)
        #expect(ReceivedFrame(demuxId: 3, width: 640, height: 480, rgba: Data(count: 640 * 480 * 4)).fits(want))
        #expect(ReceivedFrame(demuxId: 3, width: 480, height: 640, rgba: Data(count: 640 * 480 * 4)).fits(want), "either orientation")
        #expect(!ReceivedFrame(demuxId: 4, width: 640, height: 480, rgba: Data(count: 640 * 480 * 4)).fits(want), "another stream")
        #expect(!ReceivedFrame(demuxId: 3, width: 641, height: 480, rgba: Data(count: 641 * 480 * 4)).fits(want), "too wide")
        #expect(!ReceivedFrame(demuxId: 3, width: 640, height: 480, rgba: Data(count: 640 * 480 * 4 - 1)).fits(want), "short")
        #expect(!ReceivedFrame(demuxId: 3, width: 0, height: 0, rgba: Data()).fits(want), "empty")
    }
}
