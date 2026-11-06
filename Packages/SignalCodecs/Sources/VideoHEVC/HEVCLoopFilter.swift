// In-loop filters (H.265 8.7): the deblocking filter (8.7.2 — boundary strength, luma strong /
// weak filtering, chroma filtering; all vertical edges of the picture, then all horizontal
// ones) and sample adaptive offset (8.7.3 — band and edge offsets per CTB, reading the
// deblocked picture).

enum HEVCLoopFilter {
    static let betaTable: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 24,
                                   26, 28, 30, 32, 34, 36, 38, 40, 42, 44, 46, 48, 50, 52, 54, 56, 58, 60, 62, 64]
    static let tcTable: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4,
                                 5, 5, 6, 6, 7, 8, 9, 10, 11, 13, 14, 16, 18, 20, 22, 24]

    static func chromaQp(_ qpi: Int) -> Int {
        if qpi < 30 { return qpi }
        if qpi > 43 { return qpi - 6 }
        return [29, 30, 31, 32, 33, 33, 34, 34, 35, 35, 36, 36, 37, 37][qpi - 30]
    }

    static func apply(_ pic: inout HEVCPictureState, geometry: HEVCGeometry, pps: HEVCPPS) {
        let sps = pic.sps
        let anyDeblock = pic.ctbDeblockDisabled.contains(false)
        if anyDeblock {
            let bsV = boundaryStrengths(pic, geometry: geometry, pps: pps, vertical: true)
            let bsH = boundaryStrengths(pic, geometry: geometry, pps: pps, vertical: false)
            deblockBands(&pic, bs: bsV, vertical: true, pps: pps, geometry: geometry)
            deblockBands(&pic, bs: bsH, vertical: false, pps: pps, geometry: geometry)
        }
        if sps.saoEnabled && pic.sao.contains(where: { $0.contains { $0.type != 0 } }) {
            applySAO(&pic, geometry: geometry, pps: pps)
        }
    }

    // MARK: boundary strength (8.7.2.3, 8.7.2.4)

    /// bS per 4x4 unit for the edge on its left (vertical) or top (horizontal) side; 0 off-grid.
    static func boundaryStrengths(_ pic: HEVCPictureState, geometry g: HEVCGeometry, pps: HEVCPPS, vertical: Bool) -> [UInt8] {
        let sps = pic.sps
        var bs = [UInt8](repeating: 0, count: pic.w4 * pic.h4)
        for y4 in 0..<pic.h4 {
            for x4 in 0..<pic.w4 {
                let x = x4 << 2, y = y4 << 2
                // 8x8 grid only, inside the picture.
                if vertical { guard x & 7 == 0, x > 0 else { continue } } else { guard y & 7 == 0, y > 0 else { continue } }
                let q = x4 + y4 * pic.w4
                let p = vertical ? q - 1 : q - pic.w4
                let tu = vertical ? pic.tuEdgeV[q] != 0 : pic.tuEdgeH[q] != 0
                let pu = vertical ? pic.puEdgeV[q] != 0 : pic.puEdgeH[q] != 0
                guard tu || pu else { continue }
                let ctbQ = g.ctbAddrRs(x, y), ctbP = vertical ? g.ctbAddrRs(x - 1, y) : g.ctbAddrRs(x, y - 1)
                if pic.ctbDeblockDisabled[ctbQ] { continue }
                if ctbP != ctbQ {
                    // Slice and tile boundaries (the slice containing q0 decides).
                    if pic.ctbSliceAddr[ctbP] != pic.ctbSliceAddr[ctbQ] && !pic.ctbFilterAcrossSlices[ctbQ] { continue }
                    if !pps.loopFilterAcrossTiles && g.tileId[g.rsToTs[ctbP]] != g.tileId[g.rsToTs[ctbQ]] { continue }
                }
                let intraP = pic.predMode[p] == 1, intraQ = pic.predMode[q] == 1
                var v: UInt8 = 0
                if intraP || intraQ { v = 2 }
                else if tu && (pic.nonZeroCoeff[p] || pic.nonZeroCoeff[q]) { v = 1 }
                else if motionDiffers(pic, p, q, ctbP: ctbP, ctbQ: ctbQ) { v = 1 }
                _ = sps
                bs[q] = v
            }
        }
        return bs
    }

    /// 8.7.2.4: different reference pictures, number of vectors, or vectors 4 quarter-samples apart.
    static func motionDiffers(_ pic: HEVCPictureState, _ p: Int, _ q: Int, ctbP: Int, ctbQ: Int) -> Bool {
        let mp = pic.motion[p], mq = pic.motion[q]
        func refs(_ m: HEVCMotion, _ ctb: Int) -> [(poc: Int, mv: (Int, Int))] {
            let slice = Int(pic.ctbSliceIndex[ctb])
            var out: [(Int, (Int, Int))] = []
            if m.refIdx.0 >= 0, pic.sliceRefPocs.indices.contains(slice) { out.append((pic.sliceRefPocs[slice][0][Int(m.refIdx.0)], (Int(m.mv.0), Int(m.mv.1)))) }
            if m.refIdx.1 >= 0, pic.sliceRefPocs.indices.contains(slice) { out.append((pic.sliceRefPocs[slice][1][Int(m.refIdx.1)], (Int(m.mv.2), Int(m.mv.3)))) }
            return out
        }
        let a = refs(mp, ctbP), b = refs(mq, ctbQ)
        guard a.count == b.count else { return true }
        func far(_ u: (Int, Int), _ v: (Int, Int)) -> Bool { abs(u.0 - v.0) >= 4 || abs(u.1 - v.1) >= 4 }
        if a.count == 1 { return a[0].poc != b[0].poc || far(a[0].mv, b[0].mv) }
        if a.count == 2 {
            let sa = Set([a[0].poc, a[1].poc]), sb = Set([b[0].poc, b[1].poc])
            guard sa == sb else { return true }
            if a[0].poc != a[1].poc {
                // Two different references: compare the vectors that point at the same picture.
                let bFor0 = b[0].poc == a[0].poc ? b[0].mv : b[1].mv, bFor1 = b[0].poc == a[1].poc ? b[0].mv : b[1].mv
                return far(a[0].mv, bFor0) || far(a[1].mv, bFor1)
            }
            // Both vectors of each side point at the same picture.
            return (far(a[0].mv, b[0].mv) || far(a[1].mv, b[1].mv)) && (far(a[0].mv, b[1].mv) || far(a[1].mv, b[0].mv))
        }
        return false
    }

    // MARK: bands

    /// All vertical (or all horizontal) edges, a CTB row per worker. A band copies its rows
    /// (plus the four above a horizontal edge it reads), filters the edges whose q side starts
    /// in it, and writes back rows no other band changes: vertical edges stay in their rows; a
    /// horizontal edge at y changes y − 3 … y + 2 (chroma: y − 1, y).
    static func deblockBands(_ pic: inout HEVCPictureState, bs: [UInt8], vertical: Bool, pps: HEVCPPS, geometry g: HEVCGeometry) {
        let sps = pic.sps
        let ctb = sps.ctbSize
        let rows = (sps.height + ctb - 1) / ctb
        let layout = pic.withoutSamples()
        let planes = pic.planes
        let chroma = sps.chromaArrayType != 0
        // Per plane: the margin read above a band, and how far up its changes reach.
        let readAbove = vertical ? 0 : 4, writeAbove = vertical ? 0 : 3
        let cReadAbove = vertical ? 0 : 2, cWriteAbove = vertical ? 0 : 1
        struct Band: Sendable { var copy: [Range<Int>], write: [Range<Int>] }
        let bands: [Band] = (0..<rows).map { r in
            let y0 = r * ctb, y1 = min(y0 + ctb, sps.height)
            var copy = [max(0, y0 - readAbove) ..< y1], write = [max(0, y0 - writeAbove) ..< (r == rows - 1 ? y1 : y1 - writeAbove)]
            if chroma {
                let ch = planes[1].height, sh = sps.subHeightC
                let c0 = y0 / sh, c1 = min(ch, (y1 + sh - 1) / sh)
                for _ in 1...2 {
                    copy.append(max(0, c0 - cReadAbove) ..< c1)
                    write.append(max(0, c0 - cWriteAbove) ..< (r == rows - 1 ? c1 : c1 - cWriteAbove))
                }
            }
            return Band(copy: copy, write: write)
        }
        let filtered = hevcParallel(Array(0..<rows), state: { () }) { _, r -> [[UInt16]] in
            let b = bands[r]
            let y4 = (r * ctb) >> 2 ..< min(layout.h4, (min(r * ctb + ctb, layout.sps.height) + 3) >> 2)
            var out = b.copy.enumerated().map { c, rr in Array(planes[c].samples[rr.lowerBound * planes[c].width ..< rr.upperBound * planes[c].width]) }
            deblockLuma(layout, &out[0], width: planes[0].width, rowBase: b.copy[0].lowerBound, y4: y4, bs: bs, vertical: vertical, geometry: g)
            if chroma {
                for c in 1...2 {
                    deblockChroma(layout, &out[c], c: c, width: planes[c].width, rowBase: b.copy[c].lowerBound, y4: y4, bs: bs, vertical: vertical,
                                  pps: pps, geometry: g)
                }
            }
            return out
        }
        for (b, out) in zip(bands, filtered) {
            for c in 0..<out.count {
                let w = planes[c].width
                let wr = b.write[c], from = (wr.lowerBound - b.copy[c].lowerBound) * w
                guard !wr.isEmpty else { continue }
                pic.planes[c].samples.replaceSubrange(wr.lowerBound * w ..< wr.upperBound * w, with: out[c][from ..< from + wr.count * w])
            }
        }
    }

    // MARK: luma (8.7.2.5.3, 8.7.2.5.6, 8.7.2.5.7)

    /// The luma edges whose q side starts in 4x4 rows `y4`, on samples whose first row is `rowBase`.
    static func deblockLuma(_ pic: HEVCPictureState, _ s: inout [UInt16], width w: Int, rowBase: Int, y4 y4Range: Range<Int>, bs: [UInt8], vertical: Bool,
                            geometry g: HEVCGeometry) {
        let sps = pic.sps
        let bitDepth = sps.bitDepthLuma
        let maxV = (1 << bitDepth) - 1
        for y4 in y4Range {
            for x4 in 0..<pic.w4 {
                let q = x4 + y4 * pic.w4
                let b = Int(bs[q])
                guard b > 0 else { continue }
                let p = vertical ? q - 1 : q - pic.w4
                let x0 = x4 << 2, y0 = y4 << 2
                let qpL = (Int(pic.qpY[q]) + Int(pic.qpY[p]) + 1) >> 1
                let ctb = g.ctbAddrRs(x0, y0)
                let betaQ = max(0, min(51, qpL + (Int(pic.ctbBetaOffset[ctb]) << 1)))
                let beta = betaTable[betaQ] * (1 << (bitDepth - 8))
                let tcQ = max(0, min(53, qpL + 2 * (b - 1) + (Int(pic.ctbTcOffset[ctb]) << 1)))
                let tc = tcTable[tcQ] * (1 << (bitDepth - 8))
                // Sample addressing: index of p_i / q_i on line k.
                let stepAcross = vertical ? 1 : w, stepAlong = vertical ? w : 1
                let origin = x0 + (y0 - rowBase) * w
                @inline(__always) func P(_ i: Int, _ k: Int) -> Int { Int(s[origin + k * stepAlong - (i + 1) * stepAcross]) }
                @inline(__always) func Q(_ i: Int, _ k: Int) -> Int { Int(s[origin + k * stepAlong + i * stepAcross]) }
                let dp0 = abs(P(2, 0) - 2 * P(1, 0) + P(0, 0)), dp3 = abs(P(2, 3) - 2 * P(1, 3) + P(0, 3))
                let dq0 = abs(Q(2, 0) - 2 * Q(1, 0) + Q(0, 0)), dq3 = abs(Q(2, 3) - 2 * Q(1, 3) + Q(0, 3))
                let dpq0 = dp0 + dq0, dpq3 = dp3 + dq3
                let d = dpq0 + dpq3
                guard d < beta else { continue }
                func strong(_ dpq: Int, _ k: Int) -> Bool {
                    2 * dpq < (beta >> 2) && abs(P(3, k) - P(0, k)) + abs(Q(0, k) - Q(3, k)) < (beta >> 3) && abs(P(0, k) - Q(0, k)) < (5 * tc + 1) >> 1
                }
                let dE = strong(dpq0, 0) && strong(dpq3, 3) ? 2 : 1
                let dEp = dp0 + dp3 < (beta + (beta >> 1)) >> 3, dEq = dq0 + dq3 < (beta + (beta >> 1)) >> 3
                let noP = pic.bypass[p], noQ = pic.bypass[q]
                for k in 0..<4 {
                    let p0 = P(0, k), p1 = P(1, k), p2 = P(2, k), p3 = P(3, k)
                    let q0 = Q(0, k), q1 = Q(1, k), q2 = Q(2, k), q3 = Q(3, k)
                    @inline(__always) func setP(_ i: Int, _ v: Int) { if !noP { s[origin + k * stepAlong - (i + 1) * stepAcross] = UInt16(v) } }
                    @inline(__always) func setQ(_ i: Int, _ v: Int) { if !noQ { s[origin + k * stepAlong + i * stepAcross] = UInt16(v) } }
                    if dE == 2 {
                        let t2 = 2 * tc
                        setP(0, max(p0 - t2, min(p0 + t2, (p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3)))
                        setP(1, max(p1 - t2, min(p1 + t2, (p2 + p1 + p0 + q0 + 2) >> 2)))
                        setP(2, max(p2 - t2, min(p2 + t2, (2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) >> 3)))
                        setQ(0, max(q0 - t2, min(q0 + t2, (p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) >> 3)))
                        setQ(1, max(q1 - t2, min(q1 + t2, (p0 + q0 + q1 + q2 + 2) >> 2)))
                        setQ(2, max(q2 - t2, min(q2 + t2, (p0 + q0 + q1 + 3 * q2 + 2 * q3 + 4) >> 3)))
                    } else {
                        var delta = (9 * (q0 - p0) - 3 * (q1 - p1) + 8) >> 4
                        guard abs(delta) < tc * 10 else { continue }
                        delta = max(-tc, min(tc, delta))
                        setP(0, max(0, min(maxV, p0 + delta)))
                        setQ(0, max(0, min(maxV, q0 - delta)))
                        if dEp {
                            let dp = max(-(tc >> 1), min(tc >> 1, (((p2 + p0 + 1) >> 1) - p1 + delta) >> 1))
                            setP(1, max(0, min(maxV, p1 + dp)))
                        }
                        if dEq {
                            let dq = max(-(tc >> 1), min(tc >> 1, (((q2 + q0 + 1) >> 1) - q1 - delta) >> 1))
                            setQ(1, max(0, min(maxV, q1 + dq)))
                        }
                    }
                }
            }
        }
    }

    // MARK: chroma (8.7.2.5.5, 4:2:0)

    /// Chroma plane `c`'s edges whose q side starts in luma 4x4 rows `y4`, on samples whose
    /// first row is `rowBase`.
    static func deblockChroma(_ pic: HEVCPictureState, _ s: inout [UInt16], c: Int, width w: Int, rowBase: Int, y4 y4Range: Range<Int>, bs: [UInt8],
                              vertical: Bool, pps: HEVCPPS, geometry g: HEVCGeometry) {
        let sps = pic.sps
        let bitDepth = sps.bitDepthChroma
        let maxV = (1 << bitDepth) - 1
        do {
            let picOffset = c == 1 ? pps.cbQpOffset : pps.crQpOffset
            for y4 in y4Range {
                for x4 in 0..<pic.w4 {
                    let x0 = x4 << 2, y0 = y4 << 2
                    // Chroma edges lie on the 8x8 chroma grid (every 16 luma samples).
                    if vertical { guard x0 & 15 == 0 else { continue } } else { guard y0 & 15 == 0 else { continue } }
                    let q = x4 + y4 * pic.w4
                    guard bs[q] == 2 else { continue }
                    let p = vertical ? q - 1 : q - pic.w4
                    let qpc = chromaQp(((Int(pic.qpY[q]) + Int(pic.qpY[p]) + 1) >> 1) + picOffset)
                    let ctb = g.ctbAddrRs(x0, y0)
                    let tcQ = max(0, min(53, qpc + 2 + (Int(pic.ctbTcOffset[ctb]) << 1)))
                    let tc = tcTable[tcQ] * (1 << (bitDepth - 8))
                    guard tc > 0 else { continue }
                    let cx = x0 >> 1, cy = y0 >> 1
                    let stepAcross = vertical ? 1 : w, stepAlong = vertical ? w : 1
                    let origin = cx + (cy - rowBase) * w
                    let noP = pic.bypass[p], noQ = pic.bypass[q]
                    for k in 0..<2 {
                        let i0 = origin + k * stepAlong
                        let p0 = Int(s[i0 - stepAcross]), p1 = Int(s[i0 - 2 * stepAcross])
                        let q0 = Int(s[i0]), q1 = Int(s[i0 + stepAcross])
                        let delta = max(-tc, min(tc, ((((q0 - p0) << 2) + p1 - q1 + 4) >> 3)))
                        if !noP { s[i0 - stepAcross] = UInt16(max(0, min(maxV, p0 + delta))) }
                        if !noQ { s[i0] = UInt16(max(0, min(maxV, q0 - delta))) }
                    }
                }
            }
        }
    }

    // MARK: SAO (8.7.3)

    static func applySAO(_ pic: inout HEVCPictureState, geometry g: HEVCGeometry, pps: HEVCPPS) {
        let sps = pic.sps
        let deblocked = pic.planes
        let comps = sps.chromaArrayType != 0 ? 3 : 1
        for c in 0..<comps {
            let src = deblocked[c].samples
            var dst = src
            let w = deblocked[c].width, h = deblocked[c].height
            let sw = c == 0 ? 1 : sps.subWidthC, sh = c == 0 ? 1 : sps.subHeightC
            let ctbW = sps.ctbSize / sw, ctbH = sps.ctbSize / sh
            let bitDepth = c == 0 ? sps.bitDepthLuma : sps.bitDepthChroma
            let maxV = (1 << bitDepth) - 1
            for ctb in 0..<sps.picSizeInCtbs {
                let sao = pic.sao[c][ctb]
                guard sao.type != 0 else { continue }
                let x0 = (ctb % g.widthCtbs) * ctbW, y0 = (ctb / g.widthCtbs) * ctbH
                let x1 = min(w, x0 + ctbW), y1 = min(h, y0 + ctbH)
                if sao.type == 1 {
                    var table = [Int](repeating: 0, count: 32)
                    for k in 0..<4 { table[(k + sao.bandPosition) & 31] = k + 1 }
                    let shift = bitDepth - 5
                    for y in y0..<y1 {
                        for x in x0..<x1 {
                            if pic.bypass[pic.i4(x * sw, y * sh)] { continue }
                            let v = Int(src[x + y * w])
                            let band = table[v >> shift]
                            if band > 0 { dst[x + y * w] = UInt16(max(0, min(maxV, v + Int(sao.offsets[band - 1])))) }
                        }
                    }
                } else {
                    let (dx0, dy0, dx1, dy1): (Int, Int, Int, Int) = [(-1, 0, 1, 0), (0, -1, 0, 1), (-1, -1, 1, 1), (1, -1, -1, 1)][sao.eoClass]
                    let sliceAcross = pic.ctbFilterAcrossSlices
                    for y in y0..<y1 {
                        for x in x0..<x1 {
                            let xa = x + dx0, ya = y + dy0, xb = x + dx1, yb = y + dy1
                            guard xa >= 0, ya >= 0, xb >= 0, yb >= 0, xa < w, ya < h, xb < w, yb < h else { continue }
                            let lx = x * sw, ly = y * sh
                            if pic.bypass[pic.i4(lx, ly)] { continue }
                            let ctbC = g.ctbAddrRs(lx, ly)
                            var skip = false
                            for (nx, ny) in [(xa, ya), (xb, yb)] {
                                let ctbN = g.ctbAddrRs(nx * sw, ny * sh)
                                guard ctbN != ctbC else { continue }
                                if pic.ctbSliceAddr[ctbN] != pic.ctbSliceAddr[ctbC] {
                                    let neighbourFirst = g.zOrder(nx * sw, ny * sh) < g.zOrder(lx, ly)
                                    if (neighbourFirst && !sliceAcross[ctbC]) || (!neighbourFirst && !sliceAcross[ctbN]) { skip = true }
                                }
                                if !pps.loopFilterAcrossTiles && g.tileId[g.rsToTs[ctbN]] != g.tileId[g.rsToTs[ctbC]] { skip = true }
                            }
                            if skip { continue }
                            let v = Int(src[x + y * w])
                            func sign(_ d: Int) -> Int { d > 0 ? 1 : d < 0 ? -1 : 0 }
                            var e = 2 + sign(v - Int(src[xa + ya * w])) + sign(v - Int(src[xb + yb * w]))
                            if e <= 2 { e = e == 2 ? 0 : e + 1 }
                            if e > 0 { dst[x + y * w] = UInt16(max(0, min(maxV, v + Int(sao.offsets[e - 1])))) }
                        }
                    }
                }
            }
            pic.planes[c].samples = dst
        }
    }
}
