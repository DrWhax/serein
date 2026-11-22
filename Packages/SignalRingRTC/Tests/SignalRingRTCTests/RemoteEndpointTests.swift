// The endpoint behind XPC (CallXPC) as the app uses it, against the calling service's handler
// in this process: losing the service ends the calls made on it, refuses what they would still
// send, and the next command starts afresh with the configuration replayed. (Calls and frames
// over XPC: LoopbackCallTests.)

import CallXPC
import Foundation
import MediaXPCInterface
import SwiftCallingServiceAdapter
import Synchronization
import Testing
import XPC
@testable import CallService
@testable import SignalRingRTC

@MainActor @Suite(.serialized) struct RemoteEndpointTests {
    static func wait(_ seconds: Double = 10, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test(arguments: [false, true])
    func lossEndsTheCallAndTheNextCommandStartsAfresh(legacySwiftVoiceRequest: Bool) async throws {
        let handler = CallXPCHandler(makeEndpoint: SwiftVoiceEndpoint.factory)
        let listener = XPCServer.anonymous(requirement: nil, handler)
        defer { listener.cancel() }
        let channel = XPCChannel(.endpoint(listener.endpoint), peer: nil, timeout: .seconds(20))
        let rtc = try RingRTC(endpoint: { trials in
            try RemoteCallEndpoint(fieldTrials: trials, channel: channel, swiftVoice: legacySwiftVoiceRequest)
        })
        // Keep the outgoing call alive until the service is deliberately lost.
        rtc.handleStartCall = { _ in true }
        try rtc.setSelfUuid(Data(repeating: 1, count: 16))
        let remote = try #require(rtc.endpoint as? RemoteCallEndpoint)
        let call = try rtc.startOutgoingCall(remoteUserId: "bob", isVideoCall: false, localDeviceId: 1)
        var states: [CallState] = []
        call.handleStateChanged = { states.append(call.state) }
        #expect(handler.endpointCount == 1)

        // The service's session ends (as when it crashes): its endpoints go with it.
        channel.reset()
        await Self.wait { states.contains(.ended) }
        #expect(states == [.ended] && call.endedReason == .internalFailure, "\(states)")
        #expect(remote.generation == 1)
        // The call's own commands do not bring the service back (nor reach a new endpoint).
        call.hangup()
        call.setOutgoingAudioMuted(true)
        #expect(handler.endpointCount == 0)
        // The next command does: a new endpoint, `setSelfUuid` replayed onto it first.
        #expect(rtc.getAudioInputs() != nil)
        #expect(handler.endpointCount == 1)
        #expect(remote.generation == 1)
    }

    /// An idle service is ended (its session, so in the app its process): once its work is done
    /// (here a peek) and nothing has happened for `idleGrace`. The next call starts a fresh one,
    /// `setSelfUuid` replayed, and the retired one's loss report is no error.
    @Test func anIdleServiceEndsAndTheNextCallStartsAFreshOne() async throws {
        let sessionsEnded = Atomic<Int>(0)
        let handler = CallXPCHandler(makeEndpoint: SwiftVoiceEndpoint.factory, onSessionEnd: { sessionsEnded.add(1, ordering: .relaxed) })
        let listener = XPCServer.anonymous(requirement: nil, handler)
        defer { listener.cancel() }
        let channel = XPCChannel(.endpoint(listener.endpoint), peer: nil, timeout: .seconds(20))
        let rtc = try RingRTC(endpoint: { trials in try RemoteCallEndpoint(fieldTrials: trials, channel: channel) })
        rtc.idleGrace = .milliseconds(300)
        var errors: [String] = []
        rtc.handleLogMessage = { level, _, _, m in if level == .error { errors.append(m) } }
        try rtc.setSelfUuid(Data(repeating: 1, count: 16))
        let remote = try #require(rtc.endpoint as? RemoteCallEndpoint)
        // Busy while a peek waits for its HTTP request (ringrtc asks us to make it).
        var asked: [UInt32] = []
        rtc.handleSendHttpRequest = { id, _, _, _, _ in asked.append(id) }
        let peek = Task { await rtc.peekGroupCall(sfuUrl: "https://sfu.example", membershipProof: Data([1]), groupMembers: []) }
        await Self.wait { !asked.isEmpty }
        try await Task.sleep(for: .milliseconds(700))
        #expect(handler.endpointCount == 1 && remote.isLive && sessionsEnded.load(ordering: .relaxed) == 0)
        rtc.httpRequestFailed(requestId: try #require(asked.first), debugInfo: nil)
        _ = await peek.value
        // Then idle: the session ends, so the service with it.
        await Self.wait { sessionsEnded.load(ordering: .relaxed) == 1 }
        #expect(sessionsEnded.load(ordering: .relaxed) == 1 && handler.endpointCount == 0 && !remote.isLive)
        #expect(remote.generation == 1)
        try await Task.sleep(for: .milliseconds(400))   // the loss report has come and gone
        #expect(errors.filter { $0.contains("calling service") }.isEmpty, "\(errors)")
        // The next call: a fresh endpoint, with our ACI.
        _ = try rtc.startOutgoingCall(remoteUserId: "carol", isVideoCall: false, localDeviceId: 1)
        #expect(handler.endpointCount == 1 && remote.isLive)
    }

    @Test func sessionLossWhileMakingAnEndpoint() async throws {
        let release = DispatchSemaphore(value: 0)
        let invoked = Mutex<String?>(nil)
        let handler = CallXPCHandler(makeEndpoint: { trials in
            invoked.withLock { $0 = trials }
            guard release.wait(timeout: .now() + 5) == .success else { throw RingRTCError.noEndpoint }
            return try SwiftVoiceEndpoint.factory(trials)
        })
        let creation = Task { try await handler.run(.create(fieldTrials: "SwiftBackendProbe/Enabled/")) }
        await Self.wait(4) { invoked.withLock { $0 != nil } }
        #expect(invoked.withLock { $0 } == "SwiftBackendProbe/Enabled/")
        handler.sessionEnded()
        release.signal()
        await #expect(throws: CallServiceError.self) { try await creation.value }
        #expect(handler.endpointCount == 0)
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
