// Prediction and reconstruction inside a tile: residual( ) / transform_block( ) /
// coeffs( ) (5.11.34 – 5.11.39), intra prediction (7.11.2), palette (7.11.4), chroma from
// luma (7.11.5), intra block copy through the inter prediction process (7.11.3 with
// refIdx -1), and dequantisation with reconstruction (7.12.3).

import CodecCore

extension AV1TileDecoder {
    // MARK: compute_prediction (intra block copy)

    mutating func computePrediction() {
        guard isInter else { return }
        for plane in 0..<(hasChroma ? 3 : 1) {
            let sx = plane > 0 ? f.subX : 0, sy = plane > 0 ? f.subY : 0
            let planeSz = AV1C.planeResidualSize(miSize, sx, sy)
            let w = AV1C.num4x4W[planeSz] * 4, h = AV1C.num4x4H[planeSz] * 4
            predictIntraBlockCopy(plane, (miCol >> sx) * 4, (miRow >> sy) * 4, w, h)
        }
    }

    /// The inter prediction process for use_intrabc: the current (unfiltered) frame, an
    /// unscaled reference, the bilinear filter, no compound.
    mutating func predictIntraBlockCopy(_ plane: Int, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        let sx = plane > 0 ? f.subX : 0, sy = plane > 0 ? f.subY : 0
        let bd = f.bitDepth
        let round0 = bd == 12 ? 5 : 3, round1 = bd == 12 ? 9 : 11
        // Motion vector scaling (7.11.3.3) with xScale = yScale = 1 << 14.
        let origX = (x << 4) + ((2 * mv.col) >> sx) + 8
        let origY = (y << 4) + ((2 * mv.row) >> sy) + 8
        let startX = round2Signed(origX * (1 << 14) - (8 << 14), 8) + 32
        let startY = round2Signed(origY * (1 << 14) - (8 << 14), 8) + 32
        let lastX = ((f.hdr.miCols * 4 + sx) >> sx) - 1, lastY = ((f.hdr.miRows * 4 + sy) >> sy) - 1
        let interH = (((h - 1) * 1024 + 1023) >> 10) + 8
        var inter = [Int](repeating: 0, count: interH * w)
        let filt = AV1C.subpelFilters
        let bilinear = 3 * 16 * 8
        for r in 0..<interH {
            let sy0 = clip3(0, lastY, (startY >> 10) + r - 3)
            for c in 0..<w {
                let p = startX + 1024 * c
                let fo = bilinear + ((p >> 6) & 15) * 8
                var s = 0
                for t in 0..<8 { s += filt[fo + t] * planes[plane].clamped(clip3(0, lastX, (p >> 10) + t - 3), sy0) }
                inter[r * w + c] = round2(s, round0)
            }
        }
        let maxV = (1 << bd) - 1
        for r in 0..<h {
            let p = (startY & 1023) + 1024 * r
            let fo = bilinear + ((p >> 6) & 15) * 8
            for c in 0..<w {
                var s = 0
                for t in 0..<8 { s += filt[fo + t] * inter[((p >> 10) + t) * w + c] }
                planes[plane].set(x + c, y + r, clip3(0, maxV, round2(s, round1)))
            }
        }
    }

    // MARK: residual

    func txSizeForPlane(_ plane: Int, _ txSz: Int) -> Int {
        if plane == 0 { return txSz }
        let uvTx = AV1C.maxTxSizeRect[AV1C.planeResidualSize(miSize, f.subX, f.subY)]
        if AV1C.txWidth[uvTx] == 64 || AV1C.txHeight[uvTx] == 64 {
            if AV1C.txWidth[uvTx] == 16 { return AV1C.tx16x32 }
            if AV1C.txHeight[uvTx] == 16 { return AV1C.tx32x16 }
            return AV1C.tx32x32
        }
        return uvTx
    }

    mutating func residual() {
        let bw = AV1C.blockWidth[miSize], bh = AV1C.blockHeight[miSize]
        let widthChunks = max(1, bw >> 6), heightChunks = max(1, bh >> 6)
        let miSizeChunk = widthChunks > 1 || heightChunks > 1 ? AV1C.block64x64 : miSize
        for chunkY in 0..<heightChunks {
            for chunkX in 0..<widthChunks {
                let miRowChunk = miRow + (chunkY << 4), miColChunk = miCol + (chunkX << 4)
                for plane in 0..<(hasChroma ? 3 : 1) {
                    let txSz = lossless ? AV1C.tx4x4 : txSizeForPlane(plane, txSize)
                    let stepX = AV1C.txWidth[txSz] >> 2, stepY = AV1C.txHeight[txSz] >> 2
                    let sx = plane > 0 ? f.subX : 0, sy = plane > 0 ? f.subY : 0
                    let planeSz = AV1C.planeResidualSize(miSizeChunk, sx, sy)
                    let num4x4W = AV1C.num4x4W[planeSz], num4x4H = AV1C.num4x4H[planeSz]
                    if isInter && !lossless && plane == 0 {
                        transformTree((miColChunk >> sx) * 4, (miRowChunk >> sy) * 4, num4x4W * 4, num4x4H * 4)
                    } else {
                        let baseX = (miCol >> sx) * 4, baseY = (miRow >> sy) * 4
                        var y = 0
                        while y < num4x4H {
                            var x = 0
                            while x < num4x4W {
                                transformBlock(plane, baseX, baseY, txSz, x + ((chunkX << 4) >> sx), y + ((chunkY << 4) >> sy))
                                x += stepX
                            }
                            y += stepY
                        }
                    }
                }
            }
        }
    }

    mutating func transformTree(_ startX: Int, _ startY: Int, _ w: Int, _ h: Int) {
        let maxX = f.hdr.miCols * 4, maxY = f.hdr.miRows * 4
        if startX >= maxX || startY >= maxY { return }
        let lumaTx = Int(interTxSizes[mi(startY >> 2, startX >> 2)])
        if w <= AV1C.txWidth[lumaTx] && h <= AV1C.txHeight[lumaTx] {
            transformBlock(0, startX, startY, AV1C.findTxSize(w, h), 0, 0)
        } else if w > h {
            transformTree(startX, startY, w / 2, h)
            transformTree(startX + w / 2, startY, w / 2, h)
        } else if w < h {
            transformTree(startX, startY, w, h / 2)
            transformTree(startX, startY + h / 2, w, h / 2)
        } else {
            transformTree(startX, startY, w / 2, h / 2)
            transformTree(startX + w / 2, startY, w / 2, h / 2)
            transformTree(startX, startY + h / 2, w / 2, h / 2)
            transformTree(startX + w / 2, startY + h / 2, w / 2, h / 2)
        }
    }

    mutating func transformBlock(_ plane: Int, _ baseX: Int, _ baseY: Int, _ txSz: Int, _ x: Int, _ y: Int) {
        let startX = baseX + 4 * x, startY = baseY + 4 * y
        let sx = plane > 0 ? f.subX : 0, sy = plane > 0 ? f.subY : 0
        let row = (startY << sy) >> 2, col = (startX << sx) >> 2
        let sbRow = row & f.sbMask, sbCol = col & f.sbMask
        let stepX = AV1C.txWidth[txSz] >> 2, stepY = AV1C.txHeight[txSz] >> 2
        let maxX = (f.hdr.miCols * 4) >> sx, maxY = (f.hdr.miRows * 4) >> sy
        if startX >= maxX || startY >= maxY { return }
        if !isInter {
            if (plane == 0 && paletteSizeY > 0) || (plane != 0 && paletteSizeUV > 0) {
                predictPalette(plane, startX, startY, x, y, txSz)
            } else {
                let isCfl = plane > 0 && uvMode == AV1C.uvCflPred
                let mode = plane == 0 ? yMode : (isCfl ? AV1C.dcPred : uvMode)
                let haveAboveRight = decoded(plane, (sbRow >> sy) - 1, (sbCol >> sx) + stepX)
                let haveBelowLeft = decoded(plane, (sbRow >> sy) + stepY, (sbCol >> sx) - 1)
                predictIntra(plane, startX, startY, haveLeft: (plane == 0 ? availL : availLChroma) || x > 0,
                             haveAbove: (plane == 0 ? availU : availUChroma) || y > 0, haveAboveRight: haveAboveRight,
                             haveBelowLeft: haveBelowLeft, mode: mode, log2W: AV1C.txWidthLog2[txSz], log2H: AV1C.txHeightLog2[txSz])
                if isCfl { predictCfl(plane, startX, startY, txSz) }
            }
            if plane == 0 {
                maxLumaW = startX + stepX * 4
                maxLumaH = startY + stepY * 4
            }
        }
        if skip == 0 {
            let eob = coeffs(plane, startX, startY, txSz)
            if eob > 0 { reconstruct(plane, startX, startY, txSz) }
        }
        let originY = miRowStart >> sy, originX = miColStart >> sx
        for i in 0..<stepY {
            for j in 0..<stepX {
                let ly = (row >> sy) + i - originY, lx = (col >> sx) + j - originX
                if ly < lfTxSizes[plane].count / lfStride[plane], lx < lfStride[plane] { lfTxSizes[plane][ly * lfStride[plane] + lx] = UInt8(txSz) }
                let by = (sbRow >> sy) + i, bx = (sbCol >> sx) + j
                if by + 1 < bdStride, bx + 1 < bdStride { blockDecoded[plane][(by + 1) * bdStride + bx + 1] = 1 }
            }
        }
    }

    // MARK: Transform type (5.11.47, 5.11.48, 5.11.40)

    func txSet(_ txSz: Int) -> Int {
        let sqr = AV1C.txSizeSqr[txSz], sqrUp = AV1C.txSizeSqrUp[txSz]
        if sqrUp > AV1C.tx32x32 { return AV1C.txSetDctOnly }
        if isInter {
            if f.hdr.reducedTxSet || sqrUp == AV1C.tx32x32 { return AV1C.txSetInter3 }
            if sqr == AV1C.tx16x16 { return AV1C.txSetInter2 }
            return AV1C.txSetInter1
        }
        if sqrUp == AV1C.tx32x32 { return AV1C.txSetDctOnly }
        if f.hdr.reducedTxSet || sqr == AV1C.tx16x16 { return AV1C.txSetIntra2 }
        return AV1C.txSetIntra1
    }

    mutating func transformType(_ x4: Int, _ y4: Int, _ txSz: Int) {
        let set = txSet(txSz)
        var type = AV1C.dctDct
        let q = f.hdr.segmentationEnabled ? f.hdr.qindex(ignoreDeltaQ: true, segment: segmentId, current: currentQIndex) : f.hdr.baseQIdx
        if set > 0 && q > 0 {
            let sqr = AV1C.txSizeSqr[txSz]
            if isInter {
                if set == AV1C.txSetInter1 {
                    type = AV1C.txTypeInterInvSet1[sd.symbol(lay.interTxSet1 + sqr * 17, 16)]
                } else if set == AV1C.txSetInter2 {
                    type = AV1C.txTypeInterInvSet2[sd.symbol(lay.interTxSet2, 12)]
                } else {
                    type = AV1C.txTypeInterInvSet3[sd.symbol(lay.interTxSet3 + sqr * 3, 2)]
                }
            } else {
                let intraDir = useFilterIntra ? AV1C.filterIntraModeToIntraDir[filterIntraMode] : yMode
                if set == AV1C.txSetIntra1 {
                    type = AV1C.txTypeIntraInvSet1[sd.symbol(lay.intraTxSet1 + (sqr * 13 + intraDir) * 8, 7)]
                } else {
                    type = AV1C.txTypeIntraInvSet2[sd.symbol(lay.intraTxSet2 + (sqr * 13 + intraDir) * 6, 5)]
                }
            }
        }
        for i in 0..<(AV1C.txWidth[txSz] >> 2) { for j in 0..<(AV1C.txHeight[txSz] >> 2) { setTxType(y4 + j, x4 + i, type) } }
    }

    @inline(__always) mutating func setTxType(_ r: Int, _ c: Int, _ t: Int) {
        let rr = r - miRowStart, cc = c - miColStart
        if rr >= 0, rr < miRowsAlloc, cc >= 0, cc < miStride { txTypes[rr * miStride + cc] = UInt8(t) }
    }

    func computeTxType(_ plane: Int, _ txSz: Int, _ blockX: Int, _ blockY: Int) -> Int {
        if lossless || AV1C.txSizeSqrUp[txSz] > AV1C.tx32x32 { return AV1C.dctDct }
        let set = txSet(txSz)
        if plane == 0 { return Int(txTypes[mi(blockY, blockX)]) }
        if isInter {
            let x4 = max(miCol, blockX << f.subX), y4 = max(miRow, blockY << f.subY)
            let t = Int(txTypes[mi(y4, x4)])
            return AV1C.txTypeInSetInter[set * 16 + t] != 0 ? t : AV1C.dctDct
        }
        let t = AV1C.modeToTxfm[uvMode]
        return AV1C.txTypeInSetIntra[set * 16 + t] != 0 ? t : AV1C.dctDct
    }

    static func txClass(_ t: Int) -> Int {
        if t == AV1C.vDct || t == AV1C.vAdst || t == AV1C.vFlipadst { return 2 }
        if t == AV1C.hDct || t == AV1C.hAdst || t == AV1C.hFlipadst { return 1 }
        return 0
    }

    // MARK: coeffs

    mutating func coeffs(_ plane: Int, _ startX: Int, _ startY: Int, _ txSz: Int) -> Int {
        let x4 = startX >> 2, y4 = startY >> 2
        let w4 = AV1C.txWidth[txSz] >> 2, h4 = AV1C.txHeight[txSz] >> 2
        let txSzCtx = (AV1C.txSizeSqr[txSz] + AV1C.txSizeSqrUp[txSz] + 1) >> 1
        let ptype = plane > 0 ? 1 : 0
        let segEob = txSz == AV1C.tx16x64 || txSz == AV1C.tx64x16 ? 512 : min(1024, AV1C.txWidth[txSz] * AV1C.txHeight[txSz])
        for c in 0..<segEob { quant[c] = 0 }
        var eob = 0, culLevel = 0, dcCategory = 0
        let sx = plane > 0 ? f.subX : 0, sy = plane > 0 ? f.subY : 0
        let maxX4 = f.hdr.miCols >> sx, maxY4 = f.hdr.miRows >> sy
        // all_zero
        let allZeroCtx: Int
        let bsize = AV1C.planeResidualSize(miSize, sx, sy)
        let bw = AV1C.blockWidth[bsize], bh = AV1C.blockHeight[bsize]
        let w = AV1C.txWidth[txSz], h = AV1C.txHeight[txSz]
        if plane == 0 {
            var top = 0, left = 0
            for k in 0..<w4 where x4 + k < maxX4 { top = max(top, Int(aboveLevel[plane][x4 + k])) }
            for k in 0..<h4 where y4 + k < maxY4 { left = max(left, Int(leftLevel[plane][y4 + k])) }
            top = min(top, 255)
            left = min(left, 255)
            if bw == w && bh == h {
                allZeroCtx = 0
            } else if top == 0 && left == 0 {
                allZeroCtx = 1
            } else if top == 0 || left == 0 {
                allZeroCtx = 2 + (max(top, left) > 3 ? 1 : 0)
            } else if max(top, left) <= 3 {
                allZeroCtx = 4
            } else if min(top, left) <= 3 {
                allZeroCtx = 5
            } else {
                allZeroCtx = 6
            }
        } else {
            var above = 0, left = 0
            for i in 0..<w4 where x4 + i < maxX4 { above |= Int(aboveLevel[plane][x4 + i]) | Int(aboveDc[plane][x4 + i]) }
            for i in 0..<h4 where y4 + i < maxY4 { left |= Int(leftLevel[plane][y4 + i]) | Int(leftDc[plane][y4 + i]) }
            var ctx = (above != 0 ? 1 : 0) + (left != 0 ? 1 : 0) + 7
            if bw * bh > w * h { ctx += 3 }
            allZeroCtx = ctx
        }
        let allZero = sd.symbol(lay.txbSkip + (txSzCtx * 13 + allZeroCtx) * 3, 2)
        if allZero == 1 {
            if plane == 0 { for i in 0..<w4 { for j in 0..<h4 { setTxType(y4 + j, x4 + i, AV1C.dctDct) } } }
        } else {
            if plane == 0 { transformType(x4, y4, txSz) }
            planeTxType = computeTxType(plane, txSz, x4, y4)
            let scan = AV1C.scan(txSz, planeTxType)
            let txClass = Self.txClass(planeTxType)
            let eobMultisize = min(AV1C.txWidthLog2[txSz], 5) + min(AV1C.txHeightLog2[txSz], 5) - 4
            let n = 5 + eobMultisize
            let eobCtx = txClass == 0 ? 0 : 1
            let eobPt: Int
            if eobMultisize <= 4 {
                eobPt = sd.symbol(lay.eobPt[eobMultisize] + (ptype * 2 + eobCtx) * (n + 1), n) + 1
            } else {
                eobPt = sd.symbol(lay.eobPt[eobMultisize] + ptype * (n + 1), n) + 1
            }
            eob = eobPt < 2 ? eobPt : (1 << (eobPt - 2)) + 1
            var eobShift = max(-1, eobPt - 3)
            if eobShift >= 0 {
                if sd.symbol(lay.eobExtra + ((txSzCtx * 2 + ptype) * 9 + (eobPt - 3)) * 3, 2) == 1 { eob += 1 << eobShift }
                if max(0, eobPt - 2) > 1 {
                    for i in 1..<max(0, eobPt - 2) {
                        eobShift = max(0, eobPt - 2) - 1 - i
                        if sd.literal(1) == 1 { eob += 1 << eobShift }
                    }
                }
            }
            let adj = AV1C.adjustedTxSize[txSz]
            let bwl = AV1C.txWidthLog2[adj], width = 1 << bwl, height = AV1C.txHeight[adj]
            let area = height << bwl
            let baseCdf = lay.coeffBase + (txSzCtx * 2 + ptype) * 42 * 5
            let brCdf = lay.coeffBr + (min(txSzCtx, 3) * 2 + ptype) * 21 * 5
            let sig = AV1C.sigRefDiffOffset, magOff = AV1C.magRefOffset
            for c in stride(from: eob - 1, through: 0, by: -1) {
                let pos = scan[c]
                let row = pos >> bwl, col = pos - (row << bwl)
                var level: Int
                if c == eob - 1 {
                    let ctx = c == 0 ? 0 : (c <= area / 8 ? 1 : (c <= area / 4 ? 2 : 3))
                    level = sd.symbol(lay.coeffBaseEob + ((txSzCtx * 2 + ptype) * 4 + ctx) * 4, 3) + 1
                } else {
                    var mag = 0
                    for idx in 0..<5 {
                        let rr = row + sig[(txClass * 5 + idx) * 2], cc = col + sig[(txClass * 5 + idx) * 2 + 1]
                        if rr >= 0 && cc >= 0 && rr < height && cc < width { mag += min(abs(Int(quant[(rr << bwl) + cc])), 3) }
                    }
                    var ctx = min((mag + 1) >> 1, 4)
                    if txClass == 0 {
                        if row == 0 && col == 0 { ctx = 0 } else { ctx += AV1C.coeffBaseCtxOffset[(txSz * 5 + min(row, 4)) * 5 + min(col, 4)] }
                    } else {
                        let idx = txClass == 2 ? row : col
                        ctx += AV1C.coeffBasePosCtxOffset[min(idx, 2)]
                    }
                    level = sd.symbol(baseCdf + ctx * 5, 4)
                }
                if level > 2 {
                    var mag = 0
                    for idx in 0..<3 {
                        let rr = row + magOff[(txClass * 3 + idx) * 2], cc = col + magOff[(txClass * 3 + idx) * 2 + 1]
                        if rr >= 0 && cc >= 0 && rr < height && cc < width { mag += min(Int(quant[rr * width + cc]), 15) }
                    }
                    mag = min((mag + 1) >> 1, 6)
                    let ctx: Int
                    if pos == 0 {
                        ctx = mag
                    } else if txClass == 0 {
                        ctx = row < 2 && col < 2 ? mag + 7 : mag + 14
                    } else if txClass == 1 {
                        ctx = col == 0 ? mag + 7 : mag + 14
                    } else {
                        ctx = row == 0 ? mag + 7 : mag + 14
                    }
                    for _ in 0..<4 {
                        let br = sd.symbol(brCdf + ctx * 5, 4)
                        level += br
                        if br < 3 { break }
                    }
                }
                quant[pos] = Int32(level)
            }
            for c in 0..<eob {
                let pos = scan[c]
                var sign = 0
                if quant[pos] != 0 {
                    if c == 0 {
                        var dcSign = 0
                        for k in 0..<w4 where x4 + k < maxX4 {
                            let s = aboveDc[plane][x4 + k]
                            if s == 1 { dcSign -= 1 } else if s == 2 { dcSign += 1 }
                        }
                        for k in 0..<h4 where y4 + k < maxY4 {
                            let s = leftDc[plane][y4 + k]
                            if s == 1 { dcSign -= 1 } else if s == 2 { dcSign += 1 }
                        }
                        let ctx = dcSign < 0 ? 1 : (dcSign > 0 ? 2 : 0)
                        sign = sd.symbol(lay.dcSign + (ptype * 3 + ctx) * 3, 2)
                    } else {
                        sign = sd.literal(1)
                    }
                }
                var q = Int(quant[pos])
                if q > 14 {
                    var length = 0
                    var bit = 0
                    repeat {
                        length += 1
                        bit = sd.literal(1)
                        if length > 32 { fail(.malformed("Golomb code longer than 32 bits")); return 0 }
                    } while bit == 0
                    var x = 1
                    if length >= 2 { for _ in 0..<(length - 1) { x = (x << 1) | sd.literal(1) } }
                    q = x + 14
                    used(.golomb)
                }
                if pos == 0 && q > 0 { dcCategory = sign != 0 ? 1 : 2 }
                q &= 0xFFFFF
                culLevel += q
                quant[pos] = Int32(sign != 0 ? -q : q)
            }
            culLevel = min(63, culLevel)
        }
        for i in 0..<w4 {
            aboveLevel[plane][x4 + i] = UInt8(culLevel)
            aboveDc[plane][x4 + i] = UInt8(dcCategory)
        }
        for i in 0..<h4 {
            leftLevel[plane][y4 + i] = UInt8(culLevel)
            leftDc[plane][y4 + i] = UInt8(dcCategory)
        }
        return eob
    }

    // MARK: Reconstruction (7.12.3)

    func dcQ(_ b: Int) -> Int { AV1C.dcQLookup[((f.bitDepth - 8) >> 1) * 256 + clip3(0, 255, b)] }
    func acQ(_ b: Int) -> Int { AV1C.acQLookup[((f.bitDepth - 8) >> 1) * 256 + clip3(0, 255, b)] }

    mutating func reconstruct(_ plane: Int, _ x: Int, _ y: Int, _ txSz: Int) {
        let h = f.hdr
        let dqDenom: Int
        switch txSz {
        case AV1C.tx32x32, AV1C.tx16x32, AV1C.tx32x16, AV1C.tx16x64, AV1C.tx64x16: dqDenom = 2
        case AV1C.tx64x64, AV1C.tx32x64, AV1C.tx64x32: dqDenom = 4
        default: dqDenom = 1
        }
        let log2W = AV1C.txWidthLog2[txSz], log2H = AV1C.txHeightLog2[txSz]
        let w = 1 << log2W, hh = 1 << log2H
        let tw = min(32, w), th = min(32, hh)
        let t = planeTxType
        let flipUD = t == AV1C.flipadstDct || t == AV1C.flipadstAdst || t == AV1C.vFlipadst || t == AV1C.flipadstFlipadst
        let flipLR = t == AV1C.dctFlipadst || t == AV1C.adstFlipadst || t == AV1C.hFlipadst || t == AV1C.flipadstFlipadst
        let qindex = h.qindex(ignoreDeltaQ: false, segment: segmentId, current: currentQIndex)
        let dcQuant: Int, acQuant: Int
        switch plane {
        case 0: dcQuant = dcQ(qindex + h.deltaQYDc); acQuant = acQ(qindex)
        case 1: dcQuant = dcQ(qindex + h.deltaQUDc); acQuant = acQ(qindex + h.deltaQUAc)
        default: dcQuant = dcQ(qindex + h.deltaQVDc); acQuant = acQ(qindex + h.deltaQVAc)
        }
        let level = h.segQMLevel[plane][segmentId]
        let useQm = h.usingQmatrix && t < AV1C.idtx && level < 15
        let qmBase = useQm ? (level * 2 + (plane > 0 ? 1 : 0)) * 3344 + AV1C.qmOffset[txSz] : 0
        let bd = f.bitDepth
        let lo = -(1 << (7 + bd)), hi = (1 << (7 + bd)) - 1
        var maxRow = 0
        for i in 0..<th {
            for j in 0..<tw {
                let qv = Int(quant[i * tw + j])
                if qv == 0 { tx.input[i * 64 + j] = 0; continue }
                let q = i == 0 && j == 0 ? dcQuant : acQuant
                let q2 = useQm ? round2(q * AV1C.quantizerMatrix[qmBase + i * tw + j], 5) : q
                let dq = qv * q2
                let dq2 = (dq < 0 ? -1 : 1) * ((abs(dq) & 0xFFFFFF) / dqDenom)
                tx.input[i * 64 + j] = clip3(lo, hi, dq2)
                maxRow = max(maxRow, i + 1)
            }
        }
        if useQm { used(.qmatrix) }
        if lossless { used(.wht) }
        if AV1C.txSizeSqrUp[txSz] == AV1C.tx64x64 { used(.tx64) }
        if t == AV1C.idtx { used(.idtx) }
        if t == AV1C.adstAdst || t == AV1C.adstDct || t == AV1C.dctAdst || t == AV1C.vAdst || t == AV1C.hAdst { used(.adst) }
        if flipUD || flipLR { used(.flipadst) }
        tx.inverse2D(txSz: txSz, txType: t, lossless: lossless, bitDepth: bd, nonzeroRows: maxRow)
        let maxV = (1 << bd) - 1
        for i in 0..<hh {
            let yy = flipUD ? hh - i - 1 : i
            for j in 0..<w {
                let xx = flipLR ? w - j - 1 : j
                let v = planes[plane].at(x + xx, y + yy) + tx.residual[i * 64 + j]
                planes[plane].set(x + xx, y + yy, clip3(0, maxV, v))
            }
        }
    }

    // MARK: Palette and chroma from luma

    mutating func predictPalette(_ plane: Int, _ startX: Int, _ startY: Int, _ x: Int, _ y: Int, _ txSz: Int) {
        let w = AV1C.txWidth[txSz], h = AV1C.txHeight[txSz]
        for i in 0..<h {
            for j in 0..<w {
                let idx: Int
                if plane == 0 { idx = Int(colorMapY[(y * 4 + i) * 64 + x * 4 + j]) } else { idx = Int(colorMapUV[(y * 4 + i) * 64 + x * 4 + j]) }
                let v = plane == 0 ? paletteY[idx] : (plane == 1 ? paletteU[idx] : paletteV[idx])
                planes[plane].set(startX + j, startY + i, v)
            }
        }
    }

    mutating func predictCfl(_ plane: Int, _ startX: Int, _ startY: Int, _ txSz: Int) {
        let w = AV1C.txWidth[txSz], h = AV1C.txHeight[txSz]
        let sx = f.subX, sy = f.subY
        let alpha = plane == 1 ? cflAlphaU : cflAlphaV
        var l = [Int](repeating: 0, count: w * h)
        var lumaAvg = 0
        for i in 0..<h {
            let lumaY = min((startY + i) << sy, maxLumaH - (1 << sy))
            for j in 0..<w {
                let lumaX = min((startX + j) << sx, maxLumaW - (1 << sx))
                var t = 0
                for dy in 0...sy { for dx in 0...sx { t += planes[0].at(lumaX + dx, lumaY + dy) } }
                let v = t << (3 - sx - sy)
                l[i * w + j] = v
                lumaAvg += v
            }
        }
        lumaAvg = round2(lumaAvg, AV1C.txWidthLog2[txSz] + AV1C.txHeightLog2[txSz])
        let maxV = (1 << f.bitDepth) - 1
        for i in 0..<h {
            for j in 0..<w {
                let dc = planes[plane].at(startX + j, startY + i)
                let scaled = round2Signed(alpha * (l[i * w + j] - lumaAvg), 6)
                planes[plane].set(startX + j, startY + i, clip3(0, maxV, dc + scaled))
            }
        }
    }

    // MARK: Intra prediction (7.11.2)

    func filterType(_ plane: Int) -> Bool {
        func isSmooth(_ r: Int, _ c: Int) -> Bool {
            let m = plane == 0 ? Int(yModes[mi(r, c)]) : Int(uvModes[mi(r, c)])
            return m == AV1C.smoothPred || m == AV1C.smoothVPred || m == AV1C.smoothHPred
        }
        var aboveSmooth = false, leftSmooth = false
        if plane == 0 ? availU : availUChroma {
            var r = miRow - 1, c = miCol
            if plane > 0 {
                if f.subX == 1 && (miCol & 1) == 0 { c += 1 }
                if f.subY == 1 && (miRow & 1) == 1 { r -= 1 }
            }
            aboveSmooth = isSmooth(r, c)
        }
        if plane == 0 ? availL : availLChroma {
            var r = miRow, c = miCol - 1
            if plane > 0 {
                if f.subX == 1 && (miCol & 1) == 1 { c -= 1 }
                if f.subY == 1 && (miRow & 1) == 0 { r += 1 }
            }
            leftSmooth = isSmooth(r, c)
        }
        return aboveSmooth || leftSmooth
    }

    mutating func predictIntra(_ plane: Int, _ x: Int, _ y: Int, haveLeft: Bool, haveAbove: Bool, haveAboveRight: Bool, haveBelowLeft: Bool,
                               mode: Int, log2W: Int, log2H: Int) {
        let w = 1 << log2W, h = 1 << log2H
        let sx = plane > 0 ? f.subX : 0, sy = plane > 0 ? f.subY : 0
        let maxX = ((f.hdr.miCols * 4) >> sx) - 1, maxY = ((f.hdr.miRows * 4) >> sy) - 1
        let bd = f.bitDepth
        let base = 1 << (bd - 1)
        let o = 16
        // AboveRow[i] at above[o + i]; LeftCol[i] at left[o + i]; -16 … 2 (w + h) are addressable.
        var above = [Int](repeating: 0, count: o + 2 * (w + h) + 16)
        var left = above
        let n = w + h
        let pl = planes[plane]
        if !haveAbove && haveLeft {
            let v = pl.at(x - 1, y)
            for i in 0..<n { above[o + i] = v }
        } else if !haveAbove && !haveLeft {
            for i in 0..<n { above[o + i] = base - 1 }
        } else {
            let limit = min(maxX, x + (haveAboveRight ? 2 * w : w) - 1)
            for i in 0..<n { above[o + i] = pl.at(min(limit, x + i), y - 1) }
        }
        if !haveLeft && haveAbove {
            let v = pl.at(x, y - 1)
            for i in 0..<n { left[o + i] = v }
        } else if !haveLeft && !haveAbove {
            for i in 0..<n { left[o + i] = base + 1 }
        } else {
            let limit = min(maxY, y + (haveBelowLeft ? 2 * h : h) - 1)
            for i in 0..<n { left[o + i] = pl.at(x - 1, min(limit, y + i)) }
        }
        if haveAbove && haveLeft {
            above[o - 1] = pl.at(x - 1, y - 1)
        } else if haveAbove {
            above[o - 1] = pl.at(x, y - 1)
        } else if haveLeft {
            above[o - 1] = pl.at(x - 1, y)
        } else {
            above[o - 1] = base
        }
        left[o - 1] = above[o - 1]
        let maxV = (1 << bd) - 1
        var pred = [Int](repeating: 0, count: w * h)
        if mode == AV1C.smoothPred || mode == AV1C.smoothVPred || mode == AV1C.smoothHPred { used(.smooth) }
        if mode == AV1C.paethPred && !(plane == 0 && useFilterIntra) { used(.paeth) }
        if plane == 0 && useFilterIntra {
            // Recursive intra prediction (7.11.2.3).
            let w4 = w >> 2, h2 = h >> 1
            let taps = AV1C.intraFilterTaps
            for i2 in 0..<h2 {
                for j4 in 0..<w4 {
                    var p = [0, 0, 0, 0, 0, 0, 0]
                    for i in 0..<7 {
                        if i < 5 {
                            if i2 == 0 {
                                p[i] = above[o + (j4 << 2) + i - 1]
                            } else if j4 == 0 && i == 0 {
                                p[i] = left[o + (i2 << 1) - 1]
                            } else {
                                p[i] = pred[((i2 << 1) - 1) * w + (j4 << 2) + i - 1]
                            }
                        } else {
                            p[i] = j4 == 0 ? left[o + (i2 << 1) + i - 5] : pred[((i2 << 1) + i - 5) * w + (j4 << 2) - 1]
                        }
                    }
                    for i1 in 0..<2 {
                        for j1 in 0..<4 {
                            var pr = 0
                            for i in 0..<7 { pr += taps[(filterIntraMode * 8 + (i1 << 2) + j1) * 7 + i] * p[i] }
                            pred[((i2 << 1) + i1) * w + (j4 << 2) + j1] = clip3(0, maxV, round2Signed(pr, 4))
                        }
                    }
                }
            }
        } else if isDirectional(mode) {
            used(.directional)
            let angleDelta = plane == 0 ? angleDeltaY : angleDeltaUV
            if angleDelta != 0 { used(.angleDelta) }
            let pAngle = AV1C.modeToAngle[mode] + angleDelta * 3
            var upsampleAbove = 0, upsampleLeft = 0
            if f.seq.enableIntraEdgeFilter {
                if pAngle != 90 && pAngle != 180 {
                    if pAngle > 90 && pAngle < 180 && w + h >= 24 {
                        let s = left[o] * 5 + above[o - 1] * 6 + above[o] * 5
                        let v = round2(s, 4)
                        left[o - 1] = v
                        above[o - 1] = v
                    }
                    let ft = filterType(plane) ? 1 : 0
                    used(.edgeFilter)
                    if haveAbove {
                        let strength = Self.edgeStrength(w, h, ft, pAngle - 90)
                        let numPx = min(w, maxX - x + 1) + (pAngle < 90 ? h : 0) + 1
                        Self.edgeFilter(&above, o, numPx, strength)
                    }
                    if haveLeft {
                        let strength = Self.edgeStrength(w, h, ft, pAngle - 180)
                        let numPx = min(h, maxY - y + 1) + (pAngle > 180 ? w : 0) + 1
                        Self.edgeFilter(&left, o, numPx, strength)
                    }
                }
                let ft = filterType(plane) ? 1 : 0
                upsampleAbove = Self.useUpsample(w, h, ft, pAngle - 90) ? 1 : 0
                if upsampleAbove == 1 || upsampleLeft == 1 || Self.useUpsample(w, h, ft, pAngle - 180) { used(.edgeUpsample) }
                if upsampleAbove == 1 { Self.upsample(&above, o, w + (pAngle < 90 ? h : 0), maxV) }
                upsampleLeft = Self.useUpsample(w, h, ft, pAngle - 180) ? 1 : 0
                if upsampleLeft == 1 { Self.upsample(&left, o, h + (pAngle > 180 ? w : 0), maxV) }
            }
            let dr = AV1C.drIntraDerivative
            if pAngle < 90 {
                let dx = dr[pAngle]
                let maxBaseX = (w + h - 1) << upsampleAbove
                for i in 0..<h {
                    let idx = (i + 1) * dx
                    let shift = ((idx << upsampleAbove) >> 1) & 0x1F
                    for j in 0..<w {
                        let b = (idx >> (6 - upsampleAbove)) + (j << upsampleAbove)
                        if b < maxBaseX {
                            pred[i * w + j] = round2(above[o + b] * (32 - shift) + above[o + b + 1] * shift, 5)
                        } else {
                            pred[i * w + j] = above[o + maxBaseX]
                        }
                    }
                }
            } else if pAngle > 90 && pAngle < 180 {
                let dx = dr[180 - pAngle], dy = dr[pAngle - 90]
                for i in 0..<h {
                    for j in 0..<w {
                        let idx = (j << 6) - (i + 1) * dx
                        let b = idx >> (6 - upsampleAbove)
                        if b >= -(1 << upsampleAbove) {
                            let shift = ((idx << upsampleAbove) >> 1) & 0x1F
                            pred[i * w + j] = round2(above[o + b] * (32 - shift) + above[o + b + 1] * shift, 5)
                        } else {
                            let idx2 = (i << 6) - (j + 1) * dy
                            let b2 = idx2 >> (6 - upsampleLeft)
                            let shift = ((idx2 << upsampleLeft) >> 1) & 0x1F
                            pred[i * w + j] = round2(left[o + b2] * (32 - shift) + left[o + b2 + 1] * shift, 5)
                        }
                    }
                }
            } else if pAngle > 180 {
                let dy = dr[270 - pAngle]
                for j in 0..<w {
                    let idx = (j + 1) * dy
                    let shift = ((idx << upsampleLeft) >> 1) & 0x1F
                    for i in 0..<h {
                        let b = (idx >> (6 - upsampleLeft)) + (i << upsampleLeft)
                        pred[i * w + j] = round2(left[o + b] * (32 - shift) + left[o + b + 1] * shift, 5)
                    }
                }
            } else if pAngle == 90 {
                for i in 0..<h { for j in 0..<w { pred[i * w + j] = above[o + j] } }
            } else {
                for i in 0..<h { for j in 0..<w { pred[i * w + j] = left[o + i] } }
            }
        } else if mode == AV1C.smoothPred {
            let wx = AV1C.smWeights[log2W], wy = AV1C.smWeights[log2H]
            for i in 0..<h {
                for j in 0..<w {
                    let s = wy[i] * above[o + j] + (256 - wy[i]) * left[o + h - 1] + wx[j] * left[o + i] + (256 - wx[j]) * above[o + w - 1]
                    pred[i * w + j] = round2(s, 9)
                }
            }
        } else if mode == AV1C.smoothVPred {
            let wy = AV1C.smWeights[log2H]
            for i in 0..<h { for j in 0..<w { pred[i * w + j] = round2(wy[i] * above[o + j] + (256 - wy[i]) * left[o + h - 1], 8) } }
        } else if mode == AV1C.smoothHPred {
            let wx = AV1C.smWeights[log2W]
            for i in 0..<h { for j in 0..<w { pred[i * w + j] = round2(wx[j] * left[o + i] + (256 - wx[j]) * above[o + w - 1], 8) } }
        } else if mode == AV1C.dcPred {
            var v: Int
            if haveLeft && haveAbove {
                var sum = 0
                for k in 0..<h { sum += left[o + k] }
                for k in 0..<w { sum += above[o + k] }
                sum += (w + h) >> 1
                v = sum / (w + h)
            } else if haveLeft {
                var sum = 0
                for k in 0..<h { sum += left[o + k] }
                v = clip3(0, maxV, (sum + (h >> 1)) >> log2H)
            } else if haveAbove {
                var sum = 0
                for k in 0..<w { sum += above[o + k] }
                v = clip3(0, maxV, (sum + (w >> 1)) >> log2W)
            } else {
                v = 1 << (bd - 1)
            }
            for i in 0..<(w * h) { pred[i] = v }
        } else {
            // PAETH_PRED (basic intra prediction, 7.11.2.2).
            let tl = above[o - 1]
            for i in 0..<h {
                for j in 0..<w {
                    let b = above[o + j] + left[o + i] - tl
                    let pLeft = abs(b - left[o + i]), pTop = abs(b - above[o + j]), pTopLeft = abs(b - tl)
                    if pLeft <= pTop && pLeft <= pTopLeft {
                        pred[i * w + j] = left[o + i]
                    } else if pTop <= pTopLeft {
                        pred[i * w + j] = above[o + j]
                    } else {
                        pred[i * w + j] = tl
                    }
                }
            }
        }
        for i in 0..<h { for j in 0..<w { planes[plane].set(x + j, y + i, pred[i * w + j]) } }
    }

    static func edgeStrength(_ w: Int, _ h: Int, _ filterType: Int, _ delta: Int) -> Int {
        let d = abs(delta), blkWh = w + h
        var strength = 0
        if filterType == 0 {
            if blkWh <= 8 {
                if d >= 56 { strength = 1 }
            } else if blkWh <= 12 {
                if d >= 40 { strength = 1 }
            } else if blkWh <= 16 {
                if d >= 40 { strength = 1 }
            } else if blkWh <= 24 {
                if d >= 8 { strength = 1 }
                if d >= 16 { strength = 2 }
                if d >= 32 { strength = 3 }
            } else if blkWh <= 32 {
                strength = 1
                if d >= 4 { strength = 2 }
                if d >= 32 { strength = 3 }
            } else {
                strength = 3
            }
        } else {
            if blkWh <= 8 {
                if d >= 40 { strength = 1 }
                if d >= 64 { strength = 2 }
            } else if blkWh <= 16 {
                if d >= 20 { strength = 1 }
                if d >= 48 { strength = 2 }
            } else if blkWh <= 24 {
                if d >= 4 { strength = 3 }
            } else {
                strength = 3
            }
        }
        return strength
    }

    static func useUpsample(_ w: Int, _ h: Int, _ filterType: Int, _ delta: Int) -> Bool {
        let d = abs(delta), blkWh = w + h
        if d <= 0 || d >= 40 { return false }
        return filterType == 0 ? blkWh <= 16 : blkWh <= 8
    }

    /// The intra edge filter (7.11.2.12) over buf[o - 1 …] of sz entries.
    static func edgeFilter(_ buf: inout [Int], _ o: Int, _ sz: Int, _ strength: Int) {
        if strength == 0 { return }
        var edge = [Int](repeating: 0, count: sz)
        for i in 0..<sz { edge[i] = buf[o + i - 1] }
        let k = AV1C.intraEdgeKernel
        for i in 1..<sz {
            var s = 0
            for j in 0..<5 { s += k[(strength - 1) * 5 + j] * edge[clip3(0, sz - 1, i - 2 + j)] }
            buf[o + i - 1] = (s + 8) >> 4
        }
    }

    /// The intra edge upsample process (7.11.2.11).
    static func upsample(_ buf: inout [Int], _ o: Int, _ numPx: Int, _ maxV: Int) {
        var dup = [Int](repeating: 0, count: numPx + 3)
        dup[0] = buf[o - 1]
        for i in -1..<numPx { dup[i + 2] = buf[o + i] }
        dup[numPx + 2] = buf[o + numPx - 1]
        buf[o - 2] = dup[0]
        for i in 0..<numPx {
            var s = -dup[i] + 9 * dup[i + 1] + 9 * dup[i + 2] - dup[i + 3]
            s = clip3(0, maxV, round2(s, 4))
            buf[o + 2 * i - 1] = s
            buf[o + 2 * i] = dup[i + 2]
        }
    }
}
