import Foundation
import Synchronization

/// RFC 3550 sender reports correlate each RTP clock with the sender's NTP clock.
/// Only subtract NTP values from the same sender. No wall-clock synchronization with the peer is needed.
struct RTCPSenderReport: Sendable {
    let ssrc: UInt32
    let ntp: UInt64
    let rtp: UInt32

    static func seconds(_ lhs: UInt64, since rhs: UInt64) -> Double {
        Double(Int64(bitPattern: lhs &- rhs)) / 4_294_967_296
    }
}

final class RTPMediaSynchronization: Sendable {
    private struct Clock {
        var report: RTCPSenderReport
        var received: ContinuousClock.Instant
        var secondsPerTick: Double

        mutating func update(_ next: RTCPSenderReport, frequency: Double, now: ContinuousClock.Instant) {
            let seconds = RTCPSenderReport.seconds(next.ntp, since: report.ntp)
            let ticks = Int32(bitPattern: next.rtp &- report.rtp)
            if received.duration(to: now) < .seconds(30) {
                guard seconds > 0, ticks > 0 else { return }
                let slope = seconds / Double(ticks)
                // Reject discontinuous or bogus reports without poisoning the last valid correlation.
                guard abs(slope * frequency - 1) < 0.02 else { return }
                if seconds >= 0.2 { secondsPerTick = 0.7 * secondsPerTick + 0.3 * slope }
            } else { secondsPerTick = 1 / frequency }
            report = next
            received = now
        }

        func offset(_ timestamp: UInt32) -> Double {
            Double(Int32(bitPattern: timestamp &- report.rtp)) * secondsPerTick
        }
    }
    private struct State {
        var streams: [UInt32: Clock] = [:]
        var audio: (ssrc: UInt32, stamp: UInt32, at: ContinuousClock.Instant)?
    }
    private let state = Mutex(State())

    func observe(_ report: RTCPSenderReport, audio: Bool, now: ContinuousClock.Instant = .now) {
        guard report.ntp != 0 else { return }
        let rate = audio ? 48_000.0 : 90_000.0
        state.withLock { s in
            if s.streams[report.ssrc] != nil { s.streams[report.ssrc]?.update(report, frequency: rate, now: now) }
            else if s.streams.count < 4 {
                s.streams[report.ssrc] = Clock(report: report, received: now, secondsPerTick: 1 / rate)
            }
        }
    }

    func played(_ timestamp: UInt32, ssrc: UInt32, at time: ContinuousClock.Instant) {
        state.withLock { $0.audio = (ssrc, timestamp, time) }
    }

    func audioMuted() { state.withLock { $0.audio = nil } }

    func deadline(for timestamp: UInt32, ssrc: UInt32, now: ContinuousClock.Instant = .now) -> ContinuousClock.Instant {
        state.withLock { s in
            guard let output = s.audio, output.at.duration(to: now) < .seconds(1),
                  let sound = s.streams[output.ssrc], let picture = s.streams[ssrc],
                  sound.received.duration(to: now) < .seconds(30),
                  picture.received.duration(to: now) < .seconds(30) else { return now }
            let audioOffset = sound.offset(output.stamp), videoOffset = picture.offset(timestamp)
            guard abs(audioOffset) < 35, abs(videoOffset) < 35 else { return now }
            let difference = RTCPSenderReport.seconds(picture.report.ntp, since: sound.report.ntp) + videoOffset - audioOffset
            guard abs(difference) < 2 else { return now }
            let when = output.at + .seconds(difference)
            return max(now, min(now + .milliseconds(200), when))
        }
    }
}

/// Extrapolate a successfully transmitted capture timestamp at the instant of an RTCP report.
/// Use one CNAME per call, shared by its related audio and video streams (RFC 3550 §6.5.1).
struct RTPOutboundClock {
    private var anchor: (stamp: UInt32, captured: ContinuousClock.Instant)?
    private(set) var counts = RTPStatsCounter()

    mutating func record(bytes: Int, timestamp: UInt32, captured: ContinuousClock.Instant) {
        counts.record(bytes)
        if anchor?.stamp != timestamp { anchor = (timestamp, captured) }
    }

    func report(ssrc: UInt32, rate: Double, cname: String, date: Date = .now,
                now: ContinuousClock.Instant = .now) -> Data? {
        guard let anchor else { return nil }
        let elapsed = anchor.captured.duration(to: now) / .seconds(1)
        let ntp = date.timeIntervalSince1970 + 2_208_988_800
        guard (0...2).contains(elapsed), (1...192_000).contains(rate), ntp.isFinite, (0...1e11).contains(ntp),
              (1...255).contains(cname.utf8.count) else { return nil }
        let whole = ntp.rounded(.down)
        var bytes = Data([0x80, 200, 0, 6])
        func word(_ value: UInt32) {
            for shift in [24, 16, 8, 0] { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        word(ssrc)
        word(UInt32(truncatingIfNeeded: Int64(whole)))
        word(UInt32((ntp - whole) * 4_294_967_296))
        word(anchor.stamp &+ UInt32(elapsed * rate))
        word(UInt32(truncatingIfNeeded: counts.packets))
        word(UInt32(truncatingIfNeeded: counts.bytes))
        RTCPReport.appendSourceDescription(to: &bytes, sender: ssrc, cname: cname)
        return bytes
    }
}
