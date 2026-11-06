// Scaling and transforms (H.264 8.5.6 … 8.5.15): LevelScale tables from the scaling lists,
// the 4x4 and 8x8 inverse transforms, the Intra16x16 luma DC Hadamard and the 2x2 chroma DC.

struct H264Dequant: Sendable {
    /// levelScale4[list 0…5][qp % 6][raster 16], lists: Y/Cb/Cr intra, Y/Cb/Cr inter.
    var scale4: [[[Int32]]]
    /// levelScale8[list 0…1][qp % 6][raster 64], Y intra, Y inter.
    var scale8: [[[Int32]]]

    static let v4: [[Int32]] = [[10, 16, 13], [11, 18, 14], [13, 20, 16], [14, 23, 18], [16, 25, 20], [18, 29, 23]]
    static let v8: [[Int32]] = [[20, 18, 32, 19, 25, 24], [22, 19, 35, 21, 28, 26], [26, 23, 42, 24, 33, 31],
                                [28, 25, 45, 26, 35, 33], [32, 28, 51, 30, 40, 38], [36, 32, 58, 34, 46, 43]]

    init(lists4: [[UInt8]]?, lists8: [[UInt8]]?) {
        scale4 = (0 ..< 6).map { l in
            (0 ..< 6).map { m in
                (0 ..< 16).map { k in
                    let i = k >> 2, j = k & 3
                    let n: Int32 = (i & 1 == 0 && j & 1 == 0) ? Self.v4[m][0] : (i & 1 == 1 && j & 1 == 1) ? Self.v4[m][1] : Self.v4[m][2]
                    return Int32(lists4?[l][k] ?? 16) * n
                }
            }
        }
        scale8 = (0 ..< 2).map { l in
            (0 ..< 6).map { m in
                (0 ..< 64).map { k in
                    let i = k >> 3, j = k & 7
                    let c: Int
                    if i % 4 == 0 && j % 4 == 0 { c = 0 } else if i % 2 == 1 && j % 2 == 1 { c = 1 } else if i % 4 == 2 && j % 4 == 2 { c = 2 }
                    else if (i % 4 == 0 && j % 2 == 1) || (i % 2 == 1 && j % 4 == 0) { c = 3 }
                    else if (i % 4 == 0 && j % 4 == 2) || (i % 4 == 2 && j % 4 == 0) { c = 4 } else { c = 5 }
                    return Int32(lists8?[l][k] ?? 16) * Self.v8[m][c]
                }
            }
        }
    }

    /// Scales a 4x4 block's coefficients in place (raster), skipping index 0 when `skipDC`.
    @inline(__always) func dequant4(_ c: inout [Int32], at o: Int, list: Int, qp: Int, skipDC: Bool) {
        let ls = scale4[list][qp % 6], q6 = qp / 6
        for k in (skipDC ? 1 : 0) ..< 16 where c[o + k] != 0 {
            if q6 >= 4 { c[o + k] = (c[o + k] &* ls[k]) << (q6 - 4) } else { c[o + k] = (c[o + k] &* ls[k] + (1 << (3 - q6))) >> (4 - q6) }
        }
    }

    @inline(__always) func dequant8(_ c: inout [Int32], at o: Int, list: Int, qp: Int) {
        let ls = scale8[list][qp % 6], q6 = qp / 6
        for k in 0 ..< 64 where c[o + k] != 0 {
            if q6 >= 6 { c[o + k] = (c[o + k] &* ls[k]) << (q6 - 6) } else { c[o + k] = (c[o + k] &* ls[k] + (1 << (5 - q6))) >> (6 - q6) }
        }
    }
}

enum H264Transform {
    /// Inverse 4x4 transform of `c[o..<o+16]` (raster), added to the 4x4 block at `dst[p]`
    /// (stride `s`), clipped.
    @inline(__always) static func add4x4(_ c: [Int32], _ o: Int, _ dst: inout [UInt8], _ p: Int, _ s: Int) {
        var t = [Int32](repeating: 0, count: 16)
        for i in 0 ..< 4 {
            let d0 = c[o + i * 4], d1 = c[o + i * 4 + 1], d2 = c[o + i * 4 + 2], d3 = c[o + i * 4 + 3]
            let e0 = d0 &+ d2, e1 = d0 &- d2, e2 = (d1 >> 1) &- d3, e3 = d1 &+ (d3 >> 1)
            t[i * 4] = e0 &+ e3; t[i * 4 + 1] = e1 &+ e2; t[i * 4 + 2] = e1 &- e2; t[i * 4 + 3] = e0 &- e3
        }
        for j in 0 ..< 4 {
            let f0 = t[j], f1 = t[4 + j], f2 = t[8 + j], f3 = t[12 + j]
            let g0 = f0 &+ f2, g1 = f0 &- f2, g2 = (f1 >> 1) &- f3, g3 = f1 &+ (f3 >> 1)
            let r = [g0 &+ g3, g1 &+ g2, g1 &- g2, g0 &- g3]
            for i in 0 ..< 4 {
                let q = p + i * s + j
                dst[q] = clip255(Int32(dst[q]) &+ ((r[i] &+ 32) >> 6))
            }
        }
    }

    /// The 4x4 inverse transform of a DC-only block (all AC zero): adds (dc + 32) >> 6.
    @inline(__always) static func addDC4x4(_ dc: Int32, _ dst: inout [UInt8], _ p: Int, _ s: Int) {
        let v = (dc &+ 32) >> 6
        guard v != 0 else { return }
        for i in 0 ..< 4 { for j in 0 ..< 4 { dst[p + i * s + j] = clip255(Int32(dst[p + i * s + j]) &+ v) } }
    }

    static func add8x8(_ c: [Int32], _ o: Int, _ dst: inout [UInt8], _ p: Int, _ s: Int) {
        var t = [Int32](repeating: 0, count: 64)
        func row(_ d: [Int32]) -> [Int32] {
            let a0 = d[0] &+ d[4], a4 = d[0] &- d[4]
            let a2 = (d[2] >> 1) &- d[6], a6 = d[2] &+ (d[6] >> 1)
            let b0 = a0 &+ a6, b2 = a4 &+ a2, b4 = a4 &- a2, b6 = a0 &- a6
            let a1 = -d[3] &+ d[5] &- d[7] &- (d[7] >> 1)
            let a3 = d[1] &+ d[7] &- d[3] &- (d[3] >> 1)
            let a5 = -d[1] &+ d[7] &+ d[5] &+ (d[5] >> 1)
            let a7 = d[3] &+ d[5] &+ d[1] &+ (d[1] >> 1)
            let b1 = a1 &+ (a7 >> 2), b7 = a7 &- (a1 >> 2)
            let b3 = a3 &+ (a5 >> 2), b5 = (a3 >> 2) &- a5
            return [b0 &+ b7, b2 &+ b5, b4 &+ b3, b6 &+ b1, b6 &- b1, b4 &- b3, b2 &- b5, b0 &- b7]
        }
        for i in 0 ..< 8 {
            let r = row(Array(c[o + i * 8 ..< o + i * 8 + 8]))
            for j in 0 ..< 8 { t[i * 8 + j] = r[j] }
        }
        for j in 0 ..< 8 {
            let col = row((0 ..< 8).map { t[$0 * 8 + j] })
            for i in 0 ..< 8 {
                let q = p + i * s + j
                dst[q] = clip255(Int32(dst[q]) &+ ((col[i] &+ 32) >> 6))
            }
        }
    }

    /// Intra16x16 DC: Hadamard of the 16 DCs (raster of 4x4 block positions) and scaling.
    static func lumaDC(_ c: [Int32], scale: Int32, qp: Int) -> [Int32] {
        var t = [Int32](repeating: 0, count: 16), f = t
        for i in 0 ..< 4 {
            let a = c[i * 4], b = c[i * 4 + 1], cc = c[i * 4 + 2], d = c[i * 4 + 3]
            t[i * 4] = a &+ b &+ cc &+ d; t[i * 4 + 1] = a &+ b &- cc &- d; t[i * 4 + 2] = a &- b &- cc &+ d; t[i * 4 + 3] = a &- b &+ cc &- d
        }
        for j in 0 ..< 4 {
            let a = t[j], b = t[4 + j], cc = t[8 + j], d = t[12 + j]
            f[j] = a &+ b &+ cc &+ d; f[4 + j] = a &+ b &- cc &- d; f[8 + j] = a &- b &- cc &+ d; f[12 + j] = a &- b &+ cc &- d
        }
        let q6 = qp / 6
        return f.map { q6 >= 6 ? ($0 &* scale) << (q6 - 6) : ($0 &* scale &+ (1 << (5 - q6))) >> (6 - q6) }
    }

    /// Chroma DC 2x2: Hadamard and scaling.
    static func chromaDC(_ c: [Int32], scale: Int32, qp: Int) -> [Int32] {
        let f = [c[0] &+ c[1] &+ c[2] &+ c[3], c[0] &- c[1] &+ c[2] &- c[3], c[0] &+ c[1] &- c[2] &- c[3], c[0] &- c[1] &- c[2] &+ c[3]]
        return f.map { (($0 &* scale) << (qp / 6)) >> 5 }
    }
}

@inline(__always) func clip255(_ v: Int32) -> UInt8 { UInt8(truncatingIfNeeded: v < 0 ? 0 : v > 255 ? 255 : v) }
@inline(__always) func clip3(_ lo: Int, _ hi: Int, _ v: Int) -> Int { v < lo ? lo : v > hi ? hi : v }
