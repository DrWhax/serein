// Scaling and transformation (H.265 8.6.2 – 8.6.4): dequantisation of TransCoeffLevel with
// the flat or scaling-list factor m, the inverse DCT (4 … 32 points, the 32-point matrix of
// 8.6.4.2 subsampled), the 4x4 DST for intra luma, transform skip, and the final shift.

enum HEVCTransform {
    /// |transMatrix| entries by cosine index j = (k·(2n+1)) mod 128 reduced to 0…32 (8.6.4.2).
    static let magnitudes: [Int32] = [64, 90, 90, 90, 89, 88, 87, 85, 83, 82, 80, 78, 75, 73, 70, 67, 64, 61, 57, 54, 50, 46, 43, 38,
                                      36, 31, 25, 22, 18, 13, 9, 4, 0]

    /// transMatrix (32x32, row = frequency k, column = sample n).
    static let matrix32: [Int32] = {
        var m = [Int32](repeating: 0, count: 32 * 32)
        for k in 0..<32 {
            for n in 0..<32 {
                var j = (k * (2 * n + 1)) % 128
                var sign: Int32 = 1
                if j > 64 { j = 128 - j; sign = -1 }    // cos(2π − a) = cos a, then the half turn flips
                if j > 32 { j = 64 - j; sign = -sign }
                m[k * 32 + n] = k == 0 ? 64 : sign * magnitudes[j]
            }
        }
        // The half-turn fold above flips the sign of every cosine past π; undo for j in (64, 128]
        // by recomputing from the true cosine sign.
        for k in 0..<32 {
            for n in 0..<32 {
                let j = (k * (2 * n + 1)) % 128
                let c = cosSign(j)
                let mag = abs(m[k * 32 + n])
                m[k * 32 + n] = k == 0 ? 64 : c * mag
            }
        }
        return m
    }()

    /// The sign of cos(j·π/64).
    static func cosSign(_ j: Int) -> Int32 {
        let r = j % 128
        if r == 32 || r == 96 { return 0 }
        return r < 32 || r > 96 ? 1 : -1
    }

    static let dst4: [Int32] = [29, 55, 74, 84, 74, 74, 0, -74, 84, -29, -74, 55, 55, -84, 74, -29]

    static let levelScale: [Int32] = [40, 45, 51, 57, 64, 72]

    /// 8.6.3: scaled coefficients d from levels (in place), raster order (x + y·n).
    static func dequantize(_ c: inout [Int32], log2Size: Int, qp: Int, bitDepth: Int, factors: [Int32]?) {
        let n = 1 << log2Size
        let bdShift = bitDepth + log2Size - 5
        let scale = levelScale[qp % 6] << (qp / 6)
        let round = Int64(1) << (bdShift - 1)
        if factors == nil {
            var cs = c.mutableSpan
            let m = 16 * Int64(scale)
            for i in 0..<(n * n) where cs[i] != 0 {
                cs[i] = Int32(max(-32768, min(32767, (Int64(cs[i]) * m + round) >> bdShift)))
            }
            return
        }
        for i in 0..<(n * n) where c[i] != 0 {
            let m = Int64(factors?[i] ?? 16)
            let v = (Int64(c[i]) * m * Int64(scale) + round) >> bdShift
            c[i] = Int32(max(-32768, min(32767, v)))
        }
    }

    /// The m[x][y] factors of a scaling list (8.6.4.1 / 7.4.5), raster order.
    static func scalingFactors(_ l: HEVCScalingList, log2Size: Int, matrixId: Int) -> [Int32] {
        let n = 1 << log2Size
        var out = [Int32](repeating: 16, count: n * n)
        let sizeId = log2Size - 2
        let list = l.lists[sizeId][matrixId]
        switch sizeId {
        case 0:
            for (i, p) in HEVCScan.order[2][0].enumerated() { out[Int(p.x) + Int(p.y) * 4] = Int32(list[i]) }
        default:
            let ratio = n / 8
            for (i, p) in HEVCScan.order[3][0].enumerated() {
                for dy in 0..<ratio { for dx in 0..<ratio { out[Int(p.x) * ratio + dx + (Int(p.y) * ratio + dy) * n] = Int32(list[i]) } }
            }
            if sizeId >= 2 { out[0] = Int32(l.dc[sizeId][matrixId]) }
        }
        return out
    }

    /// 8.6.4.2 / 8.6.2 step 3–4: residual (raster, x + y·n) from the scaled coefficients `d`,
    /// with `work` (n·n) for the vertical pass.
    static func inverse(_ dArr: [Int32], into rArr: inout [Int32], work eArr: inout [Int32], log2Size: Int, bitDepth: Int, dst4x4: Bool, transformSkip: Bool) {
        let n = 1 << log2Size
        let d = dArr.span
        var r = rArr.mutableSpan, e = eArr.mutableSpan
        let bdShift = Int32(max(20 - bitDepth, 0))
        let round = Int32(1) << (bdShift - 1)
        if transformSkip {
            let ts = Int32(5 + log2Size)
            var i = 0
            while i < n * n { r[i] = (d[i] << ts + round) >> bdShift; i += 1 }
            return
        }
        // The extent of nonzero coefficients bounds both passes.
        var lastRow = -1, lastCol = -1
        var y = 0
        while y < n {
            var x = 0
            while x < n { if d[x + y * n] != 0 { if y > lastRow { lastRow = y }; if x > lastCol { lastCol = x } }; x += 1 }
            y += 1
        }
        var i = 0
        guard lastRow >= 0 else { while i < n * n { r[i] = 0; i += 1 }; return }
        // DC only: every residual sample is the same.
        if lastRow == 0 && lastCol == 0 && !dst4x4 {
            let e0 = max(-32768, min(32767, (d[0] &* 64 &+ 64) >> 7))
            let v = (e0 &* 64 &+ round) >> bdShift
            i = 0
            while i < n * n { r[i] = v; i += 1 }
            return
        }
        if dst4x4 {
            // DST 4x4 (intra luma): the plain matrix product.
            var x = 0
            while x <= lastCol {
                var yy = 0
                while yy < 4 {
                    var s: Int32 = 0
                    var j = 0
                    while j <= lastRow { s &+= dst4[j * 4 + yy] &* d[x + j * 4]; j += 1 }
                    e[x + yy * 4] = max(-32768, min(32767, (s &+ 64) >> 7))
                    yy += 1
                }
                x += 1
            }
            y = 0
            while y < 4 {
                var xx = 0
                while xx < 4 {
                    var s: Int32 = 0
                    var j = 0
                    while j <= lastCol { s &+= dst4[j * 4 + xx] &* e[j + y * 4]; j += 1 }
                    r[xx + y * 4] = (s &+ round) >> bdShift
                    xx += 1
                }
                y += 1
            }
            return
        }
        var col = InlineArray<32, Int32>(repeating: 0), v = InlineArray<32, Int32>(repeating: 0), out = InlineArray<32, Int32>(repeating: 0)
        // Vertical pass, column by column (only columns up to lastCol hold coefficients).
        var x = 0
        while x <= lastCol {
            var j = 0
            while j < n { col[j] = j <= lastRow ? d[x + j * n] : 0; j += 1 }
            butterfly(col, n: n, last: lastRow, v: &v, out: &out)
            var yy = 0
            while yy < n { e[x + yy * n] = max(-32768, min(32767, (out[yy] &+ 64) >> 7)); yy += 1 }
            x += 1
        }
        // Horizontal pass, row by row over e[0…lastCol][y].
        y = 0
        while y < n {
            var j = 0
            while j < n { col[j] = j <= lastCol ? e[j + y * n] : 0; j += 1 }
            butterfly(col, n: n, last: lastCol, v: &v, out: &out)
            var xx = 0
            while xx < n { r[xx + y * n] = (out[xx] &+ round) >> bdShift; xx += 1 }
            y += 1
        }
    }

    /// The n-point inverse DCT of `a` (coefficients 0…last nonzero) by the even / odd
    /// decomposition of the 8.6.4.2 matrix: the 4-point inverse of a[0], a[n/4], a[n/2],
    /// a[3n/4], then each doubling adds the odd rows' contribution. Result in `out[0..<n]`.
    @inline(__always) static func butterfly(_ a: borrowing InlineArray<32, Int32>, n: Int, last: Int, v: inout InlineArray<32, Int32>,
                                             out: inout InlineArray<32, Int32>) {
        let m32 = matrix32.span
        let q = n / 4
        let a0 = a[0], a1 = q <= last ? a[q] : 0, a2 = 2 * q <= last ? a[2 * q] : 0, a3 = 3 * q <= last ? a[3 * q] : 0
        let o0 = 83 &* a1 &+ 36 &* a3, o1 = 36 &* a1 &- 83 &* a3
        let e0 = 64 &* (a0 &+ a2), e1 = 64 &* (a0 &- a2)
        out[0] = e0 &+ o0; out[1] = e1 &+ o1; out[2] = e1 &- o1; out[3] = e0 &- o0
        var m = 8
        while m <= n {
            let stride = n / m, rowStep = 32 / m, half = m / 2
            var k = 0
            while k < half { v[k] = out[k]; k += 1 }
            k = 0
            while k < half {
                var o: Int32 = 0
                var i = 0
                while true {
                    let ci = stride * (2 * i + 1)
                    if ci > last || i >= half { break }
                    o &+= m32[(2 * i + 1) * rowStep * 32 + k] &* a[ci]
                    i += 1
                }
                out[k] = v[k] &+ o
                out[m - 1 - k] = v[k] &- o
                k += 1
            }
            m <<= 1
        }
    }
}
