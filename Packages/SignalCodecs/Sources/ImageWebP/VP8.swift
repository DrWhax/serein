// VP8 key-frame decoder (RFC 6386), a port of libwebp's vp8_dec.c / tree_dec.c /
// quant_dec.c / frame_dec.c / dsp/dec.c, bit-exact with dwebp. Output is the
// decoded YUV 4:2:0 frame (full macroblock size) after the in-loop filter.

public import CodecCore

// MARK: boolean decoder (utils/bit_reader*: byte-wise loading)

struct VP8BoolDecoder {
    let data: [UInt8]
    var pos = 0
    var value: UInt64 = 0
    var range: UInt32 = 255 - 1
    var bits = -8
    var eof = false

    init(_ bytes: [UInt8]) {
        data = bytes
        load()
    }

    @inline(__always) mutating func load() {
        if pos < data.count {
            bits += 8
            value = UInt64(data[pos]) | (value << 8)
            pos += 1
        } else if !eof {
            value <<= 8
            bits += 8
            eof = true
        } else {
            bits = 0
        }
    }

    @inline(__always) mutating func bit(_ prob: Int) -> Int {
        var r = range
        if bits < 0 { load() }
        let p = bits
        let split = (r &* UInt32(prob)) >> 8
        let v = UInt32(truncatingIfNeeded: value >> UInt64(p))
        let b: Int
        if v > split {
            r -= split
            value &-= UInt64(split + 1) << UInt64(p)
            b = 1
        } else {
            r = split + 1
            b = 0
        }
        let shift = 7 ^ (31 - r.leadingZeroBitCount)
        r <<= UInt32(shift)
        bits -= shift
        range = r - 1
        return b
    }

    /// VP8GetSigned: returns ±v using a 1/2-probability sign bit.
    @inline(__always) mutating func signed(_ v: Int) -> Int {
        if bits < 0 { load() }
        let p = bits
        let split = range >> 1
        let val = UInt32(truncatingIfNeeded: value >> UInt64(p))
        let mask = Int32(bitPattern: split &- val) >> 31
        bits -= 1
        range = range &+ UInt32(bitPattern: mask)
        range |= 1
        value &-= UInt64((split + 1) & UInt32(bitPattern: mask)) << UInt64(p)
        return (v ^ Int(mask)) - Int(mask)
    }

    mutating func value(_ n: Int) -> Int {
        var v = 0
        var k = n
        while k > 0 { k -= 1; v |= bit(0x80) << k }
        return v
    }
    mutating func flag() -> Bool { value(1) == 1 }
    mutating func signedValue(_ n: Int) -> Int {
        let v = value(n)
        return flag() ? -v : v
    }
}

// MARK: frame

public struct VP8Frame: Sendable {
    public var width: Int, height: Int
    public var mbW: Int, mbH: Int
    public var y: [UInt8], u: [UInt8], v: [UInt8]
    public var yStride: Int { mbW * 16 }
    public var uvStride: Int { mbW * 8 }
}

public enum VP8Decoder {
    static let BPS = 32
    static let yOff = 32 * 1 + 8, uOff = 32 * 1 + 8 + 32 * 16 + 32, vOff = 32 * 1 + 8 + 32 * 16 + 32 + 16
    static let zigzag = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15]
    static let cat3456: [[Int]] = [[173, 148, 140], [176, 155, 140, 135], [180, 157, 141, 134, 130],
                                   [254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129]]
    static let scan: [Int] = (0..<16).map { ($0 & 3) * 4 + ($0 >> 2) * 4 * 32 }

    struct Segment { var useSegment = false, updateMap = false, absoluteDelta = true; var quantizer = [0, 0, 0, 0], filterStrength = [0, 0, 0, 0] }
    struct Filter { var simple = false, level = 0, sharpness = 0, useLfDelta = false; var refDelta = [0, 0, 0, 0], modeDelta = [0, 0, 0, 0] }
    struct Quant { var y1 = [0, 0], y2 = [0, 0], uv = [0, 0] }
    struct FInfo { var limit = 0, ilevel = 0, inner = false, hevThresh = 0 }
    struct MBData {
        var coeffs = [Int16](repeating: 0, count: 384)
        var isI4x4 = false
        var imodes = [Int](repeating: 0, count: 16)
        var uvmode = 0
        var segment = 0
        var skip = false
        var nonZeroY: UInt32 = 0, nonZeroUV: UInt32 = 0
    }

    public static func decode(_ payload: ByteSlice, limits: DecodeLimits = .default) throws(ParseFailure) -> VP8Frame {
        var c = payload.cursor()
        let at = c.position
        let tag = Int(try c.u24le("VP8.frameTag"))
        guard tag & 1 == 0 else { throw ParseFailure(offset: at, rule: "VP8", reason: .invalid("not a key frame")) }
        guard (tag >> 1) & 7 <= 3 else { throw ParseFailure(offset: at, rule: "VP8", reason: .invalid("profile \((tag >> 1) & 7)")) }
        guard (tag >> 4) & 1 == 1 else { throw ParseFailure(offset: at, rule: "VP8", reason: .invalid("frame not shown")) }
        let partLen = tag >> 5
        try c.expect([0x9D, 0x01, 0x2A], "VP8.startCode")
        let width = Int(try c.u16le("VP8.width")) & 0x3FFF
        let height = Int(try c.u16le("VP8.height")) & 0x3FFF
        try limits.checkDimensions(width: width, height: height, at: at, rule: "VP8")
        guard partLen <= c.remaining else {
            throw ParseFailure(offset: at, rule: "VP8", reason: .unexpectedEnd(needed: partLen, available: c.remaining))
        }
        var br = VP8BoolDecoder(try c.bytes(partLen, "VP8.partition0").copyBytes())
        let mbW = (width + 15) >> 4, mbH = (height + 15) >> 4

        _ = br.flag()  // colour space
        _ = br.flag()  // clamping type (decoder always clamps)

        // Segment header.
        var seg = Segment()
        var segProbs = [255, 255, 255]
        seg.useSegment = br.flag()
        if seg.useSegment {
            seg.updateMap = br.flag()
            if br.flag() {
                seg.absoluteDelta = br.flag()
                for s in 0..<4 { seg.quantizer[s] = br.flag() ? br.signedValue(7) : 0 }
                for s in 0..<4 { seg.filterStrength[s] = br.flag() ? br.signedValue(6) : 0 }
            }
            if seg.updateMap { for s in 0..<3 { segProbs[s] = br.flag() ? br.value(8) : 255 } }
        }
        guard !br.eof else { throw ParseFailure(offset: at, rule: "VP8", reason: .unexpectedEnd(needed: 1, available: 0)) }

        // Filter header.
        var flt = Filter()
        flt.simple = br.flag()
        flt.level = br.value(6)
        flt.sharpness = br.value(3)
        flt.useLfDelta = br.flag()
        if flt.useLfDelta, br.flag() {
            for i in 0..<4 where br.flag() { flt.refDelta[i] = br.signedValue(6) }
            for i in 0..<4 where br.flag() { flt.modeDelta[i] = br.signedValue(6) }
        }
        let filterType = flt.level == 0 ? 0 : flt.simple ? 1 : 2
        guard !br.eof else { throw ParseFailure(offset: at, rule: "VP8", reason: .unexpectedEnd(needed: 1, available: 0)) }

        // Token partitions (sizes are clamped to what is left, as libwebp does).
        let numParts = 1 << br.value(2)
        var rest = c.rest()
        guard rest.count >= 3 * (numParts - 1) else {
            throw ParseFailure(offset: rest.lowerBound, rule: "VP8.partitions", reason: .unexpectedEnd(needed: 3 * (numParts - 1), available: rest.count))
        }
        var sizes = rest.cursor()
        var sizeList: [Int] = []
        for _ in 0..<(numParts - 1) { sizeList.append(Int(try sizes.u24le("VP8.partitionSize"))) }
        var pc = sizes.rest().cursor()
        var parts: [VP8BoolDecoder] = []
        for p in 0..<(numParts - 1) {
            let n = min(sizeList[p], pc.remaining)
            parts.append(VP8BoolDecoder(try pc.bytes(n, "VP8.partition").copyBytes()))
        }
        // The last partition takes the rest and must not be empty (libwebp ParsePartitions).
        guard pc.remaining > 0 else {
            throw ParseFailure(offset: pc.position, rule: "VP8.partitions", reason: .unexpectedEnd(needed: 1, available: 0))
        }
        parts.append(VP8BoolDecoder(pc.rest().copyBytes()))
        rest = .empty

        // Quantisers (quant_dec.c).
        let baseQ = br.value(7)
        let dqy1dc = br.flag() ? br.signedValue(4) : 0
        let dqy2dc = br.flag() ? br.signedValue(4) : 0
        let dqy2ac = br.flag() ? br.signedValue(4) : 0
        let dquvdc = br.flag() ? br.signedValue(4) : 0
        let dquvac = br.flag() ? br.signedValue(4) : 0
        func clipQ(_ v: Int, _ m: Int) -> Int { v < 0 ? 0 : v > m ? m : v }
        var quant = [Quant](repeating: Quant(), count: 4)
        for i in 0..<4 {
            var q: Int
            if seg.useSegment { q = seg.quantizer[i]; if !seg.absoluteDelta { q += baseQ } }
            else if i > 0 { quant[i] = quant[0]; continue } else { q = baseQ }
            var m = Quant()
            m.y1[0] = Int(VP8Tables.dcTable[clipQ(q + dqy1dc, 127)])
            m.y1[1] = Int(VP8Tables.acTable[clipQ(q, 127)])
            m.y2[0] = Int(VP8Tables.dcTable[clipQ(q + dqy2dc, 127)]) * 2
            m.y2[1] = max(8, (Int(VP8Tables.acTable[clipQ(q + dqy2ac, 127)]) * 101_581) >> 16)
            m.uv[0] = Int(VP8Tables.dcTable[clipQ(q + dquvdc, 117)])
            m.uv[1] = Int(VP8Tables.acTable[clipQ(q + dquvac, 127)])
            quant[i] = m
        }

        _ = br.flag()  // update_proba: ignored
        var proba = [Int](repeating: 0, count: 4 * 8 * 3 * 11)
        for i in 0..<proba.count {
            proba[i] = br.bit(Int(VP8Tables.coeffsUpdateProba[i])) == 1 ? br.value(8) : Int(VP8Tables.coeffsProba0[i])
        }
        let useSkip = br.flag()
        let skipP = useSkip ? br.value(8) : 0

        // Filter strengths (frame_dec.c PrecomputeFilterStrengths).
        var fstr = [[FInfo]](repeating: [FInfo(), FInfo()], count: 4)
        if filterType > 0 {
            for s in 0..<4 {
                var base = seg.useSegment ? seg.filterStrength[s] : flt.level
                if seg.useSegment && !seg.absoluteDelta { base += flt.level }
                for i4 in 0...1 {
                    var level = base
                    if flt.useLfDelta { level += flt.refDelta[0]; if i4 == 1 { level += flt.modeDelta[0] } }
                    level = max(0, min(63, level))
                    var info = FInfo()
                    if level > 0 {
                        var il = level
                        if flt.sharpness > 0 {
                            il >>= flt.sharpness > 4 ? 2 : 1
                            if il > 9 - flt.sharpness { il = 9 - flt.sharpness }
                        }
                        if il < 1 { il = 1 }
                        info.ilevel = il
                        info.limit = 2 * level + il
                        info.hevThresh = level >= 40 ? 2 : level >= 15 ? 1 : 0
                    }
                    info.inner = i4 == 1
                    fstr[s][i4] = info
                }
            }
        }

        // Decode macroblocks.
        var frame = VP8Frame(width: width, height: height, mbW: mbW, mbH: mbH,
                             y: [UInt8](repeating: 0, count: mbW * 16 * mbH * 16),
                             u: [UInt8](repeating: 0, count: mbW * 8 * mbH * 8),
                             v: [UInt8](repeating: 0, count: mbW * 8 * mbH * 8))
        var intraT = [Int](repeating: 0, count: 4 * mbW)
        var nzTop = [UInt32](repeating: 0, count: mbW), nzDcTop = [Int](repeating: 0, count: mbW)
        var topY = [[UInt8]](repeating: [UInt8](repeating: 0, count: 16), count: mbW)
        var topU = [[UInt8]](repeating: [UInt8](repeating: 0, count: 8), count: mbW)
        var topV = topU
        var finfo = [FInfo](repeating: FInfo(), count: mbW * mbH)
        var ws = [UInt8](repeating: 0, count: 32 * 17 + 32 * 9)
        var row = [MBData](repeating: MBData(), count: mbW)

        for mbY in 0..<mbH {
            // Intra modes for the whole row (partition 0).
            var intraL = [0, 0, 0, 0]
            for mbX in 0..<mbW {
                var b = row[mbX]
                b.segment = seg.updateMap ? (br.bit(segProbs[0]) == 0 ? br.bit(segProbs[1]) : br.bit(segProbs[2]) + 2) : 0
                b.skip = useSkip ? br.bit(skipP) == 1 : false
                b.isI4x4 = br.bit(145) == 0
                if !b.isI4x4 {
                    let ymode = br.bit(156) == 1 ? (br.bit(128) == 1 ? 1 : 3) : (br.bit(163) == 1 ? 2 : 0)
                    b.imodes[0] = ymode
                    for k in 0..<4 { intraT[4 * mbX + k] = ymode; intraL[k] = ymode }
                } else {
                    for yy in 0..<4 {
                        var ymode = intraL[yy]
                        for xx in 0..<4 {
                            let pbase = (intraT[4 * mbX + xx] * 10 + ymode) * 9
                            func p(_ k: Int) -> Int { Int(VP8Tables.bModesProba[pbase + k]) }
                            if br.bit(p(0)) == 0 { ymode = 0 }
                            else if br.bit(p(1)) == 0 { ymode = 1 }
                            else if br.bit(p(2)) == 0 { ymode = 2 }
                            else if br.bit(p(3)) == 0 { ymode = br.bit(p(4)) == 0 ? 3 : (br.bit(p(5)) == 0 ? 4 : 5) }
                            else { ymode = br.bit(p(6)) == 0 ? 6 : (br.bit(p(7)) == 0 ? 7 : (br.bit(p(8)) == 0 ? 8 : 9)) }
                            intraT[4 * mbX + xx] = ymode
                        }
                        for xx in 0..<4 { b.imodes[yy * 4 + xx] = intraT[4 * mbX + xx] }
                        intraL[yy] = ymode
                    }
                }
                b.uvmode = br.bit(142) == 0 ? 0 : br.bit(114) == 0 ? 2 : br.bit(183) == 1 ? 1 : 3
                row[mbX] = b
            }
            guard !br.eof else { throw ParseFailure(offset: at, rule: "VP8", reason: .invalid("premature end of partition 0")) }

            // Residuals.
            var nzLeft: UInt32 = 0, nzDcLeft = 0
            let pi = mbY & (numParts - 1)
            for mbX in 0..<mbW {
                var skip = row[mbX].skip
                if !skip {
                    skip = parseResiduals(&parts[pi], &row[mbX], quant[row[mbX].segment], proba, &nzTop[mbX], &nzLeft, &nzDcTop[mbX], &nzDcLeft)
                } else {
                    nzLeft = 0; nzTop[mbX] = 0
                    if !row[mbX].isI4x4 { nzDcLeft = 0; nzDcTop[mbX] = 0 }
                    row[mbX].nonZeroY = 0; row[mbX].nonZeroUV = 0
                }
                if filterType > 0 {
                    var f = fstr[row[mbX].segment][row[mbX].isI4x4 ? 1 : 0]
                    f.inner = f.inner || !skip
                    finfo[mbY * mbW + mbX] = f
                }
                guard !parts[pi].eof else { throw ParseFailure(offset: at, rule: "VP8", reason: .invalid("premature end of token partition")) }
            }

            reconstructRow(mbY, &row, &ws, &frame, &topY, &topU, &topV)
        }

        if filterType > 0 { loopFilter(&frame, finfo, simple: filterType == 1) }
        return frame
    }

    // MARK: residuals (vp8_dec.c ParseResiduals / GetCoeffs)

    static func getCoeffs(_ br: inout VP8BoolDecoder, _ proba: [Int], _ type: Int, _ ctx: Int, _ dq: [Int], _ first: Int,
                          _ out: inout [Int16], _ base: Int) -> Int {
        @inline(__always) func p(_ band: Int, _ c: Int, _ k: Int) -> Int { proba[((type * 8 + band) * 3 + c) * 11 + k] }
        var n = first
        var band = Int(VP8Tables.bands[n]), c = ctx
        while n < 16 {
            if br.bit(p(band, c, 0)) == 0 { return n }
            while br.bit(p(band, c, 1)) == 0 {
                n += 1
                if n == 16 { return 16 }
                band = Int(VP8Tables.bands[n]); c = 0
            }
            let nextBand = Int(VP8Tables.bands[n + 1])
            var v: Int
            if br.bit(p(band, c, 2)) == 0 {
                v = 1
                c = 1
            } else {
                // GetLargeValue
                if br.bit(p(band, c, 3)) == 0 {
                    v = br.bit(p(band, c, 4)) == 0 ? 2 : 3 + br.bit(p(band, c, 5))
                } else if br.bit(p(band, c, 6)) == 0 {
                    if br.bit(p(band, c, 7)) == 0 { v = 5 + br.bit(159) }
                    else { v = 7 + 2 * br.bit(165); v += br.bit(145) }
                } else {
                    let b1 = br.bit(p(band, c, 8))
                    let b0 = br.bit(p(band, c, 9 + b1))
                    let cat = 2 * b1 + b0
                    v = 0
                    for t in cat3456[cat] { v += v + br.bit(t) }
                    v += 3 + (8 << cat)
                }
                c = 2
            }
            out[base + zigzag[n]] = Int16(truncatingIfNeeded: br.signed(v) * dq[n > 0 ? 1 : 0])
            band = nextBand
            n += 1
        }
        return 16
    }

    static func nzCode(_ bits: UInt32, _ nz: Int, _ dcNz: Bool) -> UInt32 {
        (bits << 2) | (nz > 3 ? 3 : nz > 1 ? 2 : (dcNz ? 1 : 0))
    }

    /// Returns true if the macroblock has no non-zero coefficient.
    static func parseResiduals(_ br: inout VP8BoolDecoder, _ b: inout MBData, _ q: Quant, _ proba: [Int],
                               _ mbNz: inout UInt32, _ leftNz: inout UInt32, _ mbNzDc: inout Int, _ leftNzDc: inout Int) -> Bool {
        for i in 0..<384 { b.coeffs[i] = 0 }
        var first = 0, acType = 3
        if !b.isI4x4 {
            var dc = [Int16](repeating: 0, count: 16)
            let ctx = mbNzDc + leftNzDc
            let nz = getCoeffs(&br, proba, 1, ctx, q.y2, 0, &dc, 0)
            mbNzDc = nz > 0 ? 1 : 0
            leftNzDc = mbNzDc
            if nz > 1 {
                transformWHT(dc, &b.coeffs)
            } else {
                let dc0 = Int16(truncatingIfNeeded: (Int(dc[0]) + 3) >> 3)
                for i in stride(from: 0, to: 256, by: 16) { b.coeffs[i] = dc0 }
            }
            first = 1
            acType = 0
        }
        var tnz = mbNz & 0x0F, lnz = leftNz & 0x0F
        var nonZeroY: UInt32 = 0
        var dst = 0
        for _ in 0..<4 {
            var l = lnz & 1
            var nzc: UInt32 = 0
            for _ in 0..<4 {
                let ctx = Int(l + (tnz & 1))
                let nz = getCoeffs(&br, proba, acType, ctx, q.y1, first, &b.coeffs, dst)
                l = nz > first ? 1 : 0
                tnz = (tnz >> 1) | (l << 7)
                nzc = nzCode(nzc, nz, b.coeffs[dst] != 0)
                dst += 16
            }
            tnz >>= 4
            lnz = (lnz >> 1) | (l << 7)
            nonZeroY = (nonZeroY << 8) | nzc
        }
        var outT = tnz, outL = lnz >> 4
        var nonZeroUV: UInt32 = 0
        for ch in stride(from: 0, to: 4, by: 2) {
            var nzc: UInt32 = 0
            tnz = mbNz >> UInt32(4 + ch)
            lnz = leftNz >> UInt32(4 + ch)
            for _ in 0..<2 {
                var l = lnz & 1
                for _ in 0..<2 {
                    let ctx = Int(l + (tnz & 1))
                    let nz = getCoeffs(&br, proba, 2, ctx, q.uv, 0, &b.coeffs, dst)
                    l = nz > 0 ? 1 : 0
                    tnz = (tnz >> 1) | (l << 3)
                    nzc = nzCode(nzc, nz, b.coeffs[dst] != 0)
                    dst += 16
                }
                tnz >>= 2
                lnz = (lnz >> 1) | (l << 5)
            }
            nonZeroUV |= nzc << UInt32(4 * ch)
            outT |= (tnz << 4) << UInt32(ch)
            outL |= (lnz & 0xF0) << UInt32(ch)
        }
        mbNz = outT
        leftNz = outL
        b.nonZeroY = nonZeroY
        b.nonZeroUV = nonZeroUV
        return nonZeroY | nonZeroUV == 0
    }

    // MARK: transforms (dsp/dec.c)

    @inline(__always) static func mul1(_ a: Int) -> Int { ((a * 20091) >> 16) + a }
    @inline(__always) static func mul2(_ a: Int) -> Int { (a * 35468) >> 16 }
    @inline(__always) static func clip8(_ v: Int) -> UInt8 { v & ~0xFF == 0 ? UInt8(v) : v < 0 ? 0 : 255 }
    @inline(__always) static func store(_ ws: inout [UInt8], _ i: Int, _ v: Int) { ws[i] = clip8(Int(ws[i]) + (v >> 3)) }

    static func transformWHT(_ input: [Int16], _ out: inout [Int16]) {
        var tmp = [Int](repeating: 0, count: 16)
        for i in 0..<4 {
            let a0 = Int(input[0 + i]) + Int(input[12 + i]), a1 = Int(input[4 + i]) + Int(input[8 + i])
            let a2 = Int(input[4 + i]) - Int(input[8 + i]), a3 = Int(input[0 + i]) - Int(input[12 + i])
            tmp[0 + i] = a0 + a1; tmp[8 + i] = a0 - a1; tmp[4 + i] = a3 + a2; tmp[12 + i] = a3 - a2
        }
        var o = 0
        for i in 0..<4 {
            let dc = tmp[0 + i * 4] + 3
            let a0 = dc + tmp[3 + i * 4], a1 = tmp[1 + i * 4] + tmp[2 + i * 4]
            let a2 = tmp[1 + i * 4] - tmp[2 + i * 4], a3 = dc - tmp[3 + i * 4]
            out[o + 0] = Int16(truncatingIfNeeded: (a0 + a1) >> 3)
            out[o + 16] = Int16(truncatingIfNeeded: (a3 + a2) >> 3)
            out[o + 32] = Int16(truncatingIfNeeded: (a0 - a1) >> 3)
            out[o + 48] = Int16(truncatingIfNeeded: (a3 - a2) >> 3)
            o += 64
        }
    }

    static func transformOne(_ c: [Int16], _ ci: Int, _ ws: inout [UInt8], _ dst: Int) {
        var t = [Int](repeating: 0, count: 16)
        for i in 0..<4 {
            let i0 = Int(c[ci + i]), i4 = Int(c[ci + 4 + i]), i8 = Int(c[ci + 8 + i]), i12 = Int(c[ci + 12 + i])
            let a = i0 + i8, b = i0 - i8
            let cc = mul2(i4) - mul1(i12), d = mul1(i4) + mul2(i12)
            t[i * 4 + 0] = a + d; t[i * 4 + 1] = b + cc; t[i * 4 + 2] = b - cc; t[i * 4 + 3] = a - d
        }
        for i in 0..<4 {
            let dc = t[i] + 4
            let a = dc + t[8 + i], b = dc - t[8 + i]
            let cc = mul2(t[4 + i]) - mul1(t[12 + i]), d = mul1(t[4 + i]) + mul2(t[12 + i])
            let row = dst + i * BPS
            store(&ws, row + 0, a + d); store(&ws, row + 1, b + cc); store(&ws, row + 2, b - cc); store(&ws, row + 3, a - d)
        }
    }

    static func transformAC3(_ c: [Int16], _ ci: Int, _ ws: inout [UInt8], _ dst: Int) {
        let a = Int(c[ci]) + 4
        let c4 = mul2(Int(c[ci + 4])), d4 = mul1(Int(c[ci + 4]))
        let c1 = mul2(Int(c[ci + 1])), d1 = mul1(Int(c[ci + 1]))
        func store2(_ y: Int, _ dcv: Int) {
            let r = dst + y * BPS
            store(&ws, r + 0, dcv + d1); store(&ws, r + 1, dcv + c1); store(&ws, r + 2, dcv - c1); store(&ws, r + 3, dcv - d1)
        }
        store2(0, a + d4); store2(1, a + c4); store2(2, a - c4); store2(3, a - d4)
    }

    static func transformDC(_ c: [Int16], _ ci: Int, _ ws: inout [UInt8], _ dst: Int) {
        let dcv = Int(c[ci]) + 4
        for j in 0..<4 { for i in 0..<4 { store(&ws, dst + i + j * BPS, dcv) } }
    }

    static func doTransform(_ bits: UInt32, _ c: [Int16], _ ci: Int, _ ws: inout [UInt8], _ dst: Int) {
        switch bits >> 30 {
        case 3: transformOne(c, ci, &ws, dst)
        case 2: transformAC3(c, ci, &ws, dst)
        case 1: transformDC(c, ci, &ws, dst)
        default: break
        }
    }

    static func doUVTransform(_ bits: UInt32, _ c: [Int16], _ ci: Int, _ ws: inout [UInt8], _ dst: Int) {
        guard bits & 0xFF != 0 else { return }
        if bits & 0xAA != 0 {
            transformOne(c, ci, &ws, dst); transformOne(c, ci + 16, &ws, dst + 4)
            transformOne(c, ci + 32, &ws, dst + 4 * BPS); transformOne(c, ci + 48, &ws, dst + 4 * BPS + 4)
        } else {
            if c[ci] != 0 { transformDC(c, ci, &ws, dst) }
            if c[ci + 16] != 0 { transformDC(c, ci + 16, &ws, dst + 4) }
            if c[ci + 32] != 0 { transformDC(c, ci + 32, &ws, dst + 4 * BPS) }
            if c[ci + 48] != 0 { transformDC(c, ci + 48, &ws, dst + 4 * BPS + 4) }
        }
    }

    // MARK: intra prediction (dsp/dec.c)

    @inline(__always) static func avg3(_ a: Int, _ b: Int, _ c: Int) -> UInt8 { UInt8((a + 2 * b + c + 2) >> 2) }
    @inline(__always) static func avg2(_ a: Int, _ b: Int) -> UInt8 { UInt8((a + b + 1) >> 1) }

    static func trueMotion(_ ws: inout [UInt8], _ d: Int, _ size: Int) {
        let tl = Int(ws[d - BPS - 1])
        for y in 0..<size {
            let l = Int(ws[d + y * BPS - 1])
            for x in 0..<size {
                let v = Int(ws[d - BPS + x]) + l - tl
                ws[d + y * BPS + x] = UInt8(max(0, min(255, v)))
            }
        }
    }

    static func fill(_ ws: inout [UInt8], _ d: Int, _ size: Int, _ v: UInt8) {
        for y in 0..<size { for x in 0..<size { ws[d + y * BPS + x] = v } }
    }

    /// 16x16 luma and 8x8 chroma modes: 0 DC, 1 TM, 2 V, 3 H (DC variants by availability).
    static func predictBlock(_ ws: inout [UInt8], _ d: Int, _ size: Int, _ mode: Int, _ mbX: Int, _ mbY: Int) {
        switch mode {
        case 1: trueMotion(&ws, d, size)
        case 2: for y in 0..<size { for x in 0..<size { ws[d + y * BPS + x] = ws[d - BPS + x] } }
        case 3: for y in 0..<size { let l = ws[d + y * BPS - 1]; for x in 0..<size { ws[d + y * BPS + x] = l } }
        default:
            let shift = size == 16 ? 4 : 3
            if mbX > 0 && mbY > 0 {
                var s = size
                for j in 0..<size { s += Int(ws[d - 1 + j * BPS]) + Int(ws[d + j - BPS]) }
                fill(&ws, d, size, UInt8(s >> (shift + 1)))
            } else if mbY > 0 {  // no left
                var s = size >> 1
                for i in 0..<size { s += Int(ws[d + i - BPS]) }
                fill(&ws, d, size, UInt8(s >> shift))
            } else if mbX > 0 {  // no top
                var s = size >> 1
                for j in 0..<size { s += Int(ws[d - 1 + j * BPS]) }
                fill(&ws, d, size, UInt8(s >> shift))
            } else {
                fill(&ws, d, size, 0x80)
            }
        }
    }

    static func predict4(_ ws: inout [UInt8], _ d: Int, _ mode: Int) {
        @inline(__always) func top(_ i: Int) -> Int { Int(ws[d - BPS + i]) }
        @inline(__always) func left(_ j: Int) -> Int { Int(ws[d - 1 + j * BPS]) }
        @inline(__always) func put(_ x: Int, _ y: Int, _ v: UInt8) { ws[d + x + y * BPS] = v }
        let X = top(-1)
        switch mode {
        case 0:  // DC
            var dc = 4
            for i in 0..<4 { dc += top(i) + left(i) }
            fill(&ws, d, 4, UInt8(dc >> 3))
        case 1: trueMotion(&ws, d, 4)
        case 2:  // VE (smoothed)
            let v = [avg3(X, top(0), top(1)), avg3(top(0), top(1), top(2)), avg3(top(1), top(2), top(3)), avg3(top(2), top(3), top(4))]
            for y in 0..<4 { for x in 0..<4 { put(x, y, v[x]) } }
        case 3:  // HE (smoothed)
            let A = X, B = left(0), C = left(1), D = left(2), E = left(3)
            let v = [avg3(A, B, C), avg3(B, C, D), avg3(C, D, E), avg3(D, E, E)]
            for y in 0..<4 { for x in 0..<4 { put(x, y, v[y]) } }
        case 4:  // RD
            let I = left(0), J = left(1), K = left(2), L = left(3), A = top(0), B = top(1), C = top(2), D = top(3)
            put(0, 3, avg3(J, K, L))
            let v1 = avg3(I, J, K); put(1, 3, v1); put(0, 2, v1)
            let v2 = avg3(X, I, J); put(2, 3, v2); put(1, 2, v2); put(0, 1, v2)
            let v3 = avg3(A, X, I); put(3, 3, v3); put(2, 2, v3); put(1, 1, v3); put(0, 0, v3)
            let v4 = avg3(B, A, X); put(3, 2, v4); put(2, 1, v4); put(1, 0, v4)
            let v5 = avg3(C, B, A); put(3, 1, v5); put(2, 0, v5)
            put(3, 0, avg3(D, C, B))
        case 5:  // VR
            let I = left(0), J = left(1), K = left(2), A = top(0), B = top(1), C = top(2), D = top(3)
            let a = avg2(X, A); put(0, 0, a); put(1, 2, a)
            let b = avg2(A, B); put(1, 0, b); put(2, 2, b)
            let cc = avg2(B, C); put(2, 0, cc); put(3, 2, cc)
            put(3, 0, avg2(C, D))
            put(0, 3, avg3(K, J, I)); put(0, 2, avg3(J, I, X))
            let e = avg3(I, X, A); put(0, 1, e); put(1, 3, e)
            let f = avg3(X, A, B); put(1, 1, f); put(2, 3, f)
            let g = avg3(A, B, C); put(2, 1, g); put(3, 3, g)
            put(3, 1, avg3(B, C, D))
        case 6:  // LD
            let A = top(0), B = top(1), C = top(2), D = top(3), E = top(4), F = top(5), G = top(6), H = top(7)
            put(0, 0, avg3(A, B, C))
            let v1 = avg3(B, C, D); put(1, 0, v1); put(0, 1, v1)
            let v2 = avg3(C, D, E); put(2, 0, v2); put(1, 1, v2); put(0, 2, v2)
            let v3 = avg3(D, E, F); put(3, 0, v3); put(2, 1, v3); put(1, 2, v3); put(0, 3, v3)
            let v4 = avg3(E, F, G); put(3, 1, v4); put(2, 2, v4); put(1, 3, v4)
            let v5 = avg3(F, G, H); put(3, 2, v5); put(2, 3, v5)
            put(3, 3, avg3(G, H, H))
        case 7:  // VL
            let A = top(0), B = top(1), C = top(2), D = top(3), E = top(4), F = top(5), G = top(6), H = top(7)
            put(0, 0, avg2(A, B))
            let a = avg2(B, C); put(1, 0, a); put(0, 2, a)
            let b = avg2(C, D); put(2, 0, b); put(1, 2, b)
            let cc = avg2(D, E); put(3, 0, cc); put(2, 2, cc)
            put(0, 1, avg3(A, B, C))
            let e = avg3(B, C, D); put(1, 1, e); put(0, 3, e)
            let f = avg3(C, D, E); put(2, 1, f); put(1, 3, f)
            let g = avg3(D, E, F); put(3, 1, g); put(2, 3, g)
            put(3, 2, avg3(E, F, G)); put(3, 3, avg3(F, G, H))
        case 8:  // HD
            let I = left(0), J = left(1), K = left(2), L = left(3), A = top(0), B = top(1), C = top(2)
            let a = avg2(I, X); put(0, 0, a); put(2, 1, a)
            let b = avg2(J, I); put(0, 1, b); put(2, 2, b)
            let cc = avg2(K, J); put(0, 2, cc); put(2, 3, cc)
            put(0, 3, avg2(L, K))
            put(3, 0, avg3(A, B, C)); put(2, 0, avg3(X, A, B))
            let e = avg3(I, X, A); put(1, 0, e); put(3, 1, e)
            let f = avg3(J, I, X); put(1, 1, f); put(3, 2, f)
            let g = avg3(K, J, I); put(1, 2, g); put(3, 3, g)
            put(1, 3, avg3(L, K, J))
        default:  // HU
            let I = left(0), J = left(1), K = left(2), L = left(3)
            put(0, 0, avg2(I, J))
            let a = avg2(J, K); put(2, 0, a); put(0, 1, a)
            let b = avg2(K, L); put(2, 1, b); put(0, 2, b)
            put(1, 0, avg3(I, J, K))
            let cc = avg3(J, K, L); put(3, 0, cc); put(1, 1, cc)
            let e = avg3(K, L, L); put(3, 1, e); put(1, 2, e)
            for (x, y) in [(3, 2), (2, 2), (0, 3), (1, 3), (2, 3), (3, 3)] { put(x, y, UInt8(L)) }
        }
    }

    // MARK: reconstruction (frame_dec.c ReconstructRow)

    static func reconstructRow(_ mbY: Int, _ row: inout [MBData], _ ws: inout [UInt8], _ f: inout VP8Frame,
                               _ topY: inout [[UInt8]], _ topU: inout [[UInt8]], _ topV: inout [[UInt8]]) {
        let y0 = yOff, u0 = uOff, v0 = vOff
        for j in 0..<16 { ws[y0 + j * BPS - 1] = 129 }
        for j in 0..<8 { ws[u0 + j * BPS - 1] = 129; ws[v0 + j * BPS - 1] = 129 }
        if mbY > 0 {
            ws[y0 - 1 - BPS] = 129; ws[u0 - 1 - BPS] = 129; ws[v0 - 1 - BPS] = 129
        } else {
            for i in 0..<21 { ws[y0 - BPS - 1 + i] = 127 }
            for i in 0..<9 { ws[u0 - BPS - 1 + i] = 127; ws[v0 - BPS - 1 + i] = 127 }
        }
        for mbX in 0..<f.mbW {
            let b = row[mbX]
            if mbX > 0 {
                for j in -1..<16 { for k in 0..<4 { ws[y0 + j * BPS - 4 + k] = ws[y0 + j * BPS + 12 + k] } }
                for j in -1..<8 {
                    for k in 0..<4 {
                        ws[u0 + j * BPS - 4 + k] = ws[u0 + j * BPS + 4 + k]
                        ws[v0 + j * BPS - 4 + k] = ws[v0 + j * BPS + 4 + k]
                    }
                }
            }
            if mbY > 0 {
                for i in 0..<16 { ws[y0 - BPS + i] = topY[mbX][i] }
                for i in 0..<8 { ws[u0 - BPS + i] = topU[mbX][i]; ws[v0 - BPS + i] = topV[mbX][i] }
            }
            var bits = b.nonZeroY
            if b.isI4x4 {
                let tr = y0 - BPS + 16
                if mbY > 0 {
                    if mbX >= f.mbW - 1 { for k in 0..<4 { ws[tr + k] = topY[mbX][15] } }
                    else { for k in 0..<4 { ws[tr + k] = topY[mbX + 1][k] } }
                }
                for r in 1...3 { for k in 0..<4 { ws[tr + r * 4 * BPS + k] = ws[tr + k] } }
                for n in 0..<16 {
                    let d = y0 + scan[n]
                    predict4(&ws, d, b.imodes[n])
                    doTransform(bits, b.coeffs, n * 16, &ws, d)
                    bits <<= 2
                }
            } else {
                predictBlock(&ws, y0, 16, b.imodes[0], mbX, mbY)
                if bits != 0 {
                    for n in 0..<16 { doTransform(bits, b.coeffs, n * 16, &ws, y0 + scan[n]); bits <<= 2 }
                }
            }
            predictBlock(&ws, u0, 8, b.uvmode, mbX, mbY)
            predictBlock(&ws, v0, 8, b.uvmode, mbX, mbY)
            doUVTransform(b.nonZeroUV, b.coeffs, 256, &ws, u0)
            doUVTransform(b.nonZeroUV >> 8, b.coeffs, 320, &ws, v0)
            if mbY < f.mbH - 1 {
                for i in 0..<16 { topY[mbX][i] = ws[y0 + 15 * BPS + i] }
                for i in 0..<8 { topU[mbX][i] = ws[u0 + 7 * BPS + i]; topV[mbX][i] = ws[v0 + 7 * BPS + i] }
            }
            let ys = f.yStride, uvs = f.uvStride
            for j in 0..<16 { for i in 0..<16 { f.y[(mbY * 16 + j) * ys + mbX * 16 + i] = ws[y0 + j * BPS + i] } }
            for j in 0..<8 {
                for i in 0..<8 {
                    f.u[(mbY * 8 + j) * uvs + mbX * 8 + i] = ws[u0 + j * BPS + i]
                    f.v[(mbY * 8 + j) * uvs + mbX * 8 + i] = ws[v0 + j * BPS + i]
                }
            }
        }
    }

    // MARK: loop filter (dsp/dec.c, frame_dec.c DoFilter)

    @inline(__always) static func sclip1(_ v: Int) -> Int { v < -128 ? -128 : v > 127 ? 127 : v }
    @inline(__always) static func sclip2(_ v: Int) -> Int { v < -16 ? -16 : v > 15 ? 15 : v }
    @inline(__always) static func clip1(_ v: Int) -> UInt8 { UInt8(v < 0 ? 0 : v > 255 ? 255 : v) }

    static func doFilter2(_ p: inout [UInt8], _ i: Int, _ s: Int) {
        let p1 = Int(p[i - 2 * s]), p0 = Int(p[i - s]), q0 = Int(p[i]), q1 = Int(p[i + s])
        let a = 3 * (q0 - p0) + sclip1(p1 - q1)
        let a1 = sclip2((a + 4) >> 3), a2 = sclip2((a + 3) >> 3)
        p[i - s] = clip1(p0 + a2)
        p[i] = clip1(q0 - a1)
    }

    static func doFilter4(_ p: inout [UInt8], _ i: Int, _ s: Int) {
        let p1 = Int(p[i - 2 * s]), p0 = Int(p[i - s]), q0 = Int(p[i]), q1 = Int(p[i + s])
        let a = 3 * (q0 - p0)
        let a1 = sclip2((a + 4) >> 3), a2 = sclip2((a + 3) >> 3)
        let a3 = (a1 + 1) >> 1
        p[i - 2 * s] = clip1(p1 + a3); p[i - s] = clip1(p0 + a2)
        p[i] = clip1(q0 - a1); p[i + s] = clip1(q1 - a3)
    }

    static func doFilter6(_ p: inout [UInt8], _ i: Int, _ s: Int) {
        let p2 = Int(p[i - 3 * s]), p1 = Int(p[i - 2 * s]), p0 = Int(p[i - s])
        let q0 = Int(p[i]), q1 = Int(p[i + s]), q2 = Int(p[i + 2 * s])
        let a = sclip1(3 * (q0 - p0) + sclip1(p1 - q1))
        let a1 = (27 * a + 63) >> 7, a2 = (18 * a + 63) >> 7, a3 = (9 * a + 63) >> 7
        p[i - 3 * s] = clip1(p2 + a3); p[i - 2 * s] = clip1(p1 + a2); p[i - s] = clip1(p0 + a1)
        p[i] = clip1(q0 - a1); p[i + s] = clip1(q1 - a2); p[i + 2 * s] = clip1(q2 - a3)
    }

    @inline(__always) static func hev(_ p: [UInt8], _ i: Int, _ s: Int, _ t: Int) -> Bool {
        abs(Int(p[i - 2 * s]) - Int(p[i - s])) > t || abs(Int(p[i + s]) - Int(p[i])) > t
    }
    @inline(__always) static func needsFilter(_ p: [UInt8], _ i: Int, _ s: Int, _ t: Int) -> Bool {
        4 * abs(Int(p[i - s]) - Int(p[i])) + abs(Int(p[i - 2 * s]) - Int(p[i + s])) <= t
    }
    @inline(__always) static func needsFilter2(_ p: [UInt8], _ i: Int, _ s: Int, _ t: Int, _ it: Int) -> Bool {
        let p3 = Int(p[i - 4 * s]), p2 = Int(p[i - 3 * s]), p1 = Int(p[i - 2 * s]), p0 = Int(p[i - s])
        let q0 = Int(p[i]), q1 = Int(p[i + s]), q2 = Int(p[i + 2 * s]), q3 = Int(p[i + 3 * s])
        if 4 * abs(p0 - q0) + abs(p1 - q1) > t { return false }
        return abs(p3 - p2) <= it && abs(p2 - p1) <= it && abs(p1 - p0) <= it
            && abs(q3 - q2) <= it && abs(q2 - q1) <= it && abs(q1 - q0) <= it
    }

    static func simpleFilter(_ p: inout [UInt8], _ i: Int, _ hstep: Int, _ vstep: Int, _ thresh: Int) {
        let t2 = 2 * thresh + 1
        for k in 0..<16 where needsFilter(p, i + k * vstep, hstep, t2) { doFilter2(&p, i + k * vstep, hstep) }
    }

    static func filterLoop(_ p: inout [UInt8], _ i: Int, _ hstep: Int, _ vstep: Int, _ size: Int,
                           _ thresh: Int, _ ithresh: Int, _ hevT: Int, six: Bool) {
        let t2 = 2 * thresh + 1
        for k in 0..<size {
            let pos = i + k * vstep
            if needsFilter2(p, pos, hstep, t2, ithresh) {
                if hev(p, pos, hstep, hevT) { doFilter2(&p, pos, hstep) }
                else if six { doFilter6(&p, pos, hstep) }
                else { doFilter4(&p, pos, hstep) }
            }
        }
    }

    static func loopFilter(_ f: inout VP8Frame, _ info: [FInfo], simple: Bool) {
        let ys = f.yStride, uvs = f.uvStride
        for mbY in 0..<f.mbH {
            for mbX in 0..<f.mbW {
                let fi = info[mbY * f.mbW + mbX]
                let limit = fi.limit
                guard limit != 0 else { continue }
                let y = (mbY * 16) * ys + mbX * 16
                if simple {
                    if mbX > 0 { simpleFilter(&f.y, y, 1, ys, limit + 4) }
                    if fi.inner { for k in 1...3 { simpleFilter(&f.y, y + 4 * k, 1, ys, limit) } }
                    if mbY > 0 { simpleFilter(&f.y, y, ys, 1, limit + 4) }
                    if fi.inner { for k in 1...3 { simpleFilter(&f.y, y + 4 * k * ys, ys, 1, limit) } }
                } else {
                    let uv = (mbY * 8) * uvs + mbX * 8
                    let il = fi.ilevel, ht = fi.hevThresh
                    if mbX > 0 {
                        filterLoop(&f.y, y, 1, ys, 16, limit + 4, il, ht, six: true)
                        filterLoop(&f.u, uv, 1, uvs, 8, limit + 4, il, ht, six: true)
                        filterLoop(&f.v, uv, 1, uvs, 8, limit + 4, il, ht, six: true)
                    }
                    if fi.inner {
                        for k in 1...3 { filterLoop(&f.y, y + 4 * k, 1, ys, 16, limit, il, ht, six: false) }
                        filterLoop(&f.u, uv + 4, 1, uvs, 8, limit, il, ht, six: false)
                        filterLoop(&f.v, uv + 4, 1, uvs, 8, limit, il, ht, six: false)
                    }
                    if mbY > 0 {
                        filterLoop(&f.y, y, ys, 1, 16, limit + 4, il, ht, six: true)
                        filterLoop(&f.u, uv, uvs, 1, 8, limit + 4, il, ht, six: true)
                        filterLoop(&f.v, uv, uvs, 1, 8, limit + 4, il, ht, six: true)
                    }
                    if fi.inner {
                        for k in 1...3 { filterLoop(&f.y, y + 4 * k * ys, ys, 1, 16, limit, il, ht, six: false) }
                        filterLoop(&f.u, uv + 4 * uvs, uvs, 1, 8, limit, il, ht, six: false)
                        filterLoop(&f.v, uv + 4 * uvs, uvs, 1, 8, limit, il, ht, six: false)
                    }
                }
            }
        }
    }
}
