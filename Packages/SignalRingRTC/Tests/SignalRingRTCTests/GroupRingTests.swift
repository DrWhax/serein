import Foundation
import RingRTCNative
import SignalRingRTC
import SwiftCalling
import Testing
@testable import SwiftCallingServiceAdapter

struct GroupRingTests {
    let group = Data(repeating: 10, count: 32)
    let me = Data(repeating: 20, count: 16)
    let other = Data(repeating: 30, count: 16)
    let id = Int64.min + 123

    private func received(_ kind: GroupRingMessage.Kind, sender: Data, age: UInt64 = 0, id: Int64? = nil) -> [String: JSONValue] {
        ["remoteUserId": .bytes(sender), "data": .bytes(GroupRingMessage(group: group, id: id ?? self.id, kind: kind).encode()),
         "messageAgeSec": .int(Int64(age)), "remoteDeviceId": .int(2), "localDeviceId": .int(1)]
    }

    @Test func receivedRingsAndSelfResponsesMatchRingRTC() throws {
        let native = try NativeEndpoint.factory("")
        let swift = try SwiftVoiceEndpoint.factory("")
        defer { native.close(); swift.close() }
        for endpoint in [native, swift] {
            func send(_ command: String, _ fields: [String: JSONValue]) throws {
                _ = try endpoint.command(command, fields, generation: nil)
            }
            try send("setSelfUuid", ["uuid": .bytes(me)])
            try send("receivedCallMessage", received(.intention(.ring), sender: other, age: 60))
            try send("receivedCallMessage", received(.response(.accepted), sender: other))
            try send("receivedCallMessage", received(.response(.ringing), sender: me))
            try send("receivedCallMessage", received(.response(.declined), sender: me))
            try send("receivedCallMessage", received(.response(.accepted), sender: me))
            try send("receivedCallMessage", received(.response(.busy), sender: me))
            try send("receivedCallMessage", received(.intention(.ring), sender: other, age: 61))
            try send("receivedCallMessage", received(.intention(.cancelled), sender: other))
            try send("cancelGroupRing", ["groupId": .bytes(group), "ringId": .string(String(id)), "reason": .int(0)])
            var events: [JSONValue] = []
            let deadline = ContinuousClock.now + .seconds(2)
            while events.count < 7 && ContinuousClock.now < deadline {
                if case .events(let batch) = endpoint.waitEvents(timeoutMs: 50) {
                    events += batch.filter { ["groupCallRingUpdate", "sendCallMessage"].contains($0["type"].string) }
                }
            }
            let updates = events.filter { $0["type"].string == "groupCallRingUpdate" }
            #expect(updates.compactMap { $0["update"].int } == [0, 3, 2, 5, 1, 6])
            #expect(updates.compactMap { $0["sender"].data } == [other, me, me, me, other, other])
            #expect(updates.allSatisfy { $0["groupId"].data == group && $0["ringId"].int64 == id })
            let msg = try #require(events.first { $0["type"].string == "sendCallMessage" })
            #expect(msg["recipientUuid"].data == me && msg["urgency"].int == 1)
            #expect(msg["message"].data == GroupRingMessage(group: group, id: id, kind: .response(.declined)).encode())
        }
    }

    @Test(arguments: [false, true]) func groupClientKeepsItsFirstRing(beforeCreation: Bool) throws {
        let native = try NativeEndpoint.factory("")
        let swift = try SwiftVoiceEndpoint.factory("")
        defer { native.close(); swift.close() }
        for ep in [native, swift] {
            func waitFor(_ type: String) throws -> JSONValue {
                let end = ContinuousClock.now + .seconds(2)
                while ContinuousClock.now < end {
                    if case .events(let batch) = ep.waitEvents(timeoutMs: 50),
                       let match = batch.first(where: { $0["type"].string == type }) { return match }
                }
                throw RingRTCError.invalidResponse
            }
            _ = try ep.command("setSelfUuid", ["uuid": .bytes(me)], generation: nil)
            func receive(_ ringID: Int64) throws {
                _ = try ep.command("receivedCallMessage", received(.intention(.ring), sender: other, id: ringID), generation: nil)
                #expect(try waitFor("groupCallRingUpdate")["ringId"].int64 == ringID)
            }
            if beforeCreation { try receive(39) }
            let client = try ep.command("createGroupCallClient", ["groupId": .bytes(group), "hkdfExtraInfo": .bytes(Data()),
                "sfuUrl": .string("https://sfu.invalid"), "audioLevelsIntervalMillis": .int(0), "dredDuration": .int(0)], generation: nil)
            if !beforeCreation { try receive(39) }
            try receive(40)
            _ = try ep.command("connect", ["clientId": client], generation: nil)
            _ = try ep.command("join", ["clientId": client], generation: nil)
            let accepted = try waitFor("sendCallMessage")
            #expect(accepted["recipientUuid"].data == me)
            #expect(accepted["message"].data == GroupRingMessage(group: group, id: 39, kind: .response(.accepted)).encode())
        }
    }

    @Test func timersReplacementOwnerAndBusy() throws {
        var rings = CallGroupRings()
        let start = ContinuousClock.now
        _ = try rings.command("setSelfUuid", ["uuid": .bytes(me)], busy: false)
        _ = try rings.command("receivedCallMessage", received(.intention(.ring), sender: other), busy: false, now: start)
        _ = try rings.command("receivedCallMessage", received(.intention(.cancelled), sender: me), busy: false, now: start)
        #expect(rings.outstandingID(for: group, now: start) == id)
        _ = try rings.command("receivedCallMessage", received(.intention(.ring), sender: other, id: 22), busy: false, now: start + .seconds(1))
        let firstTimeout = rings.expire(now: start + .seconds(60))
        #expect(firstTimeout.map { $0["ringId"].int64 } == [id])
        #expect(rings.outstandingID(for: group, now: start + .seconds(60)) == 22)
        #expect(rings.expire(now: start + .seconds(61)).map { $0["update"].int } == [1])
        #expect(rings.outstandingID(for: group, now: start + .seconds(61)) == nil)
        let busy = try rings.command("receivedCallMessage", received(.intention(.ring), sender: other), busy: true)
        try #require(busy.count == 2)
        #expect(busy[0]["recipientUuid"].data == me && busy[0]["message"].data == GroupRingMessage(group: group, id: id, kind: .response(.busy)).encode())
        #expect(busy[1]["update"].int == RingUpdate.busyLocally.rawValue)
    }
}
