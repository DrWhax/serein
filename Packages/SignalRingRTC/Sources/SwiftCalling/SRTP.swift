import CodecCore
import CryptoKit
import Foundation
import Synchronization

enum SRTPError: Error { case invalidPacket, replay, exhausted }

struct SRTPKeys: Sendable {
    let key: SymmetricKey
    let salt: [UInt8]

    func nonce(ssrc: UInt32, index: UInt64) throws -> AES.GCM.Nonce {
        guard salt.count == 12, index < 1 << 48 else { throw SRTPError.exhausted }
        var iv = salt
        for i in 0..<4 { iv[5-i] ^= UInt8(truncatingIfNeeded: ssrc >> (8*i)) }
        for i in 0..<6 { iv[11-i] ^= UInt8(truncatingIfNeeded: index >> (8*i)) }
        return try AES.GCM.Nonce(data: iv)
    }
}

/// One sending SSRC owns its packet counter for the lifetime of these session keys.
final class SRTPSender: Sendable {
    let keys: SRTPKeys
    let ssrc: UInt32
    private let sent = Mutex(RTPOutboundClock())
    var stats: RTPStatsCounter { sent.withLock { $0.counts } }
    func didSend(payloadBytes: Int, timestamp: UInt32, captured: ContinuousClock.Instant) {
        sent.withLock { $0.record(bytes: payloadBytes, timestamp: timestamp, captured: captured) }
    }
    func senderReport(rate: Double, cname: String) -> Data? {
        sent.withLock { $0.report(ssrc: ssrc, rate: rate, cname: cname) }
    }
    private let nextIndex: Mutex<UInt64>
    private let transportNumbers: TransportPacketNumbers?

    init(keys: SRTPKeys, ssrc: UInt32, startingAt sequence: UInt16, transportNumbers: TransportPacketNumbers? = nil) {
        self.transportNumbers = transportNumbers
        self.keys = keys
        self.ssrc = ssrc
        nextIndex = Mutex(UInt64(sequence))
    }

    /// RTX shares transport feedback numbering with primary media and owns a separate SRTP counter.
    func makeRepairSender(ssrc: UInt32) -> SRTPSender {
        SRTPSender(keys: keys, ssrc: ssrc, startingAt: .random(in: 0...0x7fff), transportNumbers: transportNumbers)
    }

    func seal(_ payload: Data, type: UInt8, timestamp: UInt32, marker: Bool = false, extensions: [(UInt8,[UInt8])] = []) throws -> Data {
        guard type < 128, payload.count <= 65_507 - 28 else { throw SRTPError.invalidPacket }
        let index = try nextIndex.withLock { value in
            guard value < 1 << 48 else { throw SRTPError.exhausted }
            defer { value += 1 }
            return value
        }
        var header: [UInt8] = [0x80, type | (marker ? 0x80 : 0), UInt8(truncatingIfNeeded: index >> 8), UInt8(truncatingIfNeeded: index)]
        for value in [timestamp, ssrc] {
            for shift in [24, 16, 8, 0] { header.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        var extensions = extensions
        if let transportNumbers { extensions.append((1,transportNumbers.next(bytes: payload.count + header.count + 24))) }
        if !extensions.isEmpty {
            var fields: [UInt8] = []
            let long = extensions.contains { $0.1.count > 16 || $0.0 > 14 }
            for (id, value) in extensions {
                guard id != 0, (1...255).contains(value.count), fields.count + value.count + 2 <= 1024 else { throw SRTPError.invalidPacket }
                if long { fields += [id, UInt8(value.count)] }
                else { fields.append((id << 4) | UInt8(value.count - 1)) }
                fields += value
            }
            while !fields.count.isMultiple(of: 4) { fields.append(0) }
            header[0] |= 0x10
            header += long ? [0x10,0] : [0xbe,0xde]
            header += [UInt8((fields.count/4) >> 8),UInt8(truncatingIfNeeded: fields.count/4)]
            header += fields
        }
        let box = try AES.GCM.seal(payload, using: keys.key, nonce: keys.nonce(ssrc: ssrc, index: index), authenticating: header)
        return Data(header) + box.ciphertext + box.tag
    }
}

struct RTPPayload: Sendable {
    let type: UInt8
    let timestamp: UInt32
    let sequence: UInt16
    let marker: Bool
    let rotation: Int
    let transportNumber: UInt16?
    let bytes: Data
    var protectedHeader: VideoFECHeader? = nil
}

/// Replay state changes only after authentication. The window includes the previous rollover
/// for delayed packets. An SSRC from a different stream cannot advance this receiver's counter.
final class SRTPReceiver: Sendable {
    let keys: SRTPKeys
    let ssrc: UInt32
    private let window = Mutex(SRTPReplayWindow())

    private let measurements: CallMediaMeasurements?
    private let clock: UInt32
    private let arrivals: TransportArrivals?
    private let collectFEC: Bool

    init(keys: SRTPKeys, ssrc: UInt32, measurements: CallMediaMeasurements? = nil, clock: UInt32 = 48_000, arrivals: TransportArrivals? = nil, collectFEC: Bool = false) {
        self.collectFEC = collectFEC
        self.arrivals = arrivals
        self.keys = keys
        self.ssrc = ssrc
        self.measurements = measurements
        self.clock = clock
    }

    /// `arrival`: when the datagram came off the network (for transport feedback and jitter).
    func open(_ packet: Data, arrival: ContinuousClock.Instant = .now) throws -> RTPPayload {
        guard (28...65_507).contains(packet.count) else { throw SRTPError.invalidPacket }
        var header = ByteCursor(Array(packet))
        let flags = try header.u8()
        let type = try header.u8()
        let seq = try header.u16be()
        let timestamp = try header.u32be()
        guard flags >> 6 == 2, try header.u32be() == ssrc else { throw SRTPError.invalidPacket }
        let fields = try RTPFields(&header, flags: flags, retainMutable: collectFEC)
        let rotation = fields.rotation, transportNumber = fields.transportNumber
        guard header.remaining >= 16 else { throw SRTPError.invalidPacket }
        let aad = packet.prefix(header.consumed)
        let ciphertext = packet.dropFirst(header.consumed).dropLast(16)
        return try window.withLock { window in
            let index = try window.index(for: seq)
            try window.check(index)
            let box = try AES.GCM.SealedBox(nonce: keys.nonce(ssrc: ssrc, index: index), ciphertext: ciphertext, tag: packet.suffix(16))
            var bytes = try AES.GCM.open(box, using: keys.key, authenticating: aad)
            var protected = collectFEC && packet.count <= 4096 ? VideoFECHeader(flags: flags, datagram: packet, headerSize: aad.count, fields: fields) : nil
            if flags & 0x20 != 0 {
                guard let padding = bytes.last, padding > 0, padding <= bytes.count else { throw SRTPError.invalidPacket }
                if protected != nil { protected?.padding = Data(bytes.suffix(Int(padding))) }
                bytes.removeLast(Int(padding))
            }
            window.accept(index)
            if let transportNumber { arrivals?.record(transportNumber, at: arrival) }
            measurements?.received(ssrc: ssrc, index: index, timestamp: timestamp, clock: clock, bytes: bytes.count, at: arrival)
            return RTPPayload(type: type & 0x7f, timestamp: timestamp, sequence: seq, marker: type & 0x80 != 0, rotation: rotation, transportNumber: transportNumber, bytes: bytes, protectedHeader: protected)
        }
    }
}


/// The receiver checks before AEAD and marks a packet only after authenticating it.
/// RTP estimates the rollover counter. RTCP carries its packet index on the wire.
struct SRTPReplayWindow {
    private var highest: UInt64?
    private var received: UInt64 = 0

    func index(for sequence: UInt16) throws -> UInt64 {
        guard let highest else { return UInt64(sequence) }
        var roc = highest >> 16
        let delta = Int(sequence) - Int(UInt16(truncatingIfNeeded: highest))
        if delta > 32_768 {
            guard roc > 0 else { throw SRTPError.replay }
            roc -= 1
        } else if delta < -32_768 { roc += 1 }
        return roc << 16 | UInt64(sequence)
    }

    func check(_ index: UInt64) throws {
        if let highest, index <= highest {
            let distance = highest - index
            guard distance < 64, received & (1 << distance) == 0 else { throw SRTPError.replay }
        }
    }

    mutating func accept(_ index: UInt64) {
        if let highest, index <= highest {
            received |= 1 << (highest - index)
        } else {
            received = (received << (index - (highest ?? index))) | 1
            highest = index
        }
    }
}
