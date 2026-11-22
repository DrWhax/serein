import Foundation
import Testing
@testable import SwiftCalling

struct CallStreamStatisticsTests {
    @Test func intervalMetricsUseRingRTCWireFieldsAndUnits() throws {
        var telemetry = CallStreamStatistics()
        let origin = ContinuousClock.now
        var received = RTPObservation(ssrc: 2002, outgoing: false, video: false)
        var playout = OpusJitterStatistics()
        playout.emittedSamples = 960
        playout.cumulativeDelaySeconds = 48
        received.audio = playout
        received.count.record(80)
        telemetry.add([received], rtt: 12, relayed: false, now: origin + .seconds(1)) { _ in (0,nil,2,nil) }
        playout.emittedSamples += 960
        playout.cumulativeDelaySeconds += 96
        playout.concealedSamples = 480
        playout.silentConcealedSamples = 240
        playout.relativeArrivalDelaySeconds = 0.012
        playout.fecReceivedPackets = 1
        received.audio = playout
        for _ in 0..<3 { received.count.record(80) }
        telemetry.add([received], rtt: 18, relayed: true, now: origin + .seconds(2)) { _ in (1,nil,8,nil) }
        let latest = try #require(telemetry.sets.last)
        let audio = try #require(latest.audio_recv_stats.first)
        #expect(audio.ssrc == 2002 && audio.bitrate == 1920 && audio.packet_loss == 25)
        #expect(audio.jitter == 8 && audio.jitter_buffer_delay == 100 && latest.rtt_stun == [18] && latest.relayed == true)
        let stream = try #require(telemetry.summaries.audio_recv_stream_summaries.first)
        #expect(stream.jitter?.mean == 5 && stream.jitter?.std_dev == 3)
        #expect(stream.audio_relative_arrival_delay?.max_val == 4 && stream.audio_concealment_pct?.max_val == 25)
        #expect(stream.audio_redundant_packets == 1 && stream.audio_jitter_buffer_flushes == 0)
        // Independent field-number and wire-type check against call_summary.proto.
        let set = try fields(latest.protobuf)
        #expect(set[7]?.first == .float(18) && set[8]?.first == .integer(1))
        let rtp = try fields(try #require(set[2]?.first?.data))
        #expect(rtp[1]?.first == .integer(2002) && rtp[2]?.first == .float(1920) && rtp[6]?.first == .float(100))
        let groups = try fields(telemetry.summaries.protobuf)
        let summary = try fields(try #require(groups[6]?.first?.data))
        let distribution = try fields(try #require(summary[3]?.first?.data))
        #expect(distribution[1]?.first == .float(5) && distribution[2]?.first == .float(3))
        #expect(distribution[5]?.first == .integer(2))
    }

    @Test func directBandwidthRequiresActiveVideoAndObservedRecovery() {
        var callbacks = DirectVideoBandwidthNotifications()
        let now = ContinuousClock.now
        #expect(callbacks.poll(estimate: 15_000, sending: false, at: now) == nil)
        callbacks.waitForAcceptance(at: now)
        #expect(callbacks.poll(estimate: 35_000, sending: true, at: now + .seconds(2)) == nil)
        #expect(callbacks.poll(estimate: 59_999, sending: true, at: now + .seconds(11)) == false)
        #expect(callbacks.poll(estimate: 80_000, sending: true, at: now + .seconds(16)) == nil)
        #expect(callbacks.poll(estimate: 70_001, sending: true, at: now + .seconds(17)) == true)
        #expect(callbacks.poll(estimate: 25_000, sending: true, at: now + .seconds(19)) == nil)
    }

    @Test func decodedSpatialLayersCountOnceAndFreezesUsePresentationTimes() {
        var frames = VideoFrameCounters()
        let origin = ContinuousClock.now
        for i in 0..<8 {
            let stamp = UInt32(i * 3000), at = origin + .milliseconds(i * 33)
            frames.receive(stamp)
            frames.receive(stamp)
            frames.complete(stamp, codec: 9, width: 320, height: 180, now: at)
            frames.complete(stamp, codec: 9, width: 640, height: 360, now: at)
            frames.render(stamp, now: at)
        }
        frames.render(99_000, now: origin + .seconds(1))
        #expect(frames.received == 8 && frames.completed == 8 && frames.rendered == 9)
        #expect(frames.width == 640 && frames.codec == 9 && frames.freezes == 1)
        #expect(abs(frames.freezeDuration - 0.769) < 0.0001)
    }

    private enum Field: Equatable {
        case integer(UInt64), float(Float), bytes(Data)
        var data: Data? { if case .bytes(let bytes) = self { bytes } else { nil } }
    }

    private func fields(_ data: Data) throws -> [Int:[Field]] {
        var reader = try CallingProtoReader(data)
        var result = [Int:[Field]]()
        while let tag = try reader.next() {
            switch tag.wire {
            case 0: result[tag.number,default: []].append(.integer(try reader.integer(tag)))
            case 2: result[tag.number,default: []].append(.bytes(Data(try reader.bytes(tag))))
            case 5: result[tag.number,default: []].append(.float(Float(bitPattern: try reader.fixed32(tag))))
            default: throw CallingWireError.malformed
            }
        }
        return result
    }
}
