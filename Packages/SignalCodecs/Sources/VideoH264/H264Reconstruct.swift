// Reconstruction (H.264 8.3–8.6) from what the parser stored, one macroblock at a time into
// the picture's row stripes: intra prediction (the row above comes as a copied border, taken
// before deblocking), inter prediction from complete reference pictures, and the residual
// (scaling + inverse transforms). Rows run in parallel as a wavefront (H264Wavefront); each
// worker has its own Reconstructor (scratch buffers) and touches only its row's stripe.

import CodecCore
import Synchronization

/// One macroblock row of the picture: luma 16 lines, chroma 8 lines, full width.
final class Stripe: Sendable {
    let y: Mutex<[UInt8]>
    let u: Mutex<[UInt8]>
    let v: Mutex<[UInt8]>
    /// The unfiltered bottom lines (luma width, then Cb and Cr width / 2), published per
    /// macroblock for the row below's intra prediction.
    let border: Mutex<[UInt8]>

    init(width: Int) {
        y = Mutex(Array(repeating: 0, count: width * 16))
        u = Mutex(Array(repeating: 128, count: (width / 2) * 8))
        v = Mutex(Array(repeating: 128, count: (width / 2) * 8))
        border = Mutex(Array(repeating: 0, count: width * 2))
    }
}

extension Mutex where Value: ~Copyable {
    /// Takes the lock by spinning (critical sections here are short): no kernel sleeps.
    @inline(__always) borrowing func spinLock<R>(_ body: (inout sending Value) -> sending R) -> R {
        while true {
            if let r = withLockIfAvailable(body) { return r }
        }
    }
}

/// The unfiltered bottom line of the row above, around one macroblock: luma columns
/// mx − 1 ..< mx + 24, chroma cx − 1 ..< cx + 8 (out-of-picture samples are never read).
struct TopBorder {
    var y = [UInt8](repeating: 0, count: 25)
    var u = [UInt8](repeating: 0, count: 9)
    var v = [UInt8](repeating: 0, count: 9)
}

struct Reconstructor {
    let pd: H264PictureDecoder
    let width: Int, cwidth: Int
    var mcSrc = [Int32](repeating: 0, count: 21 * 21)
    var mcTmp = [Int32](repeating: 0, count: 16 * 21)
    var predY0 = [Int32](repeating: 0, count: 256), predY1 = [Int32](repeating: 0, count: 256)
    var predU0 = [Int32](repeating: 0, count: 64), predU1 = [Int32](repeating: 0, count: 64)
    var predV0 = [Int32](repeating: 0, count: 64), predV1 = [Int32](repeating: 0, count: 64)
    var coeff = [Int32](repeating: 0, count: 384)
    var coeff8 = [Int32](repeating: 0, count: 256)

    let st: MBState

    init(_ pd: H264PictureDecoder) {
        self.pd = pd
        st = pd.st
        width = pd.st.widthMbs * 16
        cwidth = width / 2
    }


    // MARK: macroblocks

    mutating func reconstruct(_ mb: Int, y: inout [UInt8], u: inout [UInt8], v: inout [UInt8], top: TopBorder) {
        let kind = st.kind[mb]
        let base = mb * MBState.levelStride
        let mx = (mb % st.widthMbs) * 16
        if kind.contains(.pcm) {
            for j in 0 ..< 16 { for i in 0 ..< 16 { y[j * width + mx + i] = UInt8(truncatingIfNeeded: st.levels[base + j * 16 + i]) } }
            for j in 0 ..< 8 {
                for i in 0 ..< 8 {
                    u[j * cwidth + mx / 2 + i] = UInt8(truncatingIfNeeded: st.levels[base + 256 + j * 8 + i])
                    v[j * cwidth + mx / 2 + i] = UInt8(truncatingIfNeeded: st.levels[base + 320 + j * 8 + i])
                }
            }
            return
        }
        let slice = Int(st.slice[mb])
        let info = pd.slices[slice]
        let cbp = Int(st.cbp[mb])
        let qp = Int(st.qp[mb])
        // Levels into the scratch (only the coded parts).
        if cbp & 15 != 0 || kind.contains(.intra16x16) {
            if kind.contains(.transform8x8) {
                for i in 0 ..< 256 { coeff8[i] = st.levels[base + i] }
            } else if cbp & 15 != 0 {
                for i in 0 ..< 256 { coeff[i] = st.levels[base + i] }
            }
        }
        if cbp >> 4 == 2 { for i in 256 ..< 384 { coeff[i] = st.levels[base + i] } }
        if kind.isIntra {
            reconstructIntraLuma(mb, kind, cbp: cbp, qp: qp, info, y: &y, top: top, base: base)
            let constrained = info.pps.constrainedIntraPred
            let sl = Int32(slice)
            let ea = pd.intraUsable(pd.neighbour(mb, 0, slice: sl), constrained: constrained)
            let eb = pd.intraUsable(pd.neighbour(mb, 1, slice: sl), constrained: constrained)
            let ed = pd.intraUsable(pd.neighbour(mb, 3, slice: sl), constrained: constrained)
            let cx = mx / 2
            for c in 0 ..< 2 {
                var e = IntraEdge(top: Array(repeating: 0, count: 16), left: Array(repeating: 0, count: 8), topLeft: 0, hasTop: eb, hasLeft: ea, hasTopLeft: ed, hasTopRight: false)
                let border = c == 0 ? top.u : top.v
                if eb { for i in 0 ..< 8 { e.top[i] = Int32(border[1 + i]) }; for i in 8 ..< 16 { e.top[i] = e.top[7] } }
                if ed { e.topLeft = Int32(border[0]) }
                if ea { for j in 0 ..< 8 { e.left[j] = Int32(c == 0 ? u[j * cwidth + cx - 1] : v[j * cwidth + cx - 1]) } }
                // The mode was checked against availability while parsing; a bad stream predicts 128.
                let p = H264Intra.predictChroma(Int(st.chromaPredMode[mb]), e) ?? Array(repeating: 128, count: 64)
                for j in 0 ..< 8 {
                    for i in 0 ..< 8 {
                        if c == 0 { u[j * cwidth + cx + i] = UInt8(truncatingIfNeeded: p[j * 8 + i]) } else { v[j * cwidth + cx + i] = UInt8(truncatingIfNeeded: p[j * 8 + i]) }
                    }
                }
            }
        } else {
            predictInter(mb, info, y: &y, u: &u, v: &v)
            if cbp & 15 != 0 { addLumaResidual(mb, kind, cbp: cbp, qp: qp, info, intra: false, y: &y) }
        }
        addChroma(mb, cbp: cbp, intra: kind.isIntra, info, base: base, u: &u, v: &v)
    }

    // MARK: intra

    func lumaEdge(_ y: [UInt8], top: TopBorder, mx: Int, bx: Int, by: Int, n: Int, _ f: (top: Bool, left: Bool, topLeft: Bool, topRight: Bool)) -> IntraEdge {
        var e = IntraEdge(top: Array(repeating: 0, count: 2 * n), left: Array(repeating: 0, count: n), topLeft: 0,
                          hasTop: f.top, hasLeft: f.left, hasTopLeft: f.topLeft, hasTopRight: f.topRight)
        if f.top {
            if by > 0 {
                let row = (by - 1) * width + mx + bx
                for i in 0 ..< n { e.top[i] = Int32(y[row + i]) }
                for i in n ..< 2 * n { e.top[i] = f.topRight ? Int32(y[row + i]) : e.top[n - 1] }
            } else {
                for i in 0 ..< n { e.top[i] = Int32(top.y[1 + bx + i]) }
                for i in n ..< 2 * n { e.top[i] = f.topRight ? Int32(top.y[1 + bx + i]) : e.top[n - 1] }
            }
        }
        if f.left { for j in 0 ..< n { e.left[j] = Int32(y[(by + j) * width + mx + bx - 1]) } }
        if f.topLeft { e.topLeft = by > 0 ? Int32(y[(by - 1) * width + mx + bx - 1]) : Int32(top.y[bx]) }
        return e
    }

    mutating func reconstructIntraLuma(_ mb: Int, _ kind: MBKind, cbp: Int, qp: Int, _ info: SliceInfo, y: inout [UInt8], top: TopBorder, base: Int) {
        let mx = (mb % st.widthMbs) * 16
        let slice = st.slice[mb]
        let constrained = info.pps.constrainedIntraPred
        let dq = info.dequant
        func write(_ p: [Int32], _ bx: Int, _ by: Int, _ n: Int, _ y: inout [UInt8]) {
            for j in 0 ..< n { for i in 0 ..< n { y[(by + j) * width + mx + bx + i] = UInt8(truncatingIfNeeded: p[j * n + i]) } }
        }
        if kind.contains(.intra16x16) {
            let f = pd.lumaEdges(mb, bx: 0, by: 0, size: 16, slice: slice, constrained: constrained)
            let e = lumaEdge(y, top: top, mx: mx, bx: 0, by: 0, n: 16, (f.top, f.left, f.topLeft, false))
            write(H264Intra.predict16x16(Int(st.i16Mode[mb]), e) ?? Array(repeating: 128, count: 256), 0, 0, 16, &y)
            var dc = [Int32](repeating: 0, count: 16)
            for i in 0 ..< 16 { dc[i] = st.levels[base + 384 + i] }
            let dcs = H264Transform.lumaDC(dc, scale: dq.scale4[0][qp % 6][0], qp: qp)
            for blk in 0 ..< 16 {
                let p = blkY(blk) * width + mx + blkX(blk)
                if cbp & 15 != 0 {
                    dq.dequant4(&coeff, at: blk * 16, list: 0, qp: qp, skipDC: true)
                    coeff[blk * 16] = dcs[blk]
                    H264Transform.add4x4(coeff, blk * 16, &y, p, width)
                } else {
                    H264Transform.addDC4x4(dcs[blk], &y, p, width)
                }
            }
            return
        }
        if kind.contains(.transform8x8) {
            for b8 in 0 ..< 4 {
                let bx = (b8 & 1) * 8, by = (b8 >> 1) * 8
                let f = pd.lumaEdges(mb, bx: bx, by: by, size: 8, slice: slice, constrained: constrained)
                let e = lumaEdge(y, top: top, mx: mx, bx: bx, by: by, n: 8, f)
                write(H264Intra.predict8x8(Int(st.intraModes[mb * 16 + (by / 4) * 4 + bx / 4]), e) ?? Array(repeating: 128, count: 64), bx, by, 8, &y)
                if cbp & (1 << b8) != 0 {
                    dq.dequant8(&coeff8, at: b8 * 64, list: 0, qp: qp)
                    H264Transform.add8x8(coeff8, b8 * 64, &y, by * width + mx + bx, width)
                }
            }
            return
        }
        for k in 0 ..< 16 {
            let blk = blkIdxToRaster[k]
            let bx = blkX(blk), by = blkY(blk)
            let f = pd.lumaEdges(mb, bx: bx, by: by, size: 4, slice: slice, constrained: constrained)
            let e = lumaEdge(y, top: top, mx: mx, bx: bx, by: by, n: 4, f)
            write(H264Intra.predict4x4(Int(st.intraModes[mb * 16 + blk]), e) ?? Array(repeating: 128, count: 16), bx, by, 4, &y)
            if cbp & (1 << ((by / 8) * 2 + bx / 8)) != 0 {
                dq.dequant4(&coeff, at: blk * 16, list: 0, qp: qp, skipDC: false)
                H264Transform.add4x4(coeff, blk * 16, &y, by * width + mx + bx, width)
            }
        }
    }

    // MARK: inter

    mutating func predictInter(_ mb: Int, _ info: SliceInfo, y: inout [UInt8], u: inout [UInt8], v: inout [UInt8]) {
        let m = st.motion
        let isB = info.header.type == .b
        for k in 0 ..< Int(st.partCount[mb]) {
            let code = Int(st.parts[mb * 16 + k])
            let x = (code & 3) * 4, yy = ((code >> 2) & 3) * 4
            let w = [4, 8, 16][(code >> 4) & 3], h = [4, 8, 16][(code >> 6) & 3]
            let b8 = (yy >> 3) * 2 + (x >> 3), b = (yy >> 2) * 4 + (x >> 2)
            let r0 = Int(m.refIdx[mb * 4 + b8]), r1 = Int(m.refIdx[m.n4 + mb * 4 + b8])
            let ref0 = r0 >= 0 && r0 < info.refs.lists[0].count ? info.refs.lists[0][r0] : nil
            let ref1 = r1 >= 0 && r1 < info.refs.lists[1].count ? info.refs.lists[1][r1] : nil
            let mv0 = (Int(m.mvX[mb * 16 + b]), Int(m.mvY[mb * 16 + b])), mv1 = (Int(m.mvX[m.n16 + mb * 16 + b]), Int(m.mvY[m.n16 + mb * 16 + b]))
            let wt = isB ? pd.bWeights(info.header, info.pps, refIdx: (ref0 != nil ? r0 : -1, ref1 != nil ? r1 : -1), refs: info.refs.lists, currentPOC: info.refs.currentPOC)
                         : pd.weights(info.header, info.pps, refIdx: (r0, -1), refs: info.refs.lists)
            predictPartition(mb, x: x, y: yy, w: w, h: h, ref0: ref0, ref1: ref1, mv0: mv0, mv1: mv1, weights: wt, dy: &y, du: &u, dv: &v)
        }
    }

    /// Predicts a partition (luma + chroma) into the stripe from one or two references.
    mutating func predictPartition(_ mb: Int, x: Int, y: Int, w: Int, h: Int, ref0: RefPicture?, ref1: RefPicture?, mv0: (Int, Int), mv1: (Int, Int),
                                   weights wt: (luma: PredWeights, cb: PredWeights, cr: PredWeights)?, dy py: inout [UInt8], du pu: inout [UInt8], dv pv: inout [UInt8]) {
        let mbx = (mb % st.widthMbs) * 16, mby = (mb / st.widthMbs) * 16
        let mx = mbx + x, my = mby + y
        let cw = w / 2, ch = h / 2
        let both = ref0 != nil && ref1 != nil
        let single = ref0 != nil ? 0 : 1
        guard let r = ref0 ?? ref1 else { return }
        let mv = ref0 != nil ? mv0 : mv1
        H264PictureDecoder.lumaMC(r.picture, x0: mx, y0: my, w: w, h: h, mvx: mv.0, mvy: mv.1, into: &predY0, src: &mcSrc, tmp: &mcTmp)
        H264PictureDecoder.chromaMC(r.picture.u, width: r.picture.chromaWidth, height: r.picture.chromaHeight, x0: mx / 2, y0: my / 2, w: cw, h: ch, mvx: mv.0, mvy: mv.1, into: &predU0)
        H264PictureDecoder.chromaMC(r.picture.v, width: r.picture.chromaWidth, height: r.picture.chromaHeight, x0: mx / 2, y0: my / 2, w: cw, h: ch, mvx: mv.0, mvy: mv.1, into: &predV0)
        if both, let r1 = ref1 {
            H264PictureDecoder.lumaMC(r1.picture, x0: mx, y0: my, w: w, h: h, mvx: mv1.0, mvy: mv1.1, into: &predY1, src: &mcSrc, tmp: &mcTmp)
            H264PictureDecoder.chromaMC(r1.picture.u, width: r1.picture.chromaWidth, height: r1.picture.chromaHeight, x0: mx / 2, y0: my / 2, w: cw, h: ch, mvx: mv1.0, mvy: mv1.1, into: &predU1)
            H264PictureDecoder.chromaMC(r1.picture.v, width: r1.picture.chromaWidth, height: r1.picture.chromaHeight, x0: mx / 2, y0: my / 2, w: cw, h: ch, mvx: mv1.0, mvy: mv1.1, into: &predV1)
        }
        // Destination rows relative to the stripe.
        let pw = width, pcw = cwidth, ly = y, cy = y / 2, cx = mx / 2
        if both {
            if let wt {
                for j in 0 ..< h { for i in 0 ..< w { py[(ly + j) * pw + mx + i] = H264Weighted.bi(predY0[j * w + i], predY1[j * w + i], wt.luma) } }
                for j in 0 ..< ch {
                    for i in 0 ..< cw {
                        pu[(cy + j) * pcw + cx + i] = H264Weighted.bi(predU0[j * cw + i], predU1[j * cw + i], wt.cb)
                        pv[(cy + j) * pcw + cx + i] = H264Weighted.bi(predV0[j * cw + i], predV1[j * cw + i], wt.cr)
                    }
                }
            } else {
                for j in 0 ..< h { for i in 0 ..< w { py[(ly + j) * pw + mx + i] = UInt8(truncatingIfNeeded: (predY0[j * w + i] + predY1[j * w + i] + 1) >> 1) } }
                for j in 0 ..< ch {
                    for i in 0 ..< cw {
                        pu[(cy + j) * pcw + cx + i] = UInt8(truncatingIfNeeded: (predU0[j * cw + i] + predU1[j * cw + i] + 1) >> 1)
                        pv[(cy + j) * pcw + cx + i] = UInt8(truncatingIfNeeded: (predV0[j * cw + i] + predV1[j * cw + i] + 1) >> 1)
                    }
                }
            }
        } else if let wt {
            for j in 0 ..< h { for i in 0 ..< w { py[(ly + j) * pw + mx + i] = H264Weighted.single(predY0[j * w + i], wt.luma, single) } }
            for j in 0 ..< ch {
                for i in 0 ..< cw {
                    pu[(cy + j) * pcw + cx + i] = H264Weighted.single(predU0[j * cw + i], wt.cb, single)
                    pv[(cy + j) * pcw + cx + i] = H264Weighted.single(predV0[j * cw + i], wt.cr, single)
                }
            }
        } else {
            for j in 0 ..< h { for i in 0 ..< w { py[(ly + j) * pw + mx + i] = UInt8(truncatingIfNeeded: predY0[j * w + i]) } }
            for j in 0 ..< ch {
                for i in 0 ..< cw {
                    pu[(cy + j) * pcw + cx + i] = UInt8(truncatingIfNeeded: predU0[j * cw + i])
                    pv[(cy + j) * pcw + cx + i] = UInt8(truncatingIfNeeded: predV0[j * cw + i])
                }
            }
        }
    }

    // MARK: residual

    mutating func addLumaResidual(_ mb: Int, _ kind: MBKind, cbp: Int, qp: Int, _ info: SliceInfo, intra: Bool, y: inout [UInt8]) {
        let mx = (mb % st.widthMbs) * 16
        let dq = info.dequant
        let list4 = intra ? 0 : 3, list8 = intra ? 0 : 1
        for b8 in 0 ..< 4 where cbp & (1 << b8) != 0 {
            let bx = (b8 & 1) * 8, by = (b8 >> 1) * 8
            if kind.contains(.transform8x8) {
                dq.dequant8(&coeff8, at: b8 * 64, list: list8, qp: qp)
                H264Transform.add8x8(coeff8, b8 * 64, &y, by * width + mx + bx, width)
            } else {
                for k in [0, 1, 4, 5] {
                    let blk = (by / 4) * 4 + bx / 4 + k
                    dq.dequant4(&coeff, at: blk * 16, list: list4, qp: qp, skipDC: false)
                    H264Transform.add4x4(coeff, blk * 16, &y, blkY(blk) * width + mx + blkX(blk), width)
                }
            }
        }
    }

    mutating func addChroma(_ mb: Int, cbp: Int, intra: Bool, _ info: SliceInfo, base: Int, u: inout [UInt8], v: inout [UInt8]) {
        guard cbp >> 4 != 0 else { return }
        let cx = (mb % st.widthMbs) * 8
        let dq = info.dequant
        for c in 0 ..< 2 {
            let q = Int(st.qpc[c * st.mbs + mb])
            let list = (intra ? 1 : 4) + c
            var dc = [Int32](repeating: 0, count: 4)
            for i in 0 ..< 4 { dc[i] = st.levels[base + 400 + c * 4 + i] }
            let dcs = H264Transform.chromaDC(dc, scale: dq.scale4[list][q % 6][0], qp: q)
            for b in 0 ..< 4 {
                let pos = (b >> 1) * 4 * cwidth + cx + (b & 1) * 4
                if cbp >> 4 == 2 {
                    let o = 256 + c * 64 + b * 16
                    dq.dequant4(&coeff, at: o, list: list, qp: q, skipDC: true)
                    coeff[o] = dcs[b]
                    if c == 0 { H264Transform.add4x4(coeff, o, &u, pos, cwidth) } else { H264Transform.add4x4(coeff, o, &v, pos, cwidth) }
                } else if c == 0 {
                    H264Transform.addDC4x4(dcs[b], &u, pos, cwidth)
                } else {
                    H264Transform.addDC4x4(dcs[b], &v, pos, cwidth)
                }
            }
        }
    }
}
