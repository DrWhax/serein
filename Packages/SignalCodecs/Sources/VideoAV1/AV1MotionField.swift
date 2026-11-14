// Motion fields between frames: the motion field motion vector storage process (7.19), run when
// a frame is saved as a reference, and the motion field estimation process (7.9), which projects
// the saved vectors of the references onto the current frame for the temporal candidates of
// the motion vector stack.

import Dispatch
import Synchronization

enum AV1MotionField {
    static let refmvsLimit = (1 << 12) - 1
    static let maxFrameDistance = 31

    /// MfRefFrames (one per mode info unit) and MfMvs (row, col per unit) of a decoded frame,
    /// MiCols per row; the frame's RefFrames / Mvs have `stride` units per row.
    static func store(refFrames: [Int8], mvs: [Int32], stride: Int, miRows: Int, miCols: Int, hdr: AV1FrameHeader, seq: AV1SequenceHeader,
                      refOrderHint: (Int) -> Int) -> (refs: [Int8], mvs: [Int32]) {
        let n = miRows * miCols
        var outRefs = [Int8](repeating: Int8(AV1Ref.none), count: n)
        var outMvs = [Int32](repeating: 0, count: 2 * n)
        let used = (miRows - 1) * stride + miCols
        guard !hdr.frameIsIntra, n > 0, stride >= miCols, refFrames.count >= 2 * used, mvs.count >= 4 * used else { return (outRefs, outMvs) }
        var dists = [Int](repeating: 0, count: 8)
        for r in AV1Ref.last...AV1Ref.altref { dists[r] = seq.relativeDist(refOrderHint(hdr.refFrameIdx[r - 1]), hdr.orderHint) }
        var backward = [Bool](repeating: false, count: 8)
        for r in AV1Ref.last...AV1Ref.altref { backward[r] = dists[r] < 0 }
        let rf = refFrames.span, mv = mvs.span
        var oRefs = outRefs.mutableSpan, oMvs = outMvs.mutableSpan
        for row in 0..<miRows {
            for col in 0..<miCols {
                let i = row * stride + col, o = row * miCols + col
                for list in 0..<2 {
                    let r = Int(rf[2 * i + list])
                    guard r > AV1Ref.intra, backward[r] else { continue }
                    let mvRow = mv[4 * i + 2 * list], mvCol = mv[4 * i + 2 * list + 1]
                    if abs(mvRow) <= Int32(refmvsLimit) && abs(mvCol) <= Int32(refmvsLimit) {
                        oRefs[o] = Int8(r)
                        oMvs[2 * o] = mvRow
                        oMvs[2 * o + 1] = mvCol
                    }
                }
            }
        }
        return (outRefs, outMvs)
    }

    /// The motion field estimation process (7.9). Every position a vector is projected to
    /// gets it for all seven references at once, so the field keeps, per 8x8, the last vector
    /// projected there and its divisor; MotionFieldMvs[ref] is that vector projected over
    /// the reference's distance (AV1MotionFieldMvs.mv). Rows project within their 64-row
    /// band, so bands run in parallel, each through the projections in order.
    static func estimate(hdr h: AV1FrameHeader, seq: AV1SequenceHeader, slots: [AV1RefSlot]) -> AV1MotionFieldMvs {
        let w8 = h.miCols >> 1, h8 = h.miRows >> 1
        var refToDst = [Int](repeating: 0, count: 8)
        for dst in AV1Ref.last...AV1Ref.altref { refToDst[dst] = clip3(-maxFrameDistance, maxFrameDistance, seq.relativeDist(h.orderHint, h.orderHints[dst])) }
        // The projections that run (7.9.1), in order: source, its sign, and whether it is
        // within range (one out of range counts as done, projecting nothing).
        struct Projection: Sendable { let src: Int, sign: Int, num: Int, offset: [Int], usable: [Bool] }
        var plan: [Projection] = []
        func project(_ src: Int, _ dstSign: Int) -> Bool {
            let slot = slots[h.refFrameIdx[src - 1]]
            guard slot.miRows == h.miRows, slot.miCols == h.miCols, slot.frameType != AV1FrameType.intraOnly, slot.frameType != AV1FrameType.key,
                  slot.savedRefFrames.count >= h.miRows * h.miCols, slot.savedMvs.count >= 2 * h.miRows * h.miCols else { return false }
            let refToCur = seq.relativeDist(h.orderHints[src], h.orderHint)
            guard abs(refToCur) <= maxFrameDistance else { return true }
            var offset = [Int](repeating: 0, count: 8), usable = [Bool](repeating: false, count: 8)
            for r in AV1Ref.last...AV1Ref.altref {
                offset[r] = seq.relativeDist(h.orderHints[src], slot.savedOrderHints[r])
                usable[r] = abs(offset[r]) <= maxFrameDistance && offset[r] > 0
            }
            plan.append(Projection(src: src, sign: dstSign, num: clip3(-maxFrameDistance, maxFrameDistance, refToCur * dstSign), offset: offset, usable: usable))
            return true
        }
        let lastIdx = h.refFrameIdx[0]
        if slots[lastIdx].savedOrderHints[AV1Ref.altref] != h.orderHints[AV1Ref.golden] { _ = project(AV1Ref.last, -1) }
        var refStamp = 3 - 2
        if seq.relativeDist(h.orderHints[AV1Ref.bwdref], h.orderHint) > 0 && project(AV1Ref.bwdref, 1) { refStamp -= 1 }
        if seq.relativeDist(h.orderHints[AV1Ref.altref2], h.orderHint) > 0 && project(AV1Ref.altref2, 1) { refStamp -= 1 }
        if seq.relativeDist(h.orderHints[AV1Ref.altref], h.orderHint) > 0 && refStamp >= 0 && project(AV1Ref.altref, 1) { refStamp -= 1 }
        if refStamp >= 0 { _ = project(AV1Ref.last2, -1) }
        var field = AV1MotionFieldMvs(stride8: w8, refToDst: refToDst)
        guard !plan.isEmpty, w8 > 0, h8 > 0 else { return field }
        let divMult = AV1Tables.divMult.map(Int.init)
        let miCols = h.miCols
        let sources = plan.map { (refs: slots[h.refFrameIdx[$0.src - 1]].savedRefFrames, mvs: slots[h.refFrameIdx[$0.src - 1]].savedMvs) }
        let bands = (h8 + 7) / 8
        let steps = plan
        let results = Mutex<[[Int32]]>(Array(repeating: [], count: bands))
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            let y0 = band * 8, y1 = min(h8, y0 + 8)
            var out = [Int32](repeating: 0, count: 3 * w8 * (y1 - y0))
            do {
                var o = out.mutableSpan
                for (pi, p) in steps.enumerated() {
                    let srcRefs = sources[pi].refs, srcMvs = sources[pi].mvs
                    let refs = srcRefs.span, mvs = srcMvs.span
                    for y8 in y0..<y1 {
                        let k0 = (2 * y8 + 1) * miCols + 1
                        for x8 in 0..<w8 {
                            let k = k0 + 2 * x8
                            let srcRef = Int(refs[k])
                            guard srcRef > AV1Ref.intra, p.usable[srcRef] else { continue }
                            let den = min(maxFrameDistance, p.offset[srcRef])
                            let mvRow = Int(mvs[2 * k]), mvCol = Int(mvs[2 * k + 1])
                            let projY = clip3(-(1 << 14) + 1, (1 << 14) - 1, round2Signed(mvRow * p.num * divMult[den], 14))
                            let offY = projY >= 0 ? projY >> 6 : -((-projY) >> 6)
                            let posY8 = y8 + p.sign * offY
                            let baseY8 = (y8 >> 3) << 3
                            guard posY8 >= 0, posY8 < h8, posY8 >= baseY8, posY8 < baseY8 + 8 else { continue }
                            let projX = clip3(-(1 << 14) + 1, (1 << 14) - 1, round2Signed(mvCol * p.num * divMult[den], 14))
                            let offX = projX >= 0 ? projX >> 6 : -((-projX) >> 6)
                            let posX8 = x8 + p.sign * offX
                            let baseX8 = (x8 >> 3) << 3
                            guard posX8 >= 0, posX8 < w8, posX8 >= baseX8 - 8, posX8 < baseX8 + 16 else { continue }
                            let i = 3 * ((posY8 - y0) * w8 + posX8)
                            o[i] = Int32(mvRow)
                            o[i + 1] = Int32(mvCol)
                            o[i + 2] = Int32(den)
                        }
                    }
                }
            }
            let done = out
            results.withLock { $0[band] = done }
        }
        var all: [Int32] = []
        all.reserveCapacity(3 * w8 * h8)
        for b in results.withLock({ $0 }) { all += b }
        field.mvs = all
        return field
    }
}

/// MotionFieldMvs, unprojected (AV1MotionField.estimate): (row, col, divisor) per 8x8, a zero
/// divisor where nothing was projected.
struct AV1MotionFieldMvs: Sendable {
    var mvs: [Int32] = []
    var stride8 = 0
    var refToDst = [Int](repeating: 0, count: 8)

    /// MotionFieldMvs[ref][y8][x8], nil where invalid.
    @inline(__always) func mv(_ ref: Int, _ y8: Int, _ x8: Int) -> (Int, Int)? {
        let k = 3 * (y8 * stride8 + x8)
        guard k + 2 < mvs.count, mvs[k + 2] != 0 else { return nil }
        let den = Int(mvs[k + 2]), num = refToDst[ref]
        let dm = Int(AV1Tables.divMult[den])
        return (clip3(-(1 << 14) + 1, (1 << 14) - 1, round2Signed(Int(mvs[k]) * num * dm, 14)),
                clip3(-(1 << 14) + 1, (1 << 14) - 1, round2Signed(Int(mvs[k + 1]) * num * dm, 14)))
    }
}
