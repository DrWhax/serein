// The inverse transform process (7.13): butterfly B / Hadamard H, inverse DCT 4–64,
// ADST 4/8/16, identity 4–32, Walsh-Hadamard for lossless, and the 2D process with its
// row shift, intermediate clamp and column shift. Step numbers follow 7.13.2.3.

struct AV1InverseTransform {
    /// Dequant[ i ][ j ] at i * 64 + j (rows ≥ the nonzero count are treated as zero).
    var input = [Int](repeating: 0, count: 64 * 64)
    /// Residual[ i ][ j ] at i * 64 + j.
    var residual = [Int](repeating: 0, count: 64 * 64)
    var t = [Int](repeating: 0, count: 64)
    var copy = [Int](repeating: 0, count: 64)

    @inline(__always) static func brev(_ numBits: Int, _ x: Int) -> Int {
        var r = 0
        for i in 0..<numBits { r |= ((x >> i) & 1) << (numBits - 1 - i) }
        return r
    }

    @inline(__always) static func cos128(_ angle: Int) -> Int {
        let a = angle & 255
        let l = AV1C.cos128Lookup
        if a <= 64 { return l[a] }
        if a <= 128 { return -l[128 - a] }
        if a <= 192 { return -l[a - 128] }
        return l[256 - a]
    }

    @inline(__always) static func sin128(_ angle: Int) -> Int { cos128(angle - 64) }

    @inline(__always) mutating func b(_ a: Int, _ bb: Int, _ angle: Int, _ flip: Bool) {
        let x = t[a] * Self.cos128(angle) - t[bb] * Self.sin128(angle)
        let y = t[a] * Self.sin128(angle) + t[bb] * Self.cos128(angle)
        t[a] = round2(x, 12)
        t[bb] = round2(y, 12)
        if flip { t.swapAt(a, bb) }
    }

    @inline(__always) mutating func hd(_ a: Int, _ bb: Int, _ flip: Bool, _ r: Int) {
        let (p, q) = flip ? (bb, a) : (a, bb)
        let x = t[p], y = t[q]
        let lo = -(1 << (r - 1)), hi = (1 << (r - 1)) - 1
        t[p] = clip3(lo, hi, x + y)
        t[q] = clip3(lo, hi, x - y)
    }

    mutating func dct(_ n: Int, _ r: Int) {
        let n0 = 1 << n
        for i in 0..<n0 { copy[i] = t[i] }
        for i in 0..<n0 { t[i] = copy[Self.brev(n, i)] }
        typealias S = AV1InverseTransform
        if n == 6 { for i in 0..<16 { b(32 + i, 63 - i, 63 - 4 * S.brev(4, i), false) } }                     // 2
        if n >= 5 { for i in 0..<8 { b(16 + i, 31 - i, 6 + (S.brev(3, 7 - i) << 3), false) } }                // 3
        if n == 6 { for i in 0..<16 { hd(32 + i * 2, 33 + i * 2, i & 1 == 1, r) } }                           // 4
        if n >= 4 { for i in 0..<4 { b(8 + i, 15 - i, 12 + (S.brev(2, 3 - i) << 4), false) } }                // 5
        if n >= 5 { for i in 0..<8 { hd(16 + 2 * i, 17 + 2 * i, i & 1 == 1, r) } }                            // 6
        if n == 6 { for i in 0..<4 { for j in 0..<2 { b(62 - i * 4 - j, 33 + i * 4 + j, 60 - 16 * S.brev(2, i) + 64 * j, true) } } } // 7
        if n >= 3 { for i in 0..<2 { b(4 + i, 7 - i, 56 - 32 * i, false) } }                                 // 8
        if n >= 4 { for i in 0..<4 { hd(8 + 2 * i, 9 + 2 * i, i & 1 == 1, r) } }                              // 9
        if n >= 5 { for i in 0..<2 { for j in 0..<2 { b(30 - 4 * i - j, 17 + 4 * i + j, 24 + (j << 6) + ((1 - i) << 5), true) } } } // 10
        if n == 6 { for i in 0..<8 { for j in 0..<2 { hd(32 + i * 4 + j, 35 + i * 4 - j, i & 1 == 1, r) } } }  // 11
        for i in 0..<2 { b(2 * i, 2 * i + 1, 32 + 16 * i, i == 0) }                                           // 12
        if n >= 3 { for i in 0..<2 { hd(4 + 2 * i, 5 + 2 * i, i == 1, r) } }                                  // 13
        if n >= 4 { for i in 0..<2 { b(14 - i, 9 + i, 48 + 64 * i, true) } }                                  // 14
        if n >= 5 { for i in 0..<4 { for j in 0..<2 { hd(16 + 4 * i + j, 19 + 4 * i - j, i & 1 == 1, r) } } }  // 15
        if n == 6 { for i in 0..<2 { for j in 0..<4 { b(61 - i * 8 - j, 34 + i * 8 + j, 56 - i * 32 + (j >> 1) * 64, true) } } } // 16
        for i in 0..<2 { hd(i, 3 - i, false, r) }                                                             // 17
        if n >= 3 { b(6, 5, 32, true) }                                                                       // 18
        if n >= 4 { for i in 0..<2 { for j in 0..<2 { hd(8 + 4 * i + j, 11 + 4 * i - j, i == 1, r) } } }      // 19
        if n >= 5 { for i in 0..<4 { b(29 - i, 18 + i, 48 + (i >> 1) * 64, true) } }                          // 20
        if n == 6 { for i in 0..<4 { for j in 0..<4 { hd(32 + 8 * i + j, 39 + 8 * i - j, i & 1 == 1, r) } } }  // 21
        if n >= 3 { for i in 0..<4 { hd(i, 7 - i, false, r) } }                                               // 22
        if n >= 4 { for i in 0..<2 { b(13 - i, 10 + i, 32, true) } }                                          // 23
        if n >= 5 { for i in 0..<2 { for j in 0..<4 { hd(16 + i * 8 + j, 23 + i * 8 - j, i == 1, r) } } }      // 24
        if n == 6 { for i in 0..<8 { b(59 - i, 36 + i, i < 4 ? 48 : 112, true) } }                            // 25
        if n >= 4 { for i in 0..<8 { hd(i, 15 - i, false, r) } }                                              // 26
        if n >= 5 { for i in 0..<4 { b(27 - i, 20 + i, 32, true) } }                                          // 27
        if n == 6 {                                                                                           // 28
            for i in 0..<8 {
                hd(32 + i, 47 - i, false, r)
                hd(48 + i, 63 - i, true, r)
            }
        }
        if n >= 5 { for i in 0..<16 { hd(i, 31 - i, false, r) } }                                             // 29
        if n == 6 { for i in 0..<8 { b(55 - i, 40 + i, 32, true) } }                                          // 30
        if n == 6 { for i in 0..<32 { hd(i, 63 - i, false, r) } }                                             // 31
    }

    mutating func adstInputPermute(_ n: Int) {
        let n0 = 1 << n
        for i in 0..<n0 { copy[i] = t[i] }
        for i in 0..<n0 { t[i] = copy[(i & 1) != 0 ? i - 1 : n0 - i - 1] }
    }

    mutating func adstOutputPermute(_ n: Int) {
        let n0 = 1 << n
        for i in 0..<n0 { copy[i] = t[i] }
        for i in 0..<n0 {
            let a = (i >> 3) & 1
            let b = ((i >> 2) & 1) ^ ((i >> 3) & 1)
            let c = ((i >> 1) & 1) ^ ((i >> 2) & 1)
            let d = (i & 1) ^ ((i >> 1) & 1)
            let idx = ((d << 3) | (c << 2) | (b << 1) | a) >> (4 - n)
            t[i] = (i & 1) != 0 ? -copy[idx] : copy[idx]
        }
    }

    mutating func adst4() {
        let s1_9 = 1321, s2_9 = 2482, s3_9 = 3344, s4_9 = 3803
        var s0 = s1_9 * t[0], s1 = s2_9 * t[0], s2 = s3_9 * t[1], s3 = s4_9 * t[2]
        let s4 = s1_9 * t[2], s5 = s2_9 * t[3], s6 = s4_9 * t[3]
        let a7 = t[0] - t[2]
        let b7 = a7 + t[3]
        s0 = s0 + s3
        s1 = s1 - s4
        s3 = s2
        s2 = s3_9 * b7
        s0 = s0 + s5
        s1 = s1 - s6
        let x0 = s0 + s3, x1 = s1 + s3, x2 = s2
        var x3 = s0 + s1
        x3 = x3 - s3
        t[0] = round2(x0, 12)
        t[1] = round2(x1, 12)
        t[2] = round2(x2, 12)
        t[3] = round2(x3, 12)
    }

    mutating func adst8(_ r: Int) {
        adstInputPermute(3)
        for i in 0..<4 { b(2 * i, 2 * i + 1, 60 - 16 * i, true) }
        for i in 0..<4 { hd(i, 4 + i, false, r) }
        for i in 0..<2 { b(4 + 3 * i, 5 + i, 48 - 32 * i, true) }
        for i in 0..<2 { for j in 0..<2 { hd(4 * j + i, 2 + 4 * j + i, false, r) } }
        for i in 0..<2 { b(2 + 4 * i, 3 + 4 * i, 32, true) }
        adstOutputPermute(3)
    }

    mutating func adst16(_ r: Int) {
        adstInputPermute(4)
        for i in 0..<8 { b(2 * i, 2 * i + 1, 62 - 8 * i, true) }
        for i in 0..<8 { hd(i, 8 + i, false, r) }
        for i in 0..<2 {
            b(8 + 2 * i, 9 + 2 * i, 56 - 32 * i, true)
            b(13 + 2 * i, 12 + 2 * i, 8 + 32 * i, true)
        }
        for i in 0..<4 { for j in 0..<2 { hd(8 * j + i, 4 + 8 * j + i, false, r) } }
        for i in 0..<2 { for j in 0..<2 { b(4 + 8 * j + 3 * i, 5 + 8 * j + i, 48 - 32 * i, true) } }
        for i in 0..<2 { for j in 0..<4 { hd(4 * j + i, 2 + 4 * j + i, false, r) } }
        for i in 0..<4 { b(2 + 4 * i, 3 + 4 * i, 32, true) }
        adstOutputPermute(4)
    }

    mutating func adst(_ n: Int, _ r: Int) {
        if n == 2 { adst4() } else if n == 3 { adst8(r) } else { adst16(r) }
    }

    mutating func identity(_ n: Int) {
        switch n {
        case 2: for i in 0..<4 { t[i] = round2(t[i] * 5793, 12) }
        case 3: for i in 0..<8 { t[i] = t[i] * 2 }
        case 4: for i in 0..<16 { t[i] = round2(t[i] * 11586, 12) }
        default: for i in 0..<32 { t[i] = t[i] * 4 }
        }
    }

    mutating func wht(_ shift: Int) {
        var a = t[0] >> shift, c = t[1] >> shift, d = t[2] >> shift, bb = t[3] >> shift
        a += c
        d -= bb
        let e = (a - d) >> 1
        bb = e - bb
        c = e - c
        a -= bb
        d += c
        t[0] = a; t[1] = bb; t[2] = c; t[3] = d
    }

    static func rowKind(_ type: Int) -> Int {
        switch type {
        case AV1C.dctDct, AV1C.adstDct, AV1C.flipadstDct, AV1C.hDct: 0
        case AV1C.dctAdst, AV1C.adstAdst, AV1C.dctFlipadst, AV1C.flipadstFlipadst, AV1C.adstFlipadst, AV1C.flipadstAdst, AV1C.hAdst, AV1C.hFlipadst: 1
        default: 2
        }
    }

    static func colKind(_ type: Int) -> Int {
        switch type {
        case AV1C.dctDct, AV1C.dctAdst, AV1C.dctFlipadst, AV1C.vDct: 0
        case AV1C.adstDct, AV1C.adstAdst, AV1C.flipadstDct, AV1C.flipadstFlipadst, AV1C.adstFlipadst, AV1C.flipadstAdst, AV1C.vAdst, AV1C.vFlipadst: 1
        default: 2
        }
    }

    /// The 2D inverse transform (7.13.3).
    mutating func inverse2D(txSz: Int, txType: Int, lossless: Bool, bitDepth: Int, nonzeroRows: Int) {
        let log2W = AV1C.txWidthLog2[txSz], log2H = AV1C.txHeightLog2[txSz]
        let w = 1 << log2W, h = 1 << log2H
        let rowShift = lossless ? 0 : AV1C.transformRowShift[txSz]
        let colShift = lossless ? 0 : 4
        let rowClamp = bitDepth + 8
        let colClamp = max(bitDepth + 6, 16)
        let rk = Self.rowKind(txType), ck = Self.colKind(txType)
        let rect = abs(log2W - log2H) == 1
        let cLo = -(1 << (colClamp - 1)), cHi = (1 << (colClamp - 1)) - 1
        for i in 0..<h {
            if i >= nonzeroRows || i >= 32 {
                // A zero row stays zero through every row transform.
                for j in 0..<w { residual[i * 64 + j] = 0 }
                continue
            }
            for j in 0..<w { t[j] = j < 32 ? input[i * 64 + j] : 0 }
            if rect { for j in 0..<w { t[j] = round2(t[j] * 2896, 12) } }
            if lossless {
                wht(2)
            } else if rk == 0 {
                dct(log2W, rowClamp)
            } else if rk == 1 {
                adst(log2W, rowClamp)
            } else {
                identity(log2W)
            }
            for j in 0..<w { residual[i * 64 + j] = clip3(cLo, cHi, round2(t[j], rowShift)) }
        }
        for j in 0..<w {
            for i in 0..<h { t[i] = residual[i * 64 + j] }
            if lossless {
                wht(0)
            } else if ck == 0 {
                dct(log2H, colClamp)
            } else if ck == 1 {
                adst(log2H, colClamp)
            } else {
                identity(log2H)
            }
            for i in 0..<h { residual[i * 64 + j] = round2(t[i], colShift) }
        }
    }
}
