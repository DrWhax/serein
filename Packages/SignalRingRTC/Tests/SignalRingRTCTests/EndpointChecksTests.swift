// What RingRTC lets the calling service ask of the app (RingRTC.swift, "what the endpoint may
// ask for"): the service reads what remote peers send, so it may be lying. Each kind of request
// is tried from a fake endpoint both ways: refused without the fact that allows it, passed on
// with it. And a lost endpoint ends its calls.

import Foundation
import Synchronization
import Testing
@testable import SignalRingRTC

/// An endpoint that records commands and has no events of its own.
final class FakeEndpoint: RingRTCEndpoint {
    let commands = Mutex<[String]>([])
    let gen = Atomic<UInt64>(0)
    var generation: UInt64 { gen.load(ordering: .relaxed) }

    func command(_ name: String, _ fields: [String: JSONValue], generation: UInt64?) throws -> JSONValue {
        if let generation, generation != self.generation { throw RingRTCError.lost }
        commands.withLock { $0.append(name) }
        switch name {
        case "createGroupCallClient", "createCallLinkCallClient": return .int(7)
        case "createOutgoingCall": return .string("5")
        default: return .null
        }
    }

    func waitEvents(timeoutMs: UInt32) -> EndpointEvents {
        Thread.sleep(forTimeInterval: Double(timeoutMs) / 1000)
        return .events([])
    }

    func sendVideoFrame(width: Int, height: Int, format: VideoPixelFormat, data: [UInt8], generation: UInt64?) -> Bool { generation == nil || generation == self.generation }
    func receiveVideoFrame(demuxId: UInt32, maxWidth: Int, maxHeight: Int, into buffer: inout [UInt8], generation: UInt64?) -> (width: Int, height: Int)? { nil }
    func close() {}
    var sent: [String] { commands.withLock { $0 } }
}

@MainActor final class Observer: GroupCallObserver {
    var ended: [CallEndReason] = []
    func requestMembershipProof(_ groupCall: GroupCall) {}
    func requestGroupMembers(_ groupCall: GroupCall) {}
    func onLocalDeviceStateChanged(_ groupCall: GroupCall) {}
    func onRemoteDeviceStatesChanged(_ groupCall: GroupCall) {}
    func onAudioLevels(_ groupCall: GroupCall) {}
    func onLowBandwidthForVideo(_ groupCall: GroupCall, recovered: Bool) {}
    func onReactions(_ groupCall: GroupCall, reactions: [Reaction]) {}
    func onRaisedHands(_ groupCall: GroupCall, raisedHands: [UInt32]) {}
    func onPeekChanged(_ groupCall: GroupCall) {}
    func onEnded(_ groupCall: GroupCall, reason: CallEndReason, summary: CallSummary) { ended.append(reason) }
    func onSpeechEvent(_ groupCall: GroupCall, event: SpeechEvent) {}
    func onRemoteMute(_ groupCall: GroupCall, demuxId: UInt32) {}
    func onObservedRemoteMute(_ groupCall: GroupCall, sourceDemuxId: UInt32, targetDemuxId: UInt32) {}
}

@MainActor @Suite struct EndpointChecksTests {
    let fake = FakeEndpoint()
    let rtc: RingRTC
    let key = Data(repeating: 5, count: 33)
    let alice = Data(repeating: 0xA1, count: 16), mallory = Data(repeating: 0x66, count: 16)
    let group = Data(repeating: 0x42, count: 32)

    init() throws {
        let fake = fake
        rtc = try RingRTC(endpoint: { _ in fake })
    }

    func options(_ peer: UserId, uuid: Data? = nil) -> RingRTC.CallingMessageOptions {
        .init(remoteUserId: peer, remoteUuid: uuid, remoteDeviceId: 2, localDeviceId: 1, ageSec: 0, receivedAtCounter: 0, receivedAtDate: 0,
              senderIdentityKey: key, receiverIdentityKey: key)
    }

    func event(_ type: String, _ fields: [String: JSONValue]) {
        rtc.handle(.object(fields.merging(["type": .string(type)]) { $1 }))
    }

    static func settle() async { for _ in 0..<20 { await Task.yield() } }

    @Test func incomingCallsOnlyForOffersPassedIn() async throws {
        var incoming: [UserId] = []
        rtc.handleIncomingCall = { call in incoming.append(call.remoteUserId); return false }
        rtc.handleStartCall = { _ in true }
        event("onStartIncomingCall", ["remoteUserId": .string("mallory"), "callId": .id(9), "isVideoCall": .bool(false)])
        await Self.settle()
        #expect(incoming.isEmpty && rtc.call == nil)
        var m = CallingMessage()
        m.offer = OfferMessage(callId: 9, type: .audioCall, opaque: Data([1]))
        rtc.handleCallingMessage(m, options("alice"))
        event("onStartIncomingCall", ["remoteUserId": .string("mallory"), "callId": .id(9), "isVideoCall": .bool(false)])
        await Self.settle()
        #expect(incoming.isEmpty, "the offer was alice's")
        event("onStartIncomingCall", ["remoteUserId": .string("alice"), "callId": .id(9), "isVideoCall": .bool(false)])
        await Self.settle()
        #expect(incoming == ["alice"])
    }

    @Test func signallingOnlyToCallPeersAndOfferers() async throws {
        var sent: [(UserId, CallId)] = []
        rtc.handleOutgoingSignaling = { peer, message in
            sent.append((peer, message.offer?.callId ?? message.busy?.callId ?? message.hangup?.callId ?? 0))
            return true
        }
        event("onSendOffer", ["remoteUserId": .string("mallory"), "callId": .id(5), "offerType": .int(0), "opaque": .bytes(Data([1]))])
        await Self.settle()
        #expect(sent.isEmpty && fake.sent.contains("signalingMessageSendFailed"))
        let call = try rtc.startOutgoingCall(remoteUserId: "bob", isVideoCall: false, localDeviceId: 1)
        #expect(call.callId == 5)
        event("onSendOffer", ["remoteUserId": .string("bob"), "callId": .id(6), "offerType": .int(0), "opaque": .bytes(Data([1]))])
        event("onSendOffer", ["remoteUserId": .string("bob"), "callId": .id(5), "offerType": .int(0), "opaque": .bytes(Data([1]))])
        var m = CallingMessage()
        m.offer = OfferMessage(callId: 11, type: .audioCall, opaque: Data([1]))
        rtc.handleCallingMessage(m, options("carol"))
        event("onSendBusy", ["remoteUserId": .string("carol"), "callId": .id(11)])
        event("onSendBusy", ["remoteUserId": .string("dave"), "callId": .id(11)])
        await Self.settle()
        #expect(sent.map(\.0) == ["bob", "carol"] && sent.map(\.1) == [5, 11], "\(sent)")
    }

    @Test func callMessagesOnlyToGroupCallMembers() async throws {
        var to: [Data] = [], groups: [Data] = []
        rtc.handleSendCallMessage = { r, _, _ in to.append(r) }
        rtc.handleSendCallMessageToGroup = { g, _, _, _ in groups.append(g) }
        event("sendCallMessage", ["recipientUuid": .bytes(alice), "message": .bytes(Data([1])), "urgency": .int(0)])
        event("sendCallMessageToGroup", ["groupId": .bytes(group), "message": .bytes(Data([1])), "urgency": .int(0), "overrideRecipients": .array([])])
        #expect(to.isEmpty && groups.isEmpty)
        let observer = Observer()
        let g = try #require(rtc.getGroupCall(groupId: group, sfuUrl: "https://sfu.example", hkdfExtraInfo: Data(), audioLevelsIntervalMillis: nil,
                                              dredDuration: nil, svcConfig: nil, observer: observer))
        g.setGroupMembers([GroupMemberInfo(userId: alice, userIdCipherText: Data([1]))])
        event("sendCallMessage", ["recipientUuid": .bytes(alice), "message": .bytes(Data([1])), "urgency": .int(0)])
        event("sendCallMessage", ["recipientUuid": .bytes(mallory), "message": .bytes(Data([1])), "urgency": .int(0)])
        event("sendCallMessageToGroup", ["groupId": .bytes(group), "message": .bytes(Data([1])), "urgency": .int(0), "overrideRecipients": .array([])])
        event("sendCallMessageToGroup", ["groupId": .bytes(Data(repeating: 1, count: 32)), "message": .bytes(Data([1])), "urgency": .int(0),
                                         "overrideRecipients": .array([])])
        event("sendCallMessageToGroup", ["groupId": .bytes(group), "message": .bytes(Data([1])), "urgency": .int(0),
                                         "overrideRecipients": .array([.bytes(mallory)])])
        #expect(to == [alice] && groups == [group])
        // A ring cancelled for another group may still go out to it, for a while.
        let other = Data(repeating: 2, count: 32)
        rtc.cancelGroupRing(groupId: other, ringId: 1, reason: nil)
        event("sendCallMessageToGroup", ["groupId": .bytes(other), "message": .bytes(Data([1])), "urgency": .int(0), "overrideRecipients": .array([])])
        #expect(groups == [group, other])
    }

    @Test func ringsOnlyFromCallMessageSenders() async throws {
        var rings: [Data] = []
        rtc.handleGroupCallRingUpdate = { _, _, sender, _ in rings.append(sender) }
        event("groupCallRingUpdate", ["groupId": .bytes(group), "ringId": .string("3"), "sender": .bytes(mallory), "update": .int(0)])
        #expect(rings.isEmpty)
        var m = CallingMessage()
        m.opaque = OpaqueMessage(data: Data([9]))
        rtc.handleCallingMessage(m, options("alice", uuid: alice))
        event("groupCallRingUpdate", ["groupId": .bytes(group), "ringId": .string("3"), "sender": .bytes(alice), "update": .int(0)])
        event("groupCallRingUpdate", ["groupId": .bytes(group), "ringId": .string("3"), "sender": .bytes(mallory), "update": .int(0)])
        #expect(rings == [alice])
    }

    @Test func aLostEndpointEndsItsCalls() async throws {
        let call = try rtc.startOutgoingCall(remoteUserId: "bob", isVideoCall: false, localDeviceId: 1)
        var states: [CallState] = []
        call.handleStateChanged = { states.append(call.state) }
        let observer = Observer()
        let g = try #require(rtc.getGroupCall(groupId: group, sfuUrl: "https://sfu.example", hkdfExtraInfo: Data(), audioLevelsIntervalMillis: nil,
                                              dredDuration: nil, svcConfig: nil, observer: observer))
        let root = try CallLinkRootKey.generate(), rtc = rtc
        let peek = Task { await rtc.peekCallLinkCall(sfuUrl: "https://sfu.example", authCredentialPresentation: Data(), rootKey: root) }
        await Self.settle()
        fake.gen.store(1, ordering: .relaxed)
        rtc.endpointLost(0)
        #expect(states == [.ended] && call.endedReason == .internalFailure)
        #expect(observer.ended == [.internalFailure] && rtc.groupCallByClientId.isEmpty)
        if case .success = await peek.value { Issue.record("a peek waiting on the lost endpoint must fail") }
        // Neither the call nor the group call reaches the endpoint that replaces the lost one.
        let before = fake.sent.count
        call.hangup()
        g.leave()
        #expect(fake.sent.count == before)
    }
}
