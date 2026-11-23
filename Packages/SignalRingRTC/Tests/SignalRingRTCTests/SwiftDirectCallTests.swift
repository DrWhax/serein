import CryptoKit
import Foundation
import SwiftCalling
import Testing

/// Hexadecimal literals from published and independently generated reference vectors.
func callingTestBytes(_ hex: String) -> [UInt8] {
    let digits = Array(hex.filter { !$0.isWhitespace }.utf8)
    return stride(from: 0, to: digits.count, by: 2).map {
        UInt8(String(decoding: digits[$0..<$0 + 2], as: UTF8.self), radix: 16)!
    }
}

struct SwiftDirectCallTests {
    // From v2.75.0 connection.rs negotiate_srtp_keys with the deterministic private
    // and identity keys below. No WebRTC, network, or device access needed for this test.
    @Test func directionalKeysMatchRingRTC() throws {
        let alice = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(0..<32))
        let bob = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(32..<64))
        let caller = Data([5]) + Data(repeating: 0x11, count: 32)
        let callee = Data([5]) + Data(repeating: 0x22, count: 32)
        let a = try DirectCallKeys(local: alice, remote: bob.publicKey.rawRepresentation, callerIdentity: caller, calleeIdentity: callee)
        let b = try DirectCallKeys(local: bob, remote: alice.publicKey.rawRepresentation, callerIdentity: caller, calleeIdentity: callee)
        #expect(a == b)
        func key(_ hex: String) -> SymmetricKey {
            SymmetricKey(data: callingTestBytes(hex))
        }
        #expect(a.offer.key == key("9c6045025bdb9e62cc2fc07f7f08ca275a625391fe2bc93be556c1473659e8f9"))
        #expect(a.offer.salt == key("6893d290f0828e13dd404e2a"))
        #expect(a.answer.key == key("230f9a31745ef0fb71d946438b3a1877c8f5f16375c39a957458d7edbf87b918"))
        #expect(a.answer.salt == key("ab372fbc746e4f64bfe87d8d"))
        let reversed = try DirectCallKeys(local: alice, remote: bob.publicKey.rawRepresentation, callerIdentity: callee, calleeIdentity: caller)
        #expect(reversed != a)
        for remote in [Data(repeating: 0, count: 32), Data([1]) + Data(repeating: 0, count: 31), Data(count: 31)] {
            #expect(throws: (any Error).self) { try DirectCallKeys(local: alice, remote: remote, callerIdentity: caller, calleeIdentity: callee) }
        }
    }

    @Test func signalingFieldPresenceAndBounds() throws {
        var example = DirectCallParameters()
        example.publicKey = Data(repeating: 7, count: 32)
        example.iceUfrag = "user"
        example.icePassword = "pw"
        example.encoders = [8, 9, nil]
        example.decoders = [9, 8]
        example.maxBitrateBps = UInt64.max
        let envelope = example.envelope()
        #expect(try DirectCallParameters(envelope: envelope) == example)
        for prefix in 0..<envelope.count {
            #expect(throws: (any Error).self) { try DirectCallParameters(envelope: envelope.prefix(prefix)) }
        }
        // Unknown proto2 groups can be skipped; length and varint fields stay bounded.
        #expect(try DirectCallParameters(envelope: Data([0x0b, 0x10, 1, 0x0c]) + envelope) == example)
        for bad in [Data([0]), Data([0x22, 3, 0x12, 1, 0xff]), Data([0x22, 1, 0x08]),
                    Data(repeating: 0xff, count: 10), Data(repeating: 0, count: 65_537)] {
            #expect(throws: (any Error).self) { try DirectCallParameters(envelope: bad) }
        }
    }

    @Test func candidateWireForms() throws {
        let added = IceCandidateUpdate(addedSDP: "candidate:test")
        #expect(try IceCandidateUpdate(envelope: added.envelope()) == added)
        for ip in [Data([127, 0, 0, 1]), Data(repeating: 1, count: 16)] {
            let removed = try IceCandidateUpdate(removingIP: ip, port: 65535)
            #expect(try IceCandidateUpdate(envelope: removed.envelope()) == removed)
            #expect(removed.addedSDP == "candidate:FAKE 1 tcp 0 127.0.0.1 0 typ host")
        }
        #expect(throws: (any Error).self) { try IceCandidateUpdate(envelope: Data([0x1a, 2, 0x10, 7])) }
        #expect(throws: (any Error).self) { try IceCandidateUpdate(removingIP: Data(count: 5), port: 7) }
    }
}
