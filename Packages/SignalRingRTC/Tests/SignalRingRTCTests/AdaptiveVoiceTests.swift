import Foundation
import Testing
@testable import SwiftCalling

struct AdaptiveVoiceTests {
    private func rms(_ samples: [Int16]) -> Double {
        sqrt(samples.reduce(0.0) { $0 + Double($1)*Double($1) } / Double(max(1, samples.count)))
    }

    @Test func suppressesBackgroundAndRumbleAndPreservesSpeechLevel() {
        let chain = CallEchoControl(enabled: true)
        var state: UInt32 = 2
        var raw = [Int16](), quiet = [Int16](), soft = [Int16](), loud = [Int16]()
        var peak = 0
        for n in 0..<240 {
            let amplitude: Double = n < 65 ? 0 : (n < 155 ? 700 : 9000)
            let input = (0..<960).map { i -> Int16 in
                state = state &* 1_664_525 &+ 1_013_904_223
                let t = Double(n*960 + i)/48_000, f = 2*Double.pi*220*t
                let background = 400 + 550*sin(2*Double.pi*23*t) + Double(Int16(truncatingIfNeeded: state >> 16))*0.007
                return Int16(background + amplitude*(sin(f) + 0.5*sin(2*f) + 0.25*sin(4*f)))
            }
            let samples = chain.capture(input, at: Int64(n*960))
            peak = max(peak, samples.reduce(0) { max($0, Int($1.magnitude)) })
            if (45..<65).contains(n) { raw += input; quiet += samples }
            if (135..<155).contains(n) { soft += samples }
            if n >= 220 { loud += samples }
        }
        #expect(rms(quiet) < rms(raw) / 5)
        #expect(rms(soft) > 1000)
        #expect((1600...3600).contains(rms(loud)))
        #expect(peak <= 30_000)
        chain.setEnabled(false)
        #expect(chain.capture(raw, at: 0) == raw)
        let original = Array(loud.prefix(960))
        #expect(chain.capture(original, at: 0) == original)
        chain.setEnabled(true)
        let fresh = CallEchoControl(enabled: true)
        #expect(chain.capture(original, at: 0) == fresh.capture(original, at: 0))
        chain.reset()
        let silence = [Int16](repeating: 0, count: 960)
        #expect(chain.capture(silence, at: 0) == silence)
    }

    @Test func keepsGroupSourcesIndependentAndStopsConcealingAnIdlePeer() throws {
        let packet = try OpusPacket(Data([0x48])), start = ContinuousClock.now
        var a = OpusJitterBuffer(), b = OpusJitterBuffer()
        a.insert(packet, timestamp: .max-479, sequence: .max, marker: true, now: start)
        b.insert(packet, timestamp: 48_000, sequence: 30, marker: true, now: start)
        let first = a.render(now: start + .milliseconds(40))
        let second = b.render(now: start + .milliseconds(40))
        #expect(first?.timestamp == .max-479 && second?.timestamp == 48_000)
        for tick in 0..<15 {
            let now = start + .milliseconds(60+tick*20)
            b.insert(packet, timestamp: UInt32(48_960+tick*960), sequence: UInt16(31+tick), marker: false, now: now)
            _ = b.render(now: now)
            _ = a.render(now: now)
        }
        #expect(!a.active && b.active)
        #expect(a.statistics.emittedSamples == 4*960)
        #expect(a.statistics.concealedSamples == 2880 && a.statistics.silentConcealedSamples == 2880)
        #expect(b.statistics.concealedSamples == 0 && b.statistics.cumulativeDelaySeconds > 0)
    }

    @Test func handlesSustainedSenderClockDriftAndBoundsQueuedData() throws {
        let packet = try OpusPacket(Data([0x48]))
        let origin = ContinuousClock.now
        for faster in [false, true] {
            var source = OpusJitterBuffer()
            var packetIndex = 0, rendered = 0
            let spacing = faster ? 19.77 : 20.23
            for tick in 0..<950 {
                let now = Double(tick*20)
                while Double(packetIndex)*spacing <= now {
                    source.insert(packet, timestamp: UInt32(packetIndex*960), sequence: UInt16(truncatingIfNeeded: packetIndex),
                                  marker: packetIndex == 0, now: origin + .milliseconds(Double(packetIndex)*spacing))
                    packetIndex += 1
                }
                if let block = source.render(now: origin + .milliseconds(now)) {
                    #expect(block.pcm.count == 960)
                    rendered += 1
                }
            }
            #expect(rendered > 940)
            #expect(faster ? source.stretchedSamples > 3000 : source.stretchedSamples < -3000)
            #expect(source.pendingPackets < 12)
        }
        var burst = OpusJitterBuffer()
        for i in 0..<1000 { burst.insert(packet, timestamp: UInt32(i*960), sequence: UInt16(i), marker: false, now: origin) }
        #expect(burst.pendingPackets <= 19)
        #expect(burst.targetSamples <= 7680)
    }
}
