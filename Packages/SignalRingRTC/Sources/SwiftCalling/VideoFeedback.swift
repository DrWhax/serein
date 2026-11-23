import CodecCore
import Foundation

/// Authenticates the peer's SRTCP feedback before allowing a PLI or FIR for
/// this sending SSRC to request an independently decodable picture.
struct VideoFeedback {
    let keys: SRTPKeys
    var receivers: [UInt32:SRTCPReceiver] = [:]
    var streamLimit = 16

    mutating func refresh(_ data: Data, for target: UInt32) throws -> Bool {
        try Self.requestsKeyframe(open(data), for: target)
    }

    mutating func open(_ data: Data) throws -> Data {
        guard data.count >= 28 else { throw SRTPError.invalidPacket }
        var clear = ByteCursor(Array(data.prefix(8)))
        try clear.skip(4)
        let id = try clear.u32be()
        guard receivers[id] != nil || receivers.count < streamLimit else { throw SRTPError.invalidPacket }
        let receiver = receivers[id] ?? SRTCPReceiver(keys: keys, ssrc: id)
        let plain = try receiver.open(data)
        receivers[id] = receiver
        return plain
    }

    /// Direct V4 also advertises PSFB AFB/REMB. A receiver can estimate the
    /// bitrate for several SSRCs in a single message. Only apply a matching cap.
    static func maximumBitrate(_ plain: Data, for stream: UInt32) throws -> UInt64? {
        var compound = ByteCursor(Array(plain))
        while !compound.isAtEnd {
            let flags = try compound.u8(), type = try compound.u8()
            guard flags >> 6 == 2 else { throw SRTPError.invalidPacket }
            var payload = try compound.bytes(Int(try compound.u16be()) * 4).cursor()
            guard type == 206, flags & 31 == 15, payload.remaining >= 16 else { continue }
            try payload.skip(4)
            guard try payload.u32be() == 0, try payload.u32be() == 0x52454d42 else { continue }
            let count = Int(try payload.u8()), encoded = UInt64(try payload.u24be())
            guard count <= payload.remaining/4 else { throw SRTPError.invalidPacket }
            let mantissa = encoded & 0x3ffff, exponent = Int(encoded >> 18)
            let bitrate = mantissa > (UInt64.max >> exponent) ? UInt64.max : mantissa << exponent
            for _ in 0..<count { if try payload.u32be() == stream { return bitrate } }
        }
        return nil
    }

    static func requestsKeyframe(_ plain: Data, for target: UInt32) throws -> Bool {
        let counts = try refreshRequests(plain, for: target)
        return counts.pli + counts.fir > 0
    }

    static func refreshRequests(_ plain: Data, for target: UInt32) throws -> (pli: UInt64, fir: UInt64) {
        var compound = ByteCursor(Array(plain))
        var pli: UInt64 = 0, fir: UInt64 = 0
        while !compound.isAtEnd {
            let flags = try compound.u8(), type = try compound.u8()
            guard flags >> 6 == 2 else { throw SRTPError.invalidPacket }
            let words = try compound.u16be()
            var payload = try compound.bytes(Int(words)*4).cursor()
            guard type == 206, payload.remaining >= 8 else { continue }
            try payload.skip(4)
            let media = try payload.u32be()
            if flags & 31 == 1, media == target { pli += 1 }
            if flags & 31 == 4 {
                var matched = false
                while payload.remaining >= 8 {
                    if try payload.u32be() == target { matched = true }
                    try payload.skip(4)
                }
                if matched { fir += 1 }
            }
        }
        return (pli,fir)
    }
}
