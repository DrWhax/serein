import CodecCore
import Foundation

/// Reception report blocks can occur in both sender and receiver reports in a compound
/// RTCP datagram. Callers pass the plaintext returned by SRTCPReceiver.
struct RTCPReport {
    let stream: UInt32
    let fractionLost: UInt8
    let cumulativeLoss: Int32
    let extendedHighestSequence: UInt32
    let jitter: UInt32
    let lastSenderReport: UInt32
    let delaySinceLastReport: UInt32

    /// Each datagram is a complete RFC 3550 RR + SDES compound, including when the
    /// microphone is muted and there is no local sender report to carry feedback.
    static func datagrams(_ reports: [Self], sender: UInt32, cname: String) -> [Data] {
        guard (1...255).contains(cname.utf8.count) else { return [] }
        return stride(from: 0, to: reports.count, by: 31).map { start in
            let blocks = reports[start..<min(start + 31, reports.count)]
            var data = Data([0x80 | UInt8(blocks.count), 201, 0, UInt8(1 + 6 * blocks.count)])
            func word(_ value: UInt32) {
                for shift in [24, 16, 8, 0] { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
            }
            word(sender)
            for block in blocks {
                word(block.stream)
                word(UInt32(block.fractionLost) << 24 | (UInt32(bitPattern: block.cumulativeLoss) & 0xffffff))
                word(block.extendedHighestSequence)
                word(block.jitter)
                word(block.lastSenderReport)
                word(block.delaySinceLastReport)
            }
            appendSourceDescription(to: &data, sender: sender, cname: cname)
            return data
        }
    }

    static func appendSourceDescription(to data: inout Data, sender: UInt32, cname: String) {
        let words = (4 + 2 + cname.utf8.count + 1 + 3) / 4
        data.append(contentsOf: [0x81, 202, 0, UInt8(words)])
        for shift in [24, 16, 8, 0] { data.append(UInt8(truncatingIfNeeded: sender >> shift)) }
        data.append(contentsOf: [1, UInt8(cname.utf8.count)])
        data.append(contentsOf: cname.utf8)
        data.append(0)
        while !data.count.isMultiple(of: 4) { data.append(0) }
    }

    static func parse(_ packet: Data) throws -> [Self] {
        try compound(packet).receivers
    }

    static func compound(_ packet: Data) throws -> (senders: [RTCPSenderReport], receivers: [Self]) {
        var senders: [RTCPSenderReport] = []
        guard (4...65_507).contains(packet.count) else { throw SRTPError.invalidPacket }
        var input = ByteCursor(Array(packet))
        var reports: [Self] = []
        while !input.isAtEnd {
            let flags = try input.u8()
            let type = try input.u8()
            guard flags >> 6 == 2, (192...223).contains(type) else { throw SRTPError.invalidPacket }
            let words = try Int(input.u16be())
            let payload = try input.bytes(words * 4)
            var body = payload.cursor()
            if flags & 0x20 != 0 {
                guard input.isAtEnd, !payload.isEmpty else { throw SRTPError.invalidPacket }
                var tail = body
                try tail.skip(tail.remaining - 1)
                let padding = try Int(tail.u8())
                guard (1...payload.count).contains(padding) else { throw SRTPError.invalidPacket }
                body = try body.bytes(payload.count - padding).cursor()
            }
            guard type == 200 || type == 201 else { continue }
            let ssrc = try body.u32be()
            if type == 200 {
                senders.append(try RTCPSenderReport(ssrc: ssrc, ntp: body.u64be(), rtp: body.u32be()))
                try body.skip(8)
            }
            for _ in 0..<(flags & 31) {
                let stream = try body.u32be()
                let fraction = try body.u8()
                let signedLoss = Int32(bitPattern: try body.u24be() << 8) >> 8
                reports.append(try Self(stream: stream, fractionLost: fraction, cumulativeLoss: signedLoss,
                    extendedHighestSequence: body.u32be(), jitter: body.u32be(),
                    lastSenderReport: body.u32be(), delaySinceLastReport: body.u32be()))
            }
        }
        return (senders, reports)
    }
}
