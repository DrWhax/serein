import Foundation
@testable import SwiftCalling
import Testing

@Suite struct GroupMediaQualityTests {
    @Test func countsPicturesSkippedAcrossClockWrapAndSpatialLayers() {
        var frames = VideoFrameCounters()
        for stamp: UInt32 in [.max-1, .max, .max, 0, 1, 1] { frames.receive(stamp) }
        frames.render(.max-1, now: .now)
        frames.render(1, now: .now)
        #expect(frames.received == 4 && frames.rendered == 2 && frames.dropped == 2)
    }

    @Test func speechSuggestionsFollowCapturedSpeechAndSilence() {
        var speech = GroupSpeechDetector()
        let start = ContinuousClock.now
        #expect((speech.poll(peak: 2000, unmuted: true, at: start)) == nil)
        #expect((speech.poll(peak: 2000, unmuted: true, at: start + .seconds(5))) == 1)
        #expect((speech.poll(peak: 100, unmuted: true, at: start + .seconds(6))) == nil)
        #expect((speech.poll(peak: 2000, unmuted: false, at: start + .seconds(9))) == 0)
        #expect((speech.poll(peak: 2000, unmuted: false, at: start + .seconds(16))) == nil)
    }

    @Test func transportFeedbackControlsSenderBudgetAndRecovery() throws {
        let sent = TransportPacketNumbers()
        var rate = GroupSendRate(), arrivals = TransportFeedback()
        let start = ContinuousClock.now
        for second in 0..<13 {
            let low = second < 2
            let origin = start + .seconds(second * 2)
            for i in 0..<50 {
                let bytes = sent.next(bytes: 120, at: origin + .milliseconds(20 * i))
                let number = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
                if !low || i % 4 != 1 {
                    arrivals.observe(number, at: origin + .milliseconds((low ? 32 : 20) * i))
                }
            }
            let feedback = arrivals.packet(sender: 202)
            let packet = try #require(feedback)
            try rate.receive(packet, sent: sent)
            let now = origin + .seconds(2)
            let estimate = rate.update(limit: 300_000, now: now)
            let value = try #require(estimate)
            switch second {
            case 0:
                #expect(value < 70_000)
                #expect((rate.bandwidthEvent(now: now)) == false)
            case 1:
                #expect((rate.bandwidthEvent(now: now)) == nil)
            case 12:
                #expect(value > 80_000)
                #expect((rate.bandwidthEvent(now: now)) == true)
                #expect((rate.bandwidthEvent(now: now)) == nil)
            default: break
            }
        }
    }
}
