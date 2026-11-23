import CodecCore
import Foundation

/// RFC 4585 Generic NACK and RFC 4588 retransmission mappings used by RingRTC.
enum VideoRepair {
    static func primaryType(_ rtx: UInt8) -> UInt8? {
        switch rtx {
        case 118: DirectVideoStream.vp8
        case 119: VP9Assembly.payloadType
        case 121: DirectVideoStream.red
        default: nil
        }
    }

    static func retransmissionType(_ primary: UInt8) -> UInt8? {
        switch primary {
        case DirectVideoStream.vp8: 118
        case VP9Assembly.payloadType: 119
        case DirectVideoStream.red: 121
        default: nil
        }
    }

    static func unpack(_ packet: RTPPayload) throws -> RTPPayload {
        guard let type = primaryType(packet.type), packet.bytes.count > 2 else { throw SRTPError.invalidPacket }
        var input = ByteCursor(Array(packet.bytes))
        let original = try input.u16be()
        return RTPPayload(type: type, timestamp: packet.timestamp, sequence: original, marker: packet.marker,
                          rotation: packet.rotation, transportNumber: packet.transportNumber, bytes: Data(input.rest().copyBytes()))
    }

    /// Sequence numbers are in RTP order and can cross the 16-bit rollover.
    static func nack(_ missing: [UInt16], from sender: UInt32, for target: UInt32) -> Data? {
        guard !missing.isEmpty else { return nil }
        var entries = [UInt8]()
        var pos = 0
        while pos < missing.count {
            let base = missing[pos]
            pos += 1
            var mask: UInt16 = 0
            while pos < missing.count {
                let delta = missing[pos] &- base
                guard (1...16).contains(delta) else { break }
                mask |= 1 << (delta-1)
                pos += 1
            }
            entries += [UInt8(base >> 8), UInt8(truncatingIfNeeded: base), UInt8(mask >> 8), UInt8(truncatingIfNeeded: mask)]
        }
        let length = 2 + entries.count/4
        var packet = Data([0x81,205,UInt8(length >> 8),UInt8(truncatingIfNeeded:length)])
        for ssrc in [sender,target] {
            for shift in [24,16,8,0] { packet.append(UInt8(truncatingIfNeeded: ssrc >> shift)) }
        }
        packet.append(contentsOf: entries)
        return packet
    }

    static func requested(_ plain: Data, for target: UInt32) throws -> [UInt16] {
        try requests(plain, for: target).sequences
    }

    static func requests(_ plain: Data, for target: UInt32) throws -> (sequences: [UInt16], messages: UInt64) {
        var messages: UInt64 = 0
        var compound = ByteCursor(Array(plain))
        var result = [UInt16]()
        while !compound.isAtEnd {
            let flags = try compound.u8(), type = try compound.u8()
            guard flags >> 6 == 2 else { throw SRTPError.invalidPacket }
            let length = Int(try compound.u16be()) * 4
            var body = try compound.bytes(length).cursor()
            guard type == 205, flags & 31 == 1 else { continue }
            try body.skip(4)
            guard try body.u32be() == target else { continue }
            var remaining = body.remaining
            if flags & 0x20 != 0 {
                let pad = Int(plain[plain.startIndex+compound.consumed-1])
                guard pad > 0, pad <= remaining else { throw SRTPError.invalidPacket }
                remaining -= pad
            }
            guard remaining.isMultiple(of: 4) else { throw SRTPError.invalidPacket }
            if remaining > 0 { messages += 1 }
            for _ in 0..<(remaining/4) {
                let base = try body.u16be(), mask = try body.u16be()
                if result.count < 64 { result.append(base) }
                for bit in 0..<16 where result.count < 64 && mask & (1 << bit) != 0 { result.append(base &+ UInt16(bit+1)) }
            }
        }
        return (result,messages)
    }
}

/// Store the already frame-encrypted group payload plus its original RTP
/// metadata. Each repair gets its own RTX SRTP nonce and transport sequence.
struct VideoSendHistory {
    struct Fragment {
        let sequence: UInt16, type: UInt8, timestamp: UInt32, marker: Bool
        let extensions: [(UInt8,[UInt8])]
        let bytes: Data
        let sent: ContinuousClock.Instant
        var repaired: ContinuousClock.Instant?
    }

    private var slots = [Fragment?](repeating: nil, count: 512)
    private var lastBatch: ContinuousClock.Instant?
    private var batchCount = 0

    mutating func record(_ fragment: Fragment) {
        slots[Int(fragment.sequence) % slots.count] = fragment
    }

    mutating func repairs(_ requested: [UInt16], now: ContinuousClock.Instant = .now) -> [Fragment] {
        if lastBatch.map({ $0.duration(to: now) >= .milliseconds(25) }) != false {
            lastBatch = now
            batchCount = 0
        }
        var repairs = [Fragment]()
        for sequence in requested {
            if batchCount >= 32 { break }
            let pos = Int(sequence) % slots.count
            guard var fragment = slots[pos], fragment.sequence == sequence,
                  fragment.sent.duration(to: now) < .seconds(1),
                  fragment.repaired.map({ $0.duration(to: now) >= .milliseconds(45) }) != false else { continue }
            fragment.repaired = now
            slots[pos] = fragment
            repairs.append(fragment)
            batchCount += 1
        }
        return repairs
    }
}

/// Hold later packets across picture boundaries while repairs are in flight.
/// Give up after a short playout deadline so reference recovery can request a PLI.
struct VideoReceiveQueue {
    struct Output {
        var ready = [RTPPayload]()
        var missing = [UInt16]()
    }
    private var next: UInt16?
    private var held = [UInt16:RTPPayload]()
    private var bytes = 0
    private var since: ContinuousClock.Instant?
    private var requested: ContinuousClock.Instant?
    var waiting: Bool { !held.isEmpty }

    mutating func insert(_ packet: RTPPayload, now: ContinuousClock.Instant = .now) -> Output {
        let expected = next ?? packet.sequence
        let distance = Int(Int16(bitPattern: packet.sequence &- expected))
        if distance < 0 || held[packet.sequence] != nil { return Output() }
        if distance > 256 || bytes + packet.bytes.count > 512 * 1024 {
            var output = flush(after: expected)
            output.ready.append(packet)
            next = packet.sequence &+ 1
            return output
        }
        next = expected
        held[packet.sequence] = packet
        bytes += packet.bytes.count
        return poll(now: now)
    }

    mutating func poll(now: ContinuousClock.Instant = .now) -> Output {
        var output = Output()
        while let expected = next, let packet = held.removeValue(forKey: expected) {
            bytes -= packet.bytes.count
            output.ready.append(packet)
            next = expected &+ 1
        }
        guard !held.isEmpty, let expected = next else {
            since = nil
            requested = nil
            return output
        }
        if since == nil { since = now }
        if let since, since.duration(to: now) >= .milliseconds(250) {
            output.ready += flush(after: expected).ready
            return output
        }
        guard requested.map({ $0.duration(to: now) >= .milliseconds(55) }) != false else { return output }
        requested = now
        let farthest = held.keys.map { $0 &- expected }.max() ?? 0
        for offset in 0..<farthest where held[expected &+ offset] == nil {
            output.missing.append(expected &+ offset)
            if output.missing.count == 64 { break }
        }
        return output
    }

    private mutating func flush(after first: UInt16) -> Output {
        let ordered = held.values.sorted { ($0.sequence &- first) < ($1.sequence &- first) }
        if let last = ordered.last { next = last.sequence &+ 1 }
        held.removeAll(keepingCapacity: true)
        bytes = 0
        since = nil
        requested = nil
        return Output(ready: ordered)
    }
}
