import Foundation
import Synchronization

/// Statistics are recorded only after SRTP/SRTCP or ICE authentication. An SSRC's
/// extended sequence number survives normal RTP wraparound and ICE migration.
package final class CallMediaMeasurements: Sendable {
    private struct Samples {
        var values: [Double] = []
        var next = 0
        mutating func add(_ value: Double) {
            if values.count < 256 { values.append(value) }
            else { values[next] = value; next = (next + 1) % 256 }
        }
        var median: Double? {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return nil }
            return (sorted[(sorted.count-1)/2] + sorted[sorted.count/2])/2
        }
    }

    private struct Incoming {
        let clock: UInt32
        var payloads = RTPStatsCounter()
        var lowest, highest, count: UInt64
        var arrival: ContinuousClock.Instant
        var timestamp: UInt32
        var jitter = 0.0
        var previousExpected: UInt64 = 0
        var previousReceived: UInt64 = 0
        var expected: UInt64 { highest - lowest + 1 }
        var loss: Int32 { Int32(clamping: max(-8_388_608, min(8_388_607, Int64(expected) - Int64(count)))) }
    }
    private struct Media {
        var jitterSend = Samples(), jitterReceive = Samples(), rtt = Samples()
        var previousReceived: UInt64 = 0, previousExpected: UInt64 = 0
        var lostSend = 0.0
        var expectedSend: UInt64 = 0
    }
    private struct State {
        var connection = Samples()
        var lastRTT: ContinuousClock.Instant?
        var streams: [UInt32: Incoming] = [:]
        var remoteReports: [UInt32: (lsr: UInt32, received: ContinuousClock.Instant)] = [:]
        var sentReports: [UInt32: [(lsr: UInt32, sent: ContinuousClock.Instant)]] = [:]
        var reportedThrough: [UInt32: UInt32] = [:]
        var audio = Media(), video = Media()
        var remoteStats: [UInt32: (jitter: Double, fraction: Double, rtt: Double?)] = [:]
        var telemetry = CallStreamStatistics()
        var relayStart: ContinuousClock.Instant?, relayDuration = Duration.zero
    }
    private let storage = Mutex(State())
    package init() {}

    /// The room may leave and rejoin with new SRTP keys, counters and SSRCs.
    /// Retain its accumulated telemetry while retiring the old RTCP association.
    package func beginSession() {
        storage.withLock { state in
            for stream in state.streams.values {
                if stream.clock == 48_000 {
                    state.audio.previousReceived += stream.count
                    state.audio.previousExpected += stream.expected
                } else {
                    state.video.previousReceived += stream.count
                    state.video.previousExpected += stream.expected
                }
            }
            state.streams.removeAll()
            state.remoteReports.removeAll()
            state.sentReports.removeAll()
            state.reportedThrough.removeAll()
            state.remoteStats.removeAll()
            state.telemetry.beginSession()
        }
    }

    func received(ssrc: UInt32, index: UInt64, timestamp: UInt32, clock: UInt32, bytes: Int = 0, at now: ContinuousClock.Instant = .now) {
        storage.withLock { state in
            guard var stream = state.streams[ssrc] else {
                guard state.streams.count < 2048 else { return }
                var first = Incoming(clock: clock, lowest: index, highest: index, count: 1, arrival: now, timestamp: timestamp)
                first.payloads.record(bytes)
                state.streams[ssrc] = first
                return
            }
            let arrivalDelta = stream.arrival.duration(to: now) / .milliseconds(1)
            let mediaDelta = Double(Int32(bitPattern: timestamp &- stream.timestamp)) * 1000 / Double(clock)
            stream.jitter += (abs(arrivalDelta - mediaDelta) - stream.jitter) / 16
            stream.arrival = now
            stream.timestamp = timestamp
            stream.highest = max(stream.highest, index)
            stream.lowest = min(stream.lowest, index)
            stream.count += 1
            stream.payloads.record(bytes)
            state.streams[ssrc] = stream
        }
    }

    func receivedSenderReport(_ report: RTCPSenderReport, at time: ContinuousClock.Instant = .now) {
        storage.withLock { state in
            guard state.remoteReports.count < 2048 || state.remoteReports[report.ssrc] != nil else { return }
            state.remoteReports[report.ssrc] = (UInt32(truncatingIfNeeded: report.ntp >> 16), time)
        }
    }

    func sentSenderReport(_ packet: Data, at time: ContinuousClock.Instant = .now) {
        guard let report = try? RTCPReport.compound(packet).senders.first else { return }
        storage.withLock { state in
            var history = state.sentReports[report.ssrc] ?? []
            if history.count == 16 { history.removeFirst() }
            history.append((UInt32(truncatingIfNeeded: report.ntp >> 16), time))
            state.sentReports[report.ssrc] = history
        }
    }

    func receptionReports(at now: ContinuousClock.Instant = .now) -> [RTCPReport] {
        storage.withLock { state in
            var reports: [RTCPReport] = []
            for id in state.streams.keys.sorted() {
                guard var stream = state.streams[id], stream.previousReceived != stream.count else { continue }
                let expected = stream.expected - stream.previousExpected
                let received = stream.count - stream.previousReceived
                let missing = expected - min(expected, received)
                let fraction = expected == 0 ? 0 : UInt8(clamping: missing * 256 / expected)
                let last = state.remoteReports[id]
                let delay = last.map { max(0, $0.received.duration(to: now) / .seconds(1)) } ?? 0
                reports.append(RTCPReport(stream: id, fractionLost: fraction, cumulativeLoss: stream.loss,
                    extendedHighestSequence: UInt32(truncatingIfNeeded: stream.highest),
                    jitter: UInt32(min(Double(UInt32.max), stream.jitter * Double(stream.clock) / 1000)),
                    lastSenderReport: last?.lsr ?? 0,
                    delaySinceLastReport: UInt32(min(Double(UInt32.max), delay * 65_536))))
                stream.previousExpected = stream.expected
                stream.previousReceived = stream.count
                state.streams[id] = stream
            }
            return reports
        }
    }

    func inboundStats(for id: UInt32) -> (lost: Int32, jitterSeconds: Double)? {
        storage.withLock { state in state.streams[id].map { ($0.loss, $0.jitter / 1000) } }
    }

    func report(_ report: RTCPReport, clock: UInt32, at now: ContinuousClock.Instant = .now) {
        storage.withLock { state in
            let path: WritableKeyPath<State, Media> = clock == 48_000 ? \.audio : \.video
            var rtt = state.remoteStats[report.stream]?.rtt
            if report.lastSenderReport != 0,
               let sent = state.sentReports[report.stream]?.last(where: { $0.lsr == report.lastSenderReport }) {
                let seconds = sent.sent.duration(to: now) / .seconds(1) - Double(report.delaySinceLastReport) / 65_536
                if (0...60).contains(seconds) { rtt = seconds * 1000; state[keyPath: path].rtt.add(seconds * 1000) }
            }
            let previous = state.reportedThrough.updateValue(report.extendedHighestSequence, forKey: report.stream)
            let advance = previous.map { Int32(bitPattern: report.extendedHighestSequence &- $0) }
            if let advance, advance <= 0 {
                state.reportedThrough[report.stream] = previous
                return
            }
            let jitter = Double(report.jitter) * 1000 / Double(clock)
            state.remoteStats[report.stream] = (jitter, Double(report.fractionLost)/256, rtt)
            state[keyPath: path].jitterSend.add(jitter)
            if let advance {
                state[keyPath: path].expectedSend += UInt64(advance)
                state[keyPath: path].lostSend += Double(advance) * Double(report.fractionLost)/256
            }
        }
    }

    func inbound(_ id: UInt32, video: Bool, frames: VideoFrameCounters? = nil, audio: OpusJitterStatistics? = nil) -> RTPObservation {
        storage.withLock { state in
            RTPObservation(ssrc: id, outgoing: false, video: video, count: state.streams[id]?.payloads ?? RTPStatsCounter(), frames: frames, audio: audio)
        }
    }

    func nominated(relayed: Bool, at now: ContinuousClock.Instant = .now) {
        storage.withLock { state in
            if relayed { state.relayStart = state.relayStart ?? now }
            else if let start = state.relayStart {
                state.relayDuration += start.duration(to: now)
                state.relayStart = nil
            }
        }
    }

    func remoteRTT(for id: UInt32) -> Double? { storage.withLock { $0.remoteStats[id]?.rtt } }

    func sample(rtt: (at: ContinuousClock.Instant, milliseconds: Double)?, media: [RTPObservation] = [], relayed: Bool? = nil, now: ContinuousClock.Instant = .now) {
        storage.withLock { state in
            let streams = state.streams, remote = state.remoteStats
            state.telemetry.add(media, rtt: rtt?.milliseconds, relayed: relayed, now: now) { source in
                if source.outgoing, let report = remote[source.ssrc] { return (nil,report.fraction,report.jitter,report.rtt) }
                if !source.outgoing, let stream = streams[source.ssrc] { return (stream.loss,nil,stream.jitter,nil) }
                return (nil,nil,nil,nil)
            }
            if let rtt, state.lastRTT != rtt.at { state.connection.add(rtt.milliseconds); state.lastRTT = rtt.at }
            for stream in state.streams.values where stream.count > 1 {
                if stream.clock == 48_000 { state.audio.jitterReceive.add(stream.jitter) }
                else { state.video.jitterReceive.add(stream.jitter) }
            }
        }
    }

    package struct MediaSummary: Sendable {
        package let jitterSend, jitterReceive, lossSend, lossReceive, rtt: Double?
    }
    package struct Summary: Sendable {
        package let connectionRTT: Double?
        package let audio, video: MediaSummary
        let sets: [StreamStatsSet], streams: StreamSummaries, relayMilliseconds: UInt64
    }

    package func summary() -> Summary {
        storage.withLock { state in
            func summary(_ media: Media, clock: UInt32) -> MediaSummary {
                var received = media.previousReceived, expected = media.previousExpected
                for stream in state.streams.values where stream.clock == clock {
                    received += stream.count
                    expected += stream.highest - stream.lowest + 1
                }
                return MediaSummary(jitterSend: media.jitterSend.median, jitterReceive: media.jitterReceive.median,
                                    lossSend: media.expectedSend > 0 ? media.lostSend / Double(media.expectedSend) : nil,
                                    lossReceive: expected > 0 ? Double(expected - min(received, expected)) / Double(expected) : nil,
                                    rtt: media.rtt.median)
            }
            return Summary(connectionRTT: state.connection.median, audio: summary(state.audio, clock: 48_000), video: summary(state.video, clock: 90_000), sets: state.telemetry.sets, streams: state.telemetry.summaries, relayMilliseconds: UInt64(max(0,(state.relayDuration + (state.relayStart?.duration(to: .now) ?? .zero)) / .milliseconds(1))))
        }
    }
}
