// Intra prediction (H.264 8.3.1.2, 8.3.2.2, 8.3.3, 8.3.4): the nine 4x4 and 8x8 modes (8x8
// with reference sample filtering), the four 16x16 modes and the four chroma modes. The
// caller gathers the neighbouring samples with their availability; unavailable samples are
// never read.

struct IntraEdge {
    /// p[x, −1] for x = 0 … 2n−1 (top and top-right), p[−1, y] for y = 0 … n−1, p[−1, −1].
    var top: [Int32]
    var left: [Int32]
    var topLeft: Int32
    var hasTop: Bool, hasLeft: Bool, hasTopLeft: Bool, hasTopRight: Bool
}

enum H264Intra {
    static func gather(_ plane: [UInt8], stride: Int, x: Int, y: Int, n: Int, hasTop: Bool, hasLeft: Bool, hasTopLeft: Bool, hasTopRight: Bool) -> IntraEdge {
        var e = IntraEdge(top: Array(repeating: 0, count: 2 * n), left: Array(repeating: 0, count: n), topLeft: 0,
                          hasTop: hasTop, hasLeft: hasLeft, hasTopLeft: hasTopLeft, hasTopRight: hasTopRight)
        if hasTop {
            for i in 0 ..< n { e.top[i] = Int32(plane[(y - 1) * stride + x + i]) }
            for i in n ..< 2 * n { e.top[i] = hasTopRight ? Int32(plane[(y - 1) * stride + x + i]) : e.top[n - 1] }
        }
        if hasLeft { for j in 0 ..< n { e.left[j] = Int32(plane[(y + j) * stride + x - 1]) } }
        if hasTopLeft { e.topLeft = Int32(plane[(y - 1) * stride + x - 1]) }
        return e
    }

    /// Intra 4x4 (modes 0…8) into `pred` (16, raster). nil if the mode needs unavailable samples.
    static func predict4x4(_ mode: Int, _ e: IntraEdge) -> [Int32]? {
        var p = [Int32](repeating: 0, count: 16)
        let t = e.top, l = e.left, q = e.topLeft
        func set(_ x: Int, _ y: Int, _ v: Int32) { p[y * 4 + x] = v }
        switch mode {
        case 0: // vertical
            guard e.hasTop else { return nil }
            for y in 0 ..< 4 { for x in 0 ..< 4 { set(x, y, t[x]) } }
        case 1: // horizontal
            guard e.hasLeft else { return nil }
            for y in 0 ..< 4 { for x in 0 ..< 4 { set(x, y, l[y]) } }
        case 2: // DC
            var s: Int32
            if e.hasTop && e.hasLeft { s = (t[0] + t[1] + t[2] + t[3] + l[0] + l[1] + l[2] + l[3] + 4) >> 3 }
            else if e.hasLeft { s = (l[0] + l[1] + l[2] + l[3] + 2) >> 2 }
            else if e.hasTop { s = (t[0] + t[1] + t[2] + t[3] + 2) >> 2 }
            else { s = 128 }
            for i in 0 ..< 16 { p[i] = s }
        case 3: // diagonal down left
            guard e.hasTop else { return nil }
            for y in 0 ..< 4 {
                for x in 0 ..< 4 {
                    if x == 3 && y == 3 { set(x, y, (t[6] + 3 * t[7] + 2) >> 2) }
                    else { set(x, y, (t[x + y] + 2 * t[x + y + 1] + t[x + y + 2] + 2) >> 2) }
                }
            }
        case 4: // diagonal down right
            guard e.hasTop, e.hasLeft, e.hasTopLeft else { return nil }
            for y in 0 ..< 4 {
                for x in 0 ..< 4 {
                    if x > y { set(x, y, (at(t, l, q, x - y - 2, -1) + 2 * at(t, l, q, x - y - 1, -1) + t[x - y] + 2) >> 2) }
                    else if x < y { set(x, y, (at(t, l, q, -1, y - x - 2) + 2 * at(t, l, q, -1, y - x - 1) + l[y - x] + 2) >> 2) }
                    else { set(x, y, (t[0] + 2 * q + l[0] + 2) >> 2) }
                }
            }
        case 5: // vertical right
            guard e.hasTop, e.hasLeft, e.hasTopLeft else { return nil }
            for y in 0 ..< 4 {
                for x in 0 ..< 4 {
                    let z = 2 * x - y
                    let v: Int32
                    if z >= 0 && z & 1 == 0 { v = (at(t, l, q, x - (y >> 1) - 1, -1) + at(t, l, q, x - (y >> 1), -1) + 1) >> 1 }
                    else if z >= 0 { v = (at(t, l, q, x - (y >> 1) - 2, -1) + 2 * at(t, l, q, x - (y >> 1) - 1, -1) + at(t, l, q, x - (y >> 1), -1) + 2) >> 2 }
                    else if z == -1 { v = (l[0] + 2 * q + t[0] + 2) >> 2 }
                    else { v = (at(t, l, q, -1, y - 1) + 2 * at(t, l, q, -1, y - 2) + at(t, l, q, -1, y - 3) + 2) >> 2 }
                    set(x, y, v)
                }
            }
        case 6: // horizontal down
            guard e.hasTop, e.hasLeft, e.hasTopLeft else { return nil }
            for y in 0 ..< 4 {
                for x in 0 ..< 4 {
                    let z = 2 * y - x
                    let v: Int32
                    if z >= 0 && z & 1 == 0 { v = (at(t, l, q, -1, y - (x >> 1) - 1) + at(t, l, q, -1, y - (x >> 1)) + 1) >> 1 }
                    else if z >= 0 { v = (at(t, l, q, -1, y - (x >> 1) - 2) + 2 * at(t, l, q, -1, y - (x >> 1) - 1) + at(t, l, q, -1, y - (x >> 1)) + 2) >> 2 }
                    else if z == -1 { v = (l[0] + 2 * q + t[0] + 2) >> 2 }
                    else { v = (at(t, l, q, x - 1, -1) + 2 * at(t, l, q, x - 2, -1) + at(t, l, q, x - 3, -1) + 2) >> 2 }
                    set(x, y, v)
                }
            }
        case 7: // vertical left
            guard e.hasTop else { return nil }
            for y in 0 ..< 4 {
                for x in 0 ..< 4 {
                    let i = x + (y >> 1)
                    set(x, y, y & 1 == 0 ? (t[i] + t[i + 1] + 1) >> 1 : (t[i] + 2 * t[i + 1] + t[i + 2] + 2) >> 2)
                }
            }
        case 8: // horizontal up
            guard e.hasLeft else { return nil }
            for y in 0 ..< 4 {
                for x in 0 ..< 4 {
                    let z = x + 2 * y
                    let v: Int32
                    if z > 5 { v = l[3] }
                    else if z == 5 { v = (l[2] + 3 * l[3] + 2) >> 2 }
                    else if z & 1 == 0 { v = (l[y + (x >> 1)] + l[y + (x >> 1) + 1] + 1) >> 1 }
                    else { v = (l[y + (x >> 1)] + 2 * l[y + (x >> 1) + 1] + l[y + (x >> 1) + 2] + 2) >> 2 }
                    set(x, y, v)
                }
            }
        default:
            return nil
        }
        return p
    }

    /// p[x, y] for x = −1 or y = −1 from the edge arrays.
    @inline(__always) static func at(_ t: [Int32], _ l: [Int32], _ q: Int32, _ x: Int, _ y: Int) -> Int32 {
        if x == -1 && y == -1 { return q }
        if y == -1 { return t[x] }
        return l[y]
    }

    /// Intra 8x8 (8.3.2.2): filters the references, then predicts 64 samples (raster).
    static func predict8x8(_ mode: Int, _ e: IntraEdge) -> [Int32]? {
        // Reference sample filtering (8.3.2.2.1).
        var t = e.top, l = e.left, q = e.topLeft
        if e.hasTop {
            var ft = t
            ft[0] = e.hasTopLeft ? (q + 2 * t[0] + t[1] + 2) >> 2 : (3 * t[0] + t[1] + 2) >> 2
            for x in 1 ..< 15 { ft[x] = (t[x - 1] + 2 * t[x] + t[x + 1] + 2) >> 2 }
            ft[15] = (t[14] + 3 * t[15] + 2) >> 2
            t = ft
        }
        if e.hasTopLeft {
            if e.hasTop && e.hasLeft { q = (e.top[0] + 2 * e.topLeft + e.left[0] + 2) >> 2 }
            else if e.hasTop { q = (3 * e.topLeft + e.top[0] + 2) >> 2 }
            else if e.hasLeft { q = (3 * e.topLeft + e.left[0] + 2) >> 2 }
        }
        if e.hasLeft {
            var fl = l
            fl[0] = e.hasTopLeft ? (e.topLeft + 2 * l[0] + l[1] + 2) >> 2 : (3 * l[0] + l[1] + 2) >> 2
            for y in 1 ..< 7 { fl[y] = (l[y - 1] + 2 * l[y] + l[y + 1] + 2) >> 2 }
            fl[7] = (l[6] + 3 * l[7] + 2) >> 2
            l = fl
        }
        var p = [Int32](repeating: 0, count: 64)
        func set(_ x: Int, _ y: Int, _ v: Int32) { p[y * 8 + x] = v }
        switch mode {
        case 0:
            guard e.hasTop else { return nil }
            for y in 0 ..< 8 { for x in 0 ..< 8 { set(x, y, t[x]) } }
        case 1:
            guard e.hasLeft else { return nil }
            for y in 0 ..< 8 { for x in 0 ..< 8 { set(x, y, l[y]) } }
        case 2:
            var s: Int32 = 128
            if e.hasTop && e.hasLeft { s = (t[0 ..< 8].reduce(0, +) + l.reduce(0, +) + 8) >> 4 }
            else if e.hasLeft { s = (l.reduce(0, +) + 4) >> 3 }
            else if e.hasTop { s = (t[0 ..< 8].reduce(0, +) + 4) >> 3 }
            for i in 0 ..< 64 { p[i] = s }
        case 3:
            guard e.hasTop else { return nil }
            for y in 0 ..< 8 {
                for x in 0 ..< 8 {
                    set(x, y, x == 7 && y == 7 ? (t[14] + 3 * t[15] + 2) >> 2 : (t[x + y] + 2 * t[x + y + 1] + t[x + y + 2] + 2) >> 2)
                }
            }
        case 4:
            guard e.hasTop, e.hasLeft, e.hasTopLeft else { return nil }
            for y in 0 ..< 8 {
                for x in 0 ..< 8 {
                    if x > y { set(x, y, (at(t, l, q, x - y - 2, -1) + 2 * at(t, l, q, x - y - 1, -1) + t[x - y] + 2) >> 2) }
                    else if x < y { set(x, y, (at(t, l, q, -1, y - x - 2) + 2 * at(t, l, q, -1, y - x - 1) + l[y - x] + 2) >> 2) }
                    else { set(x, y, (t[0] + 2 * q + l[0] + 2) >> 2) }
                }
            }
        case 5:
            guard e.hasTop, e.hasLeft, e.hasTopLeft else { return nil }
            for y in 0 ..< 8 {
                for x in 0 ..< 8 {
                    let z = 2 * x - y
                    let v: Int32
                    if z >= 0 && z & 1 == 0 { v = (at(t, l, q, x - (y >> 1) - 1, -1) + at(t, l, q, x - (y >> 1), -1) + 1) >> 1 }
                    else if z >= 0 { v = (at(t, l, q, x - (y >> 1) - 2, -1) + 2 * at(t, l, q, x - (y >> 1) - 1, -1) + at(t, l, q, x - (y >> 1), -1) + 2) >> 2 }
                    else if z == -1 { v = (l[0] + 2 * q + t[0] + 2) >> 2 }
                    else { v = (at(t, l, q, -1, y - 2 * x - 1) + 2 * at(t, l, q, -1, y - 2 * x - 2) + at(t, l, q, -1, y - 2 * x - 3) + 2) >> 2 }
                    set(x, y, v)
                }
            }
        case 6:
            guard e.hasTop, e.hasLeft, e.hasTopLeft else { return nil }
            for y in 0 ..< 8 {
                for x in 0 ..< 8 {
                    let z = 2 * y - x
                    let v: Int32
                    if z >= 0 && z & 1 == 0 { v = (at(t, l, q, -1, y - (x >> 1) - 1) + at(t, l, q, -1, y - (x >> 1)) + 1) >> 1 }
                    else if z >= 0 { v = (at(t, l, q, -1, y - (x >> 1) - 2) + 2 * at(t, l, q, -1, y - (x >> 1) - 1) + at(t, l, q, -1, y - (x >> 1)) + 2) >> 2 }
                    else if z == -1 { v = (l[0] + 2 * q + t[0] + 2) >> 2 }
                    else { v = (at(t, l, q, x - 2 * y - 1, -1) + 2 * at(t, l, q, x - 2 * y - 2, -1) + at(t, l, q, x - 2 * y - 3, -1) + 2) >> 2 }
                    set(x, y, v)
                }
            }
        case 7:
            guard e.hasTop else { return nil }
            for y in 0 ..< 8 {
                for x in 0 ..< 8 {
                    let i = x + (y >> 1)
                    set(x, y, y & 1 == 0 ? (t[i] + t[i + 1] + 1) >> 1 : (t[i] + 2 * t[i + 1] + t[i + 2] + 2) >> 2)
                }
            }
        case 8:
            guard e.hasLeft else { return nil }
            for y in 0 ..< 8 {
                for x in 0 ..< 8 {
                    let z = x + 2 * y
                    let v: Int32
                    if z > 13 { v = l[7] }
                    else if z == 13 { v = (l[6] + 3 * l[7] + 2) >> 2 }
                    else if z & 1 == 0 { v = (l[y + (x >> 1)] + l[y + (x >> 1) + 1] + 1) >> 1 }
                    else { v = (l[y + (x >> 1)] + 2 * l[y + (x >> 1) + 1] + l[y + (x >> 1) + 2] + 2) >> 2 }
                    set(x, y, v)
                }
            }
        default:
            return nil
        }
        return p
    }

    /// Intra 16x16 (modes 0 V, 1 H, 2 DC, 3 plane) → 256 samples.
    static func predict16x16(_ mode: Int, _ e: IntraEdge) -> [Int32]? {
        var p = [Int32](repeating: 0, count: 256)
        let t = e.top, l = e.left
        switch mode {
        case 0:
            guard e.hasTop else { return nil }
            for y in 0 ..< 16 { for x in 0 ..< 16 { p[y * 16 + x] = t[x] } }
        case 1:
            guard e.hasLeft else { return nil }
            for y in 0 ..< 16 { for x in 0 ..< 16 { p[y * 16 + x] = l[y] } }
        case 2:
            var s: Int32 = 128
            if e.hasTop && e.hasLeft { s = (t[0 ..< 16].reduce(0, +) + l.reduce(0, +) + 16) >> 5 }
            else if e.hasLeft { s = (l.reduce(0, +) + 8) >> 4 }
            else if e.hasTop { s = (t[0 ..< 16].reduce(0, +) + 8) >> 4 }
            for i in 0 ..< 256 { p[i] = s }
        case 3:
            guard e.hasTop, e.hasLeft, e.hasTopLeft else { return nil }
            var hh: Int32 = 0, vv: Int32 = 0
            for i in 0 ..< 8 {
                hh += Int32(i + 1) * (t[8 + i] - (i == 7 ? e.topLeft : t[6 - i]))
                vv += Int32(i + 1) * (l[8 + i] - (i == 7 ? e.topLeft : l[6 - i]))
            }
            let a = 16 * (l[15] + t[15]), b = (5 * hh + 32) >> 6, c = (5 * vv + 32) >> 6
            for y in 0 ..< 16 { for x in 0 ..< 16 { p[y * 16 + x] = Int32(clip255((a + b * Int32(x - 7) + c * Int32(y - 7) + 16) >> 5)) } }
        default:
            return nil
        }
        return p
    }

    /// Chroma (4:2:0, 8x8; modes 0 DC, 1 H, 2 V, 3 plane) → 64 samples.
    static func predictChroma(_ mode: Int, _ e: IntraEdge) -> [Int32]? {
        var p = [Int32](repeating: 0, count: 64)
        let t = e.top, l = e.left
        switch mode {
        case 0:
            // Per 4x4 block (8.3.4.1-3): corner blocks use both edges when available.
            for by in 0 ..< 2 {
                for bx in 0 ..< 2 {
                    let st = t[bx * 4 ..< bx * 4 + 4].reduce(0, +), sl = l[by * 4 ..< by * 4 + 4].reduce(0, +)
                    var s: Int32 = 128
                    if (bx == 0 && by == 0) || (bx == 1 && by == 1) {
                        if e.hasTop && e.hasLeft { s = (st + sl + 4) >> 3 } else if e.hasTop { s = (st + 2) >> 2 } else if e.hasLeft { s = (sl + 2) >> 2 }
                    } else if bx == 1 && by == 0 {
                        if e.hasTop { s = (st + 2) >> 2 } else if e.hasLeft { s = (sl + 2) >> 2 }
                    } else {
                        if e.hasLeft { s = (sl + 2) >> 2 } else if e.hasTop { s = (st + 2) >> 2 }
                    }
                    for y in 0 ..< 4 { for x in 0 ..< 4 { p[(by * 4 + y) * 8 + bx * 4 + x] = s } }
                }
            }
        case 1:
            guard e.hasLeft else { return nil }
            for y in 0 ..< 8 { for x in 0 ..< 8 { p[y * 8 + x] = l[y] } }
        case 2:
            guard e.hasTop else { return nil }
            for y in 0 ..< 8 { for x in 0 ..< 8 { p[y * 8 + x] = t[x] } }
        case 3:
            guard e.hasTop, e.hasLeft, e.hasTopLeft else { return nil }
            var hh: Int32 = 0, vv: Int32 = 0
            for i in 0 ..< 4 {
                hh += Int32(i + 1) * (t[4 + i] - (i == 3 ? e.topLeft : t[2 - i]))
                vv += Int32(i + 1) * (l[4 + i] - (i == 3 ? e.topLeft : l[2 - i]))
            }
            let a = 16 * (l[7] + t[7]), b = (34 * hh + 32) >> 6, c = (34 * vv + 32) >> 6
            for y in 0 ..< 8 { for x in 0 ..< 8 { p[y * 8 + x] = Int32(clip255((a + b * Int32(x - 3) + c * Int32(y - 3) + 16) >> 5)) } }
        default:
            return nil
        }
        return p
    }
}
