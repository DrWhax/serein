// Intra sample prediction (H.265 8.4.4.2): reference sample filtering (8.4.4.2.3, with strong
// intra smoothing), then planar (8.4.4.2.5), DC (8.4.4.2.6) or angular (8.4.4.2.6) prediction.
// References: `left[0]` = p[−1][−1], left[1 + y] = p[−1][y]; `top[0]` = p[−1][−1],
// top[1 + x] = p[x][−1]; each 2·nTbS + 1 long, already substituted (8.4.4.2.2).

enum HEVCIntraPred {
    static let angle: [Int] = [0, 0, 32, 26, 21, 17, 13, 9, 5, 2, 0, -2, -5, -9, -13, -17, -21, -26, -32, -26, -21, -17, -13, -9, -5, -2,
                               0, 2, 5, 9, 13, 17, 21, 26, 32]
    static let invAngle: [Int] = [-4096, -1638, -910, -630, -482, -390, -315, -256, -315, -390, -482, -630, -910, -1638, -4096]   // modes 11…25

    /// 8.4.4.2.3: [1 2 1] or strong (bilinear) filtering of the references, when the mode asks.
    static func filter(left: inout [Int32], top: inout [Int32], log2Size: Int, mode: Int, isLuma: Bool, strongSmoothing: Bool, bitDepth: Int) {
        let n = 1 << log2Size
        guard isLuma, mode != 1, n != 4 else { return }
        let minDist = min(abs(mode - 26), abs(mode - 10))
        let thres = n == 8 ? 7 : n == 16 ? 1 : 0
        guard minDist > thres else { return }
        let c = left[0]
        if strongSmoothing && n == 32 {
            let lim = Int32(1) << (bitDepth - 5)
            if abs(c + top[2 * n] - 2 * top[n]) < lim && abs(c + left[2 * n] - 2 * left[n]) < lim {
                let l63 = left[64], t63 = top[64]
                for y in 0..<63 { left[1 + y] = ((63 - Int32(y)) * c + (Int32(y) + 1) * l63 + 32) >> 6 }
                for x in 0..<63 { top[1 + x] = ((63 - Int32(x)) * c + (Int32(x) + 1) * t63 + 32) >> 6 }
                return
            }
        }
        let l = left, t = top
        let corner = (l[1] + 2 * c + t[1] + 2) >> 2
        for y in 0..<(2 * n - 1) { left[1 + y] = (l[y + 2] + 2 * l[1 + y] + l[y] + 2) >> 2 }
        for x in 0..<(2 * n - 1) { top[1 + x] = (t[x + 2] + 2 * t[1 + x] + t[x] + 2) >> 2 }
        left[0] = corner
        top[0] = corner
    }

    /// The predicted block (raster, x + y·n).
    static func predict(left: [Int32], top: [Int32], log2Size: Int, mode: Int, isLuma: Bool, bitDepth: Int,
                        disableBoundaryFilter: Bool = false) -> [Int32] {
        let n = 1 << log2Size
        var p = [Int32](repeating: 0, count: n * n)
        let maxV = (Int32(1) << bitDepth) - 1
        @inline(__always) func clip(_ v: Int32) -> Int32 { max(0, min(maxV, v)) }
        switch mode {
        case 0:    // planar
            let tr = top[1 + n], bl = left[1 + n]
            let shift = Int32(log2Size + 1)
            for y in 0..<n {
                for x in 0..<n {
                    let v = Int32(n - 1 - x) * left[1 + y] + Int32(x + 1) * tr + Int32(n - 1 - y) * top[1 + x] + Int32(y + 1) * bl + Int32(n)
                    p[x + y * n] = v >> shift
                }
            }
        case 1:    // DC
            var sum = Int32(n)
            for i in 0..<n { sum += top[1 + i] + left[1 + i] }
            let dc = sum >> Int32(log2Size + 1)
            for i in 0..<(n * n) { p[i] = dc }
            if isLuma && n < 32 {
                p[0] = (left[1] + 2 * dc + top[1] + 2) >> 2
                for x in 1..<n { p[x] = (top[1 + x] + 3 * dc + 2) >> 2 }
                for y in 1..<n { p[y * n] = (left[1 + y] + 3 * dc + 2) >> 2 }
            }
        default:
            let a = angle[mode]
            var ref = [Int32](repeating: 0, count: 3 * n + 2)
            let base = n    // ref[x] stored at ref[base + x], x from −n
            let vertical = mode >= 18
            let main = vertical ? top : left, side = vertical ? left : top
            for x in 0...n { ref[base + x] = main[x] }    // ref[x] = p[−1+x][−1] (vertical) = main[x]
            if a < 0 {
                let last = (n * a) >> 5
                if last < -1 {
                    let inv = invAngle[mode - 11]
                    for x in last...(-1) { ref[base + x] = side[(x * inv + 128) >> 8] }
                }
            } else {
                for x in (n + 1)...(2 * n) { ref[base + x] = main[x] }
            }
            for j in 0..<n {
                let pos = (j + 1) * a
                let idx = pos >> 5, fact = Int32(pos & 31)
                for i in 0..<n {
                    let r0 = ref[base + i + idx + 1]
                    let v = fact == 0 ? r0 : ((32 - fact) * r0 + fact * ref[base + i + idx + 2] + 16) >> 5
                    if vertical { p[i + j * n] = v } else { p[j + i * n] = v }
                }
            }
            if isLuma && n < 32 && !disableBoundaryFilter {
                if mode == 26 { for y in 0..<n { p[y * n] = clip(top[1] + ((left[1 + y] - left[0]) >> 1)) } }
                if mode == 10 { for x in 0..<n { p[x] = clip(left[1] + ((top[1 + x] - top[0]) >> 1)) } }
            }
        }
        return p
    }
}
