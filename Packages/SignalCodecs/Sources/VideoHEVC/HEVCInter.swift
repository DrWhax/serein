// Inter prediction (H.265 8.5): prediction_unit syntax (7.3.8.6, mvd_coding 7.3.8.9), merge
// candidates (8.5.3.2.2 – 8.5.3.2.5), AMVP (8.5.3.2.6 – 8.5.3.2.7), temporal motion vector
// prediction (8.5.3.2.8 – 8.5.3.2.9), and motion compensation: fractional sample
// interpolation (8.5.3.3.3) and weighted sample prediction (8.5.3.3.4).

import CodecCore

/// One slice's references: pictures, POCs, long-term flags; the collocated picture.
final class HEVCInterContext {
    let refs: [[HEVCPicture]]
    let refPoc: [[Int]]
    let refLongTerm: [[Bool]]
    let currPoc: Int
    let colPic: HEVCPicture?
    let noBackwardPred: Bool
    let weights: HEVCPredWeight?

    init(refs: [[HEVCPicture]], refLongTerm: [[Bool]], currPoc: Int, colPic: HEVCPicture?, weights: HEVCPredWeight?) {
        self.refs = refs
        refPoc = refs.map { $0.map(\.poc) }
        self.refLongTerm = refLongTerm
        self.currPoc = currPoc
        self.colPic = colPic
        noBackwardPred = refs.allSatisfy { $0.allSatisfy { $0.poc <= currPoc } }
        self.weights = weights
    }

    struct Cand: Equatable {
        var m = HEVCMotion()
    }

    // MARK: syntax (7.3.8.6)

    static let partRects: [[(Int, Int, Int, Int)]] = [
        [(0, 0, 4, 4)], [(0, 0, 4, 2), (0, 2, 4, 2)], [(0, 0, 2, 4), (2, 0, 2, 4)], [(0, 0, 2, 2), (2, 0, 2, 2), (0, 2, 2, 2), (2, 2, 2, 2)],
        [(0, 0, 4, 1), (0, 1, 4, 3)], [(0, 0, 4, 3), (0, 3, 4, 1)], [(0, 0, 1, 4), (1, 0, 3, 4)], [(0, 0, 3, 4), (3, 0, 1, 4)]]

    /// The CU's prediction units (in quarters of nCbS); returns merge_flag of the first PU.
    func predictionUnits(_ d: inout HEVCSliceDecoder, _ x0: Int, _ y0: Int, log2CbSize: Int, partMode: Int) throws(ParseFailure) -> Bool {
        let s = 1 << log2CbSize, q = s / 4
        var firstMerge = false
        for (i, r) in Self.partRects[partMode].enumerated() {
            let merge = d.cabac.decision(HEVCCtx.mergeFlag) == 1
            if i == 0 { firstMerge = merge }
            try predictionUnit(&d, x0 + r.0 * q, y0 + r.1 * q, r.2 * q, r.3 * q, log2CbSize: log2CbSize, partIdx: i, merge: merge,
                               cb: (x0, y0, s), partMode: partMode)
        }
        return firstMerge
    }

    /// cu_skip: one 2Nx2N merge PU.
    func predictionUnit(_ d: inout HEVCSliceDecoder, _ x: Int, _ y: Int, _ w: Int, _ h: Int, log2CbSize: Int, partIdx: Int, merge: Bool) throws(ParseFailure) {
        try predictionUnit(&d, x, y, w, h, log2CbSize: log2CbSize, partIdx: partIdx, merge: merge, cb: (x, y, 1 << log2CbSize), partMode: 0)
    }

    func predictionUnit(_ d: inout HEVCSliceDecoder, _ x: Int, _ y: Int, _ w: Int, _ h: Int, log2CbSize: Int, partIdx: Int, merge: Bool,
                        cb: (x: Int, y: Int, s: Int), partMode: Int) throws(ParseFailure) {
        let hd = d.header
        var motion: HEVCMotion
        if merge {
            var idx = 0
            if hd.maxNumMergeCand > 1 {
                if d.cabac.decision(HEVCCtx.mergeIdx) == 1 {
                    idx = 1
                    while idx < hd.maxNumMergeCand - 1 && d.cabac.bypass() == 1 { idx += 1 }
                }
            }
            motion = mergeMotion(d, x, y, w, h, cb: cb, partIdx: partIdx, partMode: partMode, mergeIdx: idx)
        } else {
            var pred = 0    // 0 L0, 1 L1, 2 BI
            if hd.type == .b {
                if w + h != 12 {
                    let depth = Int(d.pic.ctDepth[d.pic.i4(cb.x, cb.y)])
                    if d.cabac.decision(HEVCCtx.interPredIdc + depth) == 1 { pred = 2 } else { pred = d.cabac.decision(HEVCCtx.interPredIdc + 4) }
                } else {
                    pred = d.cabac.decision(HEVCCtx.interPredIdc + 4)
                }
            }
            var refIdx = [-1, -1]
            var mvd = [(0, 0), (0, 0)]
            var mvpFlag = [0, 0]
            for l in 0..<2 where (l == 0 && pred != 1) || (l == 1 && pred != 0) {
                refIdx[l] = 0
                let n = hd.numRefIdxActive[l]
                if n > 1 {
                    var v = 0
                    while v < n - 1 {
                        let bin = v < 2 ? d.cabac.decision(HEVCCtx.refIdx + v) : d.cabac.bypass()
                        if bin == 0 { break }
                        v += 1
                    }
                    refIdx[l] = v
                }
                if l == 1 && hd.mvdL1Zero && pred == 2 { mvd[1] = (0, 0) } else { mvd[l] = try mvdCoding(&d) }
                mvpFlag[l] = d.cabac.decision(HEVCCtx.mvpFlag)
            }
            motion = HEVCMotion()
            for l in 0..<2 where refIdx[l] >= 0 {
                let mvp = amvp(d, x, y, w, h, cb: cb, partIdx: partIdx, list: l, refIdx: refIdx[l])[mvpFlag[l]]
                let mx = Int16(truncatingIfNeeded: mvp.0 + mvd[l].0), my = Int16(truncatingIfNeeded: mvp.1 + mvd[l].1)
                if l == 0 { motion.refIdx.0 = Int8(refIdx[0]); motion.mv.0 = mx; motion.mv.1 = my }
                else { motion.refIdx.1 = Int8(refIdx[1]); motion.mv.2 = mx; motion.mv.3 = my }
            }
        }
        d.pic.fill(&d.pic.motion, x, y, w, h, motion)
        d.markEdges(x, y, w, h, tu: false)
        motionCompensate(&d, x, y, w, h, motion)
    }

    /// mvd_coding (7.3.8.9; abs_mvd_minus2 is EG1).
    func mvdCoding(_ d: inout HEVCSliceDecoder) throws(ParseFailure) -> (Int, Int) {
        let g0x = d.cabac.decision(HEVCCtx.absMvdGreater0) == 1, g0y = d.cabac.decision(HEVCCtx.absMvdGreater0) == 1
        let g1x = g0x && d.cabac.decision(HEVCCtx.absMvdGreater1) == 1, g1y = g0y && d.cabac.decision(HEVCCtx.absMvdGreater1) == 1
        func component(_ g0: Bool, _ g1: Bool) throws(ParseFailure) -> Int {
            guard g0 else { return 0 }
            var v = 1
            if g1 {
                var k = 1, abs = 0
                while d.cabac.bypass() == 1 {
                    abs += 1 << k
                    k += 1
                    guard k < 32 else { throw ParseFailure(offset: 0, rule: "abs_mvd_minus2", reason: .invalid("too long")) }
                }
                abs += d.cabac.bypassBits(k)
                v = abs + 2
            }
            return d.cabac.bypass() == 1 ? -v : v
        }
        let x = try component(g0x, g1x), y = try component(g0y, g1y)
        return (x, y)
    }

    // MARK: neighbours (6.4.2)

    /// Prediction block availability of (xN, yN) for the PU at (xP, yP) of the CU `cb`.
    func availablePB(_ d: HEVCSliceDecoder, cb: (x: Int, y: Int, s: Int), _ xP: Int, _ yP: Int, w: Int, h: Int, partIdx: Int, _ xN: Int, _ yN: Int) -> Bool {
        var ok: Bool
        let sameCb = cb.x <= xN && yN >= cb.y && cb.x + cb.s > xN && cb.y + cb.s > yN
        if !sameCb {
            ok = d.available(xP, yP, xN, yN)
        } else if w << 1 == cb.s && h << 1 == cb.s && partIdx == 1 && cb.y + h <= yN && cb.x + w > xN {
            ok = false
        } else {
            ok = true
        }
        if ok && d.pic.predMode[d.pic.i4(xN, yN)] == 1 { ok = false }
        if ok && d.pic.predMode[d.pic.i4(xN, yN)] == 255 { ok = false }
        return ok
    }

    @inline(__always) func motionAt(_ d: HEVCSliceDecoder, _ x: Int, _ y: Int) -> HEVCMotion { d.pic.motion[d.pic.i4(x, y)] }

    // MARK: merge (8.5.3.2.2 – 8.5.3.2.5)

    func mergeMotion(_ d: HEVCSliceDecoder, _ xOrig: Int, _ yOrig: Int, _ wOrig: Int, _ hOrig: Int, cb: (x: Int, y: Int, s: Int), partIdx pOrig: Int,
                     partMode: Int, mergeIdx: Int) -> HEVCMotion {
        var x = xOrig, y = yOrig, w = wOrig, h = hOrig, partIdx = pOrig
        let parMrg = d.pps.log2ParallelMergeLevel
        if parMrg > 2 && cb.s == 8 { x = cb.x; y = cb.y; w = cb.s; h = cb.s; partIdx = 0 }
        let singleMCL = parMrg > 2 && cb.s == 8
        var list: [HEVCMotion] = []
        func spatial(_ xN: Int, _ yN: Int) -> HEVCMotion? {
            if (x >> parMrg) == (xN >> parMrg) && (y >> parMrg) == (yN >> parMrg) { return nil }
            guard availablePB(d, cb: cb, x, y, w: w, h: h, partIdx: partIdx, xN, yN) else { return nil }
            return motionAt(d, xN, yN)
        }
        let pm = singleMCL ? 0 : partMode
        // availableN (after the partition rules) and availableFlagN (after pruning), 8.5.3.2.3.
        var a1 = spatial(x - 1, y + h - 1)
        if partIdx == 1 && [2, 6, 7].contains(pm) { a1 = nil }
        var b1 = spatial(x + w - 1, y - 1)
        if partIdx == 1 && [1, 4, 5].contains(pm) { b1 = nil }
        let b0 = spatial(x + w, y - 1), a0 = spatial(x - 1, y + h), b2 = spatial(x - 1, y - 1)
        func same(_ u: HEVCMotion?, _ v: HEVCMotion?) -> Bool { u != nil && v != nil && u! == v! }
        let fA1 = a1
        let fB1 = same(a1, b1) ? nil : b1
        let fB0 = same(b1, b0) ? nil : b0
        let fA0 = same(a1, a0) ? nil : a0
        var fB2 = same(a1, b2) || same(b1, b2) ? nil : b2
        if [fA0, fA1, fB0, fB1].allSatisfy({ $0 != nil }) { fB2 = nil }
        for c in [fA1, fB1, fB0, fA0, fB2] { if let c { list.append(c) } }
        // Temporal (refIdx 0).
        if list.count < d.header.maxNumMergeCand && d.header.temporalMvpEnabled {
            var m = HEVCMotion()
            if let mv = temporal(d, x, y, w, h, list: 0, refIdx: 0) { m.refIdx.0 = 0; m.mv.0 = mv.0; m.mv.1 = mv.1 }
            if d.header.type == .b, let mv = temporal(d, x, y, w, h, list: 1, refIdx: 0) { m.refIdx.1 = 0; m.mv.2 = mv.0; m.mv.3 = mv.1 }
            if m.refIdx.0 >= 0 || m.refIdx.1 >= 0 { list.append(m) }
        }
        // Combined bi-predictive (B).
        let numOrig = list.count
        if d.header.type == .b && numOrig > 1 && numOrig < d.header.maxNumMergeCand {
            let l0Idx = [0, 1, 0, 2, 1, 2, 0, 3, 1, 3, 2, 3], l1Idx = [1, 0, 2, 0, 2, 1, 3, 0, 3, 1, 3, 2]
            var combIdx = 0
            while combIdx < numOrig * (numOrig - 1) && list.count < d.header.maxNumMergeCand {
                let c0 = list[l0Idx[combIdx]], c1 = list[l1Idx[combIdx]]
                if c0.refIdx.0 >= 0 && c1.refIdx.1 >= 0
                    && (refPoc[0][Int(c0.refIdx.0)] != refPoc[1][Int(c1.refIdx.1)] || c0.mv.0 != c1.mv.2 || c0.mv.1 != c1.mv.3) {
                    var m = HEVCMotion()
                    m.refIdx = (c0.refIdx.0, c1.refIdx.1)
                    m.mv = (c0.mv.0, c0.mv.1, c1.mv.2, c1.mv.3)
                    list.append(m)
                }
                combIdx += 1
            }
        }
        // Zero candidates.
        let numRef = d.header.type == .p ? d.header.numRefIdxActive[0] : min(d.header.numRefIdxActive[0], d.header.numRefIdxActive[1])
        var zeroIdx = 0
        while list.count < d.header.maxNumMergeCand {
            var m = HEVCMotion()
            let r = Int8(zeroIdx < numRef ? zeroIdx : 0)
            m.refIdx.0 = r
            if d.header.type == .b { m.refIdx.1 = r }
            list.append(m)
            zeroIdx += 1
        }
        var m = list[mergeIdx]
        if m.refIdx.0 >= 0 && m.refIdx.1 >= 0 && wOrig + hOrig == 12 { m.refIdx.1 = -1; m.mv.2 = 0; m.mv.3 = 0 }
        return m
    }

    // MARK: AMVP (8.5.3.2.6, 8.5.3.2.7)

    func scale(_ mv: (Int, Int), td tdRaw: Int, tb tbRaw: Int) -> (Int, Int) {
        let td = max(-128, min(127, tdRaw)), tb = max(-128, min(127, tbRaw))
        guard td != 0 else { return mv }
        let tx = (16384 + (abs(td) >> 1)) / td
        let dsf = max(-4096, min(4095, (tb * tx + 32) >> 6))
        func s(_ v: Int) -> Int {
            let p = dsf * v
            return max(-32768, min(32767, (p >= 0 ? 1 : -1) * ((abs(p) + 127) >> 8)))
        }
        return (s(mv.0), s(mv.1))
    }

    func amvp(_ d: HEVCSliceDecoder, _ x: Int, _ y: Int, _ w: Int, _ h: Int, cb: (x: Int, y: Int, s: Int), partIdx: Int, list X: Int, refIdx: Int) -> [(Int, Int)] {
        let Y = 1 - X
        let targetPoc = refPoc[X][refIdx], targetLT = refLongTerm[X][refIdx]
        func mvOf(_ m: HEVCMotion, _ l: Int) -> (Int, Int) { l == 0 ? (Int(m.mv.0), Int(m.mv.1)) : (Int(m.mv.2), Int(m.mv.3)) }
        func ref(_ m: HEVCMotion, _ l: Int) -> Int { Int(l == 0 ? m.refIdx.0 : m.refIdx.1) }
        func avail(_ xN: Int, _ yN: Int) -> HEVCMotion? {
            availablePB(d, cb: cb, x, y, w: w, h: h, partIdx: partIdx, xN, yN) ? motionAt(d, xN, yN) : nil
        }
        // First pass: same picture, no scaling.
        func samePicture(_ m: HEVCMotion) -> (Int, Int)? {
            if ref(m, X) >= 0 && refPoc[X][ref(m, X)] == targetPoc && refLongTerm[X][ref(m, X)] == targetLT { return mvOf(m, X) }
            if ref(m, Y) >= 0 && refPoc[Y][ref(m, Y)] == targetPoc && refLongTerm[Y][ref(m, Y)] == targetLT { return mvOf(m, Y) }
            return nil
        }
        // Second pass: any picture of the same long-term-ness, scaled when both short-term.
        func scaled(_ m: HEVCMotion) -> (Int, Int)? {
            for l in [X, Y] where ref(m, l) >= 0 && refLongTerm[l][ref(m, l)] == targetLT {
                let mv = mvOf(m, l)
                if targetLT { return mv }
                return scale(mv, td: currPoc - refPoc[l][ref(m, l)], tb: currPoc - targetPoc)
            }
            return nil
        }
        let aN = [avail(x - 1, y + h), avail(x - 1, y + h - 1)]
        let isScaled = aN.contains { $0 != nil }
        var mvA: (Int, Int)?
        for m in aN { if mvA == nil, let m { mvA = samePicture(m) } }
        if mvA == nil { for m in aN { if mvA == nil, let m { mvA = scaled(m) } } }
        let bN = [avail(x + w, y - 1), avail(x + w - 1, y - 1), avail(x - 1, y - 1)]
        var mvB: (Int, Int)?
        for m in bN { if mvB == nil, let m { mvB = samePicture(m) } }
        if !isScaled && mvB != nil && mvA == nil { mvA = mvB }
        if !isScaled {
            mvB = nil
            for m in bN { if mvB == nil, let m { mvB = scaled(m) } }
        }
        var out: [(Int, Int)] = []
        if let a = mvA { out.append(a) }
        if let b = mvB, !(mvA.map { $0 == b } ?? false) { out.append(b) }
        if out.count < 2 && d.header.temporalMvpEnabled, let t = temporal(d, x, y, w, h, list: X, refIdx: refIdx) {
            out.append((Int(t.0), Int(t.1)))
        }
        while out.count < 2 { out.append((0, 0)) }
        return Array(out.prefix(2))
    }

    // MARK: temporal (8.5.3.2.8, 8.5.3.2.9)

    func temporal(_ d: HEVCSliceDecoder, _ x: Int, _ y: Int, _ w: Int, _ h: Int, list X: Int, refIdx: Int) -> (Int16, Int16)? {
        guard let col = colPic else { return nil }
        let sps = d.sps
        let xBr = x + w, yBr = y + h
        if (y >> sps.log2CtbSize) == (yBr >> sps.log2CtbSize) && yBr < sps.height && xBr < sps.width,
           let mv = collocated(col, (xBr >> 4) << 4, (yBr >> 4) << 4, list: X, refIdx: refIdx, d: d) {
            return mv
        }
        let xC = x + (w >> 1), yC = y + (h >> 1)
        return collocated(col, (xC >> 4) << 4, (yC >> 4) << 4, list: X, refIdx: refIdx, d: d)
    }

    func collocated(_ col: HEVCPicture, _ x: Int, _ y: Int, list X: Int, refIdx: Int, d: HEVCSliceDecoder) -> (Int16, Int16)? {
        let k = col.i4(x, y)
        guard col.predMode[k] == 0 || col.predMode[k] == 2 else { return nil }
        let m = col.motion[k]
        let ctb = (x >> col.sps.log2CtbSize) + (y >> col.sps.log2CtbSize) * col.sps.widthCtbs
        let slice = Int(col.ctbSliceIndex[ctb])
        guard col.sliceRefPocs.indices.contains(slice) else { return nil }
        var listCol: Int
        if m.refIdx.0 < 0 { listCol = 1 }
        else if m.refIdx.1 < 0 { listCol = 0 }
        else { listCol = noBackwardPred ? X : (d.header.collocatedFromL0 ? 1 : 0) }
        let refIdxCol = Int(listCol == 0 ? m.refIdx.0 : m.refIdx.1)
        guard refIdxCol >= 0 else { return nil }
        let mvCol = listCol == 0 ? (Int(m.mv.0), Int(m.mv.1)) : (Int(m.mv.2), Int(m.mv.3))
        let colRefLT = col.sliceRefLongTerm[slice][listCol][refIdxCol]
        guard colRefLT == refLongTerm[X][refIdx] else { return nil }
        let colPocDiff = col.poc - col.sliceRefPocs[slice][listCol][refIdxCol]
        let currPocDiff = currPoc - refPoc[X][refIdx]
        if refLongTerm[X][refIdx] || colPocDiff == currPocDiff { return (Int16(mvCol.0), Int16(mvCol.1)) }
        let s = scale(mvCol, td: colPocDiff, tb: currPocDiff)
        return (Int16(s.0), Int16(s.1))
    }

    // MARK: motion compensation (8.5.3.3)

    static let lumaFilter: [[Int32]] = [[0, 0, 0, 64, 0, 0, 0, 0], [-1, 4, -10, 58, 17, -5, 1, 0], [-1, 4, -11, 40, 40, -11, 4, -1], [0, 1, -5, 17, 58, -10, 4, -1]]
    static let chromaFilter: [[Int32]] = [[0, 64, 0, 0], [-2, 58, 10, -2], [-4, 54, 16, -2], [-6, 46, 28, -4], [-4, 36, 36, -4], [-4, 28, 46, -6],
                                          [-2, 16, 54, -4], [-2, 10, 58, -2]]

    /// predSamplesLX (14-bit intermediate) of one component: the reference window (clamped at
    /// the picture edges) is copied once, then filtered without bounds clamping.
    static func interpolate(_ ref: HEVCPlane, x xPb: Int, y yPb: Int, w: Int, h: Int, mvx: Int, mvy: Int, chroma: Bool, bitDepth: Int,
                            into outArr: inout [Int32], win winArr: inout [Int32], tmp tmpArr: inout [Int32]) {
        let fracBits = chroma ? 3 : 2, taps = chroma ? 4 : 8, half = chroma ? 1 : 3
        let xFrac = mvx & ((1 << fracBits) - 1), yFrac = mvy & ((1 << fracBits) - 1)
        let xInt = xPb + (mvx >> fracBits) - half, yInt = yPb + (mvy >> fracBits) - half
        let fxA = chroma ? Self.chromaFilter[xFrac] : Self.lumaFilter[xFrac], fyA = chroma ? Self.chromaFilter[yFrac] : Self.lumaFilter[yFrac]
        let shift1 = Int32(min(4, bitDepth - 8)), shift3 = Int32(max(2, 14 - bitDepth))
        let rw = ref.width, rh = ref.height
        let ww = w + taps - 1, wh = h + taps - 1
        if winArr.count < ww * wh { winArr = [Int32](repeating: 0, count: ww * wh) }
        if outArr.count < w * h { outArr = [Int32](repeating: 0, count: w * h) }
        do {
            let srcArr = ref.samples
            let src = srcArr.span
            var win = winArr.mutableSpan
            let inside = xInt >= 0 && yInt >= 0 && xInt + ww <= rw && yInt + wh <= rh
            var j = 0
            while j < wh {
                let sy = inside ? yInt + j : max(0, min(rh - 1, yInt + j))
                var i = 0
                let row = sy * rw, d = j * ww
                if inside {
                    let base = row + xInt
                    while i < ww { win[d + i] = Int32(src[base + i]); i += 1 }
                } else {
                    while i < ww { win[d + i] = Int32(src[row + max(0, min(rw - 1, xInt + i))]); i += 1 }
                }
                j += 1
            }
        }
        let win = winArr.span
        let fx = fxA.span, fy = fyA.span
        if xFrac == 0 && yFrac == 0 {
            var out = outArr.mutableSpan
            var j = 0
            while j < h {
                let src = half + (j + half) * ww, dst = j * w
                var i = 0
                while i < w { out[dst + i] = win[src + i] << shift3; i += 1 }
                j += 1
            }
        } else if yFrac == 0 {
            var out = outArr.mutableSpan
            var j = 0
            while j < h { Self.filter(&out, j * w, win, (j + half) * ww, step: 1, fx, taps, w, shift1); j += 1 }
        } else if xFrac == 0 {
            var out = outArr.mutableSpan
            var j = 0
            while j < h { Self.filter(&out, j * w, win, half + j * ww, step: ww, fy, taps, w, shift1); j += 1 }
        } else {
            if tmpArr.count < w * wh { tmpArr = [Int32](repeating: 0, count: w * wh) }
            do {
                var tmp = tmpArr.mutableSpan
                var j = 0
                while j < wh { Self.filter(&tmp, j * w, win, j * ww, step: 1, fx, taps, w, shift1); j += 1 }
            }
            let tmp = tmpArr.span
            var out = outArr.mutableSpan
            var j = 0
            while j < h { Self.filter(&out, j * w, tmp, j * w, step: w, fy, taps, w, 6); j += 1 }
        }
    }

    /// One row of an n-tap filter: dst[d + i] = (Σ c[t]·src[s + t·step + i]) >> shift, taps
    /// outer and pixels inner (the loops the optimiser vectorises).
    @inline(__always)
    static func filter(_ dst: inout MutableSpan<Int32>, _ d: Int, _ src: Span<Int32>, _ s: Int, step: Int, _ c: Span<Int32>, _ n: Int, _ w: Int,
                       _ shift: Int32) {
        let c0 = c[0]
        var i = 0
        while i < w { dst[d + i] = c0 &* src[s + i]; i += 1 }
        var t = 1
        while t < n {
            let ct = c[t], b = s + t * step
            i = 0
            while i < w { dst[d + i] &+= ct &* src[b + i]; i += 1 }
            t += 1
        }
        i = 0
        while i < w { dst[d + i] >>= shift; i += 1 }
    }

    /// The prediction of one PU, recorded (P/B slices reconstruct after parsing, in parallel)
    /// or made now.
    func motionCompensate(_ d: inout HEVCSliceDecoder, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ m: HEVCMotion) {
        var job = HEVCMCJob(x: Int32(x), y: Int32(y), w: Int32(w), h: Int32(h), refIdx: (-1, -1), mv: m.mv)
        if m.refIdx.0 >= 0 && refs[0].indices.contains(Int(m.refIdx.0)) { job.refIdx.0 = m.refIdx.0 }
        if m.refIdx.1 >= 0 && refs[1].indices.contains(Int(m.refIdx.1)) { job.refIdx.1 = m.refIdx.1 }
        d.mcJobs.append(job)
    }

    /// What every job of the slice shares: the reference planes and the weights.
    func shared(sps: HEVCSPS, pps: HEVCPPS, type: HEVCSliceHeader.SliceType) -> HEVCMCShared {
        let weighted = ((type == .p && pps.weightedPred) || (type == .b && pps.weightedBipred)) && weights != nil
        var ws = [Int32](repeating: 0, count: 2 * 16 * 3), os = ws
        if weighted, let wt = weights {
            for l in 0..<2 {
                for r in 0..<min(16, refs[l].count) {
                    if wt.luma[l].indices.contains(r) {
                        ws[(l * 16 + r) * 3] = Int32(wt.luma[l][r].w)
                        os[(l * 16 + r) * 3] = Int32(wt.luma[l][r].o)
                    }
                    if sps.chromaArrayType != 0, wt.chroma[l].indices.contains(r) {
                        for c in 0..<2 {
                            ws[(l * 16 + r) * 3 + 1 + c] = Int32(wt.chroma[l][r][c].w)
                            os[(l * 16 + r) * 3 + 1 + c] = Int32(wt.chroma[l][r][c].o)
                        }
                    }
                }
            }
        }
        return HEVCMCShared(refIds: refs.map { $0.map(\.id) }, planes: [], weightW: ws, weightO: os, weighted: weighted,
                            lumaLog2Denom: weights?.lumaLog2Denom ?? 0, chromaLog2Denom: weights?.chromaLog2Denom ?? 0,
                            comps: sps.chromaArrayType != 0 ? 3 : 1, subW: sps.subWidthC, subH: sps.subHeightC,
                            bitDepthLuma: sps.bitDepthLuma, bitDepthChroma: sps.bitDepthChroma)
    }

    /// 8.5.3.3: the predicted samples of a job, Y then Cb then Cr (raster in each component's
    /// block, chroma at `job.chromaOffset`).
    static func predict(_ job: HEVCMCJob, _ sh: HEVCMCShared, _ scratch: inout HEVCMCScratch) -> [UInt16] {
        let jw = Int(job.w), jh = Int(job.h), jx = Int(job.x), jy = Int(job.y)
        let cwC = jw / sh.subW, chC = jh / sh.subH
        var out = [UInt16](repeating: 0, count: jw * jh + (sh.comps > 1 ? 2 * cwC * chC : 0))
        // The lists used, first (L0 before L1), as (list, refIdx, mvx, mvy).
        var used: [(l: Int, r: Int, mvx: Int, mvy: Int)] = []
        if job.refIdx.0 >= 0 { used.append((0, Int(job.refIdx.0), Int(job.mv.0), Int(job.mv.1))) }
        if job.refIdx.1 >= 0 { used.append((1, Int(job.refIdx.1), Int(job.mv.2), Int(job.mv.3))) }
        if used.isEmpty { return out }
        let bi = used.count > 1
        var base = 0
        for c in 0..<sh.comps {
            let chroma = c > 0
            let bitDepth = chroma ? sh.bitDepthChroma : sh.bitDepthLuma
            let cx = chroma ? jx / sh.subW : jx, cy = chroma ? jy / sh.subH : jy
            let cw = chroma ? cwC : jw, ch = chroma ? chC : jh
            let n = cw * ch
            defer { base += n }
            let u0 = used[0]
            interpolate(sh.planes[u0.l][u0.r][c], x: cx, y: cy, w: cw, h: ch, mvx: u0.mvx, mvy: u0.mvy, chroma: chroma, bitDepth: bitDepth,
                        into: &scratch.pred0, win: &scratch.win, tmp: &scratch.tmp)
            if bi {
                let u1 = used[1]
                interpolate(sh.planes[u1.l][u1.r][c], x: cx, y: cy, w: cw, h: ch, mvx: u1.mvx, mvy: u1.mvy, chroma: chroma, bitDepth: bitDepth,
                            into: &scratch.pred1, win: &scratch.win, tmp: &scratch.tmp)
            }
            let maxV = Int32((1 << bitDepth) - 1)
            let shift1 = Int32(14 - bitDepth)
            let p0 = scratch.pred0.span, p1 = scratch.pred1.span
            var o = out.mutableSpan
            if sh.weighted {
                let log2WD = Int32(chroma ? sh.chromaLog2Denom : sh.lumaLog2Denom) + shift1
                let k0 = (used[0].l * 16 + used[0].r) * 3 + c
                let w0 = sh.weightW[k0], o0 = sh.weightO[k0]
                if !bi {
                    for i in 0..<n {
                        let p = p0[i]
                        let v = log2WD >= 1 ? ((p * w0 + (1 << (log2WD - 1))) >> log2WD) + o0 : p * w0 + o0
                        o[base + i] = UInt16(max(0, min(maxV, v)))
                    }
                } else {
                    let k1 = (used[1].l * 16 + used[1].r) * 3 + c
                    let w1 = sh.weightW[k1], o1 = sh.weightO[k1]
                    for i in 0..<n {
                        let v = (p0[i] * w0 + p1[i] * w1 + ((o0 + o1 + 1) << log2WD)) >> (log2WD + 1)
                        o[base + i] = UInt16(max(0, min(maxV, v)))
                    }
                }
            } else if !bi {
                let off = shift1 > 0 ? Int32(1) << (shift1 - 1) : 0
                for i in 0..<n { o[base + i] = UInt16(max(0, min(maxV, (p0[i] + off) >> shift1))) }
            } else {
                let shift2 = Int32(15 - bitDepth), off = Int32(1) << (shift2 - 1)
                for i in 0..<n { o[base + i] = UInt16(max(0, min(maxV, (p0[i] + p1[i] + off) >> shift2))) }
            }
        }
        return out
    }
}

/// Per-worker buffers for motion compensation (reused across jobs).
struct HEVCMCScratch {
    var win: [Int32] = []
    var tmp: [Int32] = []
    var pred0: [Int32] = []
    var pred1: [Int32] = []
}

/// One PU's motion compensation as plain data (no references: nothing to retain or free).
struct HEVCMCJob: Sendable {
    var x: Int32, y: Int32, w: Int32, h: Int32
    /// Per list the reference index, −1 when the list is unused.
    var refIdx: (Int8, Int8)
    var mv: (Int16, Int16, Int16, Int16)
}

/// What the jobs of one slice share (reference planes are copy-on-write values).
struct HEVCMCShared: Sendable {
    /// [list][refIdx] → picture id; the stage resolves them to `planes`.
    var refIds: [[Int]]
    /// [list][refIdx] → Y, Cb, Cr.
    var planes: [[[HEVCPlane]]]
    /// Weight and offset at (list · 16 + refIdx) · 3 + component, when weighted.
    var weightW: [Int32], weightO: [Int32]
    var weighted: Bool
    var lumaLog2Denom: Int, chromaLog2Denom: Int
    var comps: Int, subW: Int, subH: Int
    var bitDepthLuma: Int, bitDepthChroma: Int
}
