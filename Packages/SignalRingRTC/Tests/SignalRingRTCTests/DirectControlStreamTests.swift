import CryptoKit
import Foundation
import Testing
@testable import SwiftCalling

struct DirectControlStreamTests {
    private func keys() -> SRTPKeys {
        SRTPKeys(key: SymmetricKey(size: .bits256), salt: Array(repeating: 0x18, count: 12))
    }

    @Test func cumulativeControlSurvivesLossAndRejectsStaleUpdates() throws {
        let outgoing = keys(), incoming = keys()
        var callee = DirectControlStream(callID: 49, role: .callee, outgoing: outgoing, incoming: incoming)
        var caller = DirectControlStream(callID: 49, role: .caller, outgoing: incoming, incoming: outgoing)
        try callee.accept()
        try callee.setAudio(enabled: true)
        let early = try callee.packet()
        try callee.setAudio(enabled: false)
        let later = try callee.packet()
        let applied = try caller.receive(try #require(later))
        #expect(applied.acceptedID == 49 && applied.sender?.audio == false)
        let old = try #require(early)
        do {
            _ = try caller.receive(old)
            Issue.record("Applied an older timestamp")
        } catch DirectControlStream.Failure.outOfOrder {}
        let retransmission = try callee.packet()
        let repeated = try caller.receive(try #require(retransmission))
        #expect(repeated.acceptedID == 49 && repeated.sender == nil)
        try callee.hangup()
        let hangup = try callee.packet()
        let end = try caller.receive(try #require(hangup))
        #expect(end.hangup?.id == 49 && end.hangup?.reason == 0)
    }

    @Test func rejectAnotherCallAndAcceptanceFromTheCaller() throws {
        let outgoing = keys(), incoming = keys()
        let wire = SRTPSender(keys: incoming, ssrc: DirectCallControl.ssrc, startingAt: 0)
        var state = DirectControlStream(callID: 19, role: .callee, outgoing: outgoing, incoming: incoming)
        for id: UInt64 in [18, 19] {
            var control = DirectCallControl()
            control.acceptedID = id
            let packet = try wire.seal(control.payload(), type: 101, timestamp: UInt32(id))
            do {
                _ = try state.receive(packet)
                Issue.record("Accepted an invalid peer control message")
            } catch DirectControlStream.Failure.wrongCall where id == 18 {
            } catch DirectControlStream.Failure.wrongRole where id == 19 {}
        }
    }
}
