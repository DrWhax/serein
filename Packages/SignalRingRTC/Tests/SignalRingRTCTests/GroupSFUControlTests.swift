import Foundation
import Testing
@testable import SwiftCalling

struct GroupSFUControlTests {
    /// Independent field tags from group_call.proto. These do not use the device encoder.
    private func inbound(_ seq: UInt8, _ body: [UInt8], count: UInt8? = nil, fragment: Bool = false) -> Data {
        var header: [UInt8] = [8, seq]
        if let count { header += [24, count] }
        return Data([0x5a, UInt8(header.count)] + header + (fragment ? [0x62, UInt8(body.count)] : []) + body)
    }

    @Test func commandsAndRetransmissions() throws {
        var control = GroupSFUControl()
        let start = ContinuousClock.now
        let request = try control.send(.videoRequest([.init(demuxID: 0x01020304, height: 72)], maxKbps: 100, activeSpeakerHeight: 10))
        #expect(request == [Data([10,13,10,7,16,72,29,4,3,2,1,24,100,32,10])])
        for (index, command) in [GroupSFUCommand.approve(0x01020304), .deny(0x01020304), .remove(0x01020304), .block(0x01020304)].enumerated() {
            let packet = try control.send(command, now: start)
            #expect(packet == [Data([UInt8(26 + index * 8),5,13,4,3,2,1,66,2,8,UInt8(index + 1)])])
        }
        #expect(try control.send(.leave) == [Data([18,0]), Data([18,0])])
        #expect(control.tick(now: start + .milliseconds(999)).isEmpty)
        #expect(try control.receive(Data([90,2,16,100]), timestamp: 2).isEmpty)
        #expect(control.tick(now: start + .seconds(1)).count == 4)
        #expect(try control.receive(Data([90,2,16,4]), timestamp: 2).isEmpty)
        #expect(control.tick(now: start + .seconds(2)).count == 1)
        _ = try control.receive(Data([90,2,16,5]), timestamp: 2)
        #expect(control.tick(now: start + .seconds(3)).isEmpty)
    }

    @Test func resendsOnlyTheLatestSubscriptionAfterLoss() throws {
        let start = ContinuousClock.now
        var control = GroupSFUControl()
        let first = try control.send(.videoRequest([.init(demuxID: 4, height: 360)], maxKbps: nil, activeSpeakerHeight: nil), now: start)
        #expect(control.tick(now: start + .milliseconds(999)).isEmpty)
        #expect(control.tick(now: start + .seconds(1)) == first)
        let stop = start + .milliseconds(1200)
        let empty = try control.send(.videoRequest([], maxKbps: 500, activeSpeakerHeight: nil), now: stop)
        #expect(first != empty)
        #expect(control.tick(now: start + .seconds(2)).isEmpty)
        #expect(control.tick(now: stop + .seconds(1)) == empty)
        _ = try control.send(.leave)
        #expect(control.tick(now: stop + .seconds(2)).isEmpty)
    }

    @Test func framesMergedInSequenceAndAcknowledgedAgainOnReplay() throws {
        let speaker: [UInt8] = [34,5,21,4,3,2,1]
        var control = GroupSFUControl()
        #expect(try control.receive(inbound(2, Array(speaker.suffix(4)), fragment: true), timestamp: 101).isEmpty)
        #expect(control.tick().isEmpty)
        let updates = try control.receive(inbound(1, Array(speaker.prefix(3)), count: 2, fragment: true), timestamp: 100)
        #expect(updates.map(\.speaker) == [0x01020304])
        #expect(updates.map(\.timestamp) == [100])
        #expect(control.tick() == [Data([66,2,16,3])])
        #expect(try control.receive(inbound(1, speaker), timestamp: 101).isEmpty)
        #expect(control.tick() == [Data([66,2,16,3])])
        #expect(throws: CallingWireError.self) { try control.receive(inbound(80, speaker), timestamp: 103) }
        #expect(try control.receive(inbound(3, [74,0]), timestamp: 105).first?.removed == true)
    }

    @Test func raiseHandRetryAndPackedRosterFields() throws {
        var control = GroupSFUControl()
        let start = ContinuousClock.now
        let request = try control.send(.raiseHand(true), now: start)
        #expect(request == [Data([58,4,8,1,16,1])])
        #expect(control.tick(now: start + .milliseconds(500)) == request)
        let hands = try control.receive(Data([82,12,10,4,9,0,0,0,18,2,4,5,24,1]), timestamp: 10)
        #expect(hands.first?.raisedHands?.demuxIDs == [9])
        #expect(hands.first?.raisedHands?.sequenceNumbers == [4,5])
        #expect(control.tick(now: start + .seconds(2)).isEmpty)
        let roster = try control.receive(Data([58,13,10,2,2,5,21,4,0,0,0,26,2,24,60]), timestamp: 2)
        #expect(roster.first?.currentDevices?.withVideo == [2,5])
        #expect(roster.first?.currentDevices?.allDemuxIDs == [4])
        #expect(roster.first?.currentDevices?.allocatedHeights == [24,60])
        let peek = try control.receive(Data([50,19,10,17,10,1,97,16,4,26,1,66,34,7,13,9,0,0,0,24,0]), timestamp: 1)
        #expect(peek.first?.rosterChanged == true && peek.first?.peek?.devices.first?.demuxID == 9)
    }

    @Test func largeVideoRequestFragmentsAndWindowIsBounded() throws {
        var control = GroupSFUControl()
        let requests = (1...320).map { GroupSFUVideoRequest(demuxID: UInt32($0), height: 120) }
        let frames = try control.send(.videoRequest(requests, maxKbps: nil, activeSpeakerHeight: nil))
        try #require(frames.count == 3)
        #expect(frames.allSatisfy { $0.count <= 1200 })
        #expect(frames[0].starts(with: [66,4,8,1,24,3,74]))
        #expect(frames[1].starts(with: [66,2,8,2,74]))
        for _ in frames.count..<64 { _ = try control.send(.remove(8)) }
        #expect(throws: CallingWireError.self) { try control.send(.approve(8)) }
    }
}
