// The frame's in-loop filters, in decode_frame_wrapup order (7.4): the loop filter (7.14),
// CDEF (7.15), superres upscaling (7.16) and loop restoration (7.17).

import CodecCore
import Dispatch
import Synchronization

/// Frame-wide mode info the filters read (assembled from the tiles).
struct AV1FrameModeInfo: Sendable {
    let miRows: Int, miCols: Int
    var miSize: [UInt8], skip: [UInt8], segmentId: [UInt8]
    var lfTxSize: [[UInt8]]
    let lfStride: [Int]
    var deltaLF: [Int8]
    var cdefIdx: [Int8]
    let cdefCols: Int
    var lrUnits: [[AV1LRUnit]]

    @inline(__always) func at(_ r: Int, _ c: Int) -> Int { r * miCols + c }
}

struct AV1Filters {
    let f: AV1FrameInfo
    let m: AV1FrameModeInfo

    // MARK: Loop filter (7.14)

    func loopFilter(_ planes: inout [AV1PlaneBuffer]) {
        let h = f.hdr
        guard h.loopFilterLevel[0] != 0 || h.loopFilterLevel[1] != 0 else { return }
        for plane in 0..<f.numPlanes where plane == 0 || h.loopFilterLevel[1 + plane] != 0 {
            for pass in 0..<2 {
                let rowStep = plane == 0 ? 1 : 1 << f.subY, colStep = plane == 0 ? 1 : 1 << f.subX
                var row = 0
                while row < h.miRows {
                    var col = 0
                    while col < h.miCols {
                        edge(&planes[plane], plane, pass, row, col)
                        col += colStep
                    }
                    row += rowStep
                }
            }
        }
    }

    func filterLevel(_ row: Int, _ col: Int, _ plane: Int, _ pass: Int) -> (lvl: Int, limit: Int, blimit: Int, thresh: Int) {
        let h = f.hdr
        let i = m.at(row, col)
        let segment = Int(m.segmentId[i])
        var deltaLF = 0
        if !m.deltaLF.isEmpty {
            deltaLF = Int(m.deltaLF[4 * i + (h.deltaLfMulti ? (plane == 0 ? pass : plane + 1) : 0)])
        }
        let li = plane == 0 ? pass : plane + 1
        var lvl = clip3(0, 63, deltaLF + h.loopFilterLevel[li])
        let feature = 1 + li
        if h.segFeatureActive(segment, feature) { lvl = clip3(0, 63, h.featureData[segment][feature] + lvl) }
        if h.loopFilterDeltaEnabled {
            let nShift = lvl >> 5
            // Every block of a key frame has ref INTRA_FRAME.
            lvl = clip3(0, 63, lvl + (h.loopFilterRefDeltas[0] << nShift))
        }
        let shift = h.loopFilterSharpness > 4 ? 2 : (h.loopFilterSharpness > 0 ? 1 : 0)
        let limit = h.loopFilterSharpness > 0 ? clip3(1, 9 - h.loopFilterSharpness, lvl >> shift) : max(1, lvl >> shift)
        return (lvl, limit, 2 * (lvl + 2) + limit, lvl >> 4)
    }

    func edge(_ p: inout AV1PlaneBuffer, _ plane: Int, _ pass: Int, _ rowIn: Int, _ colIn: Int) {
        let h = f.hdr
        let sx = plane == 0 ? 0 : f.subX, sy = plane == 0 ? 0 : f.subY
        let dx = pass == 0 ? 1 : 0, dy = pass == 0 ? 0 : 1
        let x = colIn * 4, y = rowIn * 4
        let row = rowIn | sy, col = colIn | sx
        if x >= h.frameWidth || y >= h.frameHeight { return }
        if pass == 0 && x == 0 { return }
        if pass == 1 && y == 0 { return }
        let xP = x >> sx, yP = y >> sy
        let prevRow = row - (dy << sy), prevCol = col - (dx << sx)
        let txSz = Int(m.lfTxSize[plane][(row >> sy) * m.lfStride[plane] + (col >> sx)])
        let prevTxSz = Int(m.lfTxSize[plane][(prevRow >> sy) * m.lfStride[plane] + (prevCol >> sx)])
        let isTxEdge = pass == 0 ? xP % AV1C.txWidth[txSz] == 0 : yP % AV1C.txHeight[txSz] == 0
        // Key frames: every block is intra, so a transform edge is always filtered.
        guard isTxEdge else { return }
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
        if x >= p.width || y >= p.height { return }
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
            var src = [Int](repeating: 0, count: 2 * n + 2)
            for k in -(n + 1)...n { src[k + n + 1] = at(k) }
            var out = [Int](repeating: 0, count: 2 * n)
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
        // Rows of 64x64 blocks in parallel: each writes its own band.
        let bands = (h.miRows + 15) / 16
        let results = Mutex<[[[UInt16]]?]>(Array(repeating: nil, count: bands))
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            var out: [[UInt16]] = []
            for plane in 0..<f.numPlanes {
                let sy = plane == 0 ? 0 : f.subY
                let y0 = (band * 64) >> sy, y1 = min(cur[plane].height, ((band + 1) * 64) >> sy)
                out.append(Array(cur[plane].px[(y0 * cur[plane].width)..<(y1 * cur[plane].width)]))
            }
            var r = band * 16
            while r < min(h.miRows, (band + 1) * 16) {
                var c = 0
                while c < h.miCols {
                    let idx = Int(m.cdefIdx[(r >> 4) * m.cdefCols + (c >> 4)])
                    if idx >= 0 { cdefBlock(cur, &out, band, r, c, idx) }
                    c += 2
                }
                r += 2
            }
            results.withLock { $0[band] = out }
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

    func cdefBlock(_ cur: [AV1PlaneBuffer], _ out: inout [[UInt16]], _ band: Int, _ r: Int, _ c: Int, _ idx: Int) {
        let h = f.hdr
        let skip = m.skip[m.at(r, c)] != 0 && m.skip[m.at(r + 1, c)] != 0 && m.skip[m.at(r, c + 1)] != 0 && m.skip[m.at(r + 1, c + 1)] != 0
        if skip { return }
        let coeffShift = f.bitDepth - 8
        let (yDir, variance) = cdefDirection(cur[0], r, c)
        var priStr = h.cdefYPri[idx] << coeffShift
        var secStr = h.cdefYSec[idx] << coeffShift
        var dir = priStr == 0 ? 0 : yDir
        let varStr = (variance >> 6) != 0 ? min(floorLog2(variance >> 6), 12) : 0
        priStr = variance != 0 ? (priStr * (4 + varStr) + 8) >> 4 : 0
        var damping = h.cdefDamping + coeffShift
        cdefFilter(cur, &out, band, 0, r, c, priStr, secStr, damping, dir)
        if f.numPlanes == 1 { return }
        priStr = h.cdefUVPri[idx] << coeffShift
        secStr = h.cdefUVSec[idx] << coeffShift
        dir = priStr == 0 ? 0 : AV1C.cdefUvDir[(f.subX * 2 + f.subY) * 8 + yDir]
        damping = h.cdefDamping + coeffShift - 1
        cdefFilter(cur, &out, band, 1, r, c, priStr, secStr, damping, dir)
        cdefFilter(cur, &out, band, 2, r, c, priStr, secStr, damping, dir)
    }

    func cdefDirection(_ p: AV1PlaneBuffer, _ r: Int, _ c: Int) -> (Int, Int) {
        var cost = [Int](repeating: 0, count: 8)
        var partial = [Int](repeating: 0, count: 8 * 15)
        let x0 = c << 2, y0 = r << 2
        let shift = f.bitDepth - 8
        for i in 0..<8 {
            for j in 0..<8 {
                let x = (p.at(x0 + j, y0 + i) >> shift) - 128
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
        let dt = AV1C.divTable
        for i in 0..<8 {
            cost[2] += partial[2 * 15 + i] * partial[2 * 15 + i]
            cost[6] += partial[6 * 15 + i] * partial[6 * 15 + i]
        }
        cost[2] *= dt[8]
        cost[6] *= dt[8]
        for i in 0..<7 {
            cost[0] += (partial[i] * partial[i] + partial[14 - i] * partial[14 - i]) * dt[i + 1]
            cost[4] += (partial[60 + i] * partial[60 + i] + partial[60 + 14 - i] * partial[60 + 14 - i]) * dt[i + 1]
        }
        cost[0] += partial[7] * partial[7] * dt[8]
        cost[4] += partial[60 + 7] * partial[60 + 7] * dt[8]
        var i = 1
        while i < 8 {
            for j in 0..<5 { cost[i] += partial[i * 15 + 3 + j] * partial[i * 15 + 3 + j] }
            cost[i] *= dt[8]
            for j in 0..<3 {
                cost[i] += (partial[i * 15 + j] * partial[i * 15 + j] + partial[i * 15 + 10 - j] * partial[i * 15 + 10 - j]) * dt[2 * j + 2]
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

    func cdefFilter(_ cur: [AV1PlaneBuffer], _ out: inout [[UInt16]], _ band: Int, _ plane: Int, _ r: Int, _ c: Int,
                    _ priStr: Int, _ secStr: Int, _ damping: Int, _ dir: Int) {
        let coeffShift = f.bitDepth - 8
        let sx = plane > 0 ? f.subX : 0, sy = plane > 0 ? f.subY : 0
        let x0 = (c * 4) >> sx, y0 = (r * 4) >> sy
        let w = 8 >> sx, h = 8 >> sy
        let p = cur[plane]
        let bandY0 = (band * 64) >> sy
        let miRows = f.hdr.miRows, miCols = f.hdr.miCols
        let priTap = ((priStr >> coeffShift) & 1) * 2
        let dirs = AV1C.cdefDirections
        func constrain(_ diff: Int, _ threshold: Int) -> Int {
            if threshold == 0 { return 0 }
            let adj = max(0, damping - floorLog2(threshold))
            let mag = clip3(0, abs(diff), threshold - (abs(diff) >> adj))
            return diff < 0 ? -mag : mag
        }
        let priTaps = [4, 2, 3, 3], secTaps = [2, 1]
        for i in 0..<h {
            for j in 0..<w {
                let x = p.at(x0 + j, y0 + i)
                var sum = 0, mx = x, mn = x
                for k in 0..<2 {
                    for sign in [-1, 1] {
                        for (d, isPri) in [(dir, true), ((dir + 2) & 7, false), ((dir - 2) & 7, false)] {
                            let yy = y0 + i + sign * dirs[(d * 2 + k) * 2]
                            let xx = x0 + j + sign * dirs[(d * 2 + k) * 2 + 1]
                            let cr = (yy << sy) >> 2, cc = (xx << sx) >> 2
                            guard yy >= 0, xx >= 0, cr < miRows, cc < miCols else { continue }
                            let s = p.at(xx, yy)
                            if isPri {
                                sum += priTaps[priTap + k] * constrain(s - x, priStr)
                            } else {
                                sum += secTaps[k] * constrain(s - x, secStr)
                            }
                            mx = max(s, mx)
                            mn = min(s, mn)
                        }
                    }
                }
                let v = clip3(mn, mx, x + ((8 + sum - (sum < 0 ? 1 : 0)) >> 4))
                out[plane][(y0 + i - bandY0) * p.width + x0 + j] = UInt16(v)
            }
        }
    }

    // MARK: Superres upscaling (7.16)

    func upscale(_ input: [AV1PlaneBuffer]) -> [AV1PlaneBuffer] {
        let h = f.hdr
        guard h.useSuperres else { return input }
        var out: [AV1PlaneBuffer] = []
        let maxV = (1 << f.bitDepth) - 1
        for plane in 0..<f.numPlanes {
            let sx = plane > 0 ? f.subX : 0, sy = plane > 0 ? f.subY : 0
            let downW = round2(h.frameWidth, sx), upW = round2(h.upscaledWidth, sx), planeH = round2(h.frameHeight, sy)
            let stepX = ((downW << 14) + (upW / 2)) / upW
            let err = upW * stepX - (downW << 14)
            var initialSubpelX = (-((upW - downW) << (14 - 1)) + upW / 2) / upW + (1 << (8 - 1)) - err / 2
            initialSubpelX &= 16383
            let miW = h.miCols >> sx
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
