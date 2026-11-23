import Foundation
import Testing
@testable import SwiftCalling

struct OpusSpeechEncoderTests {
    @Test func silkGainLevelsMatchPinnedWebRTC() {
        // Absolute gain indices independently decoded by silk_gains_dequant. Both
        // speech analysis and synthesis depend on these exact fixed-point steps.
        #expect([0, 1, 32, 63].map(SILKSynthesis.gainQ16) == [81_920, 96_256, 12_713_984, 1_686_110_208])
    }

    @Test func rangeCodingMatchesPinnedWebRTC() throws {
        // Independently encoded using ec_enc_icdf / ec_enc_done in the pinned WebRTC
        // archive. Includes repeated rare symbols, carry propagation, and termination.
        var random: UInt32 = 9
        var range = OpusRangeEncoder()
        for _ in 0..<240 {
            random = random &* 1_664_525 &+ 1_013_904_223
            try range.symbol(Int(random >> 30), [254, 191, 85, 0])
        }
        #expect(try range.finish() == callingTestBytes("""
            0002ac06d5b4b5e5d647f75264eb04e7cac2e32c0a578629ff599889f73169498792c9e3929d1aee2efd976c0c7b6184
            3506e1a98c202f0921ca7df8fb7200180d3afb9de8b8b3597daa1237b657d7b5d4bf897d2b96e2e06c37ed6845db76dc3a9dbc00
            """))
    }

    @Test func widebandLowDataFECAndDTX() throws {
        var encoder = OpusSpeechEncoder()
        let tone = (0..<960).map { Int16(5000 * sin(2 * Double.pi * 5600 * Double($0) / 48000)) }
        var reference = OpusSpeechDecoder(), missing = OpusSpeechDecoder()
        encoder.setPacketLoss(25)
        let first = try OpusPacket(encoder.encode(tone))
        #expect(first.configuration == 9)
        _ = try reference.decode(first)
        _ = try missing.decode(first)
        let second = try OpusPacket(encoder.encode(tone))
        let third = try OpusPacket(encoder.encode(tone))
        #expect(try reference.decode(second) == missing.recover(before: third, samples: 960))
        #expect(try reference.decode(third) == missing.decode(third))
        encoder.setLowDataMode(true)
        #expect(try OpusPacket(encoder.encode(tone)).configuration == 1)
        let quiet = [Int16](repeating: 0, count: 960)
        for _ in 0..<10 { _ = try encoder.transmission(quiet) }
        #expect(try encoder.transmission(quiet) == nil)
        let candidate = try encoder.transmission(tone)
        let resumed = try #require(candidate)
        #expect(resumed.marker && resumed.skipped == 960)
    }

    @Test func normalSpeechUsesRingRTCPacketBudget() throws {
        for size in [960, 2880] {
            var encoder = OpusSpeechEncoder()
            for frame in 0..<15 {
                let pcm = (0..<size).map { i -> Int16 in
                    let t = Double(frame * size + i) / 48000
                    return Int16(6500 * sin(2 * .pi * 600 * t) + 5000 * sin(2 * .pi * 5600 * t))
                }
                let packet = try encoder.encode(pcm)
                #expect(packet.count == size / 12)
                #expect(try OpusPacket(packet).sampleCount == size)
            }
        }
    }

    @Test(arguments: [960, 2880], [false, true])
    func fullbandHybridAndCELTPreserveMicrophoneSpectrum(samples: Int, transformOnly: Bool) throws {
        let levels = transformOnly ? [1000.0, 8200.0, 3800.0] : [8000.0, 3400.0, 1600.0]
        let frequencies = [600.0, 10_500.0, 16_500.0]
        var encoder = OpusSpeechEncoder(), decoder = OpusSpeechDecoder()
        var output: [Int16] = []
        for packetIndex in 0..<(28_800 / samples) {
            let pcm = (0..<samples).map { i -> Int16 in
                let time = Double(packetIndex*samples+i) * 2*Double.pi/48_000
                let value = zip(frequencies,levels).reduce(0.0) { $0 + $1.1 * sin($1.0*time) }
                return Int16(value.rounded())
            }
            let packet = try OpusPacket(encoder.encode(pcm))
            #expect(packet.configuration == (transformOnly ? 31 : 15))
            #expect(packet.sampleCount == samples)
            output += try decoder.decode(packet)
        }
        let signal = output[4800..<19_200]
        for (frequency, target) in zip(frequencies, levels) {
            var real = 0.0, imaginary = 0.0
            for (index, sample) in signal.enumerated() {
                let phase = Double(index) * 2*Double.pi*frequency/48_000
                real += Double(sample)*cos(phase)
                imaginary += Double(sample)*sin(phase)
            }
            let amplitude = 2*hypot(real, imaginary)/Double(signal.count)
            #expect(amplitude > 0.80*target && amplitude < 1.20*target)
        }
    }

    @Test func sixtyMillisecondsPreservesAllThreeFrames() throws {
        let pcm = (0..<2880).map { Int16(truncatingIfNeeded: ($0 * 5243) ^ ($0 / 31)) }
        var short = OpusSpeechEncoder(), long = OpusSpeechEncoder()
        let bundle = try OpusPacket(long.encode(pcm))
        #expect(bundle.sampleCount == 2880 && bundle.frames.count == 3 && !bundle.stereo)
        for i in 0..<3 {
            #expect(throws: (any Error).self) { try short.encode([]) }
            let single = try OpusPacket(short.encode(Array(pcm[i * 960..<i * 960 + 960])))
            #expect(single.sampleCount == 960 && single.frames[0].copyBytes() == bundle.frames[i].copyBytes())
        }
        // Both encoders have consumed exactly the same samples and have identical history.
        #expect(try short.encode(Array(pcm.suffix(960))) == long.encode(Array(pcm.suffix(960))))
    }
}
