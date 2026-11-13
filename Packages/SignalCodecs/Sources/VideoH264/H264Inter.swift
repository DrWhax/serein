// Inter prediction (H.264 8.4): motion vector prediction (8.4.1.3) with neighbour
// availability inside the macroblock, P_Skip (8.4.1.1), fractional sample interpolation
// (8.4.2.2: 6-tap luma at quarter samples, bilinear chroma at eighth samples, reference
// coordinates clamped to the picture), and weighted sample prediction (8.4.2.3).

/// A reference picture as the slice sees it. A class: partitions refer to it per block, and a
/// struct copy retained and released its planes and motion arrays each time.
final class RefPicture: Sendable {
    /// Its samples: complete once reconstruction gets to a picture that refers to it.
    let samples: PictureSamples
    /// Its motion: published once its parse is done (only B slices' co-located picture's is read).
    let motion: MotionPromise
    let poc: Int
    let longTerm: Bool
    let id: Int32

    init(samples: PictureSamples, motion: MotionPromise, poc: Int, longTerm: Bool, id: Int32) {
        self.samples = samples
        self.motion = motion
        self.poc = poc
        self.longTerm = longTerm
        self.id = id
    }
}

/// A reference picture's samples during reconstruction (a class, so partitions read its
/// planes in place).
final class RefPlanes: Sendable {
    let picture: YUVPicture
    init(_ picture: YUVPicture) { self.picture = picture }

    /// Luma and chroma prediction of a w×h block at (x0, y0) + `mv` from this picture, into
    /// `y`, `u`, `v` (`src` and `tmp` scratch). A method, so the planes are read in place.
    func predict(x0: Int, y0: Int, w: Int, h: Int, mv: (Int, Int), y: inout [Int32], u: inout [Int32], v: inout [Int32], src: inout [Int32], tmp: inout [Int32]) {
        H264PictureDecoder.lumaMC(picture, x0: x0, y0: y0, w: w, h: h, mvx: mv.0, mvy: mv.1, into: &y, src: &src, tmp: &tmp)
        H264PictureDecoder.chromaMC(picture.u, width: picture.chromaWidth, height: picture.chromaHeight, x0: x0 / 2, y0: y0 / 2, w: w / 2, h: h / 2,
                                    mvx: mv.0, mvy: mv.1, into: &u)
        H264PictureDecoder.chromaMC(picture.v, width: picture.chromaWidth, height: picture.chromaHeight, x0: x0 / 2, y0: y0 / 2, w: w / 2, h: h / 2,
                                    mvx: mv.0, mvy: mv.1, into: &v)
    }
}

/// A neighbouring partition's motion for one list: refIdx (−1: unused/intra) and vector;
/// `available` false when outside the picture/slice or not decoded yet.
struct NeighbourMotion {
    var available: Bool
    var refIdx: Int
    var mvx: Int, mvy: Int
    static let unavailable = NeighbourMotion(available: false, refIdx: -1, mvx: 0, mvy: 0)
}

extension H264PictureDecoder {
    /// Motion of the 4x4 block containing luma position (x, y) relative to the current
    /// MB's top-left (−1 … 16), list `l`. `done` marks the current MB's decoded 4x4 blocks.
    func motionAt(_ mb: Int, _ x: Int, _ y: Int, list l: Int, done: UInt16, slice: Int32) -> NeighbourMotion {
        var m = mb, bx = x, by = y
        if y < 0 {
            if x < 0 { guard let n = neighbour(mb, 3, slice: slice) else { return .unavailable }; m = n; bx = 15; by = 15 }
            else if x >= 16 { guard let n = neighbour(mb, 2, slice: slice) else { return .unavailable }; m = n; bx = x - 16; by = 15 }
            else { guard let n = neighbour(mb, 1, slice: slice) else { return .unavailable }; m = n; by = 15 }
        } else if x < 0 {
            guard let n = neighbour(mb, 0, slice: slice) else { return .unavailable }
            m = n; bx = 15
        } else if x >= 16 {
            return .unavailable
        } else {
            let b = (by >> 2) * 4 + (bx >> 2)
            guard done & (1 << UInt16(b)) != 0 else { return .unavailable }
        }
        let b = (by >> 2) * 4 + (bx >> 2), b8 = (by >> 3) * 2 + (bx >> 3)
        let ref = Int(st.motion.refIdx[(l) * st.motion.n4 + m * 4 + b8])
        if ref < 0 { return NeighbourMotion(available: true, refIdx: -1, mvx: 0, mvy: 0) }
        return NeighbourMotion(available: true, refIdx: ref, mvx: Int(st.motion.mvX[(l) * st.motion.n16 + m * 16 + b]), mvy: Int(st.motion.mvY[(l) * st.motion.n16 + m * 16 + b]))
    }

    /// The A, B, C neighbours of a partition at (x, y) of width w (C falls back to D).
    func neighbours(_ mb: Int, x: Int, y: Int, w: Int, list l: Int, done: UInt16, slice: Int32) -> (NeighbourMotion, NeighbourMotion, NeighbourMotion) {
        let a = motionAt(mb, x - 1, y, list: l, done: done, slice: slice)
        let b = motionAt(mb, x, y - 1, list: l, done: done, slice: slice)
        var c = motionAt(mb, x + w, y - 1, list: l, done: done, slice: slice)
        if !c.available { c = motionAt(mb, x - 1, y - 1, list: l, done: done, slice: slice) }
        return (a, b, c)
    }

    /// mvpLX (8.4.1.3). `shape`: 0 other, 1 16x8 top, 2 16x8 bottom, 3 8x16 left, 4 8x16 right.
    func predictMV(_ mb: Int, x: Int, y: Int, w: Int, refIdx: Int, list l: Int, shape: Int, done: UInt16, slice: Int32) -> (Int, Int) {
        var (a, b, c) = neighbours(mb, x: x, y: y, w: w, list: l, done: done, slice: slice)
        switch shape {
        case 1: if b.refIdx == refIdx { return (b.mvx, b.mvy) }
        case 2: if a.refIdx == refIdx { return (a.mvx, a.mvy) }
        case 3: if a.refIdx == refIdx { return (a.mvx, a.mvy) }
        case 4: if c.refIdx == refIdx { return (c.mvx, c.mvy) }
        default: break
        }
        return median(&a, &b, &c, refIdx)
    }

    func median(_ a: inout NeighbourMotion, _ b: inout NeighbourMotion, _ c: inout NeighbourMotion, _ refIdx: Int) -> (Int, Int) {
        if !b.available && !c.available && a.available { b = a; c = a }
        let matches = (a.refIdx == refIdx ? 1 : 0) + (b.refIdx == refIdx ? 1 : 0) + (c.refIdx == refIdx ? 1 : 0)
        if matches == 1 {
            if a.refIdx == refIdx { return (a.mvx, a.mvy) }
            if b.refIdx == refIdx { return (b.mvx, b.mvy) }
            return (c.mvx, c.mvy)
        }
        func med(_ p: Int, _ q: Int, _ r: Int) -> Int { max(min(p, q), min(max(p, q), r)) }
        return (med(a.mvx, b.mvx, c.mvx), med(a.mvy, b.mvy, c.mvy))
    }

    /// P_Skip's vector (8.4.1.1).
    func pSkipMV(_ mb: Int, slice: Int32) -> (Int, Int) {
        let a = motionAt(mb, -1, 0, list: 0, done: 0, slice: slice), b = motionAt(mb, 0, -1, list: 0, done: 0, slice: slice)
        if !a.available || !b.available { return (0, 0) }
        if a.refIdx == 0 && a.mvx == 0 && a.mvy == 0 { return (0, 0) }
        if b.refIdx == 0 && b.mvx == 0 && b.mvy == 0 { return (0, 0) }
        return predictMV(mb, x: 0, y: 0, w: 16, refIdx: 0, list: 0, shape: 0, done: 0, slice: slice)
    }

    /// Records a partition's motion (list `l`) for the 4x4 blocks it covers.
    mutating func setMotion(_ mb: Int, x: Int, y: Int, w: Int, h: Int, list l: Int, refIdx: Int, mvx: Int, mvy: Int, ref: RefPicture?) {
        for by in stride(from: y, to: y + h, by: 4) {
            for bx in stride(from: x, to: x + w, by: 4) {
                let b = (by >> 2) * 4 + (bx >> 2)
                st.motion.mvX[(l) * st.motion.n16 + mb * 16 + b] = Int16(truncatingIfNeeded: mvx)
                st.motion.mvY[(l) * st.motion.n16 + mb * 16 + b] = Int16(truncatingIfNeeded: mvy)
            }
        }
        for by in stride(from: y, to: y + h, by: 8) {
            for bx in stride(from: x, to: x + w, by: 8) {
                let b8 = (by >> 3) * 2 + (bx >> 3)
                st.motion.refIdx[(l) * st.motion.n4 + mb * 4 + b8] = Int8(refIdx)
                st.motion.refPOC[(l) * st.motion.n4 + mb * 4 + b8] = Int32(truncatingIfNeeded: ref?.poc ?? 0)
                st.motion.refLongTerm[(l) * st.motion.n4 + mb * 4 + b8] = ref?.longTerm ?? false
                st.motion.refID[(l) * st.motion.n4 + mb * 4 + b8] = ref?.id ?? -1
            }
        }
    }

    // MARK: sample interpolation

    /// Luma prediction of a w×h block at integer position (x0, y0) + quarter-sample vector,
    /// into `out[0 ..< w·h]`. `src` and `tmp` are scratch (≥ 21·21 entries each).
    static func lumaMC(_ ref: YUVPicture, x0: Int, y0: Int, w: Int, h: Int, mvx: Int, mvy: Int, into out: inout [Int32], src: inout [Int32], tmp: inout [Int32]) {
        if lumaMCFast(ref, x0: x0, y0: y0, w: w, h: h, mvx: mvx, mvy: mvy, into: &out) { return }
        let ry = ref.y.span
        var ov = out.mutableSpan, sv = src.mutableSpan, tv = tmp.mutableSpan
        let xi = x0 + (mvx >> 2), yi = y0 + (mvy >> 2), fx = mvx & 3, fy = mvy & 3
        let W = ref.width, H = ref.height
        let sw = w + 5, sh = h + 5
        if fx == 0 && fy == 0 && xi >= 0 && yi >= 0 && xi + w <= W && yi + h <= H {
            for j in 0 ..< h { let row = (yi + j) * W + xi; for i in 0 ..< w { ov[j * w + i] = Int32(ry[row + i]) } }
            return
        }
        // Source window: 2 samples before, 3 after, clamped to the picture.
        if xi - 2 >= 0 && yi - 2 >= 0 && xi + w + 3 <= W && yi + h + 3 <= H {
            for j in 0 ..< sh {
                let row = (yi - 2 + j) * W + xi - 2
                for i in 0 ..< sw { sv[j * sw + i] = Int32(ry[row + i]) }
            }
        } else {
            for j in 0 ..< sh {
                let row = clip3(0, H - 1, yi - 2 + j) * W
                for i in 0 ..< sw { sv[j * sw + i] = Int32(ry[row + clip3(0, W - 1, xi - 2 + i)]) }
            }
        }
        @inline(__always) func clip(_ v: Int32) -> Int32 { v < 0 ? 0 : v > 255 ? 255 : v }
        let o = 2 * sw + 2   // G(0, 0)
        if fx == 0 && fy == 0 {
            for j in 0 ..< h { for i in 0 ..< w { ov[j * w + i] = sv[o + j * sw + i] } }
            return
        }
        if fy == 0 || fx == 0 {
            // One-dimensional: horizontal (fy == 0) or vertical (fx == 0) half samples.
            let step = fy == 0 ? 1 : sw
            let frac = fy == 0 ? fx : fy
            for j in 0 ..< h {
                for i in 0 ..< w {
                    let p = o + j * sw + i
                    let half = clip((sv[p - 2 * step] - 5 * sv[p - step] + 20 * sv[p] + 20 * sv[p + step] - 5 * sv[p + 2 * step] + sv[p + 3 * step] + 16) >> 5)
                    ov[j * w + i] = frac == 2 ? half : (half + sv[frac == 1 ? p : p + step] + 1) >> 1
                }
            }
            return
        }
        if fx != 2 && fy != 2 {
            // Diagonal quarter positions: average of a horizontal and a vertical half sample.
            let rowOff = fy == 3 ? sw : 0, colOff = fx == 3 ? 1 : 0
            for j in 0 ..< h {
                for i in 0 ..< w {
                    let pb = o + j * sw + i + rowOff
                    let b = clip((sv[pb - 2] - 5 * sv[pb - 1] + 20 * sv[pb] + 20 * sv[pb + 1] - 5 * sv[pb + 2] + sv[pb + 3] + 16) >> 5)
                    let ph = o + j * sw + i + colOff
                    let hh = clip((sv[ph - 2 * sw] - 5 * sv[ph - sw] + 20 * sv[ph] + 20 * sv[ph + sw] - 5 * sv[ph + 2 * sw] + sv[ph + 3 * sw] + 16) >> 5)
                    ov[j * w + i] = (b + hh + 1) >> 1
                }
            }
            return
        }
        // The centre j (fx == 2 or fy == 2 with the other non-zero): vertical taps over the
        // unclipped horizontal intermediates, rows −2 … h+2.
        for j in 0 ..< sh {
            for i in 0 ..< w {
                let p = j * sw + i + 2
                tv[j * w + i] = sv[p - 2] - 5 * sv[p - 1] + 20 * sv[p] + 20 * sv[p + 1] - 5 * sv[p + 2] + sv[p + 3]
            }
        }
        for j in 0 ..< h {
            for i in 0 ..< w {
                let p = (j + 2) * w + i
                let jj = clip((tv[p - 2 * w] - 5 * tv[p - w] + 20 * tv[p] + 20 * tv[p + w] - 5 * tv[p + 2 * w] + tv[p + 3 * w] + 512) >> 10)
                var v = jj
                if fx == 2 && fy != 2 {
                    // f / q: with the horizontal half sample of row j (fy 1) or j + 1 (fy 3).
                    let b = clip((tv[p + (fy == 3 ? w : 0)] + 16) >> 5)
                    v = (jj + b + 1) >> 1
                } else if fy == 2 && fx != 2 {
                    // i / k: with the vertical half sample of column i (fx 1) or i + 1 (fx 3).
                    let ph = o + j * sw + i + (fx == 3 ? 1 : 0)
                    let hh = clip((sv[ph - 2 * sw] - 5 * sv[ph - sw] + 20 * sv[ph] + 20 * sv[ph + sw] - 5 * sv[ph + 2 * sw] + sv[ph + 3 * sw] + 16) >> 5)
                    v = (jj + hh + 1) >> 1
                }
                ov[j * w + i] = v
            }
        }
    }

    /// Chroma prediction (one plane) of a w×h chroma block at chroma position (x0, y0)
    /// with an eighth-sample vector, into `ov[0 ..< w·h]`.
    static func chromaMC(_ plane: [UInt8], width W: Int, height H: Int, x0: Int, y0: Int, w: Int, h: Int, mvx: Int, mvy: Int, into out: inout [Int32]) {
        if chromaMCFast(plane, width: W, height: H, x0: x0, y0: y0, w: w, h: h, mvx: mvx, mvy: mvy, into: &out) { return }
        let pv = plane.span
        var ov = out.mutableSpan
        let xi = x0 + (mvx >> 3), yi = y0 + (mvy >> 3), fx = Int32(mvx & 7), fy = Int32(mvy & 7)
        let wa = (8 - fx) * (8 - fy), wb = fx * (8 - fy), wc = (8 - fx) * fy, wd = fx * fy
        if xi >= 0 && yi >= 0 && xi + w + 1 <= W && yi + h + 1 <= H {
            for j in 0 ..< h {
                let r0 = (yi + j) * W + xi, r1 = r0 + W
                for i in 0 ..< w {
                    ov[j * w + i] = (wa * Int32(pv[r0 + i]) + wb * Int32(pv[r0 + i + 1]) + wc * Int32(pv[r1 + i]) + wd * Int32(pv[r1 + i + 1]) + 32) >> 6
                }
            }
            return
        }
        for j in 0 ..< h {
            let y0r = clip3(0, H - 1, yi + j) * W, y1r = clip3(0, H - 1, yi + j + 1) * W
            for i in 0 ..< w {
                let x0c = clip3(0, W - 1, xi + i), x1c = clip3(0, W - 1, xi + i + 1)
                ov[j * w + i] = (wa * Int32(pv[y0r + x0c]) + wb * Int32(pv[y0r + x1c]) + wc * Int32(pv[y1r + x0c]) + wd * Int32(pv[y1r + x1c]) + 32) >> 6
            }
        }
    }
}

/// Weighted sample prediction parameters for one block.
struct PredWeights {
    var logWD: Int
    var w0: Int, w1: Int, o0: Int, o1: Int
}

/// How a partition's prediction samples (one or two lists, 0…255) become the picture's
/// (8.4.2.3): copied, averaged, or weighted. Whole blocks at a time, through spans (no
/// copy-on-write check per sample); the same arithmetic as H264Weighted, which cannot overflow
/// in Int32 (|weights|, |offsets| ≤ 128).
enum PredictionCombine {
    case copy, average
    case single(PredWeights, Int)
    case bi(PredWeights)

    static func store(into dst: inout [UInt8], stride: Int, x: Int, y: Int, w: Int, h: Int, _ a: [Int32], _ b: [Int32], _ mode: PredictionCombine) {
        if storeFast(into: &dst, stride: stride, x: x, y: y, w: w, h: h, a, b, mode) { return }
        var d = dst.mutableSpan
        let pa = a.span, pb = b.span
        @inline(__always) func clip(_ v: Int32) -> UInt8 { UInt8(truncatingIfNeeded: v < 0 ? 0 : v > 255 ? 255 : v) }
        switch mode {
        case .copy:
            for j in 0 ..< h { let o = (y + j) * stride + x, s = j * w; for i in 0 ..< w { d[o + i] = UInt8(truncatingIfNeeded: pa[s + i]) } }
        case .average:
            for j in 0 ..< h { let o = (y + j) * stride + x, s = j * w; for i in 0 ..< w { d[o + i] = UInt8(truncatingIfNeeded: (pa[s + i] &+ pb[s + i] &+ 1) >> 1) } }
        case .bi(let wt):
            let w0 = Int32(wt.w0), w1 = Int32(wt.w1), round = Int32(1 << wt.logWD), shift = Int32(wt.logWD + 1), offset = Int32((wt.o0 + wt.o1 + 1) >> 1)
            for j in 0 ..< h {
                let o = (y + j) * stride + x, s = j * w
                for i in 0 ..< w { d[o + i] = clip(((pa[s + i] &* w0 &+ pb[s + i] &* w1 &+ round) >> shift) &+ offset) }
            }
        case .single(let wt, let l):
            let wl = Int32(l == 0 ? wt.w0 : wt.w1), o0 = Int32(l == 0 ? wt.o0 : wt.o1)
            if wt.logWD >= 1 {
                let round = Int32(1 << (wt.logWD - 1)), shift = Int32(wt.logWD)
                for j in 0 ..< h { let o = (y + j) * stride + x, s = j * w; for i in 0 ..< w { d[o + i] = clip(((pa[s + i] &* wl &+ round) >> shift) &+ o0) } }
            } else {
                for j in 0 ..< h { let o = (y + j) * stride + x, s = j * w; for i in 0 ..< w { d[o + i] = clip(pa[s + i] &* wl &+ o0) } }
            }
        }
    }
}

enum H264Weighted {
    /// Single-list prediction with explicit weights.
    @inline(__always) static func single(_ p: Int32, _ wt: PredWeights, _ l: Int) -> UInt8 {
        let w = l == 0 ? wt.w0 : wt.w1, o = l == 0 ? wt.o0 : wt.o1
        let v = wt.logWD >= 1 ? ((Int(p) * w + (1 << (wt.logWD - 1))) >> wt.logWD) + o : Int(p) * w + o
        return UInt8(clip3(0, 255, v))
    }

    @inline(__always) static func bi(_ a: Int32, _ b: Int32, _ wt: PredWeights) -> UInt8 {
        let v = ((Int(a) * wt.w0 + Int(b) * wt.w1 + (1 << wt.logWD)) >> (wt.logWD + 1)) + ((wt.o0 + wt.o1 + 1) >> 1)
        return UInt8(clip3(0, 255, v))
    }
}
