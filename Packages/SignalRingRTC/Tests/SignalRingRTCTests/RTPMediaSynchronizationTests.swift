import Foundation
import Testing
import VideoVP9
@testable import SwiftCalling

struct RTPMediaSynchronizationTests {
    @Test func compoundReportsPreserveSenderAndReceptionClocks() throws {
        let bytes = Data([0x80,200,0,6, 0,0,0,32, 0xff,0xff,0xff,0xff, 0x80,0,0,0,
                          0xff,0xff,0xf0,0, 0,0,0,6, 0,0,2,0, 0x80,201,0,1, 0,0,0,99])
        let compound = try RTCPReport.compound(bytes)
        let sender = try #require(compound.senders.first)
        #expect(sender.ssrc == 32 && sender.rtp == 0xfffff000 && sender.ntp == 0xffffffff80000000)
        #expect(compound.receivers.isEmpty)
        #expect(throws: (any Error).self) { try RTCPReport.compound(bytes.dropLast()) }
    }

    @Test func videoTracksRenderedAudioAcrossClockRolloverAndSkew() {
        let sync = RTPMediaSynchronization(), t = ContinuousClock.now
        let audio: UInt32 = 0xfffff000, video: UInt32 = 0xffffe000
        let ntp: UInt64 = 0xffffffff80000000
        sync.observe(.init(ssrc: 32, ntp: ntp, rtp: audio), audio: true, now: t)
        sync.observe(.init(ssrc: 34, ntp: ntp, rtp: video), audio: false, now: t)
        // Both NTP seconds and each RTP counter wrap. The video oscillator runs 0.1% fast.
        sync.observe(.init(ssrc: 34, ntp: ntp &+ (1 << 32), rtp: video &+ 90_090), audio: false, now: t + .seconds(1))
        sync.played(audio &+ 48000, ssrc: 32, at: t + .milliseconds(1060))
        let due = sync.deadline(for: video &+ 90_090 &+ 3600, ssrc: 34, now: t + .seconds(1))
        #expect(abs((t + .milliseconds(1100)).duration(to: due) / .milliseconds(1)) < 0.2)
        #expect(sync.deadline(for: video &+ 180000, ssrc: 34, now: t + .seconds(1)) == t + .milliseconds(1200))
        #expect(sync.deadline(for: video, ssrc: 34, now: t + .seconds(3)) == t + .seconds(3))
        sync.audioMuted()
        #expect(sync.deadline(for: video, ssrc: 34, now: t) == t)
        // A remote clock correction during a long suspension starts a new correlation.
        let restart = t + .seconds(40), earlier = ntp &- (100 << 32)
        sync.observe(.init(ssrc: 32, ntp: earlier, rtp: 10), audio: true, now: restart)
        sync.observe(.init(ssrc: 34, ntp: earlier, rtp: 20), audio: false, now: restart)
        sync.played(10, ssrc: 32, at: restart + .milliseconds(60))
        #expect(sync.deadline(for: 20, ssrc: 34, now: restart) == restart + .milliseconds(60))
    }

    @Test func decodedVideoWaitsForScheduledPCM() async throws {
        let sink = DirectCallVideo()
        sink.startReceiving {}
        defer { sink.close() }
        let uv = [UInt8](repeating: 128, count: 64)
        var encoder = VP9VideoEncoder()
        var image = [UInt8](repeating: 128, count: 256)
        let first = encoder.encode(width: 16, height: 16, y: image, u: uv, v: uv)
        let firstBytes = try #require(first)
        sink.decode(.init(bytes: Data(firstBytes), spatialLayer: 0, rotation: 0, timestamp: 0, start: 0, end: 0), ssrc: 34)
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        func receive(until timeout: ContinuousClock.Instant) async throws -> ContinuousClock.Instant? {
            while ContinuousClock.now < timeout {
                if sink.receive(maxWidth: 16, maxHeight: 16, into: &pixels) != nil { return .now }
                try await Task.sleep(for: .milliseconds(2))
            }
            return nil
        }
        let warm = try await receive(until: .now + .seconds(2))
        try #require(warm != nil)
        image[0] = 192
        let second = encoder.encode(width: 16, height: 16, y: image, u: uv, v: uv)
        let secondBytes = try #require(second)
        let now = ContinuousClock.now, playout = now + .milliseconds(130)
        sink.synchronization.observe(.init(ssrc: 32, ntp: 1 << 32, rtp: 900), audio: true, now: now)
        sink.synchronization.observe(.init(ssrc: 34, ntp: 1 << 32, rtp: 1800), audio: false, now: now)
        sink.synchronization.played(900, ssrc: 32, at: playout)
        sink.decode(.init(bytes: Data(secondBytes), spatialLayer: 0, rotation: 0, timestamp: 1800, start: 1, end: 1), ssrc: 34)
        let firstVisible = try await receive(until: .now + .seconds(2))
        let visible = try #require(firstVisible)
        #expect(visible >= playout)
    }

    @Test func outgoingReportExtrapolatesFromCaptureAndUsesOneCNAME() throws {
        var clock = RTPOutboundClock()
        let t = ContinuousClock.now, stamp = UInt32.max - 8
        clock.record(bytes: 70, timestamp: stamp, captured: t)
        clock.record(bytes: 30, timestamp: stamp, captured: t + .milliseconds(6))
        let result = clock.report(ssrc: 1003, rate: 90_000, cname: "rtc", date: Date(timeIntervalSince1970: 0.25),
                                  now: t + .milliseconds(100))
        let bytes = try #require(result)
        let compound = try RTCPReport.compound(bytes)
        let report = try #require(compound.senders.first)
        #expect(report.ssrc == 1003 && report.rtp == stamp &+ 9000)
        #expect(report.ntp == UInt64(2208988800) << 32 | (1 << 30))
        #expect(Array(bytes[20..<28]) == [0, 0, 0, 2, 0, 0, 0, 100])
        #expect(Array(bytes[28...]) == [0x81, 202, 0, 3, 0, 0, 3, 235, 1, 3, 114, 116, 99, 0, 0, 0])
        #expect(clock.report(ssrc: 1003, rate: 90_000, cname: "rtc", now: t + .seconds(3)) == nil)
    }

    @Test func groupMixerUsesEachMembersOwnRTPClock() {
        let a = RTPMediaSynchronization(), b = RTPMediaSynchronization(), t = ContinuousClock.now
        for (sync, audio, video) in [(a, UInt32(32), UInt32(34)), (b, UInt32(48), UInt32(50))] {
            sync.observe(.init(ssrc: audio, ntp: 1 << 32, rtp: 1000), audio: true, now: t)
            sync.observe(.init(ssrc: video, ntp: 1 << 32, rtp: 4000), audio: false, now: t)
        }
        a.played(1000, ssrc: 32, at: t + .milliseconds(70))
        #expect(a.deadline(for: 4000, ssrc: 34, now: t) == t + .milliseconds(70))
        #expect(b.deadline(for: 4000, ssrc: 50, now: t) == t)
    }

    @Test func receptionReportsMeasureIntervalLossAcrossWrapAndLatePackets() throws {
        let stats = CallMediaMeasurements(), t = ContinuousClock.now
        let stream: UInt32 = 1002, cname = "serein"
        let sr = RTCPSenderReport(ssrc: stream, ntp: 0x12345678aabbccdd, rtp: 0)
        stats.receivedSenderReport(sr, at: t)
        for (offset, sequence) in [65534, 65535, 65537, 65538].enumerated() {
            stats.received(ssrc: stream, index: UInt64(sequence), timestamp: UInt32((sequence - 65534) * 960),
                           clock: 48_000, at: t + .milliseconds(20 * offset))
        }
        let blocks = stats.receptionReports(at: t + .milliseconds(250))
        let packet = try #require(RTCPReport.datagrams(blocks, sender: 2002, cname: cname).first)
        let decoded = try #require(RTCPReport.parse(packet).first)
        #expect(decoded.extendedHighestSequence == 65538 && decoded.fractionLost == 51 && decoded.cumulativeLoss == 1)
        #expect(decoded.lastSenderReport == 0x5678aabb && decoded.delaySinceLastReport == 16384)
        #expect(decoded.jitter > 0 && stats.receptionReports().isEmpty)
        stats.received(ssrc: stream, index: 65536, timestamp: 1920, clock: 48_000, at: t + .milliseconds(300))
        let late = try #require(stats.receptionReports().first)
        #expect(late.fractionLost == 0 && late.cumulativeLoss == 0)
        let split = RTCPReport.datagrams(Array(repeating: decoded, count: 32), sender: 2002, cname: cname)
        #expect(try split.map { try RTCPReport.parse($0).count } == [31, 1])
    }
}
