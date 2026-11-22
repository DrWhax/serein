import CryptoKit
import Foundation
import Testing
@testable import SwiftCalling

struct OpusTests {
    @Test func framingMatchesPinnedWebRTC() throws {
        // The pinned archive's opus_packet_parse and opus_packet_get_nb_samples produced
        // this digest. Hash acceptance, count, duration, each frame length and its contents.
        var state: UInt32 = 0x2468_ace1
        func nextByte() -> UInt8 {
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(state >> 24)
        }
        var digest = SHA256()
        var accepted = 0
        for _ in 0..<8192 {
            let input = Data((0..<Int(nextByte() % 96)).map { _ in nextByte() })
            guard let packet = try? OpusPacket(input) else {
                digest.update(data: Data([0xff]))
                continue
            }
            accepted += 1
            var record = [UInt8(packet.frames.count), UInt8(packet.sampleCount >> 8), UInt8(truncatingIfNeeded: packet.sampleCount)]
            for frame in packet.frames {
                record += [UInt8(frame.count >> 8), UInt8(truncatingIfNeeded: frame.count)]
                frame.append(to: &record)
            }
            digest.update(data: Data(record))
        }
        #expect(accepted == 3409)
        #expect(Array(digest.finalize()) == callingTestBytes("d5e82e5dfb01b99c1b0645bf8d12c722286ae74d8239bdb40bb65f41990142db"))
    }

    @Test func durationFrameAndPaddingLimits() throws {
        let toc: UInt8 = 16 << 3
        let maxDuration = try OpusPacket(Data([toc | 3, 48]))
        #expect(maxDuration.frames.count == 48 && maxDuration.sampleCount == 5760)
        #expect(throws: (any Error).self) { try OpusPacket(Data([toc | 3, 49])) }
        #expect(try OpusPacket(Data([toc]) + Data(repeating: 3, count: 1275)).frames.first?.count == 1275)
        #expect(throws: (any Error).self) { try OpusPacket(Data([toc]) + Data(repeating: 3, count: 1276)) }
        let padded = Data([toc | 3, 0xc2, 255, 2, 252, 0]) + Data(repeating: 7, count: 252) + Data([3]) + Data(repeating: 0, count: 256)
        let parsed = try OpusPacket(padded)
        #expect(parsed.frames.map(\.count) == [252, 1] && parsed.frames.last?.copyBytes() == [3])
        #expect(throws: (any Error).self) { try OpusPacket(Data([toc | 3, 0x41, 255])) }
    }

    @Test func directStreamClockUsesFrameDurationAndDTXGap() throws {
        let keys = SRTPKeys(key: SymmetricKey(size: .bits256), salt: Array(repeating: 0x29, count: 12))
        let start = UInt32.max - 100
        let sender = DirectOpusSender(keys: keys, role: .callee, sequence: 100, timestamp: start)
        let receiver = DirectOpusReceiver(keys: keys, remoteRole: .callee)
        let single = Data(callingTestBytes(toneFixtures[0].0))
        let first = try receiver.open(sender.seal(single, talkspurt: true))
        #expect(first.timestamp == start && first.packet.sampleCount == 960)
        #expect(throws: (any Error).self) { try sender.seal(Data()) }
        let later = try receiver.open(sender.seal(single, talkspurt: true, skippedSamples: 480))
        #expect(later.timestamp == start &+ 1440 && later.packet.sampleCount == 960)
    }

    @Test func rangeSymbolsFromReferenceToneFrames() throws {
        // The reference encoder encoded the first 20 ms of a mono 440 Hz tone. Expected
        // symbols come from the pinned archive's ec_dec_* routines applied in this order.
        for (hex, expected) in toneFixtures {
            let packet = try OpusPacket(Data(callingTestBytes(hex)))
            #expect(!packet.stereo && packet.sampleCount == 960)
            var range = try OpusRangeDecoder(try #require(packet.frames.first))
            #expect(range.bitsUsed == 1)
            let results = try [range.bit(logProbability: 1), range.bit(logProbability: 2),
                               range.symbol(inverseCDF: [180, 88, 33, 0]), range.uniform(below: 500),
                               range.rawBits(5), range.uniform(below: 7), range.rawBits(12)]
            #expect(results == expected)
        }
    }

    private var toneFixtures: [(String, [UInt32])] {
        [
            ("""
            488288036c9e99ac0000066062e8ae9eb824de15f3abef06ad97142be7548a742c6252f4749fc3bacfc7a970c4f7db09
            edbf7ae8b3758d49f6a9179e5823d275d249e846c1d68f53c380
            """, [1, 0, 0, 44, 0, 1, 3854]),
            ("""
            f878723af80359a38b138ae7629ac2d2de4c25b185fb0b68eddab7d2a3f499183d0bf3102fac0a3e6b311959f1efacad
            68d121d65099cc02d4542477aff1b4a19563cf2c0d15cb8f8eeb7ad769617c9ecf72943e02b66af70bd5a37dd7d7f4af
            6f236349e0c5d43965d439638b480833fc14439f47eefc84439f42a6adea912ace286364752a5d85dea67422d1a0e94f
            73bd2107434d1b6ef18c53c8d60320a09aa3fcef3e30f71af9240abac100c5a8e8e0ea0f416a298939f243f1935ec7f0
            b010ff4086bcd2855c2a420e039d24
            """, [0, 1, 2, 250, 18, 2, 3700]),
            ("""
            f8b4f004d5b508d107d627b8089eac05a8af1397b55f4909ec1354e922a174fc6662faa6a021e1170375aa216409d952
            752ea7d9c4f18fd597c2de7eb52837f462220db3d384769e46a23f5353644540ccdffeeadcc6b313feadd95cfbf99638
            f0c2844c84c20f662508961bc51ffbe3ec4acb20000000dda6e6b0bb852f3d3453852650da0b219a234986816958ac5b
            d97ada2f7d047762abe78b7459881bd6b0303e1849e44151c7ea7740c6a8bc31b3b681182e7bb1b4b7e27f9668ecd0f0
            a8662e711a1e50a9c82de1c52dc1456c
            """, [1, 0, 1, 354, 22, 0, 1301]),
        ]
    }
}
