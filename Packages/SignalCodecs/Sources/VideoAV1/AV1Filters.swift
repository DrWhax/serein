// The frame's in-loop filters, in decode_frame_wrapup order (7.4): the loop filter (7.14),
// CDEF (7.15), superres upscaling (7.16) and loop restoration (7.17).

import CodecCore
import Dispatch
import Synchronization

/// Frame-wide mode info the filters read (assembled from the tiles).
struct AV1FrameModeInfo: Sendable {
    let miRows: Int, miCols: Int
    /// Units per row of the per-unit arrays (MiCols, or a single tile's padded width).
    let stride: Int
    var miSize: [UInt8], skip: [UInt8], segmentId: [UInt8]
    var lfTxSize: [[UInt8]]
    let lfStride: [Int]
    var deltaLF: [Int8]
    var cdefIdx: [Int8]
    let cdefCols: Int
    var lrUnits: [[AV1LRUnit]]
    /// RefFrames (two per unit) and YModes (the loop filter's deltas and edges).
    var refFrames: [Int8]
    var yMode: [UInt8]

    @inline(__always) func at(_ r: Int, _ c: Int) -> Int { r * stride + c }

    static let empty = AV1FrameModeInfo(miRows: 0, miCols: 0, stride: 0, miSize: [], skip: [], segmentId: [], lfTxSize: [], lfStride: [], deltaLF: [], cdefIdx: [],
                                        cdefCols: 0, lrUnits: [], refFrames: [], yMode: [])
}

struct AV1Filters {
    let f: AV1FrameInfo
    let m: AV1FrameModeInfo

    // MARK: Loop filter (7.14)

    /// Every vertical edge of a plane, then every horizontal one. A vertical edge's filter
    /// reads and writes only its own rows, a horizontal edge's only its own columns, so the
    /// first pass runs by bands of 64 luma rows in parallel and the second by strips of 64
    /// luma columns, each in a buffer of its own.
    func loopFilter(_ planes: inout [AV1PlaneBuffer]) {
        guard f.hdr.loopFilterLevel[0] != 0 || f.hdr.loopFilterLevel[1] != 0 else { return }
        for plane in 0..<f.numPlanes where plane == 0 || f.hdr.loopFilterLevel[1 + plane] != 0 {
            planes[plane] = verticalEdges(planes[plane], plane)
            planes[plane] = horizontalEdges(planes[plane], plane)
        }
    }

    func verticalEdges(_ p: AV1PlaneBuffer, _ plane: Int) -> AV1PlaneBuffer {
        let sy = plane == 0 ? 0 : f.subY
        let rowStep = plane == 0 ? 1 : 1 << f.subY, colStep = plane == 0 ? 1 : 1 << f.subX
        let miRows = f.hdr.miRows, miCols = f.hdr.miCols
        let bands = max(1, (miRows + 15) / 16)
        let results = Mutex<[[UInt16]]>(Array(repeating: [], count: bands))
        DispatchQueue.concurrentPerform(iterations: bands) { b in
            let r0 = b * 16, r1 = min(miRows, r0 + 16)
            let y0 = min(p.height, (r0 * 4) >> sy), y1 = b == bands - 1 ? p.height : min(p.height, (r1 * 4) >> sy)
            var band = AV1PlaneBuffer(x0: p.x0, y0: p.y0 + y0, width: p.width, height: y1 - y0, allocate: false)
            band.px = Array(p.px[(y0 * p.width)..<(y1 * p.width)])
            var row = r0
            while row < r1 {
                var col = 0
                while col < miCols {
                    edge(&band, plane, 0, row, col)
                    col += colStep
                }
                row += rowStep
            }
            let done = band.px
            results.withLock { $0[b] = done }
        }
        var out = p
        var px: [UInt16] = []
        px.reserveCapacity(p.px.count)
        for b in results.withLock({ $0 }) { px += b }
        if px.count == p.px.count { out.px = px }
        return out
    }

    func horizontalEdges(_ p: AV1PlaneBuffer, _ plane: Int) -> AV1PlaneBuffer {
        let sx = plane == 0 ? 0 : f.subX
        let rowStep = plane == 0 ? 1 : 1 << f.subY, colStep = plane == 0 ? 1 : 1 << f.subX
        let miRows = f.hdr.miRows, miCols = f.hdr.miCols
        let strips = max(1, (miCols + 15) / 16)
        let results = Mutex<[[UInt16]]>(Array(repeating: [], count: strips))
        DispatchQueue.concurrentPerform(iterations: strips) { s in
            let c0 = s * 16, c1 = min(miCols, c0 + 16)
            let x0 = min(p.width, (c0 * 4) >> sx), x1 = s == strips - 1 ? p.width : min(p.width, (c1 * 4) >> sx)
            let w = x1 - x0
            var strip = AV1PlaneBuffer(x0: p.x0 + x0, y0: p.y0, width: w, height: p.height, allocate: false)
            var px: [UInt16] = []
            px.reserveCapacity(w * p.height)
            for y in 0..<p.height { px += p.px[(y * p.width + x0)..<(y * p.width + x1)] }
            strip.px = px
            var row = 0
            while row < miRows {
                var col = c0
                while col < c1 {
                    edge(&strip, plane, 1, row, col)
                    col += colStep
                }
                row += rowStep
            }
            let done = strip.px
            results.withLock { $0[s] = done }
        }
        let all = results.withLock { $0 }
        var widths: [Int] = []
        for s in 0..<strips {
            let c0 = s * 16, c1 = min(miCols, c0 + 16)
            let x0 = min(p.width, (c0 * 4) >> sx), x1 = s == strips - 1 ? p.width : min(p.width, (c1 * 4) >> sx)
            widths.append(x1 - x0)
        }
        guard all.indices.allSatisfy({ all[$0].count == widths[$0] * p.height }) else { return p }
        var out = p
        var px: [UInt16] = []
        px.reserveCapacity(p.px.count)
        for y in 0..<p.height {
            for s in 0..<strips where widths[s] > 0 { px += all[s][(y * widths[s])..<((y + 1) * widths[s])] }
        }
        if px.count == p.px.count { out.px = px }
        return out
    }

    func filterLevel(_ row: Int, _ col: Int, _ plane: Int, _ pass: Int) -> (lvl: Int, limit: Int, blimit: Int, thresh: Int) {
        let i = m.at(row, col)
        let segment = Int(m.segmentId[i])
        var deltaLF = 0
        if !m.deltaLF.isEmpty {
            deltaLF = Int(m.deltaLF[4 * i + (f.hdr.deltaLfMulti ? (plane == 0 ? pass : plane + 1) : 0)])
        }
        let li = plane == 0 ? pass : plane + 1
        var lvl = clip3(0, 63, deltaLF + f.hdr.loopFilterLevel[li])
        let feature = 1 + li
        if f.hdr.segFeatureActive(segment, feature) { lvl = clip3(0, 63, f.hdr.featureData[segment][feature] + lvl) }
        if f.hdr.loopFilterDeltaEnabled {
            let nShift = lvl >> 5
            let ref = Int(m.refFrames[2 * i])
            if ref <= AV1Ref.intra {
                lvl += f.hdr.loopFilterRefDeltas[AV1Ref.intra] << nShift
            } else {
                let mode = Int(m.yMode[i])
                let modeType = mode >= AV1Inter.nearestMv && mode != AV1Inter.globalMv && mode != AV1Inter.globalGlobalMv ? 1 : 0
                lvl += (f.hdr.loopFilterRefDeltas[ref] << nShift) + (f.hdr.loopFilterModeDeltas[modeType] << nShift)
            }
            lvl = clip3(0, 63, lvl)
        }
        let shift = f.hdr.loopFilterSharpness > 4 ? 2 : (f.hdr.loopFilterSharpness > 0 ? 1 : 0)
        let limit = f.hdr.loopFilterSharpness > 0 ? clip3(1, 9 - f.hdr.loopFilterSharpness, lvl >> shift) : max(1, lvl >> shift)
        return (lvl, limit, 2 * (lvl + 2) + limit, lvl >> 4)
    }

    func edge(_ p: inout AV1PlaneBuffer, _ plane: Int, _ pass: Int, _ rowIn: Int, _ colIn: Int) {
        let sx = plane == 0 ? 0 : f.subX, sy = plane == 0 ? 0 : f.subY
        let dx = pass == 0 ? 1 : 0, dy = pass == 0 ? 0 : 1
        let x = colIn * 4, y = rowIn * 4
        let row = rowIn | sy, col = colIn | sx
        if x >= f.hdr.frameWidth || y >= f.hdr.frameHeight { return }
        if pass == 0 && x == 0 { return }
        if pass == 1 && y == 0 { return }
        let xP = x >> sx, yP = y >> sy
        let prevRow = row - (dy << sy), prevCol = col - (dx << sx)
        let txSz = Int(m.lfTxSize[plane][(row >> sy) * m.lfStride[plane] + (col >> sx)])
        let prevTxSz = Int(m.lfTxSize[plane][(prevRow >> sy) * m.lfStride[plane] + (prevCol >> sx)])
        let isTxEdge = pass == 0 ? xP % AV1C.txWidth[txSz] == 0 : yP % AV1C.txHeight[txSz] == 0
        guard isTxEdge else { return }
        let mi = m.at(row, col)
        let planeSize = AV1C.planeResidualSize(Int(m.miSize[mi]), sx, sy)
        let isBlockEdge = pass == 0 ? xP % AV1C.blockWidth[planeSize] == 0 : yP % AV1C.blockHeight[planeSize] == 0
        let isIntra = Int(m.refFrames[2 * mi]) <= AV1Ref.intra
        guard isBlockEdge || m.skip[mi] == 0 || isIntra else { return }
        let baseSize = pass == 0 ? min(AV1C.txWidth[prevTxSz], AV1C.txWidth[txSz]) : min(AV1C.txHeight[prevTxSz], AV1C.txHeight[txSz])
        let filterSize = plane == 0 ? min(16, baseSize) : min(8, baseSize)
        var s = filterLevel(row, col, plane, pass)
        if s.lvl == 0 { s = filterLevel(prevRow, prevCol, plane, pass) }
        guard s.lvl > 0 else { return }
        for i in 0..<4 { sample(&p, xP + dy * i, yP + dx * i, plane, s.limit, s.blimit, s.thresh, dx, dy, filterSize) }
    }

    @inline(__always)
    func sample(_ p: inout AV1PlaneBuffer, _ x: Int, _ y: Int, _ plane: Int, _ limit: Int, _ blimit: Int, _ thresh: Int, _ dx: Int, _ dy: Int, _ filterSize: Int) {
        let bd = f.bitDepth
        if x - p.x0 >= p.width || y - p.y0 >= p.height { return }
        func at(_ k: Int) -> Int { p.at(x + dx * k, y + dy * k) }
        let filterLen: Int = filterSize == 4 ? 4 : (plane != 0 ? 6 : (filterSize == 8 ? 8 : 16))
        let q0 = at(0), q1 = at(1), q2 = filterLen >= 6 ? at(2) : 0, q3 = filterLen >= 8 ? at(3) : 0
        let p0 = at(-1), p1 = at(-2), p2 = filterLen >= 6 ? at(-3) : 0, p3 = filterLen >= 8 ? at(-4) : 0
        let shift = bd - 8
        let threshBd = thresh << shift, limitBd = limit << shift, blimitBd = blimit << shift
        let hevMask = abs(p1 - p0) > threshBd || abs(q1 - q0) > threshBd
        var mask = abs(p1 - p0) > limitBd || abs(q1 - q0) > limitBd || abs(p0 - q0) * 2 + abs(p1 - q1) / 2 > blimitBd
        if filterLen >= 6 { mask = mask || abs(p2 - p1) > limitBd || abs(q2 - q1) > limitBd }
        if filterLen >= 8 { mask = mask || abs(p3 - p2) > limitBd || abs(q3 - q2) > limitBd }
        guard !mask else { return }
        let one = 1 << shift
        var flat = false
        if filterSize >= 8 {
            var fm = abs(p1 - p0) > one || abs(q1 - q0) > one || abs(p2 - p0) > one || abs(q2 - q0) > one
            if filterLen >= 8 { fm = fm || abs(p3 - p0) > one || abs(q3 - q0) > one }
            flat = !fm
        }
        var flat2 = false
        if filterSize >= 16 {
            let q4 = at(4), q5 = at(5), q6 = at(6), p4 = at(-5), p5 = at(-6), p6 = at(-7)
            flat2 = !(abs(p6 - p0) > one || abs(q6 - q0) > one || abs(p5 - p0) > one || abs(q5 - q0) > one || abs(p4 - p0) > one || abs(q4 - q0) > one)
        }
        if filterSize == 4 || !flat {
            // Narrow filter (7.14.6.3).
            let lo = -(1 << (bd - 1)), hi = (1 << (bd - 1)) - 1
            func c4(_ v: Int) -> Int { clip3(lo, hi, v) }
            let off = 0x80 << shift
            let ps1 = p1 - off, ps0 = p0 - off, qs0 = q0 - off, qs1 = q1 - off
            var filter = hevMask ? c4(ps1 - qs1) : 0
            filter = c4(filter + 3 * (qs0 - ps0))
            let filter1 = c4(filter + 4) >> 3, filter2 = c4(filter + 3) >> 3
            p.set(x, y, c4(qs0 - filter1) + off)
            p.set(x - dx, y - dy, c4(ps0 + filter2) + off)
            if !hevMask {
                let f3 = round2(filter1, 1)
                p.set(x + dx, y + dy, c4(qs1 - f3) + off)
                p.set(x - 2 * dx, y - 2 * dy, c4(ps1 + f3) + off)
            }
        } else {
            let log2Size = filterSize == 8 || !flat2 ? 3 : 4
            let n = log2Size == 4 ? 6 : (plane == 0 ? 3 : 2)
            let n2 = log2Size == 3 && plane == 0 ? 0 : 1
            var src = InlineArray<14, Int>(repeating: 0)
            for k in -(n + 1)...n { src[k + n + 1] = at(k) }
            var out = InlineArray<12, Int>(repeating: 0)
            for i in -n..<n {
                var t = 0
                for j in -n...n {
                    let pp = clip3(-(n + 1), n, i + j)
                    let tap = abs(j) <= n2 ? 2 : 1
                    t += src[pp + n + 1] * tap
                }
                out[i + n] = round2(t, log2Size)
            }
            for i in -n..<n { p.set(x + i * dx, y + i * dy, out[i + n]) }
        }
    }

    // MARK: CDEF (7.15)

    func cdef(_ cur: [AV1PlaneBuffer]) -> [AV1PlaneBuffer] {
        let h = f.hdr
        var anyStrength = false
        for i in 0..<(1 << h.cdefBits) where h.cdefYPri[i] != 0 || h.cdefYSec[i] != 0 || h.cdefUVPri[i] != 0 || h.cdefUVSec[i] != 0 { anyStrength = true }
        guard f.seq.enableCdef, !h.codedLossless, !h.allowIntrabc, anyStrength else { return cur }
        // Rows of 64x64 blocks in parallel: each writes its own band. The bands cover the
        // whole buffer (a single tile's is padded to its superblocks).
        let bands = (cur[0].height + 63) / 64
        let results = Mutex<[[[UInt16]]?]>(Array(repeating: nil, count: bands))
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            var out: [[UInt16]] = []
            for plane in 0..<f.numPlanes {
                let sy = plane == 0 ? 0 : f.subY
                let y0 = (band * 64) >> sy, y1 = min(cur[plane].height, ((band + 1) * 64) >> sy)
                out.append(Array(cur[plane].px[(y0 * cur[plane].width)..<(y1 * cur[plane].width)]))
            }
            let src = cur.map(\.px)
            var r = band * 16
            while r < min(h.miRows, (band + 1) * 16) {
                var c = 0
                while c < h.miCols {
                    let idx = Int(m.cdefIdx[(r >> 4) * m.cdefCols + (c >> 4)])
                    if idx >= 0 { cdefBlock(cur, src, &out, band, r, c, idx) }
                    c += 2
                }
                r += 2
            }
            let done = out
            results.withLock { $0[band] = done }
        }
        var dst = cur
        let all = results.withLock { $0 }
        for plane in 0..<f.numPlanes {
            var px: [UInt16] = []
            px.reserveCapacity(cur[plane].px.count)
            for band in 0..<bands { if let b = all[band] { px += b[plane] } }
            if px.count == cur[plane].px.count { dst[plane].px = px }
        }
        return dst
    }

    func cdefBlock(_ cur: [AV1PlaneBuffer], _ src: [[UInt16]], _ out: inout [[UInt16]], _ band: Int, _ r: Int, _ c: Int, _ idx: Int) {
        let h = f.hdr
        let skip = m.skip[m.at(r, c)] != 0 && m.skip[m.at(r + 1, c)] != 0 && m.skip[m.at(r, c + 1)] != 0 && m.skip[m.at(r + 1, c + 1)] != 0
        if skip { return }
        let coeffShift = f.bitDepth - 8
        let y = src[0]
        let (yDir, variance) = Self.cdefDirection(y.span, cur[0].width, c << 2, r << 2, shift: coeffShift)
        var priStr = h.cdefYPri[idx] << coeffShift
        var secStr = h.cdefYSec[idx] << coeffShift
        var dir = priStr == 0 ? 0 : yDir
        let varStr = (variance >> 6) != 0 ? min(floorLog2(variance >> 6), 12) : 0
        priStr = variance != 0 ? (priStr * (4 + varStr) + 8) >> 4 : 0
        var damping = h.cdefDamping + coeffShift
        cdefFilter(y.span, cur[0].width, &out[0], band, 0, r, c, priStr, secStr, damping, dir)
        if f.numPlanes == 1 { return }
        priStr = h.cdefUVPri[idx] << coeffShift
        secStr = h.cdefUVSec[idx] << coeffShift
        dir = priStr == 0 ? 0 : AV1C.cdefUvDir[(f.subX * 2 + f.subY) * 8 + yDir]
        damping = h.cdefDamping + coeffShift - 1
        let u = src[1], v = src[2]
        cdefFilter(u.span, cur[1].width, &out[1], band, 1, r, c, priStr, secStr, damping, dir)
        cdefFilter(v.span, cur[2].width, &out[2], band, 2, r, c, priStr, secStr, damping, dir)
    }

    /// The CDEF direction process (7.15.2) of the 8x8 luma block at (x0, y0).
    static func cdefDirection(_ p: Span<UInt16>, _ stride: Int, _ x0: Int, _ y0: Int, shift: Int) -> (Int, Int) {
        var cost = InlineArray<8, Int>(repeating: 0)
        var partial = InlineArray<120, Int>(repeating: 0)
        for i in 0..<8 {
            let row = (y0 + i) * stride + x0
            for j in 0..<8 {
                let x = (Int(p[row + j]) >> shift) - 128
                partial[0 * 15 + i + j] += x
                partial[1 * 15 + i + j / 2] += x
                partial[2 * 15 + i] += x
                partial[3 * 15 + 3 + i - j / 2] += x
                partial[4 * 15 + 7 + i - j] += x
                partial[5 * 15 + 3 - i / 2 + j] += x
                partial[6 * 15 + j] += x
                partial[7 * 15 + i / 2 + j] += x
            }
        }
        @inline(__always) func dt(_ i: Int) -> Int { i == 0 ? 0 : 840 / i }
        for i in 0..<8 {
            cost[2] += partial[2 * 15 + i] * partial[2 * 15 + i]
            cost[6] += partial[6 * 15 + i] * partial[6 * 15 + i]
        }
        cost[2] *= dt(8)
        cost[6] *= dt(8)
        for i in 0..<7 {
            cost[0] += (partial[i] * partial[i] + partial[14 - i] * partial[14 - i]) * dt(i + 1)
            cost[4] += (partial[60 + i] * partial[60 + i] + partial[60 + 14 - i] * partial[60 + 14 - i]) * dt(i + 1)
        }
        cost[0] += partial[7] * partial[7] * dt(8)
        cost[4] += partial[60 + 7] * partial[60 + 7] * dt(8)
        var i = 1
        while i < 8 {
            for j in 0..<5 { cost[i] += partial[i * 15 + 3 + j] * partial[i * 15 + 3 + j] }
            cost[i] *= dt(8)
            for j in 0..<3 {
                cost[i] += (partial[i * 15 + j] * partial[i * 15 + j] + partial[i * 15 + 10 - j] * partial[i * 15 + 10 - j]) * dt(2 * j + 2)
            }
            i += 2
        }
        var best = 0, yDir = 0
        for k in 0..<8 where cost[k] > best {
            best = cost[k]
            yDir = k
        }
        return (yDir, (best - cost[(yDir + 4) & 7]) >> 10)
    }

    /// The CDEF filter process (7.15.3) of one plane's 8x8 (luma) block: the twelve taps
    /// with their weights worked out once; blocks two samples or more inside the frame skip
    /// the availability test.
    func cdefFilter(_ p: Span<UInt16>, _ stride: Int, _ out: inout [UInt16], _ band: Int, _ plane: Int, _ r: Int, _ c: Int,
                    _ priStr: Int, _ secStr: Int, _ damping: Int, _ dir: Int) {
        let coeffShift = f.bitDepth - 8
        let sx = plane > 0 ? f.subX : 0, sy = plane > 0 ? f.subY : 0
        let x0 = (c * 4) >> sx, y0 = (r * 4) >> sy
        let w = 8 >> sx, h = 8 >> sy
        let bandY0 = (band * 64) >> sy
        let planeW = (f.hdr.miCols * 4) >> sx, planeH = (f.hdr.miRows * 4) >> sy
        let priTap = ((priStr >> coeffShift) & 1) * 2
        let dirs = AV1C.cdefDirections
        // Taps: offset (in samples), weight, threshold, damping shift.
        var off = InlineArray<12, Int>(repeating: 0), dy = InlineArray<12, Int>(repeating: 0), dx = InlineArray<12, Int>(repeating: 0)
        var weight = InlineArray<12, Int>(repeating: 0), thr = InlineArray<12, Int>(repeating: 0), adj = InlineArray<12, Int>(repeating: 0)
        let priAdj = priStr == 0 ? 0 : max(0, damping - floorLog2(priStr))
        let secAdj = secStr == 0 ? 0 : max(0, damping - floorLog2(secStr))
        var n = 0
        for k in 0..<2 {
            for si in 0..<2 {
                let sign = si == 0 ? -1 : 1
                for t in 0..<3 {
                    let d = t == 0 ? dir : (t == 1 ? (dir + 2) & 7 : (dir - 2) & 7)
                    dy[n] = sign * dirs[(d * 2 + k) * 2]
                    dx[n] = sign * dirs[(d * 2 + k) * 2 + 1]
                    off[n] = dy[n] * stride + dx[n]
                    weight[n] = t == 0 ? (priTap == 0 ? (k == 0 ? 4 : 2) : 3) : (k == 0 ? 2 : 1)
                    thr[n] = t == 0 ? priStr : secStr
                    adj[n] = t == 0 ? priAdj : secAdj
                    n += 1
                }
            }
        }
        @inline(__always) func constrain(_ diff: Int, _ threshold: Int, _ a: Int) -> Int {
            if threshold == 0 { return 0 }
            let ad = abs(diff)
            let mag = min(ad, max(0, threshold - (ad >> a)))
            return diff < 0 ? -mag : mag
        }
        let interior = x0 >= 2 && y0 >= 2 && x0 + w + 2 <= planeW && y0 + h + 2 <= planeH
        var o = out.mutableSpan
        for i in 0..<h {
            for j in 0..<w {
                let pos = (y0 + i) * stride + x0 + j
                let x = Int(p[pos])
                var sum = 0, mx = x, mn = x
                for t in 0..<12 {
                    if !interior {
                        let yy = y0 + i + dy[t], xx = x0 + j + dx[t]
                        guard yy >= 0, xx >= 0, yy < planeH, xx < planeW else { continue }
                    }
                    let s = Int(p[pos + off[t]])
                    sum += weight[t] * constrain(s - x, thr[t], adj[t])
                    mx = max(s, mx)
                    mn = min(s, mn)
                }
                let v = clip3(mn, mx, x + ((8 + sum - (sum < 0 ? 1 : 0)) >> 4))
                o[(y0 + i - bandY0) * stride + x0 + j] = UInt16(v)
            }
        }
    }

    // MARK: Superres upscaling (7.16)

    func upscale(_ input: [AV1PlaneBuffer]) -> [AV1PlaneBuffer] {
        guard f.hdr.useSuperres else { return input }
        var out: [AV1PlaneBuffer] = []
        let maxV = (1 << f.bitDepth) - 1
        for plane in 0..<f.numPlanes {
            let sx = plane > 0 ? f.subX : 0, sy = plane > 0 ? f.subY : 0
            let downW = round2(f.hdr.frameWidth, sx), upW = round2(f.hdr.upscaledWidth, sx), planeH = round2(f.hdr.frameHeight, sy)
            let stepX = ((downW << 14) + (upW / 2)) / upW
            let err = upW * stepX - (downW << 14)
            var initialSubpelX = (-((upW - downW) << (14 - 1)) + upW / 2) / upW + (1 << (8 - 1)) - err / 2
            initialSubpelX &= 16383
            let miW = f.hdr.miCols >> sx
            let maxX = miW * 4 - 1
            let src = input[plane]
            var dst = AV1PlaneBuffer(x0: 0, y0: 0, width: upW, height: src.height)
            let filt = AV1C.upscaleFilter
            for y in 0..<planeH {
                for x in 0..<upW {
                    let srcX = -(1 << 14) + initialSubpelX + x * stepX
                    let srcXPx = srcX >> 14
                    let srcXSubpel = (srcX & 16383) >> 8
                    var sum = 0
                    for k in 0..<8 { sum += src.at(clip3(0, maxX, srcXPx + (k - 3)), y) * filt[srcXSubpel * 8 + k] }
                    dst.set(x, y, clip3(0, maxV, round2(sum, 7)))
                }
            }
            out.append(dst)
        }
        return out
    }

    // MARK: Loop restoration (7.17)

    func loopRestoration(cur: [AV1PlaneBuffer], cdef: [AV1PlaneBuffer]) -> [AV1PlaneBuffer] {
        let h = f.hdr
        guard h.usesLr else { return cdef }
        var lr = cdef
        let rowsTotal = (h.frameHeight + 3) / 4
        let results = Mutex<[[(plane: Int, y: Int, x: Int, w: Int, h: Int, px: [UInt16])]]>(Array(repeating: [], count: rowsTotal))
        DispatchQueue.concurrentPerform(iterations: rowsTotal) { row in
            var blocks: [(plane: Int, y: Int, x: Int, w: Int, h: Int, px: [UInt16])] = []
            for plane in 0..<f.numPlanes where h.frameRestorationType[plane] != AV1C.restoreNone {
                let sx = plane == 0 ? 0 : f.subX, sy = plane == 0 ? 0 : f.subY
                let unitSize = h.loopRestorationSize[plane]
                let unitRows = f.lrUnitRows[plane], unitCols = f.lrUnitCols[plane]
                let lumaY = row * 4
                let stripeNum = (lumaY + 8) / 64
                let stripeStartY = (-8 + stripeNum * 64) >> sy
                let stripeEndY = stripeStartY + (64 >> sy) - 1
                let unitRow = min(unitRows - 1, ((row * 4 + 8) >> sy) / unitSize)
                let planeEndX = round2(h.upscaledWidth, sx) - 1, planeEndY = round2(h.frameHeight, sy) - 1
                let y = (row * 4) >> sy
                let bh = min(4 >> sy, planeEndY - y + 1)
                guard bh > 0 else { continue }
                // Runs of 4x4 blocks in the same unit share the filter (7.17 note).
                var col = 0
                let colsTotal = (h.upscaledWidth + 3) / 4
                while col < colsTotal {
                    let x = (col * 4) >> sx
                    let unitCol = min(unitCols - 1, x / unitSize)
                    var endCol = col + 1
                    while endCol < colsTotal && min(unitCols - 1, ((endCol * 4) >> sx) / unitSize) == unitCol { endCol += 1 }
                    let xEnd = min(planeEndX + 1, (endCol * 4) >> sx)
                    let bw = xEnd - x
                    col = endCol
                    guard bw > 0 else { continue }
                    let unit = m.lrUnits[plane][unitRow * unitCols + unitCol]
                    let src = SourceRegion(cur: cur[plane], cdef: cdef[plane], stripeStartY: stripeStartY, stripeEndY: stripeEndY,
                                           planeEndX: planeEndX, planeEndY: planeEndY)
                    let px: [UInt16]
                    switch unit.type {
                    case AV1C.restoreWiener: px = wiener(src, unit, x, y, bw, bh)
                    case AV1C.restoreSgrproj: px = selfGuided(src, cdef[plane], unit, x, y, bw, bh)
                    default: continue
                    }
                    blocks.append((plane, y, x, bw, bh, px))
                }
            }
            results.withLock { $0[row] = blocks }
        }
        for band in results.withLock({ $0 }) {
            for b in band {
                for i in 0..<b.h { for j in 0..<b.w { lr[b.plane].set(b.x + j, b.y + i, Int(b.px[i * b.w + j])) } }
            }
        }
        return lr
    }

    struct SourceRegion {
        let cur: AV1PlaneBuffer, cdef: AV1PlaneBuffer
        let stripeStartY: Int, stripeEndY: Int, planeEndX: Int, planeEndY: Int

        /// get_source_sample (7.17.6).
        @inline(__always) func sample(_ xIn: Int, _ yIn: Int) -> Int {
            let x = max(0, min(planeEndX, xIn))
            var y = max(0, min(planeEndY, yIn))
            if y < stripeStartY {
                y = max(stripeStartY - 2, y)
                return cur.at(x, y)
            } else if y > stripeEndY {
                y = min(stripeEndY + 2, y)
                return cur.at(x, y)
            }
            return cdef.at(x, y)
        }
    }

    func wiener(_ src: SourceRegion, _ unit: AV1LRUnit, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> [UInt16] {
        let bd = f.bitDepth
        let round0 = bd == 12 ? 5 : 3, round1 = bd == 12 ? 9 : 11
        func coeffs(_ pass: Int) -> [Int] {
            var filter = [0, 0, 0, 128, 0, 0, 0]
            for i in 0..<3 {
                let c = unit.wiener[pass * 3 + i]
                filter[i] = c
                filter[6 - i] = c
                filter[3] -= 2 * c
            }
            return filter
        }
        let vfilter = coeffs(0), hfilter = coeffs(1)
        let offset = 1 << (bd + 7 - round0 - 1)
        let limit = (1 << (bd + 1 + 7 - round0)) - 1
        var inter = [Int](repeating: 0, count: (h + 6) * w)
        for r in 0..<(h + 6) {
            for c in 0..<w {
                var s = 0
                for t in 0..<7 { s += hfilter[t] * src.sample(x + c + t - 3, y + r - 3) }
                inter[r * w + c] = clip3(-offset, limit - offset, round2(s, round0))
            }
        }
        let maxV = (1 << bd) - 1
        var out = [UInt16](repeating: 0, count: w * h)
        for r in 0..<h {
            for c in 0..<w {
                var s = 0
                for t in 0..<7 { s += vfilter[t] * inter[(r + t) * w + c] }
                out[r * w + c] = UInt16(clip3(0, maxV, round2(s, round1)))
            }
        }
        return out
    }

    func selfGuided(_ src: SourceRegion, _ cdef: AV1PlaneBuffer, _ unit: AV1LRUnit, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> [UInt16] {
        let set = unit.sgrSet
        let flt0 = boxFilter(src, cdef, x, y, w, h, set, 0)
        let flt1 = boxFilter(src, cdef, x, y, w, h, set, 1)
        let w0 = unit.xqd[0], w1 = unit.xqd[1], w2 = (1 << 7) - w0 - w1
        let r0 = AV1C.sgrParams[set * 4], r1 = AV1C.sgrParams[set * 4 + 2]
        let maxV = (1 << f.bitDepth) - 1
        var out = [UInt16](repeating: 0, count: w * h)
        for i in 0..<h {
            for j in 0..<w {
                let u = cdef.at(x + j, y + i) << 4
                var v = w1 * u
                v += r0 != 0 ? w0 * flt0[i * w + j] : w0 * u
                v += r1 != 0 ? w2 * flt1[i * w + j] : w2 * u
                out[i * w + j] = UInt16(clip3(0, maxV, round2(v, 4 + 7)))
            }
        }
        return out
    }

    func boxFilter(_ src: SourceRegion, _ cdef: AV1PlaneBuffer, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ set: Int, _ pass: Int) -> [Int] {
        let r = AV1C.sgrParams[set * 4 + pass * 2]
        if r == 0 { return [] }
        let eps = AV1C.sgrParams[set * 4 + pass * 2 + 1]
        let bd = f.bitDepth
        let n = (2 * r + 1) * (2 * r + 1)
        let n2e = n * n * eps
        let s = ((1 << 20) + n2e / 2) / n2e
        let oneOverN = ((1 << 12) + (n / 2)) / n
        let aw = w + 2, ah = h + 2
        var aArr = [Int](repeating: 0, count: aw * ah), bArr = aArr
        // Box sums over the source window via a column-sum pass.
        let sw = w + 2 + 2 * r, sh = h + 2 + 2 * r
        var win = [Int](repeating: 0, count: sw * sh)
        for yy in 0..<sh { for xx in 0..<sw { win[yy * sw + xx] = src.sample(x - 1 - r + xx, y - 1 - r + yy) } }
        for i in -1..<(h + 1) {
            for j in -1..<(w + 1) {
                var a = 0, b = 0
                for dy in -r...r {
                    let rowBase = (i + 1 + r + dy) * sw + (j + 1 + r)
                    for dx in -r...r {
                        let c = win[rowBase + dx]
                        a += c * c
                        b += c
                    }
                }
                a = round2(a, 2 * (bd - 8))
                let d = round2(b, bd - 8)
                let p = max(0, a * n - d * d)
                let z = round2(p * s, 20)
                let a2: Int
                if z >= 255 { a2 = 256 } else if z == 0 { a2 = 1 } else { a2 = ((z << 8) + (z / 2)) / (z + 1) }
                let b2 = ((1 << 8) - a2) * b * oneOverN
                aArr[(i + 1) * aw + j + 1] = a2
                bArr[(i + 1) * aw + j + 1] = round2(b2, 12)
            }
        }
        var out = [Int](repeating: 0, count: w * h)
        for i in 0..<h {
            let shift = pass == 0 && (i & 1) == 1 ? 4 : 5
            for j in 0..<w {
                var a = 0, b = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let weight: Int
                        if pass == 0 {
                            weight = ((i + dy) & 1) != 0 ? (dx == 0 ? 6 : 5) : 0
                        } else {
                            weight = dx == 0 || dy == 0 ? 4 : 3
                        }
                        if weight == 0 { continue }
                        a += weight * aArr[(i + 1 + dy) * aw + j + 1 + dx]
                        b += weight * bArr[(i + 1 + dy) * aw + j + 1 + dx]
                    }
                }
                let v = a * cdef.at(x + j, y + i) + b
                out[i * w + j] = round2(v, 8 + shift - 4)
            }
        }
        return out
    }
}
