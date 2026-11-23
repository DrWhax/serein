import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import SwiftCalling

struct TURNTests {
    @Test func authenticatedFieldsAndAddressFamilies() throws {
        let id = Array(UInt8(0)..<12)
        let key = SymmetricKey(data: [1, 2, 3])
        for candidate in ["candidate:1 1 udp 6 192.0.2.1 32768 typ relay", "candidate:2 1 udp 9 2001:db8::1 32769 typ relay"] {
            let relay = try #require(ICERelayCandidate(candidate))
            #expect(ICERelayCandidate(relay.sdp) == relay)
            let encoded = try TURNMessage.xorAddress(relay.address, id: id)
            let packet = try TURNMessage.packet(0x103, id: id, attributes: [(.relayed, encoded), (.lifetime, [0, 0, 2, 88])], key: key)
            let reply = try TURNMessage(packet)
            try reply.verify(using: key)
            #expect(try reply.lifetime() == 600)
            #expect(try reply.address(.relayed) == relay.address)
            var corrupt = packet
            corrupt[24] ^= 1
            #expect(throws: TURNMessage.Failure.self) { try TURNMessage(corrupt).verify(using: key) }
            // An appended unauthenticated attribute cannot affect the answer.
            var appended = packet + [0, 0x12, 0, 4, 0, 0, 0, 0]
            appended[3] += 8
            let extended = try TURNMessage(appended)
            try extended.verify(using: key)
            #expect(extended[.peer] == nil)
        }
        #expect(ICERelayCandidate("candidate:1 1 udp 123 192.0.2.1 42 typ host") == nil)
        #expect(ICERelayCandidate("candidate:1 1 udp 123 example.com 42 typ relay") == nil)
        for address in ["127.0.0.1", "192.168.2.3", "100.64.0.1", "239.4.2.1", "::1", "fd00::1", "2002::1"] {
            #expect(ICERelayCandidate("candidate:1 1 udp 123 \(address) 42 typ relay") == nil)
        }
    }

    @Test func onlyChallengesCanOmitIntegrity() throws {
        let id = TURNMessage.newID()
        let key = SymmetricKey(data: [2, 3])
        let stale = try TURNMessage.packet(0x0114, id: id, attributes: [(.error, [0, 0, 4, 38]), (.nonce, Array("next".utf8))])
        #expect(try TURNMessage(stale).acceptsResponse(key: key))
        let forged = try TURNMessage.packet(0x0104, id: id, attributes: [(.lifetime, [0, 0, 2, 88])])
        #expect(try !TURNMessage(forged).acceptsResponse(key: key))
        let modern = try TURNMessage.packet(0x0113, id: id, attributes: [(.nonce, Array("obMatJos2AAAAcookie".utf8))])
        #expect(try TURNMessage(modern).legacyNonce == nil)
    }

    @Test
    func deniedPermissionEndsAllocation() async throws {
        let allocation = try await TURNTestRelay.open()
        defer { allocation.close() }
        // The runner only permits its own mapped relay address. A refused permission
        // closes the transport without sending a peer datagram or starting a direct path.
        let refused = try #require(ICERelayCandidate("candidate:1 1 udp 42 192.0.2.2 32000 typ relay"))
        do {
            _ = try await allocation.connect(to: refused)
            Issue.record("The local relay must refuse permissions outside its mapping")
        } catch TURNMessage.Failure.server(let code) { #expect(code == 403) }
        do {
            _ = try await allocation.connect(to: allocation.localCandidate)
            Issue.record("Relay failure must retire the allocation")
        } catch TURNMessage.Failure.closed {}
    }

    @Test
    func twoIndependentAllocations() async throws {
        let first = try await TURNTestRelay.open()
        defer { first.close() }
        let second = try await TURNTestRelay.open()
        defer { second.close() }
        #expect(first.localCandidate.address.port != second.localCandidate.address.port)
        let alice = try await first.connect(to: second.localCandidate)
        let bob = try await second.connect(to: first.localCandidate)
        let left = Mutex<Data?>(nil), right = Mutex<Data?>(nil)
        alice.receive { data in left.withLock { $0 = data } }
        bob.receive { data in right.withLock { $0 = data } }
        if ProcessInfo.processInfo.environment["SEREIN_TEST_TURN_SHORT_LEASE"] == "1" {
            // The runner configures an eight-second allocation and two-second nonce.
            // Both permissions must still work after the original allocation expires.
            try await Task.sleep(for: .seconds(10))
        }
        for _ in 0..<50 {
            try alice.send(Data([1, 2, 3]))
            try bob.send(Data([4, 5, 6]))
            try await Task.sleep(for: .milliseconds(20))
            if left.withLock({ $0 != nil }), right.withLock({ $0 != nil }) { break }
        }
        #expect(left.withLock { $0 == Data([4, 5, 6]) })
        #expect(right.withLock { $0 == Data([1, 2, 3]) })
        first.close()
        #expect(throws: TURNMessage.Failure.self) { try alice.send(Data([7])) }
    }
}
