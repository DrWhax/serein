// In-loop filters (H.265 8.7): the deblocking filter (8.7.2 — boundary strength, luma strong /
// weak filtering, chroma filtering; all vertical edges of the picture, then all horizontal
// ones) and sample adaptive offset (8.7.3 — band and edge offsets per CTB, reading the
// deblocked picture).

enum HEVCLoopFilter {
    static let betaTable: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 24,
                                   26, 28, 30, 32, 34, 36, 38, 40, 42, 44, 46, 48, 50, 52, 54, 56, 58, 60, 62, 64]
    static let tcTable: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4,
                                 5, 5, 6, 6, 7, 8, 9, 10, 11, 13, 14, 16, 18, 20, 22, 24]

    static let chromaQpTable: [Int] = [29, 30, 31, 32, 33, 33, 34, 34, 35, 35, 36, 36, 37, 37]
    static func chromaQp(_ qpi: Int) -> Int {
        if qpi < 30 { return qpi }
        if qpi > 43 { return qpi - 6 }
        return chromaQpTable[qpi - 30]
    }

    static func apply(_ pic: inout HEVCPictureState, geometry: HEVCGeometry, pps: HEVCPPS) {
        let sps = pic.sps
        let anyDeblock = pic.ctbDeblockDisabled.contains(false)
        let anySAO = sps.saoEnabled && pic.sao.contains(where: { $0.contains { $0.type != 0 } })
        guard anyDeblock || anySAO, !pic.planes.isEmpty else { return }
        filterBands(&pic, deblocking: anyDeblock, sao: anySAO, pps: pps, geometry: geometry)
    }

    // MARK: boundary strength (8.7.2.3, 8.7.2.4)

    /// bS per 4x4 unit for the edge on its left (vertical) or top (horizontal) side, 0 off the
    /// 8x8 grid, for 4x4 rows `rows` (their units only, row-major): each unit reads only the
    /// picture's parse results.
    static func boundaryStrengths(_ pic: HEVCPictureState, geometry g: HEVCGeometry, pps: HEVCPPS, vertical: Bool, rows: Range<Int>) -> [UInt8] {
        let sps = pic.sps
        var bs = [UInt8](repeating: 0, count: pic.w4 * rows.count)
        let base = rows.lowerBound * pic.w4
        for y4 in rows {
            // The 8x8 grid only, inside the picture: every other column (or row) of units.
            if !vertical && (y4 & 1 != 0 || y4 == 0) { continue }
            for x4 in stride(from: vertical ? 2 : 0, to: pic.w4, by: vertical ? 2 : 1) {
                let x = x4 << 2, y = y4 << 2
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
                bs[q - base] = v
            }
        }
        return bs
    }

    /// One side's prediction for 8.7.2.4: how many vectors, and each one's reference picture
    /// and value, in list order (as plain values: this runs for every edge of the picture).
    struct Side {
        var n = 0
        var poc0 = 0, x0 = 0, y0 = 0
        var poc1 = 0, x1 = 0, y1 = 0
    }

    @inline(__always) static func side(_ pic: HEVCPictureState, _ i: Int, _ ctb: Int) -> Side {
        let m = pic.motion[i]
        let slice = Int(pic.ctbSliceIndex[ctb])
        var s = Side()
        guard pic.sliceRefPocs.indices.contains(slice) else { return s }
        if m.refIdx.0 >= 0 {
            s.poc0 = pic.sliceRefPocs[slice][0][Int(m.refIdx.0)]
            s.x0 = Int(m.mv.0); s.y0 = Int(m.mv.1)
            s.n = 1
        }
        if m.refIdx.1 >= 0 {
            let poc = pic.sliceRefPocs[slice][1][Int(m.refIdx.1)], x = Int(m.mv.2), y = Int(m.mv.3)
            if s.n == 0 { s.poc0 = poc; s.x0 = x; s.y0 = y } else { s.poc1 = poc; s.x1 = x; s.y1 = y }
            s.n += 1
        }
        return s
    }

    /// 8.7.2.4: different reference pictures, number of vectors, or vectors 4 quarter-samples apart.
    static func motionDiffers(_ pic: HEVCPictureState, _ p: Int, _ q: Int, ctbP: Int, ctbQ: Int) -> Bool {
        let a = side(pic, p, ctbP), b = side(pic, q, ctbQ)
        guard a.n == b.n else { return true }
        @inline(__always) func far(_ ux: Int, _ uy: Int, _ vx: Int, _ vy: Int) -> Bool { abs(ux - vx) >= 4 || abs(uy - vy) >= 4 }
        if a.n == 1 { return a.poc0 != b.poc0 || far(a.x0, a.y0, b.x0, b.y0) }
        if a.n == 2 {
            // The same set of reference pictures on both sides.
            guard (a.poc0 == b.poc0 && a.poc1 == b.poc1) || (a.poc0 == b.poc1 && a.poc1 == b.poc0) else { return true }
            if a.poc0 != a.poc1 {
                // Two different references: compare the vectors that point at the same picture.
                let b0 = b.poc0 == a.poc0, b1 = b.poc0 == a.poc1
                return far(a.x0, a.y0, b0 ? b.x0 : b.x1, b0 ? b.y0 : b.y1) || far(a.x1, a.y1, b1 ? b.x0 : b.x1, b1 ? b.y0 : b.y1)
            }
            // Both vectors of each side point at the same picture.
            return (far(a.x0, a.y0, b.x0, b.y0) || far(a.x1, a.y1, b.x1, b.y1)) && (far(a.x0, a.y0, b.x1, b.y1) || far(a.x1, a.y1, b.x0, b.y0))
        }
        return false
    }

    // MARK: bands

    /// Deblocking (the vertical edges of the whole picture, then the horizontal ones) and SAO,
    /// by CTB-row bands in parallel, each into a band of its own (the picture's bands are what
    /// the bands next to it read). A band takes its rows and 4 luma (2 chroma) rows on either
    /// side, filters the vertical edges of all of these (a vertical edge never mixes rows), then
    /// the horizontal edges from its top one to the one below it: each changes up to 3 (1) rows
    /// on either side and reads 4 (2), so the band's rows and the row on either side come out
    /// final, which is what SAO reads (8.7.3: the deblocked picture, one sample around). Bands
    /// with no edge to filter and no SAO stay as they are.
    static func filterBands(_ pic: inout HEVCPictureState, deblocking: Bool, sao anySAO: Bool, pps: HEVCPPS, geometry g: HEVCGeometry) {
        let sps = pic.sps
        let ctb = sps.ctbSize
        let rows = pic.planes[0].bands.count
        let layout = pic.withoutSamples()
        let planes = pic.planes
        let anyBypass = anySAO && pic.bypass.contains(true)
        let h4 = pic.h4
        let filtered = hevcParallel(Array(0..<rows), state: { () }) { _, r -> [[UInt16]?] in
            let y0 = r * ctb, y1 = min(y0 + ctb, sps.height)
            // 4x4 rows: of the vertical edges (the band and 4 rows on either side), of the
            // horizontal edges' q sides (from the band's top edge to the one below it).
            // Their boundary strengths, the band's own (the rows it shares with the bands next to it
            // come out the same in theirs).
            let v4 = max(0, (y0 >> 2) - 1) ..< min(h4, (y1 >> 2) + 1), q4 = (y0 >> 2) ..< min(h4, (y1 >> 2) + 1)
            let bsV = deblocking ? boundaryStrengths(layout, geometry: g, pps: pps, vertical: true, rows: v4) : []
            let bsH = deblocking ? boundaryStrengths(layout, geometry: g, pps: pps, vertical: false, rows: q4) : []
            let deblock = bsV.contains { $0 != 0 } || bsH.contains { $0 != 0 }
            return (0..<planes.count).map { c -> [UInt16]? in
                let saoHere = anySAO && (0..<g.widthCtbs).contains { layout.sao[c][$0 + r * g.widthCtbs].type != 0 }
                guard deblock || saoHere else { return nil }
                let p = planes[c], w = p.width
                let own = p.rows(r)
                let halo = deblock ? (c == 0 ? 4 : 2) : 1
                let b0 = max(0, own.lowerBound - halo), b1 = min(p.height, own.upperBound + halo)
                var buf = gather(p, b0 ..< b1)
                if deblock {
                    for vertical in [true, false] {
                        let bs = vertical ? bsV : bsH, y4 = vertical ? v4 : q4
                        if c == 0 {
                            deblockLuma(layout, &buf, width: w, rowBase: b0, y4: y4, bs: bs, vertical: vertical, geometry: g)
                        } else {
                            deblockChroma(layout, &buf, c: c, width: w, rowBase: b0, y4: y4, bs: bs, vertical: vertical, pps: pps, geometry: g)
                        }
                    }
                }
                var out = Array(buf[((own.lowerBound - b0) * w) ..< ((own.upperBound - b0) * w)])
                if saoHere {
                    let sw = c == 0 ? 1 : sps.subWidthC, sh = c == 0 ? 1 : sps.subHeightC
                    saoRow(layout, src: buf, srcRow: b0, into: &out, c: c, row: r, w: w, h: p.height, sw: sw, sh: sh, ctbW: ctb / sw, ctbH: ctb / sh,
                           anyBypass: anyBypass, pps: pps, geometry: g)
                }
                return out
            }
        }
        for (r, f) in filtered.enumerated() {
            for (c, b) in f.enumerated() { if let b { pic.planes[c].bands[r] = b } }
        }
    }

    /// Rows `rows` of a plane, from its bands.
    static func gather(_ p: HEVCPlane, _ rows: Range<Int>) -> [UInt16] {
        var out: [UInt16] = []
        out.reserveCapacity(rows.count * p.width)
        var y = rows.lowerBound
        while y < rows.upperBound {
            let k = y >> p.log2Rows, band = p.rows(k)
            let end = min(rows.upperBound, band.upperBound)
            out += p.bands[k][((y - band.lowerBound) * p.width) ..< ((end - band.lowerBound) * p.width)]
            y = end
        }
        return out
    }

    // MARK: luma (8.7.2.5.3, 8.7.2.5.6, 8.7.2.5.7)

    /// The luma edges whose q side starts in 4x4 rows `y4` (`bs` theirs, from the first), on
    /// samples whose first row is `rowBase`.
    static func deblockLuma(_ pic: HEVCPictureState, _ s: inout [UInt16], width w: Int, rowBase: Int, y4 y4Range: Range<Int>, bs: [UInt8], vertical: Bool,
                            geometry g: HEVCGeometry) {
        let sps = pic.sps
        let bitDepth = sps.bitDepthLuma
        let maxV = (1 << bitDepth) - 1
        for y4 in y4Range {
            // Strengths are only set on the 8x8 grid.
            if !vertical && y4 & 1 != 0 { continue }
            for x4 in stride(from: 0, to: pic.w4, by: vertical ? 2 : 1) {
                let q = x4 + y4 * pic.w4
                let b = Int(bs[q - y4Range.lowerBound * pic.w4])
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

    /// Chroma plane `c`'s edges whose q side starts in luma 4x4 rows `y4` (`bs` theirs), on
    /// samples whose first row is `rowBase`.
    static func deblockChroma(_ pic: HEVCPictureState, _ s: inout [UInt16], c: Int, width w: Int, rowBase: Int, y4 y4Range: Range<Int>, bs: [UInt8],
                              vertical: Bool, pps: HEVCPPS, geometry g: HEVCGeometry) {
        let sps = pic.sps
        let bitDepth = sps.bitDepthChroma
        let maxV = (1 << bitDepth) - 1
        do {
            let picOffset = c == 1 ? pps.cbQpOffset : pps.crQpOffset
            for y4 in y4Range {
                // Chroma edges lie on the 8x8 chroma grid (every 16 luma samples).
                if !vertical && y4 & 3 != 0 { continue }
                for x4 in stride(from: 0, to: pic.w4, by: vertical ? 4 : 1) {
                    let x0 = x4 << 2, y0 = y4 << 2
                    let q = x4 + y4 * pic.w4
                    guard bs[q - y4Range.lowerBound * pic.w4] == 2 else { continue }
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

    static let eoOffsets: [(Int, Int, Int, Int)] = [(-1, 0, 1, 0), (0, -1, 0, 1), (-1, -1, 1, 1), (1, -1, -1, 1)]

    /// One CTB row of component `c`: `out` holds its rows of the deblocked picture, `src` the
    /// same rows and one on either side, from row `srcRow`.
    static func saoRow(_ pic: HEVCPictureState, src: [UInt16], srcRow: Int, into out: inout [UInt16], c: Int, row r: Int, w: Int, h: Int, sw: Int, sh: Int,
                       ctbW: Int, ctbH: Int, anyBypass: Bool, pps: HEVCPPS, geometry g: HEVCGeometry) {
        let sps = pic.sps
        let bitDepth = c == 0 ? sps.bitDepthLuma : sps.bitDepthChroma
        let maxV = (1 << bitDepth) - 1
        let sp = src.span
        var o = out.mutableSpan
        // Indices: x + y·w less these.
        let rowBase = r * ctbH * w, srcBase = srcRow * w
        for cx in 0..<g.widthCtbs {
            let ctb = cx + r * g.widthCtbs
            let sao = pic.sao[c][ctb]
            guard sao.type != 0 else { continue }
            let x0 = cx * ctbW, y0 = r * ctbH
            let x1 = min(w, x0 + ctbW), y1 = min(h, y0 + ctbH)
            let off0 = Int(sao.offsets[0]), off1 = Int(sao.offsets[1]), off2 = Int(sao.offsets[2]), off3 = Int(sao.offsets[3])
            if sao.type == 1 && !anyBypass {
                // Band offset without bypassed samples: rows as spans, a sample outside the
                // four bands written back unchanged.
                let shift = Int32(bitDepth - 5), band = Int32(sao.bandPosition), top = Int32(maxV)
                let o0 = Int32(off0), o1 = Int32(off1), o2 = Int32(off2), o3 = Int32(off3)
                let n = x1 - x0
                for y in y0..<y1 {
                    let c0 = y * w + x0
                    let r = sp.extracting(c0 - srcBase ..< c0 - srcBase + n)
                    var k = 0
                    for i in (c0 - rowBase) ..< (c0 - rowBase + n) {
                        let v = Int32(r[k])
                        let b = ((v &>> shift) &- band) & 31
                        let off = b == 0 ? o0 : b == 1 ? o1 : b == 2 ? o2 : b == 3 ? o3 : 0
                        o[i] = UInt16(truncatingIfNeeded: max(0, min(top, v &+ off)))
                        k += 1
                    }
                }
            } else if sao.type == 1 {
                let shift = bitDepth - 5
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        if anyBypass && pic.bypass[pic.i4(x * sw, y * sh)] { continue }
                        let v = Int(sp[x + y * w - srcBase])
                        let k = ((v >> shift) - sao.bandPosition) & 31
                        guard k < 4 else { continue }
                        let off = k == 0 ? off0 : k == 1 ? off1 : k == 2 ? off2 : off3
                        o[x + y * w - rowBase] = UInt16(max(0, min(maxV, v + off)))
                    }
                }
            } else {
                let (dx0, dy0, dx1, dy1) = eoOffsets[sao.eoClass]
                // Whether each neighbouring CTB (by direction, [dy + 1][dx + 1]) may be read: a
                // slice edge without filtering across (the later slice decides), or a tile edge.
                let ctbC = ctb
                let lumaX0 = x0 * sw, lumaY0 = y0 * sh
                var allowed = InlineArray<9, Bool>(repeating: true)
                for ny in -1...1 {
                    for nx in -1...1 where nx != 0 || ny != 0 {
                        let ncx = cx + nx, ncy = r + ny
                        guard ncx >= 0, ncy >= 0, ncx < g.widthCtbs, ncy < g.heightCtbs else { continue }
                        let ctbN = ncx + ncy * g.widthCtbs
                        var ok = true
                        if pic.ctbSliceAddr[ctbN] != pic.ctbSliceAddr[ctbC] {
                            let neighbourFirst = g.zOrder(ncx << g.log2Ctb, ncy << g.log2Ctb) < g.zOrder(lumaX0, lumaY0)
                            if (neighbourFirst && !pic.ctbFilterAcrossSlices[ctbC]) || (!neighbourFirst && !pic.ctbFilterAcrossSlices[ctbN]) { ok = false }
                        }
                        if !pps.loopFilterAcrossTiles && g.tileId[g.rsToTs[ctbN]] != g.tileId[g.rsToTs[ctbC]] { ok = false }
                        allowed[(ny + 1) * 3 + nx + 1] = ok
                    }
                }
                @inline(__always) func dir(_ v: Int, _ lo: Int, _ hi: Int) -> Int { v < lo ? 0 : v >= hi ? 2 : 1 }
                // One sample with every check: picture edges, neighbours' CTBs, bypass.
                @inline(__always) func sample(_ x: Int, _ y: Int, _ o: inout MutableSpan<UInt16>) {
                    let ya = y + dy0, yb = y + dy1, xa = x + dx0, xb = x + dx1
                    guard ya >= 0, yb >= 0, ya < h, yb < h, xa >= 0, xb >= 0, xa < w, xb < w else { return }
                    if anyBypass && pic.bypass[pic.i4(x * sw, y * sh)] { return }
                    guard allowed[dir(ya, y0, y1) * 3 + dir(xa, x0, x1)], allowed[dir(yb, y0, y1) * 3 + dir(xb, x0, x1)] else { return }
                    let v = Int(sp[x + y * w - srcBase])
                    let a = Int(sp[xa + ya * w - srcBase]), b = Int(sp[xb + yb * w - srcBase])
                    var e = 2 + (v > a ? 1 : v < a ? -1 : 0) + (v > b ? 1 : v < b ? -1 : 0)
                    if e <= 2 { e = e == 2 ? 0 : e + 1 }
                    guard e > 0 else { return }
                    let off = e == 1 ? off0 : e == 2 ? off1 : e == 3 ? off2 : off3
                    o[x + y * w - rowBase] = UInt16(max(0, min(maxV, v + off)))
                }
                if anyBypass || x1 - x0 < 3 || y1 - y0 < 3 {
                    for y in y0..<y1 { for x in x0..<x1 { sample(x, y, &o) } }
                    continue
                }
                // Inside the CTB every neighbour is in it (and in the picture): rows as spans, no
                // checks per sample. A sample without an offset is written back unchanged.
                let n = x1 - x0 - 2
                let o0 = Int32(off0), o1 = Int32(off1), o2 = Int32(off2), o3 = Int32(off3), top = Int32(maxV)
                for y in (y0 + 1)..<(y1 - 1) {
                    let c0 = y * w + x0 + 1, s0 = c0 - srcBase
                    let rc = sp.extracting(s0 ..< s0 + n)
                    let ra = sp.extracting(s0 + dy0 * w + dx0 ..< s0 + dy0 * w + dx0 + n), rb = sp.extracting(s0 + dy1 * w + dx1 ..< s0 + dy1 * w + dx1 + n)
                    var k = 0
                    for i in (c0 - rowBase) ..< (c0 - rowBase + n) {
                        let v = Int32(rc[k]), a = Int32(ra[k]), b = Int32(rb[k])
                        let s = (v > a ? 1 : v < a ? -1 : 0) + (v > b ? 1 : v < b ? -1 : 0)
                        let off = s == -2 ? o0 : s == -1 ? o1 : s == 1 ? o2 : s == 2 ? o3 : 0
                        o[i] = UInt16(truncatingIfNeeded: max(0, min(top, v &+ off)))
                        k += 1
                    }
                }
                // The CTB's border: first and last rows, first and last columns.
                for x in x0..<x1 { sample(x, y0, &o); sample(x, y1 - 1, &o) }
                for y in (y0 + 1)..<(y1 - 1) { sample(x0, y, &o); sample(x1 - 1, y, &o) }
            }
        }
    }
}
