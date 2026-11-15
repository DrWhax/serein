// In-loop filters (H.265 8.7): the deblocking filter (8.7.2 — boundary strength, luma strong /
// weak filtering, chroma filtering; all vertical edges of the picture, then all horizontal
// ones) and sample adaptive offset (8.7.3 — band and edge offsets per CTB, reading the
// deblocked picture).

enum HEVCLoopFilter {
    /// Tables 8-12 (β′ for Q 0 … 51, tC′ for Q 0 … 53), literals: static data.
    static let betaTable: InlineArray<52, Int16> = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 20,
                                                    22, 24, 26, 28, 30, 32, 34, 36, 38, 40, 42, 44, 46, 48, 50, 52, 54, 56, 58, 60, 62, 64]
    static let tcTable: InlineArray<54, Int16> = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4,
                                                  4, 4, 5, 5, 6, 6, 7, 8, 9, 10, 11, 13, 14, 16, 18, 20, 22, 24]

    static let chromaQpTable: [Int] = [29, 30, 31, 32, 33, 33, 34, 34, 35, 35, 36, 36, 37, 37]
    static func chromaQp(_ qpi: Int) -> Int {
        if qpi < 30 { return qpi }
        if qpi > 43 { return qpi - 6 }
        return chromaQpTable[qpi - 30]
    }

    /// Both filters on a picture's planes.
    static func apply<S: HEVCSample>(_ pic: HEVCPictureState, _ planes: inout [HEVCPlane<S>], geometry: HEVCGeometry, pps: HEVCPPS) {
        let sps = pic.sps
        let anyDeblock = pic.ctbDeblockDisabled.contains(false)
        let anySAO = sps.saoEnabled && pic.sao.contains(where: { $0.contains { $0.type != 0 } })
        guard anyDeblock || anySAO, !planes.isEmpty else { return }
        filterBands(pic, &planes, deblocking: anyDeblock, sao: anySAO, pps: pps, geometry: geometry)
    }

    // MARK: boundary strength (8.7.2.3, 8.7.2.4)

    /// The edges to filter (bS > 0) of 4x4 units in rows `rows`, each on its unit's left
    /// (vertical) or top (horizontal) side, of the 8x8 grid, in raster order, and the largest
    /// bS: each unit reads only the picture's parse results. An edge between blocks of one CTB
    /// with the same motion and no coefficients (most of them) is 0 at once; the CTB conditions
    /// (filtering disabled, slice and tile boundaries) are checked only where an edge would be
    /// filtered.
    static func boundaryStrengths(_ pic: HEVCPictureState, geometry g: HEVCGeometry, pps: HEVCPPS, vertical: Bool,
                                  rows: Range<Int>) -> (edges: [HEVCDeblockEdge], strongest: UInt8) {
        let w4 = pic.w4
        var edges: [HEVCDeblockEdge] = []
        let ctbMask4 = (1 << (g.log2Ctb - 2)) - 1
        let tuEdges = vertical ? pic.tuEdgeV : pic.tuEdgeH, puEdges = vertical ? pic.puEdgeV : pic.puEdgeH
        let tuE = tuEdges.span, puE = puEdges.span
        let mode = pic.predMode.span, nz = pic.nonZeroCoeff.span, motion = pic.motion.span, sliceOf = pic.ctbSliceIndex.span
        var strongest: UInt8 = 0
        for y4 in rows {
            // The 8x8 grid only, inside the picture: every other column (or row) of units.
            if !vertical && (y4 & 1 != 0 || y4 == 0) { continue }
            for x4 in stride(from: vertical ? 2 : 0, to: w4, by: vertical ? 2 : 1) {
                let q = x4 + y4 * w4
                let tu = tuE[q] != 0
                guard tu || puE[q] != 0 else { continue }
                let p = vertical ? q - 1 : q - w4
                let sameCtb = vertical ? x4 & ctbMask4 != 0 : y4 & ctbMask4 != 0
                var v: UInt8 = 0
                if mode[p] == 1 || mode[q] == 1 { v = 2 }
                else if tu && (nz[p] || nz[q]) { v = 1 }
                else if sameCtb && motion[p] == motion[q] { v = 0 }
                else {
                    let x = x4 << 2, y = y4 << 2
                    let ctbQ = g.ctbAddrRs(x, y), ctbP = vertical ? g.ctbAddrRs(x - 1, y) : g.ctbAddrRs(x, y - 1)
                    // The same motion in the same slice (the same reference lists): no difference.
                    if !(motion[p] == motion[q] && sliceOf[ctbP] == sliceOf[ctbQ]) && motionDiffers(pic, p, q, ctbP: ctbP, ctbQ: ctbQ) { v = 1 }
                }
                if v != 0 && edgeFiltered(pic, geometry: g, pps: pps, x4: x4, y4: y4, vertical: vertical, sameCtb: sameCtb) {
                    edges.append(HEVCDeblockEdge(x4: Int32(x4), y4: Int32(y4), bs: v))
                    strongest = max(strongest, v)
                }
            }
        }
        return (edges, strongest)
    }

    /// Whether the edge of unit (x4, y4) is filtered at all: not in a CTB with deblocking
    /// disabled, nor on a slice or tile boundary the filter may not cross (the slice containing
    /// q0 decides).
    static func edgeFiltered(_ pic: HEVCPictureState, geometry g: HEVCGeometry, pps: HEVCPPS, x4: Int, y4: Int, vertical: Bool, sameCtb: Bool) -> Bool {
        let x = x4 << 2, y = y4 << 2
        let ctbQ = g.ctbAddrRs(x, y)
        if pic.ctbDeblockDisabled[ctbQ] { return false }
        guard !sameCtb else { return true }
        let ctbP = vertical ? g.ctbAddrRs(x - 1, y) : g.ctbAddrRs(x, y - 1)
        if pic.ctbSliceAddr[ctbP] != pic.ctbSliceAddr[ctbQ] && !pic.ctbFilterAcrossSlices[ctbQ] { return false }
        if !pps.loopFilterAcrossTiles && g.tileId[g.rsToTs[ctbP]] != g.tileId[g.rsToTs[ctbQ]] { return false }
        return true
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
    static func filterBands<S: HEVCSample>(_ layout: HEVCPictureState, _ pic: inout [HEVCPlane<S>], deblocking: Bool, sao anySAO: Bool, pps: HEVCPPS,
                                           geometry g: HEVCGeometry) {
        let sps = layout.sps
        let ctb = sps.ctbSize
        let rows = pic[0].bands.count
        let planes = pic
        let anyBypass = anySAO && layout.bypass.contains(true)
        let h4 = layout.h4
        let filtered = hevcParallel(Array(0..<rows), state: { () }) { _, r -> [[S]?] in
            let y0 = r * ctb, y1 = min(y0 + ctb, sps.height)
            // 4x4 rows: of the vertical edges (the band and 4 rows on either side), of the
            // horizontal edges' q sides (from the band's top edge to the one below it).
            // Their boundary strengths, the band's own (the rows it shares with the bands next to it
            // come out the same in theirs).
            let v4 = max(0, (y0 >> 2) - 1) ..< min(h4, (y1 >> 2) + 1), q4 = (y0 >> 2) ..< min(h4, (y1 >> 2) + 1)
            let none: (edges: [HEVCDeblockEdge], strongest: UInt8) = ([], 0)
            let (edgesV, maxV) = deblocking ? boundaryStrengths(layout, geometry: g, pps: pps, vertical: true, rows: v4) : none
            let (edgesH, maxH) = deblocking ? boundaryStrengths(layout, geometry: g, pps: pps, vertical: false, rows: q4) : none
            // Chroma edges are filtered only between intra blocks (bS 2).
            let deblockLumaEdges = max(maxV, maxH) > 0, deblockChromaEdges = max(maxV, maxH) == 2
            return (0..<planes.count).map { c -> [S]? in
                let saoHere = anySAO && (0..<g.widthCtbs).contains { layout.sao[c][$0 + r * g.widthCtbs].type != 0 }
                let deblock = c == 0 ? deblockLumaEdges : deblockChromaEdges
                guard deblock || saoHere else { return nil }
                let p = planes[c], w = p.width
                let own = p.rows(r)
                let halo = deblock ? (c == 0 ? 4 : 2) : 1
                let b0 = max(0, own.lowerBound - halo), b1 = min(p.height, own.upperBound + halo)
                var buf = gather(p, b0 ..< b1)
                if deblock {
                    for vertical in [true, false] {
                        let edges = vertical ? edgesV : edgesH
                        if c == 0 {
                            deblockLuma(layout, &buf, width: w, rowBase: b0, edges: edges, vertical: vertical, geometry: g)
                        } else {
                            deblockChroma(layout, &buf, c: c, width: w, rowBase: b0, edges: edges, vertical: vertical, pps: pps, geometry: g)
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
            for (c, b) in f.enumerated() { if let b { pic[c].bands[r] = b } }
        }
    }

    /// Rows `rows` of a plane, from its bands.
    static func gather<S: HEVCSample>(_ p: HEVCPlane<S>, _ rows: Range<Int>) -> [S] {
        var out: [S] = []
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

    /// The luma edges `edges` on samples whose first row is `rowBase`. p_i and q_i of line k of
    /// an edge at `o` are o + k·along − (i + 1)·across and o + k·along + i·across.
    static func deblockLuma<S: HEVCSample>(_ pic: HEVCPictureState, _ s: inout [S], width w: Int, rowBase: Int, edges: [HEVCDeblockEdge],
                                           vertical: Bool, geometry g: HEVCGeometry) {
        let bitDepth = pic.sps.bitDepthLuma
        let maxV = (1 << bitDepth) - 1, scale = 1 << (bitDepth - 8)
        let w4 = pic.w4
        let qpY = pic.qpY.span, bypass = pic.bypass.span, betaOffsets = pic.ctbBetaOffset.span, tcOffsets = pic.ctbTcOffset.span
        let a = vertical ? 1 : w, along = vertical ? w : 1
        var sp = s.mutableSpan
        for e in edges {
            let x4 = Int(e.x4), y4 = Int(e.y4), b = Int(e.bs)
            let q = x4 + y4 * w4, p = vertical ? q - 1 : q - w4
            let x0 = x4 << 2, y0 = y4 << 2
            let qpL = (Int(qpY[q]) + Int(qpY[p]) + 1) >> 1
            let ctb = g.ctbAddrRs(x0, y0)
            let beta = Int(betaTable[max(0, min(51, qpL + (Int(betaOffsets[ctb]) << 1)))]) * scale
            let tc = Int(tcTable[max(0, min(53, qpL + 2 * (b - 1) + (Int(tcOffsets[ctb]) << 1)))]) * scale
            let origin = x0 + (y0 - rowBase) * w
            // Lines 0 and 3 decide (8.7.2.5.3).
            let o0 = origin, o3 = origin + 3 * along
            let p00 = Int(sp[o0 - a]), p10 = Int(sp[o0 - 2 * a]), p20 = Int(sp[o0 - 3 * a]), p30 = Int(sp[o0 - 4 * a])
            let q00 = Int(sp[o0]), q10 = Int(sp[o0 + a]), q20 = Int(sp[o0 + 2 * a]), q30 = Int(sp[o0 + 3 * a])
            let p03 = Int(sp[o3 - a]), p13 = Int(sp[o3 - 2 * a]), p23 = Int(sp[o3 - 3 * a]), p33 = Int(sp[o3 - 4 * a])
            let q03 = Int(sp[o3]), q13 = Int(sp[o3 + a]), q23 = Int(sp[o3 + 2 * a]), q33 = Int(sp[o3 + 3 * a])
            let dp0 = abs(p20 - 2 * p10 + p00), dp3 = abs(p23 - 2 * p13 + p03)
            let dq0 = abs(q20 - 2 * q10 + q00), dq3 = abs(q23 - 2 * q13 + q03)
            let dpq0 = dp0 + dq0, dpq3 = dp3 + dq3
            guard dpq0 + dpq3 < beta else { continue }
            let strong0 = 2 * dpq0 < (beta >> 2) && abs(p30 - p00) + abs(q00 - q30) < (beta >> 3) && abs(p00 - q00) < (5 * tc + 1) >> 1
            let strong3 = 2 * dpq3 < (beta >> 2) && abs(p33 - p03) + abs(q03 - q33) < (beta >> 3) && abs(p03 - q03) < (5 * tc + 1) >> 1
            let dEp = dp0 + dp3 < (beta + (beta >> 1)) >> 3, dEq = dq0 + dq3 < (beta + (beta >> 1)) >> 3
            let noP = bypass[p], noQ = bypass[q]
            for k in 0..<4 {
                let o = origin + k * along
                let p0 = Int(sp[o - a]), p1 = Int(sp[o - 2 * a]), p2 = Int(sp[o - 3 * a]), p3 = Int(sp[o - 4 * a])
                let q0 = Int(sp[o]), q1 = Int(sp[o + a]), q2 = Int(sp[o + 2 * a]), q3 = Int(sp[o + 3 * a])
                if strong0 && strong3 {
                    let t2 = 2 * tc
                    if !noP {
                        sp[o - a] = S(max(p0 - t2, min(p0 + t2, (p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3)))
                        sp[o - 2 * a] = S(max(p1 - t2, min(p1 + t2, (p2 + p1 + p0 + q0 + 2) >> 2)))
                        sp[o - 3 * a] = S(max(p2 - t2, min(p2 + t2, (2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) >> 3)))
                    }
                    if !noQ {
                        sp[o] = S(max(q0 - t2, min(q0 + t2, (p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) >> 3)))
                        sp[o + a] = S(max(q1 - t2, min(q1 + t2, (p0 + q0 + q1 + q2 + 2) >> 2)))
                        sp[o + 2 * a] = S(max(q2 - t2, min(q2 + t2, (p0 + q0 + q1 + 3 * q2 + 2 * q3 + 4) >> 3)))
                    }
                } else {
                    var delta = (9 * (q0 - p0) - 3 * (q1 - p1) + 8) >> 4
                    guard abs(delta) < tc * 10 else { continue }
                    delta = max(-tc, min(tc, delta))
                    if !noP {
                        sp[o - a] = S(max(0, min(maxV, p0 + delta)))
                        if dEp { sp[o - 2 * a] = S(max(0, min(maxV, p1 + max(-(tc >> 1), min(tc >> 1, (((p2 + p0 + 1) >> 1) - p1 + delta) >> 1))))) }
                    }
                    if !noQ {
                        sp[o] = S(max(0, min(maxV, q0 - delta)))
                        if dEq { sp[o + a] = S(max(0, min(maxV, q1 + max(-(tc >> 1), min(tc >> 1, (((q2 + q0 + 1) >> 1) - q1 - delta) >> 1))))) }
                    }
                }
            }
        }
    }

    // MARK: chroma (8.7.2.5.5, 4:2:0)

    /// Chroma plane `c`'s edges of `edges` (those between intra blocks, bS 2, on the chroma
    /// 8x8 grid: every 16 luma samples), on samples whose first row is `rowBase`.
    static func deblockChroma<S: HEVCSample>(_ pic: HEVCPictureState, _ s: inout [S], c: Int, width w: Int, rowBase: Int, edges: [HEVCDeblockEdge],
                                             vertical: Bool, pps: HEVCPPS, geometry g: HEVCGeometry) {
        let bitDepth = pic.sps.bitDepthChroma
        let maxV = (1 << bitDepth) - 1, scale = 1 << (bitDepth - 8)
        let w4 = pic.w4
        let qpY = pic.qpY.span, bypass = pic.bypass.span, tcOffsets = pic.ctbTcOffset.span
        let picOffset = c == 1 ? pps.cbQpOffset : pps.crQpOffset
        let a = vertical ? 1 : w, along = vertical ? w : 1
        var sp = s.mutableSpan
        for e in edges where e.bs == 2 && (vertical ? e.x4 & 3 : e.y4 & 3) == 0 {
            let x4 = Int(e.x4), y4 = Int(e.y4)
            let q = x4 + y4 * w4, p = vertical ? q - 1 : q - w4
            let x0 = x4 << 2, y0 = y4 << 2
            let qpc = chromaQp(((Int(qpY[q]) + Int(qpY[p]) + 1) >> 1) + picOffset)
            let ctb = g.ctbAddrRs(x0, y0)
            let tc = Int(tcTable[max(0, min(53, qpc + 2 + (Int(tcOffsets[ctb]) << 1)))]) * scale
            guard tc > 0 else { continue }
            let origin = (x0 >> 1) + ((y0 >> 1) - rowBase) * w
            let noP = bypass[p], noQ = bypass[q]
            for k in 0..<2 {
                let i0 = origin + k * along
                let p0 = Int(sp[i0 - a]), p1 = Int(sp[i0 - 2 * a])
                let q0 = Int(sp[i0]), q1 = Int(sp[i0 + a])
                let delta = max(-tc, min(tc, ((((q0 - p0) << 2) + p1 - q1 + 4) >> 3)))
                if !noP { sp[i0 - a] = S(max(0, min(maxV, p0 + delta))) }
                if !noQ { sp[i0] = S(max(0, min(maxV, q0 - delta))) }
            }
        }
    }

    // MARK: SAO (8.7.3)

    static let eoOffsets: [(Int, Int, Int, Int)] = [(-1, 0, 1, 0), (0, -1, 0, 1), (-1, -1, 1, 1), (1, -1, -1, 1)]

    /// One CTB row of component `c`: `out` holds its rows of the deblocked picture, `src` the
    /// same rows and one on either side, from row `srcRow`.
    static func saoRow<S: HEVCSample>(_ pic: HEVCPictureState, src: [S], srcRow: Int, into out: inout [S], c: Int, row r: Int, w: Int, h: Int, sw: Int, sh: Int,
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
                        o[i] = S(truncatingIfNeeded: max(0, min(top, v &+ off)))
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
                        o[x + y * w - rowBase] = S(max(0, min(maxV, v + off)))
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
                @inline(__always) func sample(_ x: Int, _ y: Int, _ o: inout MutableSpan<S>) {
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
                    o[x + y * w - rowBase] = S(max(0, min(maxV, v + off)))
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
                        o[i] = S(truncatingIfNeeded: max(0, min(top, v &+ off)))
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

/// An edge to filter: its q-side 4x4 unit and bS.
struct HEVCDeblockEdge: Sendable {
    var x4: Int32, y4: Int32
    var bs: UInt8
}
