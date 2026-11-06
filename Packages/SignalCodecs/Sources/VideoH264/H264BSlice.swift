// B macroblocks (H.264 7.4.5 Tables 7-14, 7-18): partitions with L0/L1/Bi prediction,
// B_8x8 sub-macroblocks, direct prediction (8.4.1.2: spatial and temporal, with
// direct_8x8_inference) for B_Skip, B_Direct_16x16 and B_Direct_8x8, and implicit weights
// (8.4.2.3.1).

import CodecCore

/// Per B mb_type 1…21: partition shape (0 16x16, 1 16x8, 2 8x16) and prediction per
/// partition (1 L0, 2 L1, 3 Bi).
let bMBTypes: [(shape: Int, pred: [Int])] = [
    (0, []), (0, [1]), (0, [2]), (0, [3]),
    (1, [1, 1]), (2, [1, 1]), (1, [2, 2]), (2, [2, 2]), (1, [1, 2]), (2, [1, 2]), (1, [2, 1]), (2, [2, 1]),
    (1, [1, 3]), (2, [1, 3]), (1, [2, 3]), (2, [2, 3]), (1, [3, 1]), (2, [3, 1]), (1, [3, 2]), (2, [3, 2]), (1, [3, 3]), (2, [3, 3]),
]
/// Per B sub_mb_type 0…12: (sub-partition layout index into pSubPartitions, prediction); 0 = direct.
let bSubTypes: [(layout: Int, pred: Int)] = [
    (0, 0), (0, 1), (0, 2), (0, 3), (1, 1), (2, 1), (1, 2), (2, 2), (1, 3), (2, 3), (3, 1), (3, 2), (3, 3),
]

/// The direct-predicted motion of one 4x4 block.
struct DirectMotion {
    var refIdx: (Int, Int)
    var mv0: (Int, Int), mv1: (Int, Int)
}

extension H264PictureDecoder {
    // MARK: direct prediction

    /// Co-located motion for 4x4 block `b` (raster) of `mb`: (mvCol, refIdxCol, the referenced
    /// picture's id and POC and long-term flag); refIdxCol −1 when the co-located block is intra.
    func colocated(_ col: RefPicture, _ mb: Int, _ b: Int, inference: Bool) -> (mv: (Int, Int), refIdx: Int, id: Int32, poc: Int, longTerm: Bool) {
        let blk = inference ? [0, 3, 12, 15][(b >> 3) * 2 + ((b & 3) >> 1)] : b
        let b8 = (blk >> 3) * 2 + ((blk & 3) >> 1)
        let m = col.motion
        if m.intra[mb] { return ((0, 0), -1, -1, 0, false) }
        let l = m.refIdx[(0) * m.n4 + mb * 4 + b8] >= 0 ? 0 : 1
        let r = Int(m.refIdx[(l) * m.n4 + mb * 4 + b8])
        guard r >= 0 else { return ((0, 0), -1, -1, 0, false) }
        return ((Int(m.mvX[(l) * m.n16 + mb * 16 + blk]), Int(m.mvY[(l) * m.n16 + mb * 16 + blk])), r, m.refID[(l) * m.n4 + mb * 4 + b8], Int(m.refPOC[(l) * m.n4 + mb * 4 + b8]), m.refLongTerm[(l) * m.n4 + mb * 4 + b8])
    }

    /// Direct motion for every 4x4 block of `mb` (8.4.1.2).
    func directMotion(_ mb: Int, _ h: H264SliceHeader, slice: Int32, refs: [[RefPicture?]], currentPOC: Int) throws(ParseFailure) -> [DirectMotion] {
        guard let col = refs[1].first ?? nil else { throw ParseFailure(offset: 0, rule: "direct", reason: .invalid("no RefPicList1[0]")) }
        let inference = sps.direct8x8Inference
        var out = [DirectMotion](repeating: DirectMotion(refIdx: (-1, -1), mv0: (0, 0), mv1: (0, 0)), count: 16)
        if h.directSpatialMvPred {
            var refIdx = [-1, -1]
            var mvp = [(0, 0), (0, 0)]
            for l in 0 ..< 2 {
                var (a, b, c) = neighbours(mb, x: 0, y: 0, w: 16, list: l, done: 0, slice: slice)
                func minPositive(_ x: Int, _ y: Int) -> Int { x >= 0 && y >= 0 ? min(x, y) : max(x, y) }
                refIdx[l] = minPositive(a.refIdx, minPositive(b.refIdx, c.refIdx))
                if refIdx[l] >= 0 { mvp[l] = median(&a, &b, &c, refIdx[l]) }
            }
            var zero = false
            if refIdx[0] < 0 && refIdx[1] < 0 { refIdx = [0, 0]; zero = true }
            let colShortTerm = !col.longTerm
            for b in 0 ..< 16 {
                let c = colocated(col, mb, b, inference: inference)
                let colZero = colShortTerm && c.refIdx == 0 && abs(c.mv.0) <= 1 && abs(c.mv.1) <= 1
                var d = DirectMotion(refIdx: (refIdx[0], refIdx[1]), mv0: (0, 0), mv1: (0, 0))
                if !zero {
                    if refIdx[0] > 0 || (refIdx[0] == 0 && !colZero) { d.mv0 = mvp[0] }
                    if refIdx[1] > 0 || (refIdx[1] == 0 && !colZero) { d.mv1 = mvp[1] }
                }
                out[b] = d
            }
            return out
        }
        // Temporal.
        for b in 0 ..< 16 {
            let c = colocated(col, mb, b, inference: inference)
            var refIdx0 = 0
            if c.refIdx >= 0 {
                // The lowest list-0 index of the picture the co-located block referenced.
                guard let i = refs[0].firstIndex(where: { $0?.id == c.id }) else {
                    throw ParseFailure(offset: 0, rule: "direct_temporal", reason: .invalid("co-located reference not in RefPicList0"))
                }
                refIdx0 = i
            }
            let mvCol = c.refIdx >= 0 ? c.mv : (0, 0)
            guard let pic0 = refs[0][refIdx0] else { throw ParseFailure(offset: 0, rule: "direct_temporal", reason: .invalid("no reference")) }
            let tb = clip3(-128, 127, currentPOC - pic0.poc), td = clip3(-128, 127, col.poc - pic0.poc)
            var d = DirectMotion(refIdx: (refIdx0, 0), mv0: mvCol, mv1: (0, 0))
            if !pic0.longTerm && td != 0 {
                let tx = (16384 + abs(td / 2)) / td
                let dsf = clip3(-1024, 1023, (tb * tx + 32) >> 6)
                d.mv0 = ((dsf * mvCol.0 + 128) >> 8, (dsf * mvCol.1 + 128) >> 8)
                d.mv1 = (d.mv0.0 - mvCol.0, d.mv0.1 - mvCol.1)
            }
            out[b] = d
        }
        return out
    }

    /// Implicit bi-prediction weights (8.4.2.3.1) for references (ref0, ref1).
    func implicitWeights(_ r0: RefPicture, _ r1: RefPicture, currentPOC: Int) -> PredWeights {
        let tb = clip3(-128, 127, currentPOC - r0.poc), td = clip3(-128, 127, r1.poc - r0.poc)
        var w0 = 32, w1 = 32
        if td != 0 && !r0.longTerm && !r1.longTerm {
            let tx = (16384 + abs(td / 2)) / td
            let dsf = clip3(-1024, 1023, (tb * tx + 32) >> 6)
            if dsf >> 2 >= -64 && dsf >> 2 <= 128 { w0 = 64 - (dsf >> 2); w1 = dsf >> 2 }
        }
        return PredWeights(logWD: 5, w0: w0, w1: w1, o0: 0, o1: 0)
    }

    /// Prediction weights for a B partition.
    func bWeights(_ h: H264SliceHeader, _ pps: H264PPS, refIdx: (Int, Int), refs: [[RefPicture?]], currentPOC: Int) -> (luma: PredWeights, cb: PredWeights, cr: PredWeights)? {
        if pps.weightedBipredIdc == 1 { return weights(h, pps, refIdx: refIdx, refs: refs) }
        if pps.weightedBipredIdc == 2 && refIdx.0 >= 0 && refIdx.1 >= 0, let a = refs[0][refIdx.0], let b = refs[1][refIdx.1] {
            let w = implicitWeights(a, b, currentPOC: currentPOC)
            return (w, w, w)
        }
        return nil
    }

    /// Applies direct motion to the 4x4 blocks selected by `mask` and predicts them, an 8x8
    /// at a time where its four blocks share their motion (always with direct_8x8_inference).
    mutating func applyDirect(_ mb: Int, _ d: [DirectMotion], mask: UInt16, _ h: H264SliceHeader, _ pps: H264PPS, refs: [[RefPicture?]], currentPOC: Int) throws(ParseFailure) {
        func same(_ a: DirectMotion, _ b: DirectMotion) -> Bool { a.refIdx == b.refIdx && a.mv0 == b.mv0 && a.mv1 == b.mv1 }
        for b8 in 0 ..< 4 {
            let corner = (b8 >> 1) * 8 + (b8 & 1) * 2
            let blocks = [corner, corner + 1, corner + 4, corner + 5]
            guard mask & (1 << UInt16(corner)) != 0 else { continue }
            let uniform = blocks.allSatisfy { same(d[$0], d[corner]) }
            for b in (uniform ? [corner] : blocks) {
                let m = d[b]
                let x = blkX(b), y = blkY(b), size = uniform ? 8 : 4
                var r0: RefPicture?, r1: RefPicture?
                for l in 0 ..< 2 {
                    let r = l == 0 ? m.refIdx.0 : m.refIdx.1
                    guard r >= 0 else { continue }
                    guard r < refs[l].count, let ref = refs[l][r] else { throw ParseFailure(offset: 0, rule: "direct", reason: .invalid("no reference \(r)")) }
                    if l == 0 { r0 = ref } else { r1 = ref }
                    let mv = l == 0 ? m.mv0 : m.mv1
                    setMotion(mb, x: x, y: y, w: size, h: size, list: l, refIdx: r, mvx: mv.0, mvy: mv.1, ref: ref)
                }
                _ = r0; _ = r1
                addPart(mb, x: x, y: y, w: size, h: size)
            }
        }
    }

    /// Vectors and prediction of one B partition (pred: 1 L0, 2 L1, 3 Bi).
    mutating func predictBPartition(_ mb: Int, x: Int, y: Int, w: Int, h: Int, pred: Int, refIdx: [Int], mvd: [(Int, Int)], shape: Int, done: inout UInt16,
                                    hdr: H264SliceHeader, _ pps: H264PPS, slice: Int32, refs: [[RefPicture?]], currentPOC: Int) throws(ParseFailure) {
        var used: [RefPicture?] = [nil, nil]
        var mvs = [(0, 0), (0, 0)]
        for l in 0 ..< 2 where pred & (1 << l) != 0 {
            guard refIdx[l] < refs[l].count, let ref = refs[l][refIdx[l]] else { throw ParseFailure(offset: 0, rule: "ref_idx", reason: .invalid("no reference \(refIdx[l])")) }
            let (px, py) = predictMV(mb, x: x, y: y, w: w, refIdx: refIdx[l], list: l, shape: shape, done: done, slice: slice)
            mvs[l] = (px + mvd[l].0, py + mvd[l].1)
            used[l] = ref
            setMotion(mb, x: x, y: y, w: w, h: h, list: l, refIdx: refIdx[l], mvx: mvs[l].0, mvy: mvs[l].1, ref: ref)
        }
        for by in stride(from: y, to: y + h, by: 4) { for bx in stride(from: x, to: x + w, by: 4) { done |= 1 << UInt16((by >> 2) * 4 + (bx >> 2)) } }
        addPart(mb, x: x, y: y, w: w, h: h)
    }
}
