// Baseline JPEG encoder, byte-identical to libjpeg-turbo's `cjpeg -quality Q
// [-sample 2x2|1x1] [-grayscale]` (C code paths: JSIMD_FORCENONE=1): islow FDCT,
// reciprocal quantisation, Annex K Huffman tables, JFIF 1.01 header.
//
// Alpha is composited over black (what Chromium's canvas toBlob('image/jpeg') does).

public import CodecCore

public enum JPEGEncoder {
    public enum Sampling: Sendable { case yuv420, yuv444, grayscale }

    // Annex K.1 tables, natural order.
    static let stdLuminance: [Int] = [
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
    ]
    static let stdChrominance: [Int] = [
        17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
    ]

    /// jcparam.c jpeg_quality_scaling + jpeg_add_quant_table (force_baseline).
    static func quantTable(_ base: [Int], quality: Int) -> [Int] {
        let q = max(1, min(100, quality))
        let scale = q < 50 ? 5000 / q : 200 - q * 2
        return base.map { max(1, min(255, ($0 * scale + 50) / 100)) }
    }

    public static func encode(_ image: PixelBuffer, quality: Int = 75, sampling: Sampling = .yuv420) -> [UInt8] {
        let W = image.width, H = image.height
        let ncomp = sampling == .grayscale ? 1 : 3
        let hs: [Int] = sampling == .yuv420 ? [2, 1, 1] : [1, 1, 1]
        let vs = hs
        let hmax = hs[0], vmax = vs[0]

        // Colour conversion (jccolor.c), alpha composited over black.
        var planes = [[UInt8]](repeating: [UInt8](repeating: 0, count: W * H), count: ncomp)
        for i in 0..<(W * H) {
            let a = Int(image.rgba[i * 4 + 3])
            func ch(_ k: Int) -> Int { a == 255 ? Int(image.rgba[i * 4 + k]) : (Int(image.rgba[i * 4 + k]) * a + 127) / 255 }
            let r = ch(0), g = ch(1), b = ch(2)
            if ncomp == 1 {
                planes[0][i] = UInt8((Color.ry[r] + Color.gy[g] + Color.by[b]) >> 16)
            } else {
                planes[0][i] = UInt8((Color.ry[r] + Color.gy[g] + Color.by[b]) >> 16)
                planes[1][i] = UInt8((Color.rcb[r] + Color.gcb[g] + Color.bcb[b]) >> 16)
                planes[2][i] = UInt8((Color.rcr[r] + Color.gcr[g] + Color.bcr[b]) >> 16)
            }
        }
        if ncomp == 1 {
            // Grey input: cjpeg reads PGM directly; Y of R=G=B is exactly that grey.
            for i in 0..<(W * H) where image.rgba[i * 4] == image.rgba[i * 4 + 1] && image.rgba[i * 4] == image.rgba[i * 4 + 2] && image.rgba[i * 4 + 3] == 255 {
                planes[0][i] = image.rgba[i * 4]
            }
        }

        let mcusPerRow = (W + 8 * hmax - 1) / (8 * hmax)
        let mcuRows = (H + 8 * vmax - 1) / (8 * vmax)
        let lumaQ = quantTable(stdLuminance, quality: quality), chromaQ = quantTable(stdChrominance, quality: quality)
        let divisors = [Quantizer(lumaQ), Quantizer(chromaQ)]
        let qIndex = [0, 1, 1]

        // Downsample + pad each component to whole blocks (jcsample.c / jcprepct.c).
        var comp: [(samples: [UInt8], stride: Int, wb: Int, hb: Int)] = []
        for c in 0..<ncomp {
            let dsW = (W * hs[c] + hmax - 1) / hmax
            let dsH = (H * vs[c] + vmax - 1) / vmax
            let wb = (dsW + 7) / 8, hb = (dsH + 7) / 8
            let stride = wb * 8
            let rows = mcuRows * vs[c] * 8
            var s = [UInt8](repeating: 0, count: stride * rows)
            // Source rows padded (expand_bottom_edge) to the row group, columns to stride*factor.
            @inline(__always) func src(_ x: Int, _ y: Int) -> Int {
                Int(planes[c][min(y, H - 1) * W + min(x, W - 1)])
            }
            let fx = hmax / hs[c], fy = vmax / vs[c]
            let realRows = (dsH + 0)
            for y in 0..<rows {
                let yy = min(y, (realRows + 0) - 1 + 0)  // rows past the real data replicate (expand_bottom_edge)
                for x in 0..<stride {
                    let v: Int
                    if fx == 1 && fy == 1 {
                        v = src(x, yy)
                    } else {
                        // h2v2_downsample: bias 1,2,1,2 per output column.
                        let bias = x & 1 == 0 ? 1 : 2
                        v = (src(2 * x, 2 * yy) + src(2 * x + 1, 2 * yy) + src(2 * x, 2 * yy + 1) + src(2 * x + 1, 2 * yy + 1) + bias) >> 2
                    }
                    s[y * stride + x] = UInt8(v)
                }
            }
            comp.append((s, stride, wb, hb))
        }

        // Entropy coding.
        var w = HuffmanWriter()
        var lastDC = [Int](repeating: 0, count: ncomp)
        var block = [Int](repeating: 0, count: 64)
        for my in 0..<mcuRows {
            for mx in 0..<mcusPerRow {
                for c in 0..<ncomp {
                    let tables = c == 0 ? (Huffman.dc0, Huffman.ac0) : (Huffman.dc1, Huffman.ac1)
                    var prevDCInMCU = 0
                    for v in 0..<vs[c] {
                        for h in 0..<hs[c] {
                            let bx = mx * hs[c] + h, by = my * vs[c] + v
                            if by >= comp[c].hb || bx >= comp[c].wb {
                                // Dummy block (jccoefct.c): zero AC, DC of the previous block in the MCU.
                                for k in 0..<64 { block[k] = 0 }
                                block[0] = prevDCInMCU
                            } else {
                                FDCT.islow(comp[c].samples, by * 8 * comp[c].stride + bx * 8, comp[c].stride, &block)
                                divisors[qIndex[c]].quantize(&block)
                            }
                            prevDCInMCU = block[0]
                            w.encodeBlock(block, &lastDC[c], dc: tables.0, ac: tables.1)
                        }
                    }
                }
            }
        }
        let scanData = w.finish()

        // Markers (jcmarker.c).
        var out: [UInt8] = [0xFF, 0xD8]
        out += [0xFF, 0xE0, 0x00, 0x10] + Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0]
        func dqt(_ index: Int, _ q: [Int]) {
            out += [0xFF, 0xDB, 0x00, 0x43, UInt8(index)]
            for k in 0..<64 { out.append(UInt8(q[JPEGZigzag.natural[k]])) }
        }
        dqt(0, lumaQ)
        if ncomp == 3 { dqt(1, chromaQ) }
        out += [0xFF, 0xC0] + be16(8 + 3 * ncomp) + [8] + be16(H) + be16(W) + [UInt8(ncomp)]
        for c in 0..<ncomp { out += [UInt8(c + 1), UInt8(hs[c] << 4 | vs[c]), UInt8(qIndex[c])] }
        func dht(_ cls: Int, _ index: Int, _ spec: (counts: [Int], symbols: [UInt8])) {
            out += [0xFF, 0xC4] + be16(2 + 1 + 16 + spec.symbols.count) + [UInt8(cls << 4 | index)]
            out += spec.counts.map(UInt8.init) + spec.symbols
        }
        dht(0, 0, Huffman.specDC0); dht(1, 0, Huffman.specAC0)
        if ncomp == 3 { dht(0, 1, Huffman.specDC1); dht(1, 1, Huffman.specAC1) }
        out += [0xFF, 0xDA] + be16(6 + 2 * ncomp) + [UInt8(ncomp)]
        for c in 0..<ncomp { out += [UInt8(c + 1), c == 0 ? 0x00 : 0x11] }
        out += [0, 63, 0]
        out += scanData
        out += [0xFF, 0xD9]
        return out
    }

    static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
}

enum JPEGZigzag {
    static let natural: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]
}

// MARK: colour tables (jccolor.c rgb_ycc_start)

enum Color {
    static func fix(_ x: Double) -> Int { Int(x * Double(1 << 16) + 0.5) }
    static let oneHalf = 1 << 15
    static let cbcrOffset = 128 << 16
    static let ry = (0..<256).map { fix(0.29900) * $0 }
    static let gy = (0..<256).map { fix(0.58700) * $0 }
    static let by = (0..<256).map { fix(0.11400) * $0 + oneHalf }
    static let rcb = (0..<256).map { -fix(0.16874) * $0 }
    static let gcb = (0..<256).map { -fix(0.33126) * $0 }
    static let bcb = (0..<256).map { fix(0.50000) * $0 + cbcrOffset + oneHalf - 1 }
    static let rcr = bcb
    static let gcr = (0..<256).map { -fix(0.41869) * $0 }
    static let bcr = (0..<256).map { -fix(0.08131) * $0 }
}

// MARK: forward DCT (jfdctint.c) — DCTELEM is 16-bit in SIMD builds

enum FDCT {
    static let c0_298631336 = 2446, c0_390180644 = 3196, c0_541196100 = 4433, c0_765366865 = 6270
    static let c0_899976223 = 7373, c1_175875602 = 9633, c1_501321110 = 12299, c1_847759065 = 15137
    static let c1_961570560 = 16069, c2_053119869 = 16819, c2_562915447 = 20995, c3_072711026 = 25172
    @inline(__always) static func descale(_ x: Int, _ n: Int) -> Int { (x + (1 << (n - 1))) >> n }
    @inline(__always) static func s16(_ x: Int) -> Int { Int(Int16(truncatingIfNeeded: x)) }

    static func islow(_ s: [UInt8], _ base: Int, _ stride: Int, _ d: inout [Int]) {
        for r in 0..<8 { for c in 0..<8 { d[r * 8 + c] = Int(s[base + r * stride + c]) - 128 } }
        for pass in 0..<2 {
            for i in 0..<8 {
                let idx: (Int) -> Int = pass == 0 ? { i * 8 + $0 } : { $0 * 8 + i }
                let tmp0 = d[idx(0)] + d[idx(7)], tmp7 = d[idx(0)] - d[idx(7)]
                let tmp1 = d[idx(1)] + d[idx(6)], tmp6 = d[idx(1)] - d[idx(6)]
                let tmp2 = d[idx(2)] + d[idx(5)], tmp5 = d[idx(2)] - d[idx(5)]
                let tmp3 = d[idx(3)] + d[idx(4)], tmp4 = d[idx(3)] - d[idx(4)]
                let tmp10 = tmp0 + tmp3, tmp13 = tmp0 - tmp3, tmp11 = tmp1 + tmp2, tmp12 = tmp1 - tmp2
                let n = pass == 0 ? 13 - 2 : 13 + 2
                if pass == 0 {
                    d[idx(0)] = s16((tmp10 + tmp11) << 2)
                    d[idx(4)] = s16((tmp10 - tmp11) << 2)
                } else {
                    d[idx(0)] = s16(descale(tmp10 + tmp11, 2))
                    d[idx(4)] = s16(descale(tmp10 - tmp11, 2))
                }
                var z1 = (tmp12 + tmp13) * c0_541196100
                d[idx(2)] = s16(descale(z1 + tmp13 * c0_765366865, n))
                d[idx(6)] = s16(descale(z1 + tmp12 * -c1_847759065, n))
                z1 = tmp4 + tmp7
                var z2 = tmp5 + tmp6, z3 = tmp4 + tmp6, z4 = tmp5 + tmp7
                let z5 = (z3 + z4) * c1_175875602
                let t4 = tmp4 * c0_298631336, t5 = tmp5 * c2_053119869, t6 = tmp6 * c3_072711026, t7 = tmp7 * c1_501321110
                z1 *= -c0_899976223; z2 *= -c2_562915447; z3 *= -c1_961570560; z4 *= -c0_390180644
                z3 += z5; z4 += z5
                d[idx(7)] = s16(descale(t4 + z1 + z3, n))
                d[idx(5)] = s16(descale(t5 + z2 + z4, n))
                d[idx(3)] = s16(descale(t6 + z2 + z3, n))
                d[idx(1)] = s16(descale(t7 + z1 + z4, n))
            }
        }
    }
}

// MARK: quantisation (jcdctmgr.c compute_reciprocal / quantize, 16-bit DCTELEM)

struct Quantizer {
    var recip = [UInt32](repeating: 0, count: 64)
    var corr = [UInt32](repeating: 0, count: 64)
    var shift = [Int](repeating: 0, count: 64)

    init(_ q: [Int]) {
        for i in 0..<64 {
            let divisor = UInt32(q[i] << 3)
            let b = 31 - divisor.leadingZeroBitCount
            var r = 16 + b
            var fq = UInt32((UInt64(1) << UInt64(r)) / UInt64(divisor))
            let fr = UInt32((UInt64(1) << UInt64(r)) % UInt64(divisor))
            var c = divisor / 2
            if fr == 0 { fq >>= 1; r -= 1 }
            else if fr <= divisor / 2 { c += 1 }
            else { fq += 1 }
            recip[i] = UInt32(UInt16(truncatingIfNeeded: fq))
            corr[i] = UInt32(UInt16(truncatingIfNeeded: c))
            shift[i] = r - 16
        }
    }

    func quantize(_ d: inout [Int]) {
        for i in 0..<64 {
            var t = d[i]
            let neg = t < 0
            if neg { t = -t }
            let product = UInt32(truncatingIfNeeded: t + Int(corr[i])) &* recip[i]
            var v = Int(Int16(truncatingIfNeeded: product >> UInt32(shift[i] + 16)))
            if neg { v = -v }
            d[i] = Int(Int16(truncatingIfNeeded: v))
        }
    }
}

// MARK: Huffman (Annex K.3 tables, jchuff.c)

enum Huffman {
    static let specDC0: (counts: [Int], symbols: [UInt8]) = ([0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0], Array(0...11))
    static let specDC1: (counts: [Int], symbols: [UInt8]) = ([0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0], Array(0...11))
    static let specAC0: (counts: [Int], symbols: [UInt8]) = ([0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D], [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
        0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
        0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6,
        0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
        0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA])
    static let specAC1: (counts: [Int], symbols: [UInt8]) = ([0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77], [
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
        0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0, 0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34, 0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
        0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
        0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4,
        0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
        0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA])

    /// symbol → (code, length)
    static func table(_ spec: (counts: [Int], symbols: [UInt8])) -> [(UInt32, Int)] {
        var t = [(UInt32, Int)](repeating: (0, 0), count: 256)
        var code: UInt32 = 0, k = 0
        for len in 1...16 {
            for _ in 0..<spec.counts[len - 1] { t[Int(spec.symbols[k])] = (code, len); code += 1; k += 1 }
            code <<= 1
        }
        return t
    }
    static let dc0 = table(specDC0), dc1 = table(specDC1), ac0 = table(specAC0), ac1 = table(specAC1)
}

struct HuffmanWriter {
    var out: [UInt8] = []
    var buffer: UInt64 = 0
    var count = 0

    mutating func put(_ code: UInt32, _ n: Int) {
        guard n > 0 else { return }
        buffer = buffer << UInt64(n) | UInt64(code & ((1 << UInt32(n)) - 1))
        count += n
        while count >= 8 {
            let b = UInt8(truncatingIfNeeded: buffer >> UInt64(count - 8))
            out.append(b)
            if b == 0xFF { out.append(0) }
            count -= 8
        }
    }

    @inline(__always) static func nbits(_ v: Int) -> Int { v == 0 ? 0 : 64 - UInt64(v).leadingZeroBitCount }

    mutating func encodeBlock(_ block: [Int], _ lastDC: inout Int, dc: [(UInt32, Int)], ac: [(UInt32, Int)]) {
        var temp = block[0] - lastDC
        lastDC = block[0]
        var temp2 = temp
        if temp < 0 { temp = -temp; temp2 -= 1 }
        var n = Self.nbits(temp)
        put(dc[n].0, dc[n].1)
        put(UInt32(truncatingIfNeeded: temp2), n)
        var run = 0
        for k in 1..<64 {
            temp = block[JPEGZigzag.natural[k]]
            if temp == 0 { run += 1; continue }
            while run > 15 { put(ac[0xF0].0, ac[0xF0].1); run -= 16 }
            temp2 = temp
            if temp < 0 { temp = -temp; temp2 -= 1 }
            n = Self.nbits(temp)
            let sym = run << 4 + n
            put(ac[sym].0, ac[sym].1)
            put(UInt32(truncatingIfNeeded: temp2), n)
            run = 0
        }
        if run > 0 { put(ac[0].0, ac[0].1) }
    }

    /// Pad with 1-bits to a byte boundary (jchuff.c flush_bits).
    mutating func finish() -> [UInt8] {
        if count > 0 { put(0x7F, 8 - count) }
        return out
    }
}
