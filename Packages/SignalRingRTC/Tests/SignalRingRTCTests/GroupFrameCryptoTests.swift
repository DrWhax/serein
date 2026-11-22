import Foundation
import Testing
@testable import SwiftCalling

struct GroupFrameCryptoTests {
    private func hex(_ bytes: Data) -> String {
        bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
    }

    @Test func pinnedRingRTCFramesAndRatchetKeys() throws {
        // Produced by vendor/ringrtc/src/rust/src/core/crypto.rs, Context::encrypt with
        // 00..1f as the initial secret, 00..24 payload, and advance_send_ratchet between calls.
        let frames = [
            "792fe80988715d3e0fc97f7899265f3dfb894aac0c8e23419475c982a5d67f08ea4f16dd5c00000000011f55dc46f3d62c8aeb787e5fbba5dcd5",
            "b96266c733ef92b4bdabc029e213979f28bb48696beacba23be6d07b035f57e736f5a2781601000000024d6bc8d28a6487a8d01b7cfd3f3385b0",
            "17ed2dadf1f2f0c6ec421f5c615757caaa8f22958761d924448287eb660c56cefa9c2c3a6502000000036f0fa70934535626e39df14e77f927b5",
        ]
        let initial = Data(0..<32), plain = Data(0..<37), user = UUID()
        let sender = try GroupFrameCrypto(secret: initial), receiver = GroupFrameCrypto()
        try receiver.setMembers([16: user])
        try receiver.install(secret: initial, ratchet: 0, demuxID: 16, sender: user)
        var records = [Data]()
        for i in frames.indices {
            if i != 0 { sender.advance() }
            let record = try sender.seal(plain)
            #expect(hex(record) == frames[i])
            records.append(record)
        }
        // Ratchet ahead without another key message, then accept the older frames exactly once.
        for record in records.reversed() { #expect(try receiver.open(record, from: 16) == plain) }
        #expect(throws: GroupFrameCrypto.Failure.replay) { try receiver.open(records[0], from: 16) }
        let finalKey = hex(sender.sendingKey.secret)
        #expect(finalKey == "36881534cce52dac2adb35450c59657cf2bfa8f4655bf37040f616bee637cb95")
    }

    @Test func membershipRotationAuthenticationAndReplay() throws {
        let alice = UUID(), bob = UUID(), sender = GroupFrameCrypto(), receiver = GroupFrameCrypto()
        let secret = sender.sendingKey.secret
        try receiver.setMembers([32: alice, 48: bob])
        #expect(throws: GroupFrameCrypto.Failure.unknownSender) {
            try receiver.install(secret: secret, ratchet: 0, demuxID: 48, sender: alice)
        }
        try receiver.install(secret: secret, ratchet: 0, demuxID: 32, sender: alice)
        let payload = Data([3, 5]), first = try sender.seal(payload)
        for i in [0, first.count-21, first.count-18, first.count-1] {
            var modified = first
            modified[i] ^= 0x40
            #expect(throws: GroupFrameCrypto.Failure.unauthenticated) { try receiver.open(modified, from: 32) }
        }
        #expect(try receiver.open(first, from: 32) == payload)
        try receiver.install(secret: secret, ratchet: 0, demuxID: 32, sender: alice)
        #expect(throws: GroupFrameCrypto.Failure.replay) { try receiver.open(first, from: 32) }
        let now = ContinuousClock.now
        sender.scheduleRotation(at: now)
        let rotated = try #require(sender.pendingKey)
        sender.scheduleRotation(at: now + .seconds(2))
        #expect(sender.applyRotation(at: now + .seconds(4)) == nil)
        #expect(try receiver.open(sender.seal(payload), from: 32) == payload)
        let following = try #require(sender.applyRotation(at: now + .seconds(5)))
        #expect(following.secret != rotated.secret)
        let next = try sender.seal(payload)
        #expect(throws: GroupFrameCrypto.Failure.unauthenticated) { try receiver.open(next, from: 32) }
        try receiver.install(secret: rotated.secret, ratchet: 0, demuxID: 32, sender: alice)
        #expect(try receiver.open(next, from: 32) == payload)
        #expect(sender.applyRotation(at: now + .seconds(10)) == nil)
        let afterBothDepartures = try sender.seal(payload)
        #expect(throws: GroupFrameCrypto.Failure.unauthenticated) { try receiver.open(afterBothDepartures, from: 32) }
        try receiver.install(secret: following.secret, ratchet: 0, demuxID: 32, sender: alice)
        #expect(try receiver.open(afterBothDepartures, from: 32) == payload)
        try receiver.setMembers([32: bob])
        #expect(throws: GroupFrameCrypto.Failure.unknownSender) { try receiver.open(next, from: 32) }
        #expect(throws: GroupFrameCrypto.Failure.unknownSender) {
            try receiver.install(secret: rotated.secret, ratchet: 0, demuxID: 32, sender: alice)
        }
    }
}
