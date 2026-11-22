import CryptoKit
import Foundation
import Testing
@testable import SwiftCalling

struct ICEHostPairTests {
    let password = "ABCDEFGHIJKLMNOPQRSTUVWXYZ123456"

    private func pair(relayOnly: Bool = false) throws -> ICEHostPair {
        let candidate = try #require(ICEHostCandidate("candidate:a 1 UDP 123 192.0.2.1 54321 typ host"))
        return try ICEHostPair(candidate: candidate, relayOnly: relayOnly, localUfrag: "here", localPassword: password,
                               remoteUfrag: "peer", remotePassword: password, role: .controlling(12))
    }

    @Test func candidateAndPrivacyPolicy() throws {
        #expect(ICEHostCandidate("candidate:x 1 udp 123 2001:db8::12 15 typ host")?.address.ip.count == 16)
        for sdp in ["candidate:x 1 tcp 1 192.0.2.1 9 typ host", "candidate:x 1 udp 1 example.org 53 typ host",
                    "candidate:x 1 udp 1 192.0.2.1 0 typ host", "candidate:x 1 udp 1 192.0.2.1 55 typ relay"] {
            #expect(ICEHostCandidate(sdp) == nil)
        }
        #expect(throws: ICEHostPair.Failure.self) { try pair(relayOnly: true) }
    }

    @Test func onlyOneOfTwoValidatedPairsCanNominate() throws {
        let election = ICENomination(), key = SymmetricKey(data: Data(password.utf8))
        var outbound = try pair(), triggered = try pair()
        outbound.reservation = ICENomination.Reservation(election)
        triggered.reservation = ICENomination.Reservation(election)
        let start = ContinuousClock.now, ready = start + .seconds(1)
        func validate(_ pair: inout ICEHostPair) throws {
            let bytes = try pair.check(at: start)
            let request = try ICEBinding(packet: Array(#require(bytes)), password: key)
            let reply = try Data(request.response(mapped: .init(ip: [192, 0, 2, 2], port: 42), password: key))
            _ = try pair.receive(reply, at: ready)
        }
        try validate(&outbound)
        try validate(&triggered)
        let first = try outbound.check(at: ready)
        #expect(try ICEBinding(packet: Array(#require(first)), password: key).nominated)
        let competing = try triggered.check(at: ready)
        #expect(competing == nil)
        outbound.reservation?.release() // nomination timeout / failed socket
        let retry = try triggered.check(at: ready + .milliseconds(101))
        #expect(try ICEBinding(packet: Array(#require(retry)), password: key).nominated)
    }

    @Test func nominationAndConsentDeadline() throws {
        var pair = try pair()
        let key = SymmetricKey(data: Data(password.utf8))
        let now = ContinuousClock.now
        func response(_ check: Data) throws -> Data {
            let request = try ICEBinding(packet: Array(check), password: key)
            return try Data(request.response(mapped: .init(ip: [192, 0, 2, 2], port: 41), password: key))
        }
        func nextCheck(at instant: ICEHostPair.Instant) throws -> Data {
            let packet = try pair.check(at: instant)
            return try #require(packet)
        }
        let first = try nextCheck(at: now)
        #expect(!pair.canSendMedia(at: now))
        #expect(try pair.check(at: now.advanced(by: .milliseconds(500))) == first)
        let selected = now.advanced(by: .seconds(1))
        _ = try pair.receive(response(first), at: selected)
        #expect(!pair.canSendMedia(at: selected))
        let nominate = try nextCheck(at: selected)
        #expect(try ICEBinding(packet: Array(nominate), password: key).nominated)
        _ = try pair.receive(response(nominate), at: selected)
        #expect(pair.canSendMedia(at: selected))
        #expect(try pair.check(at: selected.advanced(by: .seconds(3))) == nil)
        let fresh = try nextCheck(at: selected.advanced(by: .seconds(6)))
        let later = try nextCheck(at: selected.advanced(by: .seconds(12)))
        #expect(later != fresh)
        let acknowledged = selected.advanced(by: .seconds(13))
        _ = try pair.receive(response(fresh), at: acknowledged)
        _ = try pair.receive(response(fresh), at: acknowledged.advanced(by: .seconds(5)))
        #expect(pair.canSendMedia(at: acknowledged.advanced(by: .seconds(29))))
        let expires = acknowledged.advanced(by: .seconds(30))
        #expect(!pair.canSendMedia(at: expires))
        #expect(throws: ICEHostPair.Failure.self) { try pair.receive(response(later), at: expires) }
        #expect(throws: ICEHostPair.Failure.self) { try pair.check(at: expires) }
    }
}
