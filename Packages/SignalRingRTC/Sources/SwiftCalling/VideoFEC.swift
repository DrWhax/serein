import CodecCore
import Foundation

/// RFC 8285 extensions shared by SRTP and WebRTC's pre-pacer FEC bit string.
struct RTPFields {
    let rotation: Int
    let transportNumber: UInt16?
    let mutable: [Range<Int>]

    init(_ input: inout ByteCursor, flags: UInt8, retainMutable: Bool) throws {
        try input.skip(Int(flags & 15)*4)
        var rotation = 0, number: UInt16?, mutable = [Range<Int>]()
        if flags & 16 != 0 {
            let profile = try input.u16be(), length = Int(try input.u16be())*4
            let origin = input.consumed
            var ext = try input.bytes(length).cursor()
            if profile == 0xbede || profile & 0xfff0 == 0x1000 {
                while !ext.isAtEnd {
                    let b = try ext.u8()
                    if b == 0 { continue }
                    let id: UInt8, size: Int
                    if profile == 0xbede {
                        id = b >> 4
                        if id == 15 { break }
                        size = Int(b & 15)+1
                    } else { id = b; size = Int(try ext.u8()) }
                    let offset = origin + ext.consumed
                    if id == 1, size == 2 { number = try ext.u16be() }
                    else if id == 4, size == 1 { rotation = Int(try ext.u8() & 3) }
                    else { try ext.skip(size) }
                    if retainMutable, id == 1 || id == 12 { mutable.append(offset..<(offset+size)) }
                }
            }
        }
        self.rotation = rotation
        self.transportNumber = number
        self.mutable = mutable
    }
}

/// WebRTC protects the original RTP header/payload before RED encapsulation.
/// Transport-wide sequence and absolute-send-time extension bytes are zero at that point.
struct VideoFECHeader: Sendable {
    let flags: UInt8
    var tail: [UInt8]
    var padding: Data = Data()

    init(flags: UInt8, tail: [UInt8]) { self.flags = flags & 63; self.tail = tail }

    init(flags: UInt8, datagram: Data, headerSize: Int, fields: RTPFields, padding: Data = Data()) {
        self.flags = flags & 63
        self.padding = padding
        tail = Array(datagram.dropFirst(12).prefix(headerSize-12))
        for range in fields.mutable {
            for index in range { tail[index-12] = 0 }
        }
    }
}

/// The single full-protection level and the 16/48-bit masks used by native WebRTC.
/// All inputs come from authenticated datagrams for one media SSRC.
struct VideoFEC {
    static let type: UInt8 = 122
    private static let maxDatagram = 4096

    struct Piece {
        let sequence: UInt16
        var flags: UInt8, markerType: UInt8, timestamp: UInt32
        var length: Int
        var tail: [UInt8]

        init?(_ packet: RTPPayload) {
            guard let header = packet.protectedHeader,
                  header.tail.count + packet.bytes.count + header.padding.count <= VideoFEC.maxDatagram else { return nil }
            sequence = packet.sequence
            flags = header.flags
            markerType = packet.type | (packet.marker ? 128 : 0)
            timestamp = packet.timestamp
            tail = header.tail + packet.bytes + header.padding
            length = tail.count
        }
        init(sequence: UInt16, flags: UInt8, markerType: UInt8, timestamp: UInt32, length: Int, tail: [UInt8]) {
            self.sequence = sequence; self.flags = flags; self.markerType = markerType
            self.timestamp = timestamp; self.length = length; self.tail = tail
        }

        mutating func xor(_ other: Self) {
            flags ^= other.flags
            markerType ^= other.markerType
            timestamp ^= other.timestamp
            length ^= other.length
            for i in 0..<min(tail.count,other.tail.count) { tail[i] ^= other.tail[i] }
        }

        func recover(_ sequence: UInt16) throws -> RTPPayload {
            let type = markerType & 127
            guard [DirectVideoStream.vp8,VP9Assembly.payloadType].contains(type), length <= tail.count else { throw SRTPError.invalidPacket }
            var header = ByteCursor(Array(tail.prefix(length)))
            let fields = try RTPFields(&header, flags: flags, retainMutable: false)
            var protected = VideoFECHeader(flags: flags, tail: Array(tail.prefix(header.consumed)))
            var bytes = Data(header.rest().copyBytes())
            if flags & 32 != 0 {
                guard let count = bytes.last, count > 0, Int(count) <= bytes.count else { throw SRTPError.invalidPacket }
                protected.padding = Data(bytes.suffix(Int(count)))
                bytes.removeLast(Int(count))
            }
            return .init(type: type,timestamp: timestamp,sequence: sequence,marker: markerType & 128 != 0,
                         rotation: fields.rotation,transportNumber: nil,bytes: bytes,protectedHeader: protected)
        }
    }

    struct Equation {
        let parity: Piece
        let sequences: [UInt16]
        let time: ContinuousClock.Instant
        init(_ bytes: Data, at now: ContinuousClock.Instant) throws {
            guard bytes.count <= VideoFEC.maxDatagram + 18 else { throw SRTPError.invalidPacket }
            var cursor = ByteCursor(Array(bytes))
            let flags = try cursor.u8(), markerType = try cursor.u8(), base = try cursor.u16be()
            guard flags & 128 == 0 else { throw SRTPError.invalidPacket }
            let timestamp = try cursor.u32be(), length = Int(try cursor.u16be()), protect = Int(try cursor.u16be())
            let mask = try cursor.bytes(flags & 64 != 0 ? 6 : 2).copyBytes()
            var sequences = [UInt16]()
            for bit in 0..<(mask.count*8) where mask[bit/8] & (128 >> (bit%8)) != 0 { sequences.append(base &+ UInt16(bit)) }
            guard !sequences.isEmpty, protect <= VideoFEC.maxDatagram, cursor.remaining == protect else { throw SRTPError.invalidPacket }
            self.sequences = sequences
            self.parity = .init(sequence:base,flags:flags & 63,markerType:markerType,timestamp:timestamp,length:length,tail:cursor.rest().copyBytes())
            time = now
        }
    }

    private var equations = [Equation]()
    private var known = [Int:(piece: Piece,time: ContinuousClock.Instant)]()
    private func find(_ sequence: UInt16, at now: ContinuousClock.Instant) -> Piece? {
        guard let entry = known[Int(sequence)%256], entry.piece.sequence == sequence, entry.time.duration(to: now) < .seconds(1) else { return nil }
        return entry.piece
    }

    mutating func ingest(_ packet: RTPPayload, at now: ContinuousClock.Instant = .now) -> [RTPPayload] {
        if packet.type == Self.type {
            if let equation = try? Equation(packet.bytes, at: now) {
                if equations.count == 32 { equations.removeFirst() }
                equations.append(equation)
            }
        } else if let piece = Piece(packet) {
            known[Int(piece.sequence)%256] = (piece, now)
        }
        var result = [RTPPayload]()
        var previous = -1
        while !equations.isEmpty, previous != result.count {
            previous = result.count
            var pending = [Equation]()
            for equation in equations where equation.time.duration(to: now) < .milliseconds(500) {
                let unavailable = equation.sequences.filter { find($0,at:now) == nil }
                if unavailable.count > 1 { pending.append(equation); continue }
                guard let sequence = unavailable.first else { continue }
                var parity = equation.parity
                for index in equation.sequences where index != sequence {
                    if let piece = find(index,at:now) { parity.xor(piece) }
                }
                if let packet = try? parity.recover(sequence), let piece = Piece(packet) {
                    known[Int(sequence)%256] = (piece,now)
                    result.append(packet)
                }
            }
            equations = pending
        }
        return result
    }

    struct Generator {
        private var batch = [Piece]()
        mutating func add(_ piece: Piece, count: Int) -> Data? {
            if let first = batch.first, piece.sequence &- first.sequence >= 16 { batch.removeAll(keepingCapacity:true) }
            batch.append(piece)
            guard batch.count >= count, let first = batch.first else { return nil }
            defer { batch.removeAll(keepingCapacity:true) }
            let protection = batch.map { $0.tail.count }.max() ?? 0
            var parity = Piece(sequence:first.sequence,flags:0,markerType:0,timestamp:0,length:0,tail:Array(repeating:0,count:protection))
            var mask: UInt16 = 0
            for p in batch { parity.xor(p); mask |= 0x8000 >> (p.sequence &- first.sequence) }
            var bytes = Data([parity.flags,parity.markerType])
            func word(_ n: UInt16) -> [UInt8] { [UInt8(n >> 8),UInt8(truncatingIfNeeded:n)] }
            bytes.append(contentsOf:word(first.sequence))
            for shift in [24,16,8,0] { bytes.append(UInt8(truncatingIfNeeded:parity.timestamp >> shift)) }
            bytes.append(contentsOf:word(UInt16(parity.length)))
            bytes.append(contentsOf:word(UInt16(protection)))
            bytes.append(contentsOf:word(mask))
            bytes.append(contentsOf:parity.tail)
            return bytes
        }
    }
}
