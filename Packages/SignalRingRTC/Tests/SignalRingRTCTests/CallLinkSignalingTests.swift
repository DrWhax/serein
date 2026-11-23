import Foundation
import SwiftCalling
import Testing
@testable import SignalRingRTC

@MainActor @Suite struct CallLinkSignalingTests {
    #if SEREIN_CALL_TEST_PEER
    @Test func localTestPeerOnlyAcceptsOneCompleteSendingKeyForItsCurrentDevice() throws {
        let observer = Observer()
        let call = GroupCall(kind: .callLink, endpoint: FakeEndpoint(), observer: observer, clientId: 1)
        let room = Data(repeating: 25, count: 32)
        call.linkRoomId = room
        var message = GroupDeviceMessage()
        message.group = room
        message.key = .init(demux: 16, ratchet: 3, secret: Data(repeating: 5, count: 32))
        let good = message.encode(signaling: true)
        #expect(!call.isLocalCallLinkMediaKey(good))
        call.handleJoinStateChanged(.joined, demuxId: 16)
        #expect(call.isLocalCallLinkMediaKey(good))
        #expect(!call.isLocalCallLinkMediaKey(good + good))
        #expect(!call.isLocalCallLinkMediaKey(good + Data([0x10, 0x01])))
        #expect(!call.isLocalCallLinkMediaKey(good.dropLast()))
        message.reaction = "extra field"
        #expect(!call.isLocalCallLinkMediaKey(message.encode(signaling: true)))
        message.reaction = nil
        message.group = Data(repeating: 26, count: 32)
        #expect(!call.isLocalCallLinkMediaKey(message.encode(signaling: true)))
        message.group = room
        message.key = .init(demux: 32, ratchet: 3, secret: Data(repeating: 5, count: 32))
        #expect(!call.isLocalCallLinkMediaKey(message.encode(signaling: true)))
        message.key = .init(demux: 16, ratchet: 3, secret: Data(repeating: 5, count: 31))
        #expect(!call.isLocalCallLinkMediaKey(message.encode(signaling: true)))
    }

    @Test func localPairDeliveryRequiresBothJoinedDevicesAndDoesNotGrantRingAuthority() throws {
        let a = FakeEndpoint(), b = FakeEndpoint()
        let sender = try RingRTC(endpoint: { _ in a }), receiver = try RingRTC(endpoint: { _ in b })
        let observer = Observer(), aci = Data(repeating: 8, count: 16), room = Data(repeating: 17, count: 32)
        try sender.setSelfUuid(aci)
        try receiver.setSelfUuid(aci)
        func remote(_ id: UInt32, _ user: Data) -> RemoteDeviceState {
            RemoteDeviceState(.object(["demuxId": .int(Int64(id)), "userId": .bytes(user)]))
        }
        func joined(_ rtc: RingRTC, local: UInt32, other: UInt32) -> GroupCall {
            let call = GroupCall(kind: .callLink, endpoint: rtc.endpoint, observer: observer, clientId: 7)
            call.linkRoomId = room
            rtc.groupCallByClientId[7] = call
            call.handleConnectionStateChanged(.connected)
            call.handleJoinStateChanged(.joined, demuxId: local)
            call.handleRemoteDevicesChanged([remote(other, aci)])
            return call
        }
        let source = joined(sender, local: 16, other: 32), destination = joined(receiver, local: 32, other: 16)
        var key = GroupDeviceMessage()
        key.group = room
        key.key = .init(demux: 16, ratchet: 3, secret: Data(repeating: 5, count: 32))
        func deliver(existingDevices: Set<UInt32> = []) {
            receiver.receiveLocalCallLinkMediaKey(key.encode(signaling: true), from: source, on: sender, to: destination, deviceId: 2,
                                                  existingDevices: existingDevices)
        }
        deliver()
        #expect(b.commands.withLock { $0.filter { $0 == "receivedCallMessage" }.count } == 1)
        #expect(receiver.callMessageSenders.isEmpty)
        source.handleRemoteDevicesChanged([remote(32, aci), remote(48, aci)])
        deliver()
        #expect(b.commands.withLock { $0.filter { $0 == "receivedCallMessage" }.count } == 1)
        destination.handleRemoteDevicesChanged([remote(48, aci), remote(16, aci)])
        deliver(existingDevices: [48])
        #expect(b.commands.withLock { $0.filter { $0 == "receivedCallMessage" }.count } == 2)
        key.key = .init(demux: 48, ratchet: 3, secret: Data(repeating: 5, count: 32))
        deliver(existingDevices: [48])
        key.key = .init(demux: 16, ratchet: 3, secret: Data(repeating: 5, count: 32))
        source.handleRemoteDevicesChanged([remote(32, aci), remote(48, Data(repeating: 9, count: 16))])
        deliver(existingDevices: [48])
        source.handleRemoteDevicesChanged([remote(48, aci)])
        deliver(existingDevices: [48])
        source.handleRemoteDevicesChanged([remote(32, aci), remote(48, aci), remote(64, aci)])
        deliver(existingDevices: [48])
        source.handleRemoteDevicesChanged([remote(32, aci)])
        destination.handleRemoteDevicesChanged([remote(16, Data(repeating: 9, count: 16))])
        deliver()
        destination.handleRemoteDevicesChanged([remote(16, aci)])
        destination.linkRoomId = Data(repeating: 18, count: 32)
        deliver()
        destination.linkRoomId = room
        let duplicateRoom = GroupCall(kind: .callLink, endpoint: b, observer: observer, clientId: 9)
        duplicateRoom.linkRoomId = room
        receiver.groupCallByClientId[9] = duplicateRoom
        deliver()
        receiver.groupCallByClientId[9] = nil
        receiver.groupCallByClientId[7] = nil
        deliver()
        #expect(b.commands.withLock { $0.filter { $0 == "receivedCallMessage" }.count } == 2)
    }

    #endif

    @Test func roomAndCurrentAudienceBindGroupedMessagesAndFallback() throws {
        let rtc = try RingRTC(endpoint: { _ in FakeEndpoint() })
        let observer = Observer()
        let alice = Data(repeating: 1, count: 16), bob = Data(repeating: 2, count: 16)
        let carol = Data(repeating: 3, count: 16)
        func room(_ id: UInt32, users: [Data]) -> GroupCall {
            let g = GroupCall(kind: .callLink, endpoint: rtc.endpoint, observer: observer, clientId: id)
            rtc.groupCallByClientId[id] = g
            g.linkRoomId = Data(repeating: UInt8(id), count: 32)
            g.handleJoinStateChanged(.joined, demuxId: 16)
            g.handleRemoteDevicesChanged(users.enumerated().map { index, aci in
                RemoteDeviceState(.object(["userId": .bytes(aci), "demuxId": .int(Int64((index + 2) * 16))]))
            })
            return g
        }
        let first = room(1, users: [alice, bob]), second = room(2, users: [alice, carol])
        var message = GroupDeviceMessage()
        message.group = first.linkRoomId
        message.key = .init(demux: 16, ratchet: 0, secret: Data(repeating: 71, count: 32))
        let payload = message.encode(signaling: true)
        var individual: [Data] = [], grouped: [[Data]] = []
        rtc.handleSendCallMessage = { recipient, _, _ in individual.append(recipient) }
        rtc.handleSendCallMessageToAdhocGroup = { _, _, _, rows in grouped.append(rows.map(\.recipientId)) }
        func request(_ g: GroupCall, _ users: [Data]) {
            rtc.handle(.object(["type": .string("sendCallLinkMessage"), "clientId": .int(Int64(g.clientId)),
                                "message": .bytes(payload), "recipientIds": .array(users.map { .bytes($0) })]))
        }
        request(first, [alice, bob])
        #expect(individual == [alice, bob])
        first.linkEndorsements = { users in (Date().addingTimeInterval(1000), users.map { _ in Data([1]) }) }
        request(first, [alice, bob])
        request(first, [alice, carol])
        request(second, [alice])
        request(first, [alice, alice])
        #expect(grouped == [[alice, bob]])
        let millis = Int64(Date().addingTimeInterval(1000).timeIntervalSince1970 * 1000)
        func requestNative(_ users: [Data]) {
            rtc.handle(.object(["type": .string("sendCallMessageToAdhocGroup"), "message": .bytes(payload), "expirationMillis": .int(millis),
                                "recipientsToEndorsements": .array(users.map { .object(["recipientId": .bytes($0), "endorsement": .bytes(Data([1]))]) })]))
        }
        requestNative([alice])
        requestNative([bob, carol])
        #expect(grouped == [[alice, bob], [alice]])

        func unicastNative(_ target: Data) {
            rtc.handle(.object(["type": .string("sendCallMessage"), "message": .bytes(payload), "recipientUuid": .bytes(target)]))
        }
        unicastNative(carol)
        unicastNative(bob)
        #expect(individual == [alice, bob, bob])

        let previousScope = try #require(first.callLinkAuthorization(for: [alice, bob]))
        first.handleRemoteDevicesChanged([RemoteDeviceState(.object(["userId": .bytes(alice), "demuxId": .int(32)]))])
        #expect(throws: RingRTCError.self) { try previousScope() }
        first.handleRemoteDevicesChanged([alice, bob].enumerated().map { index, aci in
            RemoteDeviceState(.object(["userId": .bytes(aci), "demuxId": .int(Int64(32 + 16 * index))]))
        })
        #expect(throws: RingRTCError.self) { try previousScope() }
        let aliceScope = try #require(first.callLinkAuthorization(for: [alice]))
        first.leave()
        #expect(throws: RingRTCError.self) { try aliceScope() }
        request(first, [alice])
        #expect(grouped.count == 2)
        first.join()
        first.handleJoinStateChanged(.joined, demuxId: 32)
        #expect(first.callLinkAuthorization(for: [alice]) == nil)
        first.handleRemoteDevicesChanged([RemoteDeviceState(.object(["userId": .bytes(alice), "demuxId": .int(48)]))])
        #expect(first.callLinkAuthorization(for: [alice]) != nil)
        #expect(throws: RingRTCError.self) { try aliceScope() }
    }
}
