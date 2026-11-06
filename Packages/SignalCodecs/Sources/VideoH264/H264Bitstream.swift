// H.264 bitstream layer (ITU-T H.264 7.3.1, 7.4.1, 9.1): NAL units from an MP4 sample
// (length-prefixed, avcC) or an Annex B byte stream, emulation-prevention removal (RBSP),
// and the Exp-Golomb codes ue(v), se(v), te(v).
//
//   nal_unit   := forbidden_zero_bit:1{0} nal_ref_idc:2 nal_unit_type:5 rbsp_byte*
//   RBSP       := NAL payload with every 0x000003 → 0x0000 (the 03 removed)

public import CodecCore

public struct NALUnit: Sendable {
    public var refIdc: Int
    public var type: Int
    /// The RBSP (emulation prevention removed), without the NAL header byte.
    public var rbsp: [UInt8]

    public static let slice = 1, sliceIDR = 5, sei = 6, sps = 7, pps = 8, aud = 9, endOfSequence = 10, endOfStream = 11, filler = 12
    public static let spsExtension = 13, prefix = 14, subsetSPS = 15, sliceAux = 19, sliceExtension = 20

    public static func rbsp(_ payload: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(payload.count)
        var zeros = 0
        for b in payload {
            if zeros >= 2 && b == 3 { zeros = 0; continue }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return out
    }

    static func make(_ nal: ArraySlice<UInt8>) throws(ParseFailure) -> NALUnit {
        guard let h = nal.first else { throw ParseFailure(offset: 0, rule: "nal_unit", reason: .unexpectedEnd(needed: 1, available: 0)) }
        guard h & 0x80 == 0 else { throw ParseFailure(offset: 0, rule: "nal_unit.forbidden_zero_bit", reason: .invalid("set")) }
        return NALUnit(refIdc: Int(h >> 5) & 3, type: Int(h & 31), rbsp: rbsp(nal.dropFirst()))
    }

    /// NAL units of one MP4 sample (`lengthSize`-byte big-endian lengths).
    public static func units(sample: ByteSlice, lengthSize: Int, maxUnits: Int = 4096) throws(ParseFailure) -> [NALUnit] {
        guard [1, 2, 4].contains(lengthSize) else { throw ParseFailure(offset: 0, rule: "avcC.lengthSizeMinusOne", reason: .invalid("\(lengthSize)")) }
        var c = sample.cursor()
        var out: [NALUnit] = []
        while !c.isAtEnd {
            var n = 0
            for _ in 0 ..< lengthSize { n = n << 8 | Int(try c.u8("nal.length")) }
            guard n > 0 else { continue }
            out.append(try make(try c.bytes(n, "nal_unit").copyBytes()[...]))
            guard out.count <= maxUnits else { throw c.fail("nal", .limitExceeded("more than \(maxUnits) NAL units")) }
        }
        return out
    }

    /// NAL units of an MP4 sample up to the first damaged length prefix (`damaged` then).
    public static func unitsLenient(sample: ByteSlice, lengthSize: Int, maxUnits: Int = 4096) -> (units: [NALUnit], damaged: Bool) {
        guard [1, 2, 4].contains(lengthSize) else { return ([], true) }
        var c = sample.cursor()
        var out: [NALUnit] = []
        while !c.isAtEnd && out.count < maxUnits {
            var n = 0
            for _ in 0 ..< lengthSize {
                guard let b = try? c.u8("nal.length") else { return (out, true) }
                n = n << 8 | Int(b)
            }
            guard n > 0 else { continue }
            guard n <= c.remaining, let bytes = try? c.bytes(n, "nal_unit"), let u = try? make(bytes.copyBytes()[...]) else { return (out, true) }
            out.append(u)
        }
        return (out, false)
    }

    /// NAL units of an Annex B byte stream (start codes 00 00 01 / 00 00 00 01).
    public static func units(annexB b: [UInt8], maxUnits: Int = 1 << 20) throws(ParseFailure) -> [NALUnit] {
        var starts: [(Int, Int)] = []   // (start code position, payload start)
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
                starts.append((i > 0 && b[i - 1] == 0 ? i - 1 : i, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        var out: [NALUnit] = []
        for (k, s) in starts.enumerated() {
            var end = k + 1 < starts.count ? starts[k + 1].0 : b.count
            while end > s.1 && b[end - 1] == 0 { end -= 1 }   // trailing_zero_8bits
            guard end > s.1 else { continue }
            out.append(try make(b[s.1 ..< end]))
            guard out.count <= maxUnits else { throw ParseFailure(offset: s.1, rule: "nal", reason: .limitExceeded("too many NAL units")) }
        }
        return out
    }
}

/// A reader over an RBSP with the H.264 descriptors.
struct H264Reader {
    var r: MSBBitReader
    let bitCount: Int
    /// Position of the rbsp_stop_one_bit (the last 1 bit), −1 without one.
    let stopBit: Int

    init(_ rbsp: [UInt8]) {
        r = MSBBitReader(rbsp, policy: .fail)
        bitCount = rbsp.count * 8
        var last = rbsp.count - 1
        while last >= 0 && rbsp[last] == 0 { last -= 1 }
        stopBit = last < 0 ? -1 : last * 8 + (7 - rbsp[last].trailingZeroBitCount)
    }

    var position: Int { r.bitPosition }
    var bitsLeft: Int { bitCount - r.bitPosition }

    @inline(__always) mutating func u(_ n: Int, _ rule: String) throws(ParseFailure) -> Int { Int(try r.bits(n, rule)) }
    @inline(__always) mutating func flag(_ rule: String) throws(ParseFailure) -> Bool { try r.bit(rule) == 1 }

    /// ue(v), at most 32 bits of value.
    @inline(__always) mutating func ue(_ rule: String) throws(ParseFailure) -> Int {
        var zeros = 0
        while try r.bit(rule) == 0 {
            zeros += 1
            guard zeros <= 31 else { throw ParseFailure(offset: position / 8, rule: rule, reason: .invalid("Exp-Golomb code too long")) }
        }
        return zeros == 0 ? 0 : (1 << zeros) - 1 + Int(try r.bits(zeros, rule))
    }

    @inline(__always) mutating func se(_ rule: String) throws(ParseFailure) -> Int {
        let k = try ue(rule)
        return k & 1 == 1 ? (k + 1) / 2 : -(k / 2)
    }

    /// te(v) with range `max` (1: an inverted bit, else ue).
    mutating func te(_ max: Int, _ rule: String) throws(ParseFailure) -> Int {
        max > 1 ? try ue(rule) : (try r.bit(rule) == 1 ? 0 : 1)
    }

    /// ue(v) checked against an inclusive range.
    mutating func ue(_ rule: String, _ range: ClosedRange<Int>) throws(ParseFailure) -> Int {
        let v = try ue(rule)
        guard range.contains(v) else { throw ParseFailure(offset: position / 8, rule: rule, reason: .invalid("\(v) not in \(range)")) }
        return v
    }

    mutating func se(_ rule: String, _ range: ClosedRange<Int>) throws(ParseFailure) -> Int {
        let v = try se(rule)
        guard range.contains(v) else { throw ParseFailure(offset: position / 8, rule: rule, reason: .invalid("\(v) not in \(range)")) }
        return v
    }

    /// more_rbsp_data(): anything other than the stop bit and trailing zeros remains.
    func moreRBSPData() -> Bool { position < stopBit }

    mutating func alignToByte() { r.alignToByte() }

    func fail(_ rule: String, _ why: String) -> ParseFailure { ParseFailure(offset: position / 8, rule: rule, reason: .invalid(why)) }
}
