import Foundation
import Synchronization

/// The fixed V4 audio streams from RingRTC's Rust_sessionDescriptionFromV4.
enum DirectCallRole: CaseIterable, Sendable {
    case caller, callee
    var audioSSRC: UInt32 { self == .caller ? 1002 : 2002 }
}

/// Packetizes already encoded Opus. The RTP timestamp counts samples on a 48 kHz clock,
/// including when a packet contains several frames or uses another internal sample rate.
final class DirectOpusSender: Sendable {
    static let payloadType: UInt8 = 102
    let sender: SRTPSender
    private let timestamp: Mutex<UInt32>
    private let sealedPayload = Mutex<(UInt32, Int)?>(nil)

    init(keys: SRTPKeys, role: DirectCallRole, sequence: UInt16 = .random(in: 0...0x7fff),
         timestamp: UInt32 = .random(in: .min ... .max), transportNumbers: TransportPacketNumbers? = nil) {
        sender = SRTPSender(keys: keys, ssrc: role.audioSSRC, startingAt: sequence, transportNumbers: transportNumbers)
        self.timestamp = Mutex(timestamp)
    }

    func seal(_ encoded: Data, talkspurt: Bool = false, skippedSamples: UInt32 = 0) throws -> Data {
        let packet = try OpusPacket(encoded)
        return try timestamp.withLock { next in
            let start = next &+ skippedSamples
            let sealed = try sender.seal(encoded, type: Self.payloadType, timestamp: start, marker: talkspurt)
            sealedPayload.withLock { $0 = (start, encoded.count) }
            next = start &+ UInt32(packet.sampleCount)
            return sealed
        }
    }
    func didSend(captured: ContinuousClock.Instant) {
        if let (stamp, length) = sealedPayload.withLock({ $0 }) {
            sender.didSend(payloadBytes: length, timestamp: stamp, captured: captured)
        }
    }

}

struct DirectOpusReceiver {
    private let receiver: SRTPReceiver

    init(keys: SRTPKeys, remoteRole: DirectCallRole, measurements: CallMediaMeasurements? = nil, arrivals: TransportArrivals? = nil) {
        receiver = SRTPReceiver(keys: keys, ssrc: remoteRole.audioSSRC, measurements: measurements, arrivals: arrivals)
    }

    func open(_ data: Data) throws -> (timestamp: UInt32, sequence: UInt16, marker: Bool, packet: OpusPacket) {
        let media = try receiver.open(data)
        guard media.type == DirectOpusSender.payloadType else { throw SRTPError.invalidPacket }
        return try (media.timestamp, media.sequence, media.marker, OpusPacket(media.bytes))
    }
}

/// One sending leg of a V4 call. Speech enters as 48 kHz mono PCM and leaves as SRTP.
struct DirectSpeechSender {
    private var encoder = CallOpusEncoder()
    let transport: DirectOpusSender

    init(transport: DirectOpusSender) { self.transport = transport }

    mutating func setDRED(_ configuration: DREDConfiguration?) { encoder.setDRED(configuration) }

    mutating func setLowDataMode(_ low: Bool) { encoder.setLowDataMode(low) }

    mutating func setPacketLoss(_ fraction: UInt8) { encoder.setPacketLoss(fraction) }

    mutating func beginTalkspurt() { encoder.beginTalkspurt() }

    mutating func seal(_ samples: [Int16], talkspurt: Bool = false, skippedSamples: UInt32 = 0) throws -> Data? {
        guard let frame = try encoder.transmission(samples) else { return nil }
        return try transport.seal(frame.payload, talkspurt: talkspurt || frame.marker, skippedSamples: skippedSamples &+ frame.skipped)
    }
}

struct DirectSpeechReceiver {
    private let transport: DirectOpusReceiver
    private var playout = OpusJitterBuffer()

    init(keys: SRTPKeys, remoteRole: DirectCallRole, measurements: CallMediaMeasurements? = nil, arrivals: TransportArrivals? = nil) {
        transport = DirectOpusReceiver(keys: keys, remoteRole: remoteRole, measurements: measurements, arrivals: arrivals)
    }

    mutating func setDRED(_ configuration: DREDConfiguration?) { playout.setDRED(configuration) }

    mutating func insert(_ data: Data) throws {
        let media = try transport.open(data)
        playout.insert(media.packet, timestamp: media.timestamp, sequence: media.sequence, marker: media.marker)
    }

    var active: Bool { playout.active }
    var statistics: OpusJitterStatistics { playout.statistics }

    mutating func render() -> OpusJitterBuffer.Block? { playout.render() }
}
