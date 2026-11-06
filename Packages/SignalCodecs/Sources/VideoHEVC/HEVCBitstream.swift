// H.265 bitstream layer (ITU-T H.265 7.3.1.1, 7.3.1.2, 7.4.2, 9.2): NAL units from an MP4
// sample (length-prefixed, hvcC), emulation-prevention removal (RBSP), Exp-Golomb codes.
//
//   nal_unit        := nal_unit_header rbsp_byte*
//   nal_unit_header := forbidden_zero_bit:1{0} nal_unit_type:6 nuh_layer_id:6 nuh_temporal_id_plus1:3{≥1}
//   RBSP            := NAL payload with every 0x000003 → 0x0000 (the 03 removed)

public import CodecCore

public struct HEVCNALUnit: Sendable {
    public var type: Int
    public var layerId: Int
    public var temporalId: Int
    /// The RBSP (emulation prevention removed), without the 2-byte NAL header.
    public var rbsp: [UInt8]
    /// RBSP offsets at which an emulation_prevention_three_byte was removed (ascending): entry
    /// point offsets count those bytes (7.4.7.1), the RBSP does not.
    public var emulationPrevention: [Int] = []

    /// The RBSP offset of a position given in NAL payload bytes (with emulation prevention).
    public func rbspOffset(payloadOffset: Int) -> Int {
        var removed = 0
        for p in emulationPrevention {
            // The removed byte sat at payload offset p + removed.
            if p + removed < payloadOffset { removed += 1 } else { break }
        }
        return payloadOffset - removed
    }

    /// The payload offset (with emulation prevention) of an RBSP offset.
    public func payloadOffset(rbspOffset: Int) -> Int {
        rbspOffset + emulationPrevention.filter { $0 < rbspOffset }.count
    }

    // Table 7-1.
    public static let trailN = 0, trailR = 1, tsaN = 2, tsaR = 3, stsaN = 4, stsaR = 5, radlN = 6, radlR = 7, raslN = 8, raslR = 9
    public static let blaWLP = 16, blaWRADL = 17, blaNLP = 18, idrWRADL = 19, idrNLP = 20, craNUT = 21
    public static let vps = 32, sps = 33, pps = 34, aud = 35, eos = 36, eob = 37, fd = 38, prefixSEI = 39, suffixSEI = 40

    public var isVCL: Bool { type < 32 }
    public var isIRAP: Bool { (16...23).contains(type) }
    public var isIDR: Bool { type == Self.idrWRADL || type == Self.idrNLP }
    /// RASL pictures (skipped after a CRA/BLA that starts decoding).
    public var isRASL: Bool { type == Self.raslN || type == Self.raslR }
    /// Sub-layer non-reference pictures (types 0, 2, 4, …, 14 below 16).
    public var isSubLayerNonReference: Bool { type <= 14 && type % 2 == 0 }

    public static func rbsp(_ payload: ArraySlice<UInt8>) -> [UInt8] { rbspWithPositions(payload).rbsp }

    static func rbspWithPositions(_ payload: ArraySlice<UInt8>) -> (rbsp: [UInt8], removed: [Int]) {
        var out: [UInt8] = []
        var removed: [Int] = []
        out.reserveCapacity(payload.count)
        var zeros = 0
        for b in payload {
            if zeros >= 2 && b == 3 { zeros = 0; removed.append(out.count); continue }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return (out, removed)
    }

    public static func make(_ nal: ArraySlice<UInt8>) throws(ParseFailure) -> HEVCNALUnit {
        guard nal.count >= 2 else { throw ParseFailure(offset: 0, rule: "nal_unit_header", reason: .unexpectedEnd(needed: 2, available: nal.count)) }
        let h0 = nal[nal.startIndex], h1 = nal[nal.startIndex + 1]
        guard h0 & 0x80 == 0 else { throw ParseFailure(offset: 0, rule: "nal_unit_header.forbidden_zero_bit", reason: .invalid("set")) }
        let tid = Int(h1 & 7)
        guard tid >= 1 else { throw ParseFailure(offset: 1, rule: "nal_unit_header.nuh_temporal_id_plus1", reason: .invalid("0")) }
        let (r, removed) = rbspWithPositions(nal.dropFirst(2))
        return HEVCNALUnit(type: Int(h0 >> 1) & 0x3F, layerId: Int(h0 & 1) << 5 | Int(h1 >> 3), temporalId: tid - 1, rbsp: r,
                           emulationPrevention: removed)
    }

    /// NAL units of one MP4 sample (`lengthSize`-byte big-endian lengths).
    public static func units(sample: ByteSlice, lengthSize: Int, maxUnits: Int = 4096) throws(ParseFailure) -> [HEVCNALUnit] {
        guard [1, 2, 4].contains(lengthSize) else { throw ParseFailure(offset: 0, rule: "hvcC.lengthSizeMinusOne", reason: .invalid("\(lengthSize)")) }
        var c = sample.cursor()
        var out: [HEVCNALUnit] = []
        while !c.isAtEnd {
            var n = 0
            for _ in 0 ..< lengthSize { n = n << 8 | Int(try c.u8("nal.length")) }
            guard n > 0 else { continue }
            out.append(try make(try c.bytes(n, "nal_unit").copyBytes()[...]))
            guard out.count <= maxUnits else { throw c.fail("nal", .limitExceeded("more than \(maxUnits) NAL units")) }
        }
        return out
    }
}

/// Reads an RBSP: fixed-length fields, Exp-Golomb codes, and the RBSP trailing bits.
struct HEVCReader {
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

    @inline(__always) mutating func u(_ n: Int, _ rule: String) throws(ParseFailure) -> Int { n == 0 ? 0 : Int(try r.bits(n, rule)) }
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

    /// ue(v) checked against an inclusive range.
    mutating func ue(_ rule: String, _ range: ClosedRange<Int>) throws(ParseFailure) -> Int {
        let v = try ue(rule)
        guard range.contains(v) else { throw fail(rule, "\(v) not in \(range)") }
        return v
    }

    mutating func se(_ rule: String, _ range: ClosedRange<Int>) throws(ParseFailure) -> Int {
        let v = try se(rule)
        guard range.contains(v) else { throw fail(rule, "\(v) not in \(range)") }
        return v
    }

    mutating func skip(_ n: Int, _ rule: String) throws(ParseFailure) {
        var left = n
        while left > 0 {
            let k = min(left, 24)
            _ = try r.bits(k, rule)
            left -= k
        }
    }

    /// more_rbsp_data(): anything other than the stop bit and trailing zeros remains.
    func moreRBSPData() -> Bool { position < stopBit }

    /// byte_alignment(): alignment_bit_equal_to_one, then zero bits to the byte boundary.
    mutating func byteAlignment(_ rule: String) throws(ParseFailure) {
        guard try r.bit(rule) == 1 else { throw fail(rule, "alignment bit not 1") }
        while position % 8 != 0 { guard try r.bit(rule) == 0 else { throw fail(rule, "alignment zero bit set") } }
    }

    func fail(_ rule: String, _ why: String) -> ParseFailure { ParseFailure(offset: position / 8, rule: rule, reason: .invalid(why)) }
}

/// Ceil(Log2(n)) for n ≥ 1 (the length of fields that index n entries).
@inline(__always) func ceilLog2(_ n: Int) -> Int { n <= 1 ? 0 : Int.bitWidth - (n - 1).leadingZeroBitCount }
