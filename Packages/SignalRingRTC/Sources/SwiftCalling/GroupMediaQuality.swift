import CodecCore
import Foundation

struct RTPStatsCounter: Sendable {
    private(set) var packets: UInt64 = 0
    private(set) var bytes: UInt64 = 0

    mutating func record(_ payloadBytes: Int) {
        packets &+= 1
        bytes &+= UInt64(payloadBytes)
    }
}

struct GroupSpeechDetector {
    private var started: ContinuousClock.Instant?
    private var silent: ContinuousClock.Instant?
    private var lastEvent: Int?

    /// Native RingRTC polls peak PCM every 200 ms. The app decides whether
    /// a lower-hand suggestion is relevant to the current hand state.
    mutating func poll(peak: UInt16, unmuted: Bool, at now: ContinuousClock.Instant) -> Int? {
        if unmuted && peak > 1000 {
            started = started ?? now
            silent = nil
        } else {
            silent = silent ?? now
            if let silent, silent.duration(to: now) >= .seconds(3) { started = nil }
        }
        let active = started.map { $0.duration(to: silent ?? now) } ?? .zero
        let event: Int?
        if active >= .seconds(5) { event = 1 }
        else if active <= .zero, lastEvent != nil { event = 0 }
        else { event = nil }
        guard let event, event != lastEvent else { return nil }
        lastEvent = event
        return event
    }
}

struct DirectVideoBandwidthNotifications {
    private var nextPoll = ContinuousClock.now
    private var firstCheck = ContinuousClock.now
    private var lowSince: ContinuousClock.Instant?
    private var recovered = false

    mutating func waitForAcceptance(at now: ContinuousClock.Instant = .now) { firstCheck = now + .seconds(10) }

    mutating func poll(estimate: UInt64?, sending: Bool, at now: ContinuousClock.Instant) -> Bool? {
        guard !recovered, now >= nextPoll else { return nil }
        nextPoll = now + .seconds(1)
        guard let estimate else { return nil }
        if let lowSince {
            if estimate > 70_000, lowSince.duration(to: now) >= .seconds(6) { recovered = true; return true }
        } else if sending && now >= firstCheck && estimate < 60_000 {
            lowSince = now
            return false
        }
        return nil
    }
}

/// Matches the SFU's transport-wide feedback to the local association's sent
/// packets. A quiet microphone or static screen cannot alone indicate congestion.
struct GroupSendRate {
    private var started = ContinuousClock.now
    private var packets = 0, missing = 0, bytes = 0
    private var minDeparture: ContinuousClock.Instant?
    private var maxDeparture: ContinuousClock.Instant?
    private var firstArrival: Int64?, lastArrival: Int64?
    private(set) var estimate: UInt64?
    private var lowSince: ContinuousClock.Instant?
    private var reportedRecovery = false

    private struct Sample {
        let sequence: UInt16
        let arrival: Int64?
    }

    @discardableResult
    mutating func receive(_ compound: Data, sent: TransportPacketNumbers) throws -> Bool {
        var acknowledged = false
        var cursor = ByteCursor(Array(compound))
        while !cursor.isAtEnd {
            let flags = try cursor.u8(), type = try cursor.u8()
            guard flags >> 6 == 2 else { throw SRTPError.invalidPacket }
            let words = Int(try cursor.u16be())
            var body = try cursor.bytes(words * 4).cursor()
            guard type == 205, flags & 31 == 15 else { continue }
            try body.skip(8)
            let first = try body.u16be(), count = Int(try body.u16be())
            var arrival = Int64(try body.u24be()) * 256
            try body.skip(1)
            guard count <= 4096 else { throw SRTPError.invalidPacket }
            var statuses: [UInt16] = []
            while statuses.count < count {
                let chunk = try body.u16be()
                if chunk & 0x8000 == 0 {
                    let run = Int(chunk & 0x1fff)
                    guard run > 0, run <= count - statuses.count else { throw SRTPError.invalidPacket }
                    statuses.append(contentsOf: repeatElement((chunk >> 13) & 3, count: run))
                } else {
                    let bits = chunk & 0x4000 == 0 ? 1 : 2
                    for shift in stride(from: 14-bits, through: 0, by: -bits) where statuses.count < count {
                        statuses.append((chunk >> shift) & (bits == 1 ? 1 : 3))
                    }
                }
            }
            var samples: [Sample] = []
            for (index, status) in statuses.enumerated() {
                switch status {
                case 0: break
                case 1: arrival += Int64(try body.u8())
                case 2: arrival += Int64(Int16(bitPattern: try body.u16be()))
                default: throw SRTPError.invalidPacket
                }
                samples.append(.init(sequence: first &+ UInt16(index), arrival: status == 0 ? nil : arrival))
            }
            for sample in samples {
                guard let packet = sent.take(sample.sequence) else { continue }
                packets += 1
                guard let arrival = sample.arrival else { missing += 1; continue }
                acknowledged = true
                bytes += packet.bytes
                minDeparture = min(minDeparture ?? packet.time, packet.time)
                maxDeparture = max(maxDeparture ?? packet.time, packet.time)
                // A 24-bit reference wraps every 12.4 days. Restart the sample
                // window at the boundary instead of treating it as a queue delay.
                if let lastArrival, abs(arrival - lastArrival) > (1 << 30) {
                    firstArrival = arrival
                    self.lastArrival = arrival
                }
                firstArrival = min(firstArrival ?? arrival, arrival)
                lastArrival = max(lastArrival ?? arrival, arrival)
            }
        }
        return acknowledged
    }

    mutating func update(limit: UInt64, now: ContinuousClock.Instant) -> UInt64? {
        guard started.duration(to: now) >= .seconds(1) else { return nil }
        defer {
            started = now
            packets = 0
            missing = 0
            bytes = 0
            firstArrival = nil
            lastArrival = nil
            minDeparture = nil
            maxDeparture = nil
        }
        guard packets >= 5, let firstArrival, let lastArrival, let minDeparture, let maxDeparture else { return nil }
        let duration = Double(lastArrival-firstArrival) / 4000
        guard duration >= 0.1 else { return nil }
        let delivered = UInt64(Double(bytes * 8) / duration)
        let departureSpan = minDeparture.duration(to: maxDeparture) / .seconds(1)
        let queued = duration - departureSpan
        let previous = min(estimate ?? limit, limit)
        let next: UInt64
        if missing * 10 >= packets || queued > max(0.08, departureSpan * 0.15) {
            next = max(30_000, min(previous * 85/100, delivered * 95/100))
        } else if missing * 50 < packets, queued < 0.05 {
            // Probe gradually from a constrained budget even for an application-limited stream.
            next = min(limit, max(previous + max(8000, previous/10), delivered))
        } else {
            next = previous
        }
        estimate = next
        return next
    }

    mutating func bandwidthEvent(now: ContinuousClock.Instant) -> Bool? {
        guard let estimate, !reportedRecovery else { return nil }
        if let lowSince {
            if estimate > 80_000, lowSince.duration(to: now) >= .seconds(6) {
                reportedRecovery = true
                return true
            }
        } else if estimate < 70_000 {
            lowSince = now
            return false
        }
        return nil
    }
}

struct GroupStatsRecord: Encodable {
    let id, type: String
    let timestamp: Double
    var kind: String?
    var ssrc: UInt32?
    var packetsSent, bytesSent, packetsReceived, bytesReceived: UInt64?
    var retransmittedPacketsSent, retransmittedBytesSent, retransmittedPacketsReceived, retransmittedBytesReceived: UInt64?
    var packetsLost: Int32?
    var fractionLost, jitter: Double?
    var availableOutgoingBitrate: UInt64?
    var currentRoundTripTime: Double?
    var state: String?
    var nominated: Bool?
    var codecId, transportId, localId, remoteId, selectedCandidatePairId, remoteCandidateId, localCandidateId: String?
    var mimeType, candidateType, address, decoderImplementation, encoderImplementation: String?
    var `protocol`: String?
    var payloadType, clockRate, channels, port, frameWidth, frameHeight: Int?
    var framesReceived, framesDecoded, framesRendered, framesEncoded, framesSent, framesDropped, freezeCount: UInt64?
    var framesPerSecond, totalFreezesDuration, totalDecodeTime, roundTripTime: Double?
    var jitterBufferEmittedCount, concealedSamples, insertedSamplesForDeceleration, removedSamplesForAcceleration: UInt64?
    var nackCount, pliCount, firCount: UInt64?
    var packetsDiscarded, fecPacketsReceived, silentConcealedSamples: UInt64?
    var jitterBufferDelay, jitterBufferTargetDelay, audioLevel, totalAudioEnergy, totalSamplesDuration: Double?
    var sereinDredRecoveredSamples: UInt64?

    static func codec(_ payload: Int, timestamp: Double) -> Self {
        let audio = payload == Int(DirectOpusSender.payloadType)
        var row = Self(id: "codec-\(payload)", type: "codec", timestamp: timestamp)
        row.payloadType = payload
        row.clockRate = audio ? 48_000 : 90_000
        row.mimeType = audio ? "audio/opus" : (payload == Int(VP9Assembly.payloadType) ? "video/VP9" : "video/VP8")
        row.channels = audio ? 2 : nil
        row.transportId = "sfu-transport"
        return row
    }

    mutating func media(_ source: RTPObservation) {
        transportId = "sfu-transport"
        if !source.video { codecId = "codec-\(DirectOpusSender.payloadType)" }
        if let video = source.frames {
            if let codec = video.codec {
                let implementation = "Swift VP\(codec)"
                codecId = "codec-\(codec == 9 ? VP9Assembly.payloadType : DirectVideoStream.vp8)"
                if source.outgoing { encoderImplementation = implementation }
                else { decoderImplementation = implementation }
            }
            frameWidth = video.width
            frameHeight = video.height
            framesPerSecond = video.fps(at: .now)
            if source.outgoing {
                framesSent = video.completed
                framesEncoded = video.encoded
            } else {
                framesReceived = video.received
                framesDecoded = video.completed
                framesRendered = video.rendered
                framesDropped = video.dropped
                freezeCount = video.freezes
                totalFreezesDuration = video.freezeDuration
                totalDecodeTime = video.decodeSeconds
            }
        }
        if let audio = source.audio {
            jitterBufferEmittedCount = audio.emittedSamples
            jitterBufferDelay = audio.cumulativeDelaySeconds
            jitterBufferTargetDelay = audio.cumulativeTargetDelay
            audioLevel = audio.audioLevel
            totalAudioEnergy = audio.totalAudioEnergy
            totalSamplesDuration = Double(audio.emittedSamples) / 48_000
            concealedSamples = audio.concealedSamples
            insertedSamplesForDeceleration = audio.insertedSamples
            removedSamplesForAcceleration = audio.removedSamples
            packetsDiscarded = audio.latePackets
            sereinDredRecoveredSamples = audio.dredRecoveredSamples
            fecPacketsReceived = audio.fecReceivedPackets
            silentConcealedSamples = audio.silentConcealedSamples
        }
    }


    static func rtp(ssrc: UInt32, kind: String, outgoing: Bool, count: RTPStatsCounter, timestamp: Double) -> Self {
        let direction = outgoing ? "outbound-rtp" : "inbound-rtp"
        var record = Self(id: "\(direction)-\(ssrc)", type: direction, timestamp: timestamp)
        record.kind = kind
        record.ssrc = ssrc
        if outgoing { record.packetsSent = count.packets; record.bytesSent = count.bytes }
        else { record.packetsReceived = count.packets; record.bytesReceived = count.bytes }
        return record
    }
}
