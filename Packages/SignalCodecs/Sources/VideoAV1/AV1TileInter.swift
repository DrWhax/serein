// The mode info of inter frames (5.11.7 … 5.11.33): segment ids with prediction, skip mode,
// is_inter, intra blocks of inter frames, reference frames, the inter modes and the motion
// vector stack (7.10.2), motion vectors, inter-intra, motion modes with the warp samples
// (7.10.4), compound types and interpolation filters. Contexts follow 9.3.

import CodecCore

/// Inter modes (YMode values) and the other inter enumerations, as the specification numbers them.
enum AV1Inter {
    static let nearestMv = 14, nearMv = 15, globalMv = 16, newMv = 17
    static let nearestNearestMv = 18, nearNearMv = 19, nearestNewMv = 20, newNearestMv = 21
    static let nearNewMv = 22, newNearMv = 23, globalGlobalMv = 24, newNewMv = 25
    static let simple = 0, obmc = 1, localWarp = 2
    static let compoundWedge = 0, compoundDiffwtd = 1, compoundAverage = 2, compoundIntra = 3, compoundDistance = 4
    static let identity = 0, translation = 1, rotzoom = 2, affine = 3
    static let refCatLevel = 640
    static let invalidMv: Int32 = -1 << 15

    static func hasNewmv(_ m: Int) -> Bool {
        m == newMv || m == newNewMv || m == nearNewMv || m == newNearMv || m == nearestNewMv || m == newNearestMv
    }
}

extension AV1TileDecoder {
    // MARK: inter_frame_mode_info (5.11.18)

    mutating func interFrameModeInfo() {
        useIntrabc = false
        if availL {
            let i = mi(miRow, miCol - 1)
            leftRef = (Int(refFrames[2 * i]), Int(refFrames[2 * i + 1]))
        } else {
            leftRef = (AV1Ref.intra, AV1Ref.none)
        }
        if availU {
            let i = mi(miRow - 1, miCol)
            aboveRef = (Int(refFrames[2 * i]), Int(refFrames[2 * i + 1]))
        } else {
            aboveRef = (AV1Ref.intra, AV1Ref.none)
        }
        skip = 0
        interSegmentId(preSkip: true)
        readSkipMode()
        if skipMode != 0 {
            skip = 1
        } else if f.hdr.segIdPreSkip && f.hdr.segFeatureActive(segmentId, 6) {
            skip = 1
        } else {
            var ctx = 0
            if availU { ctx += Int(skips[mi(miRow - 1, miCol)]) }
            if availL { ctx += Int(skips[mi(miRow, miCol - 1)]) }
            skip = sd.symbol(lay.skip + ctx * 3, 2)
        }
        if !f.hdr.segIdPreSkip { interSegmentId(preSkip: false) }
        lossless = f.hdr.losslessArray[segmentId]
        readCdef()
        readDeltaQIndex()
        readDeltaLf()
        readDeltas = false
        readIsInter()
        if isInter { interBlockModeInfo() } else { intraBlockModeInfo(); used(.intraInInter) }
    }

    var leftIntra: Bool { leftRef.0 <= AV1Ref.intra }
    var aboveIntra: Bool { aboveRef.0 <= AV1Ref.intra }
    var leftSingle: Bool { leftRef.1 <= AV1Ref.intra }
    var aboveSingle: Bool { aboveRef.1 <= AV1Ref.intra }

    /// get_segment_id (5.11.21): the smallest previous segment id under the block.
    func predictedSegmentId() -> Int {
        let bw4 = AV1C.num4x4W[miSize], bh4 = AV1C.num4x4H[miSize]
        let xMis = min(f.hdr.miCols - miCol, bw4), yMis = min(f.hdr.miRows - miRow, bh4)
        guard !f.prevSegmentIds.isEmpty else { return 0 }
        var seg = 7
        for y in 0..<yMis { for x in 0..<xMis { seg = min(seg, Int(f.prevSegmentIds[(miRow + y) * f.prevSegmentStride + miCol + x])) } }
        return seg
    }

    /// inter_segment_id( preSkip ) (5.11.19).
    mutating func interSegmentId(preSkip: Bool) {
        guard f.hdr.segmentationEnabled else { segmentId = 0; return }
        let predicted = predictedSegmentId()
        guard f.hdr.segmentationUpdateMap else { segmentId = predicted; return }
        if preSkip && !f.hdr.segIdPreSkip { segmentId = 0; return }
        let bw4 = AV1C.num4x4W[miSize], bh4 = AV1C.num4x4H[miSize]
        func setPredContexts(_ v: UInt8) {
            for i in 0..<bw4 where miCol + i < aboveSegPred.count { aboveSegPred[miCol + i] = v }
            for i in 0..<bh4 where miRow + i < leftSegPred.count { leftSegPred[miRow + i] = v }
        }
        if !preSkip && skip != 0 {
            setPredContexts(0)
            readSegmentId()
            return
        }
        if f.hdr.segmentationTemporalUpdate {
            let ctx = Int(leftSegPred[miRow]) + Int(aboveSegPred[miCol])
            let predictedFlag = sd.symbol(lay.segmentIdPredicted + ctx * 3, 2)
            if predictedFlag != 0 { segmentId = predicted; used(.segmentPredicted) } else { readSegmentId() }
            setPredContexts(UInt8(predictedFlag))
        } else {
            readSegmentId()
        }
    }

    /// read_skip_mode (5.11.20).
    mutating func readSkipMode() {
        if f.hdr.segFeatureActive(segmentId, 6) || f.hdr.segFeatureActive(segmentId, 5) || f.hdr.segFeatureActive(segmentId, 7) || !f.hdr.skipModePresent
            || AV1C.blockWidth[miSize] < 8 || AV1C.blockHeight[miSize] < 8 {
            skipMode = 0
            return
        }
        var ctx = 0
        if availU { ctx += Int(skipModes[mi(miRow - 1, miCol)]) }
        if availL { ctx += Int(skipModes[mi(miRow, miCol - 1)]) }
        skipMode = sd.symbol(lay.skipMode + ctx * 3, 2)
    }

    /// read_is_inter (5.11.20).
    mutating func readIsInter() {
        if skipMode != 0 {
            isInter = true
        } else if f.hdr.segFeatureActive(segmentId, 5) {
            isInter = f.hdr.featureData[segmentId][5] != AV1Ref.intra
        } else if f.hdr.segFeatureActive(segmentId, 7) {
            isInter = true
        } else {
            let ctx: Int
            if availU && availL {
                ctx = leftIntra && aboveIntra ? 3 : (leftIntra || aboveIntra ? 1 : 0)
            } else if availU || availL {
                ctx = 2 * ((availU ? aboveIntra : leftIntra) ? 1 : 0)
            } else {
                ctx = 0
            }
            isInter = sd.symbol(lay.isInter + ctx * 3, 2) == 1
        }
    }

    // MARK: intra_block_mode_info (5.11.22)

    mutating func intraBlockModeInfo() {
        refFrame = (AV1Ref.intra, AV1Ref.none)
        useFilterIntra = false
        paletteSizeY = 0
        paletteSizeUV = 0
        angleDeltaY = 0
        angleDeltaUV = 0
        interintra = false
        motionMode = AV1Inter.simple
        compoundType = AV1Inter.compoundAverage
        let ctx = Int(AV1Tables.sizeGroup[miSize])
        yMode = sd.symbol(lay.yMode + ctx * 14, 13)
        intraChromaAndFilters()
    }

    /// The intra block's angle deltas, chroma mode, palette and filter intra (shared by intra
    /// frames' and inter frames' intra blocks).
    mutating func intraChromaAndFilters() {
        if miSize >= AV1C.block8x8 && isDirectional(yMode) {
            angleDeltaY = sd.symbol(lay.angleDelta + (yMode - AV1C.vPred) * 8, 7) - 3
        }
        if hasChroma {
            let cflAllowed: Bool
            if lossless && AV1C.planeResidualSize(miSize, f.subX, f.subY) == AV1C.block4x4 {
                cflAllowed = true
            } else {
                cflAllowed = !lossless && max(AV1C.blockWidth[miSize], AV1C.blockHeight[miSize]) <= 32
            }
            uvMode = cflAllowed ? sd.symbol(lay.uvModeCflAllowed + yMode * 15, 14) : sd.symbol(lay.uvModeCflNotAllowed + yMode * 14, 13)
            if uvMode == AV1C.uvCflPred { readCflAlphas(); used(.cfl) }
            if miSize >= AV1C.block8x8 && isDirectional(uvMode) {
                angleDeltaUV = sd.symbol(lay.angleDelta + (uvMode - AV1C.vPred) * 8, 7) - 3
            }
        } else {
            uvMode = AV1C.dcPred
        }
        if miSize >= AV1C.block8x8 && AV1C.blockWidth[miSize] <= 64 && AV1C.blockHeight[miSize] <= 64 && f.hdr.allowScreenContentTools {
            paletteModeInfo()
        }
        if f.seq.enableFilterIntra && yMode == AV1C.dcPred && paletteSizeY == 0 && max(AV1C.blockWidth[miSize], AV1C.blockHeight[miSize]) <= 32 {
            useFilterIntra = sd.symbol(lay.filterIntra + miSize * 3, 2) == 1
            if useFilterIntra { filterIntraMode = sd.symbol(lay.filterIntraMode, 5); used(.filterIntra) }
        }
    }

    // MARK: inter_block_mode_info (5.11.23)

    mutating func interBlockModeInfo() {
        paletteSizeY = 0
        paletteSizeUV = 0
        useFilterIntra = false
        angleDeltaY = 0
        angleDeltaUV = 0
        readRefFrames()
        let isCompound = refFrame.1 > AV1Ref.intra
        findMvStack(isCompound)
        if skipMode != 0 {
            yMode = AV1Inter.nearestNearestMv
        } else if f.hdr.segFeatureActive(segmentId, 6) || f.hdr.segFeatureActive(segmentId, 7) {
            yMode = AV1Inter.globalMv
        } else if isCompound {
            let ctx = Int(AV1Tables.compoundModeCtxMap[(refMvContext >> 1) * 5 + min(newMvContext, 4)])
            yMode = AV1Inter.nearestNearestMv + sd.symbol(lay.compoundMode + ctx * 9, 8)
        } else {
            if sd.symbol(lay.newMv + newMvContext * 3, 2) == 0 {
                yMode = AV1Inter.newMv
            } else if sd.symbol(lay.zeroMv + zeroMvContext * 3, 2) == 0 {
                yMode = AV1Inter.globalMv
            } else {
                yMode = sd.symbol(lay.refMv + refMvContext * 3, 2) == 0 ? AV1Inter.nearestMv : AV1Inter.nearMv
            }
        }
        refMvIdx = 0
        if yMode == AV1Inter.newMv || yMode == AV1Inter.newNewMv {
            for idx in 0..<2 where numMvFound > idx + 1 {
                if sd.symbol(lay.drlMode + drlCtxStack[idx] * 3, 2) == 0 {
                    refMvIdx = idx
                    break
                }
                refMvIdx = idx + 1
            }
        } else if hasNearmv {
            refMvIdx = 1
            for idx in 1..<3 where numMvFound > idx + 1 {
                if sd.symbol(lay.drlMode + drlCtxStack[idx] * 3, 2) == 0 {
                    refMvIdx = idx
                    break
                }
                refMvIdx = idx + 1
            }
        }
        if skipMode != 0 { used(.skipMode) }
        if isCompound { used(.compound); if (refFrame.0 >= AV1Ref.bwdref) == (refFrame.1 >= AV1Ref.bwdref) { used(.unidirCompound) } }
        if getMode(0) == AV1Inter.newMv || (isCompound && getMode(1) == AV1Inter.newMv) { used(.newMv) }
        if hasNearmv { used(.nearMv) }
        if yMode == AV1Inter.globalMv || yMode == AV1Inter.globalGlobalMv { used(.globalMv) }
        assignMv(isCompound)
        readInterIntraMode(isCompound)
        readMotionMode(isCompound)
        readCompoundType(isCompound)
        if f.hdr.interpolationFilter == 4 {
            for dir in 0..<(f.seq.enableDualFilter ? 2 : 1) {
                if needsInterpFilter() {
                    var ctx = ((dir & 1) * 2 + (refFrame.1 > AV1Ref.intra ? 1 : 0)) * 4
                    var leftType = 3, aboveType = 3
                    if availL {
                        let i = mi(miRow, miCol - 1)
                        if Int(refFrames[2 * i]) == refFrame.0 || Int(refFrames[2 * i + 1]) == refFrame.0 { leftType = Int(interpFilters[2 * i + dir]) }
                    }
                    if availU {
                        let i = mi(miRow - 1, miCol)
                        if Int(refFrames[2 * i]) == refFrame.0 || Int(refFrames[2 * i + 1]) == refFrame.0 { aboveType = Int(interpFilters[2 * i + dir]) }
                    }
                    if leftType == aboveType { ctx += leftType } else if leftType == 3 { ctx += aboveType } else if aboveType == 3 { ctx += leftType } else { ctx += 3 }
                    interpFilter[dir] = sd.symbol(lay.interpFilter + ctx * 4, 3)
                    used(dir == 0 ? .switchableFilter : .dualFilter)
                } else {
                    interpFilter[dir] = 0
                }
            }
            if !f.seq.enableDualFilter { interpFilter[1] = interpFilter[0] }
        } else {
            interpFilter[0] = f.hdr.interpolationFilter
            interpFilter[1] = f.hdr.interpolationFilter
        }
    }

    var hasNearmv: Bool {
        yMode == AV1Inter.nearMv || yMode == AV1Inter.nearNearMv || yMode == AV1Inter.nearNewMv || yMode == AV1Inter.newNearMv
    }

    func needsInterpFilter() -> Bool {
        let large = min(AV1C.blockWidth[miSize], AV1C.blockHeight[miSize]) >= 8
        if skipMode != 0 || motionMode == AV1Inter.localWarp { return false }
        if large && yMode == AV1Inter.globalMv { return f.hdr.gmType[refFrame.0] == AV1Inter.translation }
        if large && yMode == AV1Inter.globalGlobalMv {
            return f.hdr.gmType[refFrame.0] == AV1Inter.translation || f.hdr.gmType[refFrame.1] == AV1Inter.translation
        }
        return true
    }

    // MARK: read_ref_frames (5.11.25), with the contexts of 9.3

    func countRefs(_ frameType: Int) -> Int {
        var c = 0
        if availU {
            if aboveRef.0 == frameType { c += 1 }
            if aboveRef.1 == frameType { c += 1 }
        }
        if availL {
            if leftRef.0 == frameType { c += 1 }
            if leftRef.1 == frameType { c += 1 }
        }
        return c
    }

    static func refCountCtx(_ a: Int, _ b: Int) -> Int { a < b ? 0 : (a == b ? 1 : 2) }

    var ctxSingleP1: Int {
        let fwd = countRefs(1) + countRefs(2) + countRefs(3) + countRefs(4)
        let bwd = countRefs(5) + countRefs(6) + countRefs(7)
        return Self.refCountCtx(fwd, bwd)
    }
    var ctxCompRef: Int { Self.refCountCtx(countRefs(1) + countRefs(2), countRefs(3) + countRefs(4)) }
    var ctxCompRefP1: Int { Self.refCountCtx(countRefs(1), countRefs(2)) }
    var ctxCompRefP2: Int { Self.refCountCtx(countRefs(3), countRefs(4)) }
    var ctxCompBwdref: Int { Self.refCountCtx(countRefs(5) + countRefs(6), countRefs(7)) }
    var ctxCompBwdrefP1: Int { Self.refCountCtx(countRefs(5), countRefs(6)) }
    var ctxUniCompRefP1: Int { Self.refCountCtx(countRefs(2), countRefs(3) + countRefs(4)) }

    static func checkBackward(_ r: Int) -> Bool { r >= AV1Ref.bwdref && r <= AV1Ref.altref }

    var ctxCompMode: Int {
        if availU && availL {
            if aboveSingle && leftSingle {
                return (Self.checkBackward(aboveRef.0) ? 1 : 0) ^ (Self.checkBackward(leftRef.0) ? 1 : 0)
            } else if aboveSingle {
                return 2 + (Self.checkBackward(aboveRef.0) || aboveIntra ? 1 : 0)
            } else if leftSingle {
                return 2 + (Self.checkBackward(leftRef.0) || leftIntra ? 1 : 0)
            }
            return 4
        } else if availU {
            return aboveSingle ? (Self.checkBackward(aboveRef.0) ? 1 : 0) : 3
        } else if availL {
            return leftSingle ? (Self.checkBackward(leftRef.0) ? 1 : 0) : 3
        }
        return 1
    }

    var ctxCompRefType: Int {
        func samedir(_ a: Int, _ b: Int) -> Bool { (a >= AV1Ref.bwdref) == (b >= AV1Ref.bwdref) }
        let aboveCompInter = availU && !aboveIntra && !aboveSingle
        let leftCompInter = availL && !leftIntra && !leftSingle
        let aboveUniComp = aboveCompInter && samedir(aboveRef.0, aboveRef.1)
        let leftUniComp = leftCompInter && samedir(leftRef.0, leftRef.1)
        if availU && !aboveIntra && availL && !leftIntra {
            let same = samedir(aboveRef.0, leftRef.0) ? 1 : 0
            if !aboveCompInter && !leftCompInter { return 1 + 2 * same }
            if !aboveCompInter { return !leftUniComp ? 1 : 3 + same }
            if !leftCompInter { return !aboveUniComp ? 1 : 3 + same }
            if !aboveUniComp && !leftUniComp { return 0 }
            if !aboveUniComp || !leftUniComp { return 2 }
            return 3 + ((aboveRef.0 == AV1Ref.bwdref) == (leftRef.0 == AV1Ref.bwdref) ? 1 : 0)
        } else if availU && availL {
            if aboveCompInter { return 1 + 2 * (aboveUniComp ? 1 : 0) }
            if leftCompInter { return 1 + 2 * (leftUniComp ? 1 : 0) }
            return 2
        } else if aboveCompInter {
            return 4 * (aboveUniComp ? 1 : 0)
        } else if leftCompInter {
            return 4 * (leftUniComp ? 1 : 0)
        }
        return 2
    }

    mutating func readRefFrames() {
        if skipMode != 0 {
            refFrame = (f.hdr.skipModeFrame[0], f.hdr.skipModeFrame[1])
            return
        }
        if f.hdr.segFeatureActive(segmentId, 5) {
            refFrame = (f.hdr.featureData[segmentId][5], AV1Ref.none)
            return
        }
        if f.hdr.segFeatureActive(segmentId, 6) || f.hdr.segFeatureActive(segmentId, 7) {
            refFrame = (AV1Ref.last, AV1Ref.none)
            return
        }
        let bw4 = AV1C.num4x4W[miSize], bh4 = AV1C.num4x4H[miSize]
        let compMode = f.hdr.referenceSelect && min(bw4, bh4) >= 2 ? sd.symbol(lay.compMode + ctxCompMode * 3, 2) : 0
        func bit(_ base: Int, _ ctx: Int, _ n: Int, _ k: Int) -> Int { sd.symbol(base + (ctx * n + k) * 3, 2) }
        if compMode == 1 {
            let compRefType = sd.symbol(lay.compRefType + ctxCompRefType * 3, 2)
            if compRefType == 0 {
                if bit(lay.uniCompRef, ctxSingleP1, 3, 0) == 1 {
                    refFrame = (AV1Ref.bwdref, AV1Ref.altref)
                } else if bit(lay.uniCompRef, ctxUniCompRefP1, 3, 1) == 1 {
                    refFrame = bit(lay.uniCompRef, ctxCompRefP2, 3, 2) == 1 ? (AV1Ref.last, AV1Ref.golden) : (AV1Ref.last, AV1Ref.last3)
                } else {
                    refFrame = (AV1Ref.last, AV1Ref.last2)
                }
            } else {
                var r0: Int
                if bit(lay.compRef, ctxCompRef, 3, 0) == 0 {
                    r0 = bit(lay.compRef, ctxCompRefP1, 3, 1) == 1 ? AV1Ref.last2 : AV1Ref.last
                } else {
                    r0 = bit(lay.compRef, ctxCompRefP2, 3, 2) == 1 ? AV1Ref.golden : AV1Ref.last3
                }
                let r1: Int
                if bit(lay.compBwdRef, ctxCompBwdref, 2, 0) == 0 {
                    r1 = bit(lay.compBwdRef, ctxCompBwdrefP1, 2, 1) == 1 ? AV1Ref.altref2 : AV1Ref.bwdref
                } else {
                    r1 = AV1Ref.altref
                }
                refFrame = (r0, r1)
                r0 = 0
            }
        } else {
            let r0: Int
            if bit(lay.singleRef, ctxSingleP1, 6, 0) == 1 {
                if bit(lay.singleRef, ctxCompBwdref, 6, 1) == 0 {
                    r0 = bit(lay.singleRef, ctxCompBwdrefP1, 6, 5) == 1 ? AV1Ref.altref2 : AV1Ref.bwdref
                } else {
                    r0 = AV1Ref.altref
                }
            } else if bit(lay.singleRef, ctxCompRef, 6, 2) == 1 {
                r0 = bit(lay.singleRef, ctxCompRefP2, 6, 4) == 1 ? AV1Ref.golden : AV1Ref.last3
            } else {
                r0 = bit(lay.singleRef, ctxCompRefP1, 6, 3) == 1 ? AV1Ref.last2 : AV1Ref.last
            }
            refFrame = (r0, AV1Ref.none)
        }
    }

    // MARK: find_mv_stack (7.10.2)

    func refFrameOf(_ list: Int) -> Int { list == 0 ? refFrame.0 : refFrame.1 }

    @inline(__always) func stackMv(_ idx: Int, _ list: Int, _ comp: Int) -> Int { refStackMv[idx * 4 + list * 2 + comp] }
    @inline(__always) mutating func setStackMv(_ idx: Int, _ list: Int, _ row: Int, _ col: Int) {
        refStackMv[idx * 4 + list * 2] = row
        refStackMv[idx * 4 + list * 2 + 1] = col
    }

    /// lower_mv_precision (7.10.2.10).
    func lowerPrecision(_ v: Int) -> Int {
        if f.hdr.allowHighPrecisionMv { return v }
        if f.hdr.forceIntegerMv {
            let a = (abs(v) + 3) >> 3
            return v > 0 ? a << 3 : -(a << 3)
        }
        if v & 1 != 0 { return v > 0 ? v - 1 : v + 1 }
        return v
    }

    /// The setup global MV process (7.10.2.1) for list `list`.
    func globalMv(_ list: Int) -> (Int, Int) {
        let ref = refFrameOf(list)
        guard ref > AV1Ref.intra else { return (0, 0) }
        let typ = f.hdr.gmType[ref]
        let gm = f.hdr.gmParams[ref]
        var row = 0, col = 0
        if typ == AV1Inter.identity {
            row = 0; col = 0
        } else if typ == AV1Inter.translation {
            row = gm[0] >> 13
            col = gm[1] >> 13
        } else {
            let bw = AV1C.blockWidth[miSize], bh = AV1C.blockHeight[miSize]
            let x = miCol * 4 + bw / 2 - 1, y = miRow * 4 + bh / 2 - 1
            let xc = (gm[2] - (1 << 16)) * x + gm[3] * y + gm[0]
            let yc = gm[4] * x + (gm[5] - (1 << 16)) * y + gm[1]
            if f.hdr.allowHighPrecisionMv {
                row = round2Signed(yc, 13)
                col = round2Signed(xc, 13)
            } else {
                row = round2Signed(yc, 14) * 2
                col = round2Signed(xc, 14) * 2
            }
        }
        return (lowerPrecision(row), lowerPrecision(col))
    }

    mutating func findMvStack(_ isCompound: Bool) {
        let bw4 = AV1C.num4x4W[miSize], bh4 = AV1C.num4x4H[miSize]
        numMvFound = 0
        newMvCount = 0
        let g0 = globalMv(0)
        globalMvs[0] = g0.0; globalMvs[1] = g0.1
        if isCompound {
            let g1 = globalMv(1)
            globalMvs[2] = g1.0; globalMvs[3] = g1.1
        }
        foundMatch = false
        scanRow(-1, isCompound)
        var foundAboveMatch = foundMatch
        foundMatch = false
        scanCol(-1, isCompound)
        var foundLeftMatch = foundMatch
        foundMatch = false
        if max(bw4, bh4) <= 16 { scanPoint(-1, bw4, isCompound) }
        if foundMatch { foundAboveMatch = true }
        let closeMatches = (foundAboveMatch ? 1 : 0) + (foundLeftMatch ? 1 : 0)
        let numNearest = numMvFound, numNew = newMvCount
        for idx in 0..<numNearest { weightStack[idx] += AV1Inter.refCatLevel }
        zeroMvContext = 0
        if f.hdr.useRefFrameMvs { temporalScan(isCompound) }
        foundMatch = false
        scanPoint(-1, -1, isCompound)
        if foundMatch { foundAboveMatch = true }
        foundMatch = false
        scanRow(-3, isCompound)
        if foundMatch { foundAboveMatch = true }
        foundMatch = false
        scanCol(-3, isCompound)
        if foundMatch { foundLeftMatch = true }
        foundMatch = false
        if bh4 > 1 { scanRow(-5, isCompound) }
        if foundMatch { foundAboveMatch = true }
        foundMatch = false
        if bw4 > 1 { scanCol(-5, isCompound) }
        if foundMatch { foundLeftMatch = true }
        let totalMatches = (foundAboveMatch ? 1 : 0) + (foundLeftMatch ? 1 : 0)
        sortStack(0, numNearest, isCompound)
        sortStack(numNearest, numMvFound, isCompound)
        if numMvFound < 2 { extraSearch(isCompound) }
        // Context and clamping (7.10.2.14).
        for idx in 0..<numMvFound {
            var z = 0
            if idx + 1 < numMvFound {
                let w0 = weightStack[idx], w1 = weightStack[idx + 1]
                if w0 >= AV1Inter.refCatLevel {
                    if w1 < AV1Inter.refCatLevel { z = 1 }
                } else {
                    z = 2
                }
            }
            drlCtxStack[idx] = z
        }
        let bw = AV1C.blockWidth[miSize], bh = AV1C.blockHeight[miSize]
        for list in 0..<(isCompound ? 2 : 1) {
            for idx in 0..<numMvFound {
                setStackMv(idx, list, clampMvRow(stackMv(idx, list, 0), 128 + bh * 8), clampMvCol(stackMv(idx, list, 1), 128 + bw * 8))
            }
        }
        if closeMatches == 0 {
            newMvContext = min(totalMatches, 1)
            refMvContext = totalMatches
        } else if closeMatches == 1 {
            newMvContext = 3 - min(numNew, 1)
            refMvContext = 2 + totalMatches
        } else {
            newMvContext = 5 - min(numNew, 1)
            refMvContext = 5
        }
    }

    /// clamp_mv_row / clamp_mv_col (5.11.53, 5.11.54).
    func clampMvRow(_ mvVec: Int, _ border: Int) -> Int {
        let bh4 = AV1C.num4x4H[miSize]
        let mbToTopEdge = -((miRow * 4) * 8)
        let mbToBottomEdge = ((f.hdr.miRows - bh4 - miRow) * 4) * 8
        return clip3(mbToTopEdge - border, mbToBottomEdge + border, mvVec)
    }

    func clampMvCol(_ mvVec: Int, _ border: Int) -> Int {
        let bw4 = AV1C.num4x4W[miSize]
        let mbToLeftEdge = -((miCol * 4) * 8)
        let mbToRightEdge = ((f.hdr.miCols - bw4 - miCol) * 4) * 8
        return clip3(mbToLeftEdge - border, mbToRightEdge + border, mvVec)
    }

    mutating func scanRow(_ deltaRowIn: Int, _ isCompound: Bool) {
        let bw4 = AV1C.num4x4W[miSize]
        let end4 = min(min(bw4, f.hdr.miCols - miCol), 16)
        var deltaRow = deltaRowIn, deltaCol = 0
        let useStep16 = bw4 >= 16
        if abs(deltaRow) > 1 {
            deltaRow += miRow & 1
            deltaCol = 1 - (miCol & 1)
        }
        var i = 0
        while i < end4 {
            let mvRow = miRow + deltaRow, mvCol = miCol + deltaCol + i
            if !isInside(mvRow, mvCol) { break }
            var len = min(bw4, AV1C.num4x4W[Int(miSizes[mi(mvRow, mvCol)])])
            if abs(deltaRow) > 1 { len = max(2, len) }
            if useStep16 { len = max(4, len) }
            addRefMvCandidate(mvRow, mvCol, isCompound, len * 2)
            i += len
        }
    }

    mutating func scanCol(_ deltaColIn: Int, _ isCompound: Bool) {
        let bh4 = AV1C.num4x4H[miSize]
        let end4 = min(min(bh4, f.hdr.miRows - miRow), 16)
        var deltaCol = deltaColIn, deltaRow = 0
        let useStep16 = bh4 >= 16
        if abs(deltaCol) > 1 {
            deltaRow = 1 - (miRow & 1)
            deltaCol += miCol & 1
        }
        var i = 0
        while i < end4 {
            let mvRow = miRow + deltaRow + i, mvCol = miCol + deltaCol
            if !isInside(mvRow, mvCol) { break }
            var len = min(bh4, AV1C.num4x4H[Int(miSizes[mi(mvRow, mvCol)])])
            if abs(deltaCol) > 1 { len = max(2, len) }
            if useStep16 { len = max(4, len) }
            addRefMvCandidate(mvRow, mvCol, isCompound, len * 2)
            i += len
        }
    }

    mutating func scanPoint(_ deltaRow: Int, _ deltaCol: Int, _ isCompound: Bool) {
        let mvRow = miRow + deltaRow, mvCol = miCol + deltaCol
        if isInside(mvRow, mvCol) && written[mi(mvRow, mvCol)] != 0 { addRefMvCandidate(mvRow, mvCol, isCompound, 4) }
    }

    /// The temporal scan process (7.10.2.5).
    mutating func temporalScan(_ isCompound: Bool) {
        let bw4 = AV1C.num4x4W[miSize], bh4 = AV1C.num4x4H[miSize]
        let stepW4 = bw4 >= 16 ? 4 : 2, stepH4 = bh4 >= 16 ? 4 : 2
        var deltaRow = 0
        while deltaRow < min(bh4, 16) {
            var deltaCol = 0
            while deltaCol < min(bw4, 16) {
                addTplRefMv(deltaRow, deltaCol, isCompound)
                deltaCol += stepW4
            }
            deltaRow += stepH4
        }
        let allowExtension = bh4 >= 2 && bh4 < 16 && bw4 >= 2 && bw4 < 16
        if allowExtension {
            for (dr, dc) in [(bh4, -2), (bh4, bw4), (bh4 - 2, bw4)] {
                let row = (miRow & 15) + dr, col = (miCol & 15) + dc
                if row >= 0 && row < 16 && col >= 0 && col < 16 { addTplRefMv(dr, dc, isCompound) }
            }
        }
    }

    /// The temporal sample process (7.10.2.6).
    mutating func addTplRefMv(_ deltaRow: Int, _ deltaCol: Int, _ isCompound: Bool) {
        let mvRow = (miRow + deltaRow) | 1, mvCol = (miCol + deltaCol) | 1
        if !isInside(mvRow, mvCol) { return }
        let x8 = mvCol >> 1, y8 = mvRow >> 1
        if deltaRow == 0 && deltaCol == 0 { zeroMvContext = 1 }
        func field(_ ref: Int) -> (Int, Int)? {
            guard let m = f.motionField.mv(ref, y8, x8) else { return nil }
            return (lowerPrecision(m.0), lowerPrecision(m.1))
        }
        if !isCompound {
            guard let cand = field(refFrame.0) else { return }
            if deltaRow == 0 && deltaCol == 0 {
                zeroMvContext = abs(cand.0 - globalMvs[0]) >= 16 || abs(cand.1 - globalMvs[1]) >= 16 ? 1 : 0
            }
            var idx = 0
            while idx < numMvFound {
                if cand.0 == stackMv(idx, 0, 0) && cand.1 == stackMv(idx, 0, 1) { break }
                idx += 1
            }
            used(.temporalCandidate)
            if idx < numMvFound {
                weightStack[idx] += 2
            } else if numMvFound < 8 {
                setStackMv(numMvFound, 0, cand.0, cand.1)
                weightStack[numMvFound] = 2
                numMvFound += 1
            }
        } else {
            guard let c0 = field(refFrame.0), let c1 = field(refFrame.1) else { return }
            if deltaRow == 0 && deltaCol == 0 {
                zeroMvContext = abs(c0.0 - globalMvs[0]) >= 16 || abs(c0.1 - globalMvs[1]) >= 16 || abs(c1.0 - globalMvs[2]) >= 16
                    || abs(c1.1 - globalMvs[3]) >= 16 ? 1 : 0
            }
            var idx = 0
            while idx < numMvFound {
                if c0.0 == stackMv(idx, 0, 0) && c0.1 == stackMv(idx, 0, 1) && c1.0 == stackMv(idx, 1, 0) && c1.1 == stackMv(idx, 1, 1) { break }
                idx += 1
            }
            if idx < numMvFound {
                weightStack[idx] += 2
            } else if numMvFound < 8 {
                setStackMv(numMvFound, 0, c0.0, c0.1)
                setStackMv(numMvFound, 1, c1.0, c1.1)
                weightStack[numMvFound] = 2
                numMvFound += 1
            }
        }
    }

    /// The add reference motion vector process (7.10.2.7) with the search stack processes.
    mutating func addRefMvCandidate(_ mvRow: Int, _ mvCol: Int, _ isCompound: Bool, _ weight: Int) {
        let i = mi(mvRow, mvCol)
        guard isInters[i] != 0 else { return }
        let candMode = Int(yModes[i])
        let candSize = Int(miSizes[i])
        let large = min(AV1C.blockWidth[candSize], AV1C.blockHeight[candSize]) >= 8
        if !isCompound {
            for candList in 0..<2 where Int(refFrames[2 * i + candList]) == refFrame.0 {
                // search_stack (7.10.2.8)
                var row: Int, col: Int
                if (candMode == AV1Inter.globalMv || candMode == AV1Inter.globalGlobalMv) && f.hdr.gmType[refFrame.0] > AV1Inter.translation && large {
                    row = globalMvs[0]; col = globalMvs[1]
                } else {
                    row = Int(mvs[4 * i + 2 * candList]); col = Int(mvs[4 * i + 2 * candList + 1])
                }
                row = lowerPrecision(row); col = lowerPrecision(col)
                if AV1Inter.hasNewmv(candMode) { newMvCount += 1 }
                foundMatch = true
                var idx = 0
                while idx < numMvFound {
                    if row == stackMv(idx, 0, 0) && col == stackMv(idx, 0, 1) { break }
                    idx += 1
                }
                if idx < numMvFound {
                    weightStack[idx] += weight
                } else if numMvFound < 8 {
                    setStackMv(numMvFound, 0, row, col)
                    weightStack[numMvFound] = weight
                    numMvFound += 1
                }
            }
        } else if Int(refFrames[2 * i]) == refFrame.0 && Int(refFrames[2 * i + 1]) == refFrame.1 {
            // compound search stack (7.10.2.9)
            var r0 = Int(mvs[4 * i]), c0 = Int(mvs[4 * i + 1]), r1 = Int(mvs[4 * i + 2]), c1 = Int(mvs[4 * i + 3])
            if candMode == AV1Inter.globalGlobalMv {
                if f.hdr.gmType[refFrame.0] > AV1Inter.translation { r0 = globalMvs[0]; c0 = globalMvs[1] }
                if f.hdr.gmType[refFrame.1] > AV1Inter.translation { r1 = globalMvs[2]; c1 = globalMvs[3] }
            }
            r0 = lowerPrecision(r0); c0 = lowerPrecision(c0); r1 = lowerPrecision(r1); c1 = lowerPrecision(c1)
            foundMatch = true
            var idx = 0
            while idx < numMvFound {
                if r0 == stackMv(idx, 0, 0) && c0 == stackMv(idx, 0, 1) && r1 == stackMv(idx, 1, 0) && c1 == stackMv(idx, 1, 1) { break }
                idx += 1
            }
            if idx < numMvFound {
                weightStack[idx] += weight
            } else if numMvFound < 8 {
                setStackMv(numMvFound, 0, r0, c0)
                setStackMv(numMvFound, 1, r1, c1)
                weightStack[numMvFound] = weight
                numMvFound += 1
            }
            if AV1Inter.hasNewmv(candMode) { newMvCount += 1 }
        }
    }

    /// The sorting process (7.10.2.11): a stable bubble sort by weight.
    mutating func sortStack(_ start: Int, _ endIn: Int, _ isCompound: Bool) {
        var end = endIn
        while end > start {
            var newEnd = start
            var idx = start + 1
            while idx < end {
                if weightStack[idx - 1] < weightStack[idx] {
                    weightStack.swapAt(idx - 1, idx)
                    for k in 0..<(isCompound ? 4 : 2) { refStackMv.swapAt((idx - 1) * 4 + k, idx * 4 + k) }
                    newEnd = idx
                }
                idx += 1
            }
            end = newEnd
        }
    }

    /// The extra search process (7.10.2.12) and add extra MV candidate (7.10.2.13).
    mutating func extraSearch(_ isCompound: Bool) {
        var refIdCount = [0, 0], refDiffCount = [0, 0]
        var refIdMvs = [Int](repeating: 0, count: 8), refDiffMvs = [Int](repeating: 0, count: 8)   // [list][2][comp]
        var w4 = min(16, AV1C.num4x4W[miSize]), h4 = min(16, AV1C.num4x4H[miSize])
        w4 = min(w4, f.hdr.miCols - miCol)
        h4 = min(h4, f.hdr.miRows - miRow)
        let num4x4 = min(w4, h4)
        for pass in 0..<2 {
            var idx = 0
            while idx < num4x4 && numMvFound < 2 {
                let mvRow = pass == 0 ? miRow - 1 : miRow + idx
                let mvCol = pass == 0 ? miCol + idx : miCol - 1
                if !isInside(mvRow, mvCol) { break }
                let i = mi(mvRow, mvCol)
                if isCompound {
                    for candList in 0..<2 {
                        let candRef = Int(refFrames[2 * i + candList])
                        guard candRef > AV1Ref.intra else { continue }
                        for list in 0..<2 {
                            var row = Int(mvs[4 * i + 2 * candList]), col = Int(mvs[4 * i + 2 * candList + 1])
                            if candRef == refFrameOf(list) && refIdCount[list] < 2 {
                                refIdMvs[list * 4 + refIdCount[list] * 2] = row
                                refIdMvs[list * 4 + refIdCount[list] * 2 + 1] = col
                                refIdCount[list] += 1
                            } else if refDiffCount[list] < 2 {
                                if f.hdr.refFrameSignBias[candRef] != f.hdr.refFrameSignBias[refFrameOf(list)] { row = -row; col = -col }
                                refDiffMvs[list * 4 + refDiffCount[list] * 2] = row
                                refDiffMvs[list * 4 + refDiffCount[list] * 2 + 1] = col
                                refDiffCount[list] += 1
                            }
                        }
                    }
                } else {
                    for candList in 0..<2 {
                        let candRef = Int(refFrames[2 * i + candList])
                        guard candRef > AV1Ref.intra else { continue }
                        var row = Int(mvs[4 * i + 2 * candList]), col = Int(mvs[4 * i + 2 * candList + 1])
                        if f.hdr.refFrameSignBias[candRef] != f.hdr.refFrameSignBias[refFrame.0] { row = -row; col = -col }
                        var k = 0
                        while k < numMvFound {
                            if row == stackMv(k, 0, 0) && col == stackMv(k, 0, 1) { break }
                            k += 1
                        }
                        if k == numMvFound {
                            setStackMv(k, 0, row, col)
                            weightStack[k] = 2
                            numMvFound += 1
                        }
                    }
                }
                idx += pass == 0 ? AV1C.num4x4W[Int(miSizes[i])] : AV1C.num4x4H[Int(miSizes[i])]
            }
        }
        if isCompound {
            var combined = [Int](repeating: 0, count: 8)   // [2][list][comp]
            for list in 0..<2 {
                var compCount = 0
                for idx in 0..<refIdCount[list] {
                    combined[compCount * 4 + list * 2] = refIdMvs[list * 4 + idx * 2]
                    combined[compCount * 4 + list * 2 + 1] = refIdMvs[list * 4 + idx * 2 + 1]
                    compCount += 1
                }
                var idx = 0
                while idx < refDiffCount[list] && compCount < 2 {
                    combined[compCount * 4 + list * 2] = refDiffMvs[list * 4 + idx * 2]
                    combined[compCount * 4 + list * 2 + 1] = refDiffMvs[list * 4 + idx * 2 + 1]
                    compCount += 1
                    idx += 1
                }
                while compCount < 2 {
                    combined[compCount * 4 + list * 2] = globalMvs[list * 2]
                    combined[compCount * 4 + list * 2 + 1] = globalMvs[list * 2 + 1]
                    compCount += 1
                }
            }
            if numMvFound == 1 {
                let same = combined[0] == stackMv(0, 0, 0) && combined[1] == stackMv(0, 0, 1) && combined[2] == stackMv(0, 1, 0) && combined[3] == stackMv(0, 1, 1)
                let k = same ? 1 : 0
                setStackMv(numMvFound, 0, combined[k * 4], combined[k * 4 + 1])
                setStackMv(numMvFound, 1, combined[k * 4 + 2], combined[k * 4 + 3])
                weightStack[numMvFound] = 2
                numMvFound += 1
            } else {
                for idx in 0..<2 {
                    setStackMv(numMvFound, 0, combined[idx * 4], combined[idx * 4 + 1])
                    setStackMv(numMvFound, 1, combined[idx * 4 + 2], combined[idx * 4 + 3])
                    weightStack[numMvFound] = 2
                    numMvFound += 1
                }
            }
        } else {
            var idx = numMvFound
            while idx < 2 {
                setStackMv(idx, 0, globalMvs[0], globalMvs[1])
                idx += 1
            }
        }
    }

    // MARK: assign_mv (5.11.26), read_mv (5.11.31, 5.11.32)

    func getMode(_ refList: Int) -> Int {
        if refList == 0 {
            if yMode < AV1Inter.nearestNearestMv { return yMode }
            if yMode == AV1Inter.newNewMv || yMode == AV1Inter.newNearestMv || yMode == AV1Inter.newNearMv { return AV1Inter.newMv }
            if yMode == AV1Inter.nearestNearestMv || yMode == AV1Inter.nearestNewMv { return AV1Inter.nearestMv }
            if yMode == AV1Inter.nearNearMv || yMode == AV1Inter.nearNewMv { return AV1Inter.nearMv }
            return AV1Inter.globalMv
        }
        if yMode == AV1Inter.newNewMv || yMode == AV1Inter.nearestNewMv || yMode == AV1Inter.nearNewMv { return AV1Inter.newMv }
        if yMode == AV1Inter.nearestNearestMv || yMode == AV1Inter.newNearestMv { return AV1Inter.nearestMv }
        if yMode == AV1Inter.nearNearMv || yMode == AV1Inter.newNearMv { return AV1Inter.nearMv }
        return AV1Inter.globalMv
    }

    mutating func assignMv(_ isCompound: Bool) {
        for i in 0..<(isCompound ? 2 : 1) {
            let compMode = getMode(i)
            var pred: (Int, Int)
            if compMode == AV1Inter.globalMv {
                pred = (globalMvs[2 * i], globalMvs[2 * i + 1])
            } else {
                var pos = compMode == AV1Inter.nearestMv ? 0 : refMvIdx
                if compMode == AV1Inter.newMv && numMvFound <= 1 { pos = 0 }
                pred = (stackMv(pos, i, 0), stackMv(pos, i, 1))
            }
            var result = pred
            if compMode == AV1Inter.newMv {
                let (dr, dc) = readMv(ctx: 0)
                result = (pred.0 + dr, pred.1 + dc)
            }
            if i == 0 { mv = (result.0, result.1) } else { mv1 = (result.0, result.1) }
        }
    }

    /// read_mv's component differences (diffMv) for MvCtx `ctx`.
    mutating func readMv(ctx: Int) -> (Int, Int) {
        let joint = sd.symbol(lay.mvJoint + ctx * 5, 4)
        var diffRow = 0, diffCol = 0
        if joint == 2 || joint == 3 { diffRow = readMvComponent(ctx, 0) }
        if joint == 1 || joint == 3 { diffCol = readMvComponent(ctx, 1) }
        return (diffRow, diffCol)
    }

    // MARK: read_interintra_mode, read_motion_mode, read_compound_type (5.11.27 – 5.11.29)

    mutating func readInterIntraMode(_ isCompound: Bool) {
        interintra = false
        guard skipMode == 0, f.seq.enableInterintraCompound, !isCompound, miSize >= AV1C.block8x8, miSize <= 9 else { return }
        let ctx = Int(AV1Tables.sizeGroup[miSize]) - 1
        interintra = sd.symbol(lay.interIntra + ctx * 3, 2) == 1
        guard interintra else { return }
        interintraMode = sd.symbol(lay.interIntraMode + ctx * 5, 4)
        used(.interintra)
        refFrame.1 = AV1Ref.intra
        angleDeltaY = 0
        angleDeltaUV = 0
        useFilterIntra = false
        wedgeInterintra = sd.symbol(lay.wedgeInterIntra + miSize * 3, 2) == 1
        if wedgeInterintra {
            used(.interintraWedge)
            wedgeIndex = sd.symbol(lay.wedgeIndex + miSize * 17, 16)
            wedgeSign = 0
        }
    }

    func isScaled(_ ref: Int) -> Bool {
        guard ref > AV1Ref.intra, let p = f.refPictures[ref] else { return false }
        let fw = f.hdr.frameWidth, fh = f.hdr.frameHeight
        let xScale = ((p.upscaledWidth << 14) + fw / 2) / fw
        let yScale = ((p.frameHeight << 14) + fh / 2) / fh
        return xScale != 1 << 14 || yScale != 1 << 14
    }

    mutating func readMotionMode(_ isCompound: Bool) {
        motionMode = AV1Inter.simple
        numSamples = 0
        if skipMode != 0 || !f.hdr.isMotionModeSwitchable { return }
        if min(AV1C.blockWidth[miSize], AV1C.blockHeight[miSize]) < 8 { return }
        if !f.hdr.forceIntegerMv && (yMode == AV1Inter.globalMv || yMode == AV1Inter.globalGlobalMv) {
            if f.hdr.gmType[refFrame.0] > AV1Inter.translation { return }
        }
        if isCompound || refFrame.1 == AV1Ref.intra || !hasOverlappableCandidates() { return }
        findWarpSamples()
        if f.hdr.forceIntegerMv || numSamples == 0 || !f.hdr.allowWarpedMotion || isScaled(refFrame.0) {
            motionMode = sd.symbol(lay.useObmc + miSize * 3, 2) == 1 ? AV1Inter.obmc : AV1Inter.simple
        } else {
            motionMode = sd.symbol(lay.motionMode + miSize * 4, 3)
        }
        if motionMode == AV1Inter.obmc { used(.obmc) } else if motionMode == AV1Inter.localWarp { used(.localWarp) }
    }

    mutating func readCompoundType(_ isCompound: Bool) {
        compGroupIdx = 0
        compoundIdx = 1
        if skipMode != 0 { compoundType = AV1Inter.compoundAverage; return }
        if isCompound {
            let n = Int(AV1Tables.wedgeBits[miSize])
            if f.seq.enableMaskedCompound {
                var ctx = 0
                if availU {
                    if !aboveSingle { ctx += Int(compGroupIdxs[mi(miRow - 1, miCol)]) } else if aboveRef.0 == AV1Ref.altref { ctx += 3 }
                }
                if availL {
                    if !leftSingle { ctx += Int(compGroupIdxs[mi(miRow, miCol - 1)]) } else if leftRef.0 == AV1Ref.altref { ctx += 3 }
                }
                compGroupIdx = sd.symbol(lay.compGroupIdx + min(5, ctx) * 3, 2)
            }
            if compGroupIdx == 0 {
                if f.seq.enableJntComp {
                    let fwd = abs(f.seq.relativeDist(f.hdr.orderHints[refFrame.0], f.hdr.orderHint))
                    let bck = abs(f.seq.relativeDist(f.hdr.orderHints[refFrame.1], f.hdr.orderHint))
                    var ctx = fwd == bck ? 3 : 0
                    if availU {
                        if !aboveSingle { ctx += Int(compoundIdxs[mi(miRow - 1, miCol)]) } else if aboveRef.0 == AV1Ref.altref { ctx += 1 }
                    }
                    if availL {
                        if !leftSingle { ctx += Int(compoundIdxs[mi(miRow, miCol - 1)]) } else if leftRef.0 == AV1Ref.altref { ctx += 1 }
                    }
                    compoundIdx = sd.symbol(lay.compoundIdx + ctx * 3, 2)
                    compoundType = compoundIdx != 0 ? AV1Inter.compoundAverage : AV1Inter.compoundDistance
                } else {
                    compoundType = AV1Inter.compoundAverage
                }
            } else if n == 0 {
                compoundType = AV1Inter.compoundDiffwtd
            } else {
                compoundType = sd.symbol(lay.compoundType + miSize * 3, 2)
            }
            if compoundType == AV1Inter.compoundWedge { used(.wedge) }
            if compoundType == AV1Inter.compoundDiffwtd { used(.diffwtd) }
            if compoundType == AV1Inter.compoundDistance { used(.distance) }
            if compoundType == AV1Inter.compoundWedge {
                wedgeIndex = sd.symbol(lay.wedgeIndex + miSize * 17, 16)
                wedgeSign = sd.literal(1)
            } else if compoundType == AV1Inter.compoundDiffwtd {
                maskType = sd.literal(1)
            }
        } else {
            compoundType = interintra ? (wedgeInterintra ? AV1Inter.compoundWedge : AV1Inter.compoundIntra) : AV1Inter.compoundAverage
        }
    }

    // MARK: has_overlappable_candidates (7.10.3), find_warp_samples (7.10.4)

    func hasOverlappableCandidates() -> Bool {
        if availU {
            let w4 = AV1C.num4x4W[miSize]
            var x4 = miCol
            while x4 < min(f.hdr.miCols, miCol + w4) {
                let c = min(x4 | 1, miColEnd - 1)
                if refFrames[2 * mi(miRow - 1, c)] > Int8(AV1Ref.intra) { return true }
                x4 += 2
            }
        }
        if availL {
            let h4 = AV1C.num4x4H[miSize]
            var y4 = miRow
            while y4 < min(f.hdr.miRows, miRow + h4) {
                let r = min(y4 | 1, miRowEnd - 1)
                if refFrames[2 * mi(r, miCol - 1)] > Int8(AV1Ref.intra) { return true }
                y4 += 2
            }
        }
        return false
    }

    mutating func findWarpSamples() {
        numSamples = 0
        numSamplesScanned = 0
        let w4 = AV1C.num4x4W[miSize], h4 = AV1C.num4x4H[miSize]
        var doTopLeft = true, doTopRight = true
        if availU {
            let srcW = AV1C.num4x4W[Int(miSizes[mi(miRow - 1, miCol)])]
            if w4 <= srcW {
                let colOffset = -(miCol & (srcW - 1))
                if colOffset < 0 { doTopLeft = false }
                if colOffset + srcW > w4 { doTopRight = false }
                addSample(-1, 0)
            } else {
                var i = 0
                while i < min(w4, f.hdr.miCols - miCol) {
                    let srcW2 = AV1C.num4x4W[Int(miSizes[mi(miRow - 1, miCol + i)])]
                    let step = min(w4, srcW2)
                    addSample(-1, i)
                    i += step
                }
            }
        }
        if availL {
            let srcH = AV1C.num4x4H[Int(miSizes[mi(miRow, miCol - 1)])]
            if h4 <= srcH {
                let rowOffset = -(miRow & (srcH - 1))
                if rowOffset < 0 { doTopLeft = false }
                addSample(0, -1)
            } else {
                var i = 0
                while i < min(h4, f.hdr.miRows - miRow) {
                    let srcH2 = AV1C.num4x4H[Int(miSizes[mi(miRow + i, miCol - 1)])]
                    let step = min(h4, srcH2)
                    addSample(i, -1)
                    i += step
                }
            }
        }
        if doTopLeft { addSample(-1, -1) }
        if doTopRight && max(w4, h4) <= 16 { addSample(-1, w4) }
        if numSamples == 0 && numSamplesScanned > 0 { numSamples = 1 }
    }

    mutating func addSample(_ deltaRow: Int, _ deltaCol: Int) {
        if numSamplesScanned >= 8 { return }
        let mvRow = miRow + deltaRow, mvCol = miCol + deltaCol
        if !isInside(mvRow, mvCol) { return }
        let i = mi(mvRow, mvCol)
        if written[i] == 0 { return }
        if Int(refFrames[2 * i]) != refFrame.0 || Int(refFrames[2 * i + 1]) != AV1Ref.none { return }
        let candSz = Int(miSizes[i])
        let candW4 = AV1C.num4x4W[candSz], candH4 = AV1C.num4x4H[candSz]
        let candRow = mvRow & ~(candH4 - 1), candCol = mvCol & ~(candW4 - 1)
        let midY = candRow * 4 + candH4 * 2 - 1, midX = candCol * 4 + candW4 * 2 - 1
        let threshold = clip3(16, 112, max(AV1C.blockWidth[miSize], AV1C.blockHeight[miSize]))
        let c = mi(candRow, candCol)
        let cRow = Int(mvs[4 * c]), cCol = Int(mvs[4 * c + 1])
        let valid = abs(cRow - mv.row) + abs(cCol - mv.col) <= threshold
        numSamplesScanned += 1
        if !valid && numSamplesScanned > 1 { return }
        candList[numSamples * 4] = midY * 8
        candList[numSamples * 4 + 1] = midX * 8
        candList[numSamples * 4 + 2] = midY * 8 + cRow
        candList[numSamples * 4 + 3] = midX * 8 + cCol
        if valid { numSamples += 1 }
    }
}
