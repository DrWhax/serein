// Inter prediction (7.11.3): compute_prediction for inter blocks — motion vector scaling,
// block inter prediction with the sub-pixel filters, local and global warp (block warp, setup
// shear, warp estimation), compound prediction (average, distance weights, wedge and
// difference masks), inter-intra, and overlapped block motion compensation. Reference samples
// come from the frames in the reference slots; the current block's samples are this tile's.

import CodecCore

/// WedgeMasks (7.11.3.11), built once: [bsize][flipSign][wedge] → w × h weights.
final class AV1WedgeMasks: Sendable {
    static let shared = AV1WedgeMasks()
    let masks: [[UInt8]]   // index (bsize * 2 + sign) * 16 + wedge

    init() {
        let size = 64
        let horizontal = 0, vertical = 1, oblique27 = 2, oblique63 = 3, oblique117 = 4, oblique153 = 5
        var master = [[Int]](repeating: [Int](repeating: 0, count: size * size), count: 6)
        let even = AV1Tables.wedgeMasterObliqueEven.map(Int.init), odd = AV1Tables.wedgeMasterObliqueOdd.map(Int.init)
        let vert = AV1Tables.wedgeMasterVertical.map(Int.init)
        for j in 0..<size {
            var shift = size / 4
            var i = 0
            while i < size {
                master[oblique63][i * size + j] = even[clip3(0, size - 1, j - shift)]
                shift -= 1
                master[oblique63][(i + 1) * size + j] = odd[clip3(0, size - 1, j - shift)]
                master[vertical][i * size + j] = vert[j]
                master[vertical][(i + 1) * size + j] = vert[j]
                i += 2
            }
        }
        for i in 0..<size {
            for j in 0..<size {
                let msk = master[oblique63][i * size + j]
                master[oblique27][j * size + i] = msk
                master[oblique117][i * size + (size - 1 - j)] = 64 - msk
                master[oblique153][(size - 1 - j) * size + i] = 64 - msk
                master[horizontal][j * size + i] = master[vertical][i * size + j]
            }
        }
        var out = [[UInt8]](repeating: [], count: 22 * 2 * 16)
        let codebook = AV1Tables.wedgeCodebook.map(Int.init)
        for bsize in AV1C.block8x8..<22 where AV1Tables.wedgeBits[bsize] > 0 {
            let w = AV1C.blockWidth[bsize], h = AV1C.blockHeight[bsize]
            let w4 = AV1C.num4x4W[bsize], h4 = AV1C.num4x4H[bsize]
            let shape = h4 > w4 ? 0 : (h4 < w4 ? 1 : 2)
            for wedge in 0..<16 {
                let e = (shape * 16 + wedge) * 3
                let dir = codebook[e]
                let xoff = size / 2 - ((codebook[e + 1] * w) >> 3)
                let yoff = size / 2 - ((codebook[e + 2] * h) >> 3)
                var sum = 0
                for i in 0..<w { sum += master[dir][yoff * size + xoff + i] }
                for i in 1..<h { sum += master[dir][(yoff + i) * size + xoff] }
                let avg = (sum + (w + h - 1) / 2) / (w + h - 1)
                let flipSign = avg < 32 ? 1 : 0
                var a = [UInt8](repeating: 0, count: w * h), b = a
                for i in 0..<h {
                    for j in 0..<w {
                        let m = master[dir][(yoff + i) * size + xoff + j]
                        a[i * w + j] = UInt8(m)
                        b[i * w + j] = UInt8(64 - m)
                    }
                }
                out[(bsize * 2 + flipSign) * 16 + wedge] = a
                out[(bsize * 2 + (1 - flipSign)) * 16 + wedge] = b
            }
        }
        masks = out
    }

    func mask(_ bsize: Int, _ sign: Int, _ wedge: Int) -> [UInt8] { masks[(bsize * 2 + sign) * 16 + wedge] }
}

extension AV1TileDecoder {
    // MARK: compute_prediction for inter blocks (5.11.33)

    mutating func computeInterPrediction() {
        let sbMask = f.sbMask
        let subBlockMiRow = miRow & sbMask, subBlockMiCol = miCol & sbMask
        for plane in 0..<(hasChroma ? 3 : 1) {
            let sx = plane > 0 ? f.subX : 0, sy = plane > 0 ? f.subY : 0
            let planeSz = AV1C.planeResidualSize(miSize, sx, sy)
            let num4x4W = AV1C.num4x4W[planeSz], num4x4H = AV1C.num4x4H[planeSz]
            let log2W = 2 + AV1C.miWidthLog2[planeSz], log2H = 2 + AV1C.miHeightLog2[planeSz]
            let baseX = (miCol >> sx) * 4, baseY = (miRow >> sy) * 4
            var candRow = (miRow >> sy) << sy, candCol = (miCol >> sx) << sx
            if refFrame.1 == AV1Ref.intra {
                let mode: Int
                switch interintraMode {
                case 0: mode = AV1C.dcPred
                case 1: mode = AV1C.vPred
                case 2: mode = AV1C.hPred
                default: mode = AV1C.smoothPred
                }
                let haveAboveRight = replaying ? (iiEdges >> (2 * plane)) & 1 != 0 : decoded(plane, (subBlockMiRow >> sy) - 1, (subBlockMiCol >> sx) + num4x4W)
                let haveBelowLeft = replaying ? (iiEdges >> (2 * plane + 1)) & 1 != 0 : decoded(plane, (subBlockMiRow >> sy) + num4x4H, (subBlockMiCol >> sx) - 1)
                predictIntra(plane, baseX, baseY, haveLeft: plane == 0 ? availL : availLChroma, haveAbove: plane == 0 ? availU : availUChroma,
                             haveAboveRight: haveAboveRight, haveBelowLeft: haveBelowLeft, mode: mode, log2W: log2W, log2H: log2H)
            }
            var predW = AV1C.blockWidth[miSize] >> sx, predH = AV1C.blockHeight[miSize] >> sy
            var someUseIntra = false
            for r in 0..<(num4x4H << sy) {
                for c in 0..<(num4x4W << sx) where isInside(candRow + r, candCol + c) {
                    if refFrames[2 * mi(candRow + r, candCol + c)] == Int8(AV1Ref.intra) { someUseIntra = true }
                }
            }
            if someUseIntra {
                predW = num4x4W * 4
                predH = num4x4H * 4
                candRow = miRow
                candCol = miCol
            }
            var r = 0, y = 0
            while y < num4x4H * 4 {
                var c = 0, x = 0
                while x < num4x4W * 4 {
                    predictInter(plane, baseX + x, baseY + y, predW, predH, candRow + r, candCol + c)
                    x += predW
                    c += 1
                }
                y += predH
                r += 1
            }
        }
    }

    // MARK: predict_inter (7.11.3.1)

    mutating func predictInter(_ plane: Int, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ candRow: Int, _ candCol: Int) {
        let ci = mi(candRow, candCol)
        let isCompound = Int(refFrames[2 * ci + 1]) > AV1Ref.intra
        // Rounding variables (7.11.3.2).
        let bd = f.bitDepth
        let round0 = bd == 12 ? 5 : 3
        let round1 = isCompound ? 7 : (bd == 12 ? 9 : 11)
        let postRound = 14 - (round0 + round1)
        if plane == 0 && motionMode == AV1Inter.localWarp {
            warpEstimation()
            if localValid { localValid = Self.setupShear(localWarpParams).valid }
        }
        let n = w * h
        if predBuf0.count < n { predBuf0 = [Int](repeating: 0, count: n) }
        if predBuf1.count < n { predBuf1 = [Int](repeating: 0, count: n) }
        for refList in 0..<(isCompound ? 2 : 1) {
            let ref = Int(refFrames[2 * ci + refList])
            var globalValid = false
            if (yMode == AV1Inter.globalMv || yMode == AV1Inter.globalGlobalMv) && f.hdr.gmType[ref] > AV1Inter.translation {
                globalValid = Self.setupShear(f.hdr.gmParams[ref]).valid
            }
            var useWarp = 0
            if w < 8 || h < 8 {
                useWarp = 0
            } else if f.hdr.forceIntegerMv {
                useWarp = 0
            } else if motionMode == AV1Inter.localWarp && localValid {
                useWarp = 1
            } else if (yMode == AV1Inter.globalMv || yMode == AV1Inter.globalGlobalMv) && f.hdr.gmType[ref] > AV1Inter.translation
                        && !isScaled(ref) && globalValid {
                useWarp = 2
            }
            let mvRow = Int(mvs[4 * ci + 2 * refList]), mvCol = Int(mvs[4 * ci + 2 * refList + 1])
            guard let pic = f.refPictures[ref] else { fail(.malformed("missing reference \(ref)")); return }
            if useWarp != 0 {
                if useWarp == 2 && plane == 0 { used(.globalWarp) }
                let params = useWarp == 1 ? localWarpParams : f.hdr.gmParams[ref]
                for i8 in 0...((h - 1) >> 3) {
                    for j8 in 0...((w - 1) >> 3) {
                        blockWarp(pic, params, plane, x, y, i8, j8, w, h, round0: round0, round1: round1, into: refList)
                    }
                }
            } else {
                let s = scaleMotion(plane, pic, x, y, mvRow, mvCol)
                if plane == 0 && (s.stepX != 1024 || s.stepY != 1024) { used(.scaledRef) }
                if !isCompound && refFrame.1 != AV1Ref.intra && s.stepX == 1024 && s.stepY == 1024 && (s.startX | s.startY) & 1023 == 0 && bd <= 10 {
                    // A whole-sample vector, one reference: the prediction is the reference's
                    // samples (the filter is the identity and InterPostRound 0), stored as is.
                    let sx = plane > 0 ? f.subX : 0, sy = plane > 0 ? f.subY : 0
                    Self.copyBlock(pic.planes[plane], lastX: ((pic.upscaledWidth + sx) >> sx) - 1, lastY: ((pic.frameHeight + sy) >> sy) - 1,
                                   x0: s.startX >> 10, y0: s.startY >> 10, into: &planes[plane], x, y, w, h)
                    if motionMode == AV1Inter.obmc { overlappedMotionCompensation(plane, w, h) }
                    return
                }
                blockInterPrediction(pic, plane, s.startX, s.startY, s.stepX, s.stepY, w, h, filters: (Int(interpFilters[2 * ci]), Int(interpFilters[2 * ci + 1])),
                                     round0: round0, round1: round1, into: refList)
            }
        }
        // Masks.
        if compoundType == AV1Inter.compoundWedge && plane == 0 {
            let m = AV1WedgeMasks.shared.mask(miSize, wedgeSign, wedgeIndex)
            maskStride = w
            if interMask.count < n { interMask = [Int](repeating: 0, count: n) }
            for i in 0..<n { interMask[i] = Int(m[i]) }
        } else if compoundType == AV1Inter.compoundIntra {
            let sizeScale = 128 / max(h, w)
            maskStride = w
            if interMask.count < n { interMask = [Int](repeating: 0, count: n) }
            for i in 0..<h {
                for j in 0..<w {
                    let v: Int
                    switch interintraMode {
                    case 1: v = Int(AV1Tables.iiWeights1d[i * sizeScale])
                    case 2: v = Int(AV1Tables.iiWeights1d[j * sizeScale])
                    case 3: v = Int(AV1Tables.iiWeights1d[min(i, j) * sizeScale])
                    default: v = 32
                    }
                    interMask[i * w + j] = v
                }
            }
        } else if compoundType == AV1Inter.compoundDiffwtd && plane == 0 {
            maskStride = w
            if interMask.count < n { interMask = [Int](repeating: 0, count: n) }
            for i in 0..<n {
                let diff = round2(abs(predBuf0[i] - predBuf1[i]), (bd - 8) + postRound)
                let m = clip3(0, 64, 38 + diff / 16)
                interMask[i] = maskType != 0 ? 64 - m : m
            }
        }
        var fwd = 0, bck = 0
        if compoundType == AV1Inter.compoundDistance { (fwd, bck) = distanceWeights(ci) }
        let maxV = (1 << bd) - 1
        let isInterIntra = isInter && refFrame.1 == AV1Ref.intra
        if !isCompound && !isInterIntra {
            Self.store(&planes[plane], x, y, w, h, predBuf0, maxV: maxV)
        } else if compoundType == AV1Inter.compoundAverage {
            Self.storeAverage(&planes[plane], x, y, w, h, predBuf0, predBuf1, w0: 1, w1: 1, shift: 1 + postRound, maxV: maxV)
        } else if compoundType == AV1Inter.compoundDistance {
            Self.storeAverage(&planes[plane], x, y, w, h, predBuf0, predBuf1, w0: fwd, w1: bck, shift: 4 + postRound, maxV: maxV)
        } else {
            maskBlend(plane, x, y, w, h, postRound: postRound)
        }
        if motionMode == AV1Inter.obmc { overlappedMotionCompensation(plane, w, h) }
    }

    /// The motion vector scaling process (7.11.3.3).
    func scaleMotion(_ plane: Int, _ pic: AV1RefPicture, _ x: Int, _ y: Int, _ mvRow: Int, _ mvCol: Int)
        -> (startX: Int, startY: Int, stepX: Int, stepY: Int) {
        let sx = plane > 0 ? f.subX : 0, sy = plane > 0 ? f.subY : 0
        let fw = f.hdr.frameWidth, fh = f.hdr.frameHeight
        let xScale = ((pic.upscaledWidth << 14) + fw / 2) / fw
        let yScale = ((pic.frameHeight << 14) + fh / 2) / fh
        let half = 8
        let origX = (x << 4) + ((2 * mvCol) >> sx) + half
        let origY = (y << 4) + ((2 * mvRow) >> sy) + half
        let baseX = origX * xScale - (half << 14)
        let baseY = origY * yScale - (half << 14)
        let off = (1 << (10 - 4)) / 2
        return (round2Signed(baseX, 14 + 4 - 10) + off, round2Signed(baseY, 14 + 4 - 10) + off,
                round2Signed(xScale, 14 - 10), round2Signed(yScale, 14 - 10))
    }

    /// The block inter prediction process (7.11.3.4), into predBuf0 (list 0) or predBuf1.
    mutating func blockInterPrediction(_ pic: AV1RefPicture, _ plane: Int, _ startX: Int, _ startY: Int, _ stepX: Int, _ stepY: Int, _ w: Int, _ h: Int,
                                       filters: (Int, Int), round0: Int, round1: Int, into list: Int) {
        let sx = plane > 0 ? f.subX : 0, sy = plane > 0 ? f.subY : 0
        let lastX = ((pic.upscaledWidth + sx) >> sx) - 1, lastY = ((pic.frameHeight + sy) >> sy) - 1
        var fh = filters.1
        if w <= 4 { if fh == 0 || fh == 2 { fh = 4 } else if fh == 1 { fh = 5 } }
        var fv = filters.0
        if h <= 4 { if fv == 0 || fv == 2 { fv = 4 } else if fv == 1 { fv = 5 } }
        if list == 0 {
            Self.predictBlock(pic.planes[plane], lastX: lastX, lastY: lastY, startX: startX, startY: startY, stepX: stepX, stepY: stepY, w: w, h: h,
                              fh: fh, fv: fv, round0: round0, round1: round1, scratch: &interBuf, out: &predBuf0)
        } else {
            Self.predictBlock(pic.planes[plane], lastX: lastX, lastY: lastY, startX: startX, startY: startY, stepX: stepX, stepY: stepY, w: w, h: h,
                              fh: fh, fv: fv, round0: round0, round1: round1, scratch: &interBuf, out: &predBuf1)
        }
    }

    /// 7.11.3.4 proper. With no fractional position in a direction the filter there is the
    /// identity (tap 3 = 128), which these fast paths compute directly: a sample copy when both
    /// are whole, one pass when one is (the same values the two passes give).
    static func predictBlock(_ ref: AV1PlaneBuffer, lastX: Int, lastY: Int, startX: Int, startY: Int, stepX: Int, stepY: Int, w: Int, h: Int,
                             fh: Int, fv: Int, round0: Int, round1: Int, scratch: inout [Int], out: inout [Int]) {
        let stride = ref.width
        let src = ref.px.span
        let filters = AV1C.subpelFilters
        let filt = filters.span
        let unscaled = stepX == 1024 && stepY == 1024
        let fracX = (startX >> 6) & 15, fracY = (startY >> 6) & 15
        let x0 = startX >> 10, y0 = startY >> 10
        var o = out.mutableSpan
        let inside = x0 - 3 >= 0 && x0 + w + 4 <= lastX && y0 - 3 >= 0 && y0 + h + 4 <= lastY
        if unscaled && fracX == 0 && fracY == 0 {
            let shift = 14 - round0 - round1
            for r in 0..<h {
                let row = clip3(0, lastY, y0 + r) * stride, d = r * w
                if inside {
                    for c in 0..<w { o[d + c] = Int(src[row + x0 + c]) << shift }
                } else {
                    for c in 0..<w { o[d + c] = Int(src[row + clip3(0, lastX, x0 + c)]) << shift }
                }
            }
            return
        }
        if unscaled && fracY == 0 {
            // Horizontal filter, then the vertical identity: Round2(Round2(s, round0) << 7, round1).
            let fo = (fh * 16 + fracX) * 8
            for r in 0..<h {
                let row = clip3(0, lastY, y0 + r) * stride, d = r * w
                for c in 0..<w {
                    var acc = 0
                    for t in 0..<8 { acc += filt[fo + t] * Int(src[row + clip3(0, lastX, x0 + c + t - 3)]) }
                    o[d + c] = round2(round2(acc, round0) << 7, round1)
                }
            }
            return
        }
        let interH = (((h - 1) * stepY + (1 << 10) - 1) >> 10) + 8
        if scratch.count < interH * w { scratch = [Int](repeating: 0, count: interH * w) }
        do {
            var mid = scratch.mutableSpan
            if unscaled && fracX == 0 {
                // The horizontal identity: Round2(128 * s, round0) is s << (7 - round0).
                for r in 0..<interH {
                    let row = clip3(0, lastY, y0 + r - 3) * stride, d = r * w
                    for c in 0..<w { mid[d + c] = Int(src[row + clip3(0, lastX, x0 + c)]) << (7 - round0) }
                }
            } else {
                for r in 0..<interH {
                    let row = clip3(0, lastY, y0 + r - 3) * stride, d = r * w
                    for c in 0..<w {
                        let p = startX + stepX * c
                        let fo = (fh * 16 + ((p >> 6) & 15)) * 8
                        let xb = (p >> 10) - 3
                        var acc = 0
                        for t in 0..<8 { acc += filt[fo + t] * Int(src[row + clip3(0, lastX, xb + t)]) }
                        mid[d + c] = round2(acc, round0)
                    }
                }
            }
        }
        let mid = scratch.span
        for r in 0..<h {
            let p = (startY & 1023) + stepY * r
            let fo = (fv * 16 + ((p >> 6) & 15)) * 8
            let base = (p >> 10) * w, d = r * w
            for c in 0..<w {
                var acc = 0
                for t in 0..<8 { acc += filt[fo + t] * mid[base + t * w + c] }
                o[d + c] = round2(acc, round1)
            }
        }
    }

    /// CurrFrame over a w × h block at (x, y) = the reference's samples from (x0, y0), clamped
    /// to its edges.
    static func copyBlock(_ ref: AV1PlaneBuffer, lastX: Int, lastY: Int, x0: Int, y0: Int, into buf: inout AV1PlaneBuffer,
                          _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        let src = ref.px.span, sstride = ref.width
        let dstride = buf.width, ox = x - buf.x0, oy = y - buf.y0
        var dst = buf.px.mutableSpan
        let inside = x0 >= 0 && x0 + w - 1 <= lastX
        for r in 0..<h {
            let srow = clip3(0, lastY, y0 + r) * sstride
            let d = (oy + r) * dstride + ox
            if inside {
                let s0 = srow + x0
                for c in 0..<w { dst[d + c] = src[s0 + c] }
            } else {
                for c in 0..<w { dst[d + c] = src[srow + clip3(0, lastX, x0 + c)] }
            }
        }
    }

    /// CurrFrame = Clip1(pred) over a w × h block at (x, y).
    static func store(_ buf: inout AV1PlaneBuffer, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ pred: [Int], maxV: Int) {
        let stride = buf.width, ox = x - buf.x0, oy = y - buf.y0
        let p = pred.span
        var px = buf.px.mutableSpan
        for i in 0..<h {
            let d = (oy + i) * stride + ox, s = i * w
            for j in 0..<w { px[d + j] = UInt16(truncatingIfNeeded: clip3(0, maxV, p[s + j])) }
        }
    }

    /// CurrFrame = Clip1(Round2(w0 · pred0 + w1 · pred1, shift)) (compound average or distance).
    static func storeAverage(_ buf: inout AV1PlaneBuffer, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ pred0: [Int], _ pred1: [Int], w0: Int, w1: Int,
                             shift: Int, maxV: Int) {
        let stride = buf.width, ox = x - buf.x0, oy = y - buf.y0
        let a = pred0.span, b = pred1.span
        var px = buf.px.mutableSpan
        for i in 0..<h {
            let d = (oy + i) * stride + ox, s = i * w
            for j in 0..<w { px[d + j] = UInt16(truncatingIfNeeded: clip3(0, maxV, round2(w0 * a[s + j] + w1 * b[s + j], shift))) }
        }
    }

    // MARK: warp (7.11.3.5 – 7.11.3.8)

    static func resolveDivisor(_ d: Int) -> (shift: Int, factor: Int) {
        let n = floorLog2(abs(d))
        let e = abs(d) - (1 << n)
        let f = n > 8 ? round2(e, n - 8) : e << (8 - n)
        let factor = Int(AV1Tables.divLut[f])
        return (n + 14, d < 0 ? -factor : factor)
    }

    static func setupShear(_ p: [Int]) -> (valid: Bool, alpha: Int, beta: Int, gamma: Int, delta: Int) {
        let alpha0 = clip3(-32768, 32767, p[2] - (1 << 16))
        let beta0 = clip3(-32768, 32767, p[3])
        let (divShift, divFactor) = resolveDivisor(p[2])
        let v = p[4] << 16
        let gamma0 = clip3(-32768, 32767, round2Signed(v &* divFactor, divShift))
        let w = p[3] &* p[4]
        let delta0 = clip3(-32768, 32767, p[5] - round2Signed(w &* divFactor, divShift) - (1 << 16))
        let alpha = round2Signed(alpha0, 6) << 6, beta = round2Signed(beta0, 6) << 6
        let gamma = round2Signed(gamma0, 6) << 6, delta = round2Signed(delta0, 6) << 6
        var valid = true
        if 4 * abs(alpha) + 7 * abs(beta) >= 1 << 16 { valid = false }
        if 4 * abs(gamma) + 4 * abs(delta) >= 1 << 16 { valid = false }
        return (valid, alpha, beta, gamma, delta)
    }

    /// The warp estimation process (7.11.3.8): LocalWarpParams and LocalValid.
    mutating func warpEstimation() {
        var a00 = 0, a01 = 0, a11 = 0, bx0 = 0, bx1 = 0, by0 = 0, by1 = 0
        let w4 = AV1C.num4x4W[miSize], h4 = AV1C.num4x4H[miSize]
        let midY = miRow * 4 + h4 * 2 - 1, midX = miCol * 4 + w4 * 2 - 1
        let suy = midY * 8, sux = midX * 8
        let duy = suy + mv.row, dux = sux + mv.col
        func ls(_ a: Int, _ b: Int) -> Int { ((a &* b) >> 2) &+ (a &+ b) }
        for i in 0..<numSamples {
            let sy = candList[i * 4] - suy, sx = candList[i * 4 + 1] - sux
            let dy = candList[i * 4 + 2] - duy, dx = candList[i * 4 + 3] - dux
            if abs(sx - dx) < 256 && abs(sy - dy) < 256 {
                a00 &+= ls(sx, sx) &+ 8
                a01 &+= ls(sx, sy) &+ 4
                a11 &+= ls(sy, sy) &+ 8
                bx0 &+= ls(sx, dx) &+ 8
                bx1 &+= ls(sy, dx) &+ 4
                by0 &+= ls(sx, dy) &+ 4
                by1 &+= ls(sy, dy) &+ 8
            }
        }
        let det = a00 &* a11 &- a01 &* a01
        localValid = det != 0
        guard localValid else { return }
        var (divShift, divFactor) = Self.resolveDivisor(det)
        divShift -= 16
        if divShift < 0 {
            divFactor = divFactor << (-divShift)
            divShift = 0
        }
        let clampND = 1 << 13
        func nondiag(_ v: Int) -> Int { clip3(-clampND + 1, clampND - 1, round2SignedWrapping(v, divFactor, divShift)) }
        func diag(_ v: Int) -> Int { clip3((1 << 16) - clampND + 1, (1 << 16) + clampND - 1, round2SignedWrapping(v, divFactor, divShift)) }
        localWarpParams[2] = diag(a11 &* bx0 &- a01 &* bx1)
        localWarpParams[3] = nondiag(-a01 &* bx0 &+ a00 &* bx1)
        localWarpParams[4] = nondiag(a11 &* by0 &- a01 &* by1)
        localWarpParams[5] = diag(-a01 &* by0 &+ a00 &* by1)
        let vx = mv.col * (1 << 13) - (midX * (localWarpParams[2] - (1 << 16)) + midY * localWarpParams[3])
        let vy = mv.row * (1 << 13) - (midX * localWarpParams[4] + midY * (localWarpParams[5] - (1 << 16)))
        localWarpParams[0] = clip3(-(1 << 23), (1 << 23) - 1, vx)
        localWarpParams[1] = clip3(-(1 << 23), (1 << 23) - 1, vy)
    }

    /// Round2Signed(v * factor, shift) with the product taken in 128 bits (the least-squares
    /// sums can exceed 64 bits when multiplied).
    func round2SignedWrapping(_ v: Int, _ factor: Int, _ shift: Int) -> Int {
        let p = v.multipliedFullWidth(by: factor)
        let neg = p.high < 0
        // |p| as a 128-bit magnitude.
        var hi = UInt64(bitPattern: Int64(p.high)), lo = UInt64(p.low)
        if neg {
            lo = ~lo &+ 1
            hi = ~hi &+ (lo == 0 ? 1 : 0)
        }
        if shift > 0 {
            let add = UInt64(1) << UInt64(shift - 1)
            let (sum, carry) = lo.addingReportingOverflow(add)
            lo = sum
            if carry { hi &+= 1 }
            if shift >= 64 {
                lo = hi >> UInt64(shift - 64)
                hi = 0
            } else {
                lo = (lo >> UInt64(shift)) | (hi << UInt64(64 - shift))
                hi >>= UInt64(shift)
            }
        }
        let mag = Int(truncatingIfNeeded: lo)
        return neg ? -mag : mag
    }

    /// The block warp process (7.11.3.5): one 8x8 section of the prediction.
    mutating func blockWarp(_ pic: AV1RefPicture, _ params: [Int], _ plane: Int, _ x: Int, _ y: Int, _ i8: Int, _ j8: Int, _ w: Int, _ h: Int,
                            round0: Int, round1: Int, into list: Int) {
        let sx = plane > 0 ? f.subX : 0, sy = plane > 0 ? f.subY : 0
        let ref = pic.planes[plane]
        let lastX = ((pic.upscaledWidth + sx) >> sx) - 1, lastY = ((pic.frameHeight + sy) >> sy) - 1
        let srcX = (x + j8 * 8 + 4) << sx, srcY = (y + i8 * 8 + 4) << sy
        let dstX = params[2] * srcX + params[3] * srcY + params[0]
        let dstY = params[4] * srcX + params[5] * srcY + params[1]
        let (_, alpha, beta, gamma, delta) = Self.setupShear(params)
        let x4 = dstX >> sx, y4 = dstY >> sy
        let ix4 = x4 >> 16, sx4 = x4 & 0xFFFF, iy4 = y4 >> 16, sy4 = y4 & 0xFFFF
        let wf = AV1C.warpedFilters
        var inter = [Int](repeating: 0, count: 15 * 8)
        let stride = ref.width
        for i1 in -7..<8 {
            let row = clip3(0, lastY, iy4 + i1) * stride
            for i2 in -4..<4 {
                let sxv = sx4 + alpha * i2 + beta * i1
                let offs = round2(sxv, 10) + 64
                var s = 0
                for i3 in 0..<8 { s += wf[offs * 8 + i3] * Int(ref.px[row + clip3(0, lastX, ix4 + i2 - 3 + i3)]) }
                inter[(i1 + 7) * 8 + i2 + 4] = round2(s, round0)
            }
        }
        for i1 in -4..<min(4, h - i8 * 8 - 4) {
            for i2 in -4..<min(4, w - j8 * 8 - 4) {
                let syv = sy4 + gamma * i2 + delta * i1
                let offs = round2(syv, 10) + 64
                var s = 0
                for i3 in 0..<8 { s += wf[offs * 8 + i3] * inter[(i1 + i3 + 4) * 8 + i2 + 4] }
                let k = (i8 * 8 + i1 + 4) * w + j8 * 8 + i2 + 4
                if list == 0 { predBuf0[k] = round2(s, round1) } else { predBuf1[k] = round2(s, round1) }
            }
        }
    }

    // MARK: masks and blending (7.11.3.14, 7.11.3.15)

    mutating func maskBlend(_ plane: Int, _ dstX: Int, _ dstY: Int, _ w: Int, _ h: Int, postRound: Int) {
        let sx = plane > 0 ? f.subX : 0, sy = plane > 0 ? f.subY : 0
        let maxV = (1 << f.bitDepth) - 1
        let ms = maskStride
        for y in 0..<h {
            for x in 0..<w {
                let m: Int
                if (sx == 0 && sy == 0) || (interintra && !wedgeInterintra) {
                    m = interMask[y * ms + x]
                } else if sx == 1 && sy == 0 {
                    m = round2(interMask[y * ms + 2 * x] + interMask[y * ms + 2 * x + 1], 1)
                } else {
                    m = round2(interMask[2 * y * ms + 2 * x] + interMask[2 * y * ms + 2 * x + 1] + interMask[(2 * y + 1) * ms + 2 * x]
                               + interMask[(2 * y + 1) * ms + 2 * x + 1], 2)
                }
                if interintra {
                    let pred0 = clip3(0, maxV, round2(predBuf0[y * w + x], postRound))
                    let pred1 = planes[plane].at(x + dstX, y + dstY)
                    planes[plane].set(x + dstX, y + dstY, round2(m * pred1 + (64 - m) * pred0, 6))
                } else {
                    let v = round2(m * predBuf0[y * w + x] + (64 - m) * predBuf1[y * w + x], 6 + postRound)
                    planes[plane].set(x + dstX, y + dstY, clip3(0, maxV, v))
                }
            }
        }
    }

    func distanceWeights(_ ci: Int) -> (Int, Int) {
        var dist = [0, 0]
        for list in 0..<2 {
            let hint = f.hdr.orderHints[Int(refFrames[2 * ci + list])]
            dist[list] = clip3(0, 31, abs(f.seq.relativeDist(hint, f.hdr.orderHint)))
        }
        let d0 = dist[1], d1 = dist[0]
        let order = d0 <= d1 ? 1 : 0
        let lookup = AV1Tables.quantDistLookup.map(Int.init), weight = AV1Tables.quantDistWeight.map(Int.init)
        if d0 == 0 || d1 == 0 { return (lookup[3 * 2 + order], lookup[3 * 2 + 1 - order]) }
        var i = 0
        while i < 3 {
            let c0 = weight[i * 2 + order], c1 = weight[i * 2 + 1 - order]
            if order == 1 { if d0 * c0 > d1 * c1 { break } } else { if d0 * c0 < d1 * c1 { break } }
            i += 1
        }
        return (lookup[i * 2 + order], lookup[i * 2 + 1 - order])
    }

    // MARK: overlapped motion compensation (7.11.3.9, 7.11.3.10)

    mutating func overlappedMotionCompensation(_ plane: Int, _ w: Int, _ h: Int) {
        let sx = plane > 0 ? f.subX : 0, sy = plane > 0 ? f.subY : 0
        let bd = f.bitDepth
        let round0 = bd == 12 ? 5 : 3, round1 = bd == 12 ? 9 : 11
        let maxV = (1 << bd) - 1
        func obmcMask(_ length: Int) -> [Int] {
            switch length {
            case 2: return AV1Tables.obmcMask2.map(Int.init)
            case 4: return AV1Tables.obmcMask4.map(Int.init)
            case 8: return AV1Tables.obmcMask8.map(Int.init)
            case 16: return AV1Tables.obmcMask16.map(Int.init)
            default: return AV1Tables.obmcMask32.map(Int.init)
            }
        }
        // The prediction of a neighbour's motion, blended into the block.
        func overlap(_ s: inout AV1TileDecoder, candRow: Int, candCol: Int, x4: Int, y4: Int, predW: Int, predH: Int, pass: Int, mask: [Int]) {
            let ci = s.mi(candRow, candCol)
            let ref = Int(s.refFrames[2 * ci])
            guard let pic = s.f.refPictures[ref] else { s.fail(.malformed("missing reference \(ref)")); return }
            let predX = (x4 * 4) >> sx, predY = (y4 * 4) >> sy
            let st = s.scaleMotion(plane, pic, predX, predY, Int(s.mvs[4 * ci]), Int(s.mvs[4 * ci + 1]))
            s.blockInterPrediction(pic, plane, st.startX, st.startY, st.stepX, st.stepY, predW, predH,
                                   filters: (Int(s.interpFilters[2 * ci]), Int(s.interpFilters[2 * ci + 1])), round0: round0, round1: round1, into: 0)
            for i in 0..<predH {
                for j in 0..<predW {
                    let o = clip3(0, maxV, s.predBuf0[i * predW + j])
                    let m = pass == 0 ? mask[i] : mask[j]
                    let cur = s.planes[plane].at(predX + j, predY + i)
                    s.planes[plane].set(predX + j, predY + i, round2(m * cur + (64 - m) * o, 6))
                }
            }
        }
        if availU && AV1C.planeResidualSize(miSize, sx, sy) >= AV1C.block8x8 {
            let w4 = AV1C.num4x4W[miSize]
            var x4 = miCol
            var nCount = 0
            let nLimit = min(4, AV1C.miWidthLog2[miSize])
            while nCount < nLimit && x4 < min(f.hdr.miCols, miCol + w4) {
                let candRow = miRow - 1, candCol = x4 | 1
                let candSz = Int(miSizes[mi(candRow, candCol)])
                let step4 = clip3(2, 16, AV1C.num4x4W[candSz])
                if Int(refFrames[2 * mi(candRow, candCol)]) > AV1Ref.intra {
                    nCount += 1
                    let predW = min(w, (step4 * 4) >> sx), predH = min(h >> 1, 32 >> sy)
                    overlap(&self, candRow: candRow, candCol: candCol, x4: x4, y4: miRow, predW: predW, predH: predH, pass: 0, mask: obmcMask(predH))
                }
                x4 += step4
            }
        }
        if availL {
            let h4 = AV1C.num4x4H[miSize]
            var y4 = miRow
            var nCount = 0
            let nLimit = min(4, AV1C.miHeightLog2[miSize])
            while nCount < nLimit && y4 < min(f.hdr.miRows, miRow + h4) {
                let candCol = miCol - 1, candRow = y4 | 1
                let candSz = Int(miSizes[mi(candRow, candCol)])
                let step4 = clip3(2, 16, AV1C.num4x4H[candSz])
                if Int(refFrames[2 * mi(candRow, candCol)]) > AV1Ref.intra {
                    nCount += 1
                    let predW = min(w >> 1, 32 >> sx), predH = min(h, (step4 * 4) >> sy)
                    overlap(&self, candRow: candRow, candCol: candCol, x4: miCol, y4: y4, predW: predW, predH: predH, pass: 1, mask: obmcMask(predW))
                }
                y4 += step4
            }
        }
    }
}
