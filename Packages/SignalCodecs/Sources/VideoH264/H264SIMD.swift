// SIMD fast paths for the hot sample loops: luma and chroma interpolation and the prediction
// combine, for blocks away from the picture's edges (the scalar code handles the rest).
// Safe Swift only: lanes are read from spans one by one after a single bounds check per row,
// which the compiler turns into vector loads (about 6× the scalar loops). Same arithmetic as
// the scalar code, so the output is bit-identical.

enum Lanes {
    @inline(__always) static func u8x16(_ s: borrowing Span<UInt8>, _ i: Int) -> SIMD16<Int16> {
        _ = s[i + 15]
        return SIMD16<Int16>(truncatingIfNeeded: SIMD16<UInt8>(s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5], s[i + 6], s[i + 7],
                                                                s[i + 8], s[i + 9], s[i + 10], s[i + 11], s[i + 12], s[i + 13], s[i + 14], s[i + 15]))
    }

    @inline(__always) static func u8x8(_ s: borrowing Span<UInt8>, _ i: Int) -> SIMD8<Int16> {
        _ = s[i + 7]
        return SIMD8<Int16>(truncatingIfNeeded: SIMD8<UInt8>(s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5], s[i + 6], s[i + 7]))
    }

    @inline(__always) static func i32x16(_ s: borrowing Span<Int32>, _ i: Int) -> SIMD16<Int32> {
        _ = s[i + 15]
        return SIMD16<Int32>(s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5], s[i + 6], s[i + 7],
                             s[i + 8], s[i + 9], s[i + 10], s[i + 11], s[i + 12], s[i + 13], s[i + 14], s[i + 15])
    }

    @inline(__always) static func i32x8(_ s: borrowing Span<Int32>, _ i: Int) -> SIMD8<Int32> {
        _ = s[i + 7]
        return SIMD8<Int32>(s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5], s[i + 6], s[i + 7])
    }

    /// The first `n` (≤ 16) lanes into `d[i ..< i + n]`.
    @inline(__always) static func store(_ d: inout MutableSpan<Int32>, _ i: Int, _ v: SIMD16<Int16>, _ n: Int) {
        _ = d[i + n - 1]
        for k in 0 ..< n { d[i + k] = Int32(v[k]) }
    }

    @inline(__always) static func store(_ d: inout MutableSpan<Int32>, _ i: Int, _ v: SIMD16<Int32>, _ n: Int) {
        _ = d[i + n - 1]
        for k in 0 ..< n { d[i + k] = v[k] }
    }

    @inline(__always) static func store(_ d: inout MutableSpan<Int32>, _ i: Int, _ v: SIMD8<Int16>, _ n: Int) {
        _ = d[i + n - 1]
        for k in 0 ..< n { d[i + k] = Int32(v[k]) }
    }

    @inline(__always) static func store(_ d: inout MutableSpan<UInt8>, _ i: Int, _ v: SIMD16<Int32>, _ n: Int) {
        _ = d[i + n - 1]
        let b = SIMD16<UInt8>(truncatingIfNeeded: v)
        for k in 0 ..< n { d[i + k] = b[k] }
    }

    @inline(__always) static func store(_ d: inout MutableSpan<UInt8>, _ i: Int, _ v: SIMD8<Int32>, _ n: Int) {
        _ = d[i + n - 1]
        let b = SIMD8<UInt8>(truncatingIfNeeded: v)
        for k in 0 ..< n { d[i + k] = b[k] }
    }
}

extension H264PictureDecoder {
    /// The 6-tap filter of six rows or columns of samples (unclipped, unrounded).
    @inline(__always) static func tap6(_ a0: SIMD16<Int16>, _ a1: SIMD16<Int16>, _ a2: SIMD16<Int16>, _ a3: SIMD16<Int16>, _ a4: SIMD16<Int16>, _ a5: SIMD16<Int16>) -> SIMD16<Int16> {
        a0 &+ a5 &- 5 &* (a1 &+ a4) &+ 20 &* (a2 &+ a3)
    }

    @inline(__always) static func half(_ t: SIMD16<Int16>) -> SIMD16<Int16> {
        ((t &+ 16) &>> 5).clamped(lowerBound: .zero, upperBound: SIMD16(repeating: 255))
    }

    /// lumaMC for a block whose 16-wide source window (2 before, 3 after) is inside the
    /// picture: rows of 16 lanes, the first `w` kept. False (nothing written) otherwise.
    static func lumaMCFast(_ ref: YUVPicture, x0: Int, y0: Int, w: Int, h: Int, mvx: Int, mvy: Int, into out: inout [Int32]) -> Bool {
        let xi = x0 + (mvx >> 2), yi = y0 + (mvy >> 2), fx = mvx & 3, fy = mvy & 3
        let W = ref.width, H = ref.height
        guard w <= 16, xi - 2 >= 0, yi - 2 >= 0, xi + 16 + 3 <= W, yi + h + 3 <= H else { return false }
        let p = ref.y.span
        var o = out.mutableSpan
        @inline(__always) func row(_ y: Int, _ dx: Int) -> SIMD16<Int16> { Lanes.u8x16(p, (yi + y) * W + xi + dx) }
        @inline(__always) func hHalf(_ y: Int) -> SIMD16<Int16> { half(tap6(row(y, -2), row(y, -1), row(y, 0), row(y, 1), row(y, 2), row(y, 3))) }
        @inline(__always) func vHalf(_ y: Int, _ dx: Int) -> SIMD16<Int16> { half(tap6(row(y - 2, dx), row(y - 1, dx), row(y, dx), row(y + 1, dx), row(y + 2, dx), row(y + 3, dx))) }
        if fx == 0 && fy == 0 {
            for j in 0 ..< h { Lanes.store(&o, j * w, row(j, 0), w) }
            return true
        }
        if fy == 0 {
            for j in 0 ..< h {
                let b = hHalf(j)
                Lanes.store(&o, j * w, fx == 2 ? b : (b &+ row(j, fx == 1 ? 0 : 1) &+ 1) &>> 1, w)
            }
            return true
        }
        if fx == 0 {
            for j in 0 ..< h {
                let v = vHalf(j, 0)
                Lanes.store(&o, j * w, fy == 2 ? v : (v &+ row(fy == 1 ? j : j + 1, 0) &+ 1) &>> 1, w)
            }
            return true
        }
        if fx != 2 && fy != 2 {
            // Diagonal quarter positions: a horizontal and a vertical half sample averaged.
            for j in 0 ..< h {
                let b = hHalf(j + (fy == 3 ? 1 : 0)), v = vHalf(j, fx == 3 ? 1 : 0)
                Lanes.store(&o, j * w, (b &+ v &+ 1) &>> 1, w)
            }
            return true
        }
        // The centre j: vertical taps over the unclipped horizontal intermediates (Int32).
        @inline(__always) func mid(_ y: Int) -> SIMD16<Int32> { SIMD16<Int32>(truncatingIfNeeded: tap6(row(y, -2), row(y, -1), row(y, 0), row(y, 1), row(y, 2), row(y, 3))) }
        var m0 = mid(-2), m1 = mid(-1), m2 = mid(0), m3 = mid(1), m4 = mid(2)
        for j in 0 ..< h {
            let m5 = mid(j + 3)
            let jj = ((m0 &+ m5 &- 5 &* (m1 &+ m4) &+ 20 &* (m2 &+ m3) &+ 512) &>> 10).clamped(lowerBound: .zero, upperBound: SIMD16(repeating: 255))
            var v = jj
            if fx == 2 && fy != 2 {
                // f / q: with the horizontal half sample of row j (fy 1) or j + 1 (fy 3).
                let b = (((fy == 3 ? m3 : m2) &+ 16) &>> 5).clamped(lowerBound: .zero, upperBound: SIMD16(repeating: 255))
                v = (jj &+ b &+ 1) &>> 1
            } else if fy == 2 && fx != 2 {
                // i / k: with the vertical half sample of column i (fx 1) or i + 1 (fx 3).
                v = (jj &+ SIMD16<Int32>(truncatingIfNeeded: vHalf(j, fx == 3 ? 1 : 0)) &+ 1) &>> 1
            }
            Lanes.store(&o, j * w, v, w)
            (m0, m1, m2, m3, m4) = (m1, m2, m3, m4, m5)
        }
        return true
    }

    /// chromaMC for a block (w ≤ 8) whose 8-wide source rows (and the next column and row)
    /// are inside the plane. False (nothing written) otherwise.
    static func chromaMCFast(_ plane: [UInt8], width W: Int, height H: Int, x0: Int, y0: Int, w: Int, h: Int, mvx: Int, mvy: Int, into out: inout [Int32]) -> Bool {
        let xi = x0 + (mvx >> 3), yi = y0 + (mvy >> 3), fx = Int16(mvx & 7), fy = Int16(mvy & 7)
        guard w <= 8, xi >= 0, yi >= 0, xi + 8 + 1 <= W, yi + h + 1 <= H else { return false }
        let wa = SIMD8<Int16>(repeating: (8 - fx) * (8 - fy)), wb = SIMD8<Int16>(repeating: fx * (8 - fy))
        let wc = SIMD8<Int16>(repeating: (8 - fx) * fy), wd = SIMD8<Int16>(repeating: fx * fy)
        let p = plane.span
        var o = out.mutableSpan
        var a = Lanes.u8x8(p, yi * W + xi), b = Lanes.u8x8(p, yi * W + xi + 1)
        for j in 0 ..< h {
            let r = (yi + j + 1) * W + xi
            let c = Lanes.u8x8(p, r), d = Lanes.u8x8(p, r + 1)
            Lanes.store(&o, j * w, (wa &* a &+ wb &* b &+ wc &* c &+ wd &* d &+ 32) &>> 6, w)
            (a, b) = (c, d)
        }
        return true
    }
}

extension PredictionCombine {
    /// `store` for rows of 16 or 8 samples, a SIMD row at a time. False (nothing written) for
    /// other widths.
    static func storeFast(into dst: inout [UInt8], stride: Int, x: Int, y: Int, w: Int, h: Int, _ a: [Int32], _ b: [Int32], _ mode: PredictionCombine) -> Bool {
        guard w == 16 || w == 8 else { return false }
        var d = dst.mutableSpan
        let pa = a.span, pb = b.span
        let lo = SIMD16<Int32>(repeating: 0), hi = SIMD16<Int32>(repeating: 255)
        for j in 0 ..< h {
            let o = (y + j) * stride + x, s = j * w
            // Lanes past w (w == 8) are computed from the scratch beyond the row and dropped.
            let va = w == 16 ? Lanes.i32x16(pa, s) : SIMD16<Int32>(lowHalf: Lanes.i32x8(pa, s), highHalf: .zero)
            let r: SIMD16<Int32>
            switch mode {
            case .copy:
                r = va
            case .average:
                let vb = w == 16 ? Lanes.i32x16(pb, s) : SIMD16<Int32>(lowHalf: Lanes.i32x8(pb, s), highHalf: .zero)
                r = (va &+ vb &+ 1) &>> 1
            case .bi(let wt):
                let vb = w == 16 ? Lanes.i32x16(pb, s) : SIMD16<Int32>(lowHalf: Lanes.i32x8(pb, s), highHalf: .zero)
                let w0 = SIMD16(repeating: Int32(wt.w0)), w1 = SIMD16(repeating: Int32(wt.w1))
                let round = SIMD16(repeating: Int32(1 << wt.logWD)), shift = SIMD16(repeating: Int32(wt.logWD + 1))
                let offset = SIMD16(repeating: Int32((wt.o0 + wt.o1 + 1) >> 1))
                r = (((va &* w0 &+ vb &* w1 &+ round) &>> shift) &+ offset).clamped(lowerBound: lo, upperBound: hi)
            case .single(let wt, let l):
                let wl = SIMD16(repeating: Int32(l == 0 ? wt.w0 : wt.w1)), o0 = SIMD16(repeating: Int32(l == 0 ? wt.o0 : wt.o1))
                if wt.logWD >= 1 {
                    let round = SIMD16(repeating: Int32(1 << (wt.logWD - 1))), shift = SIMD16(repeating: Int32(wt.logWD))
                    r = (((va &* wl &+ round) &>> shift) &+ o0).clamped(lowerBound: lo, upperBound: hi)
                } else {
                    r = (va &* wl &+ o0).clamped(lowerBound: lo, upperBound: hi)
                }
            }
            Lanes.store(&d, o, r, w)
        }
        return true
    }
}
