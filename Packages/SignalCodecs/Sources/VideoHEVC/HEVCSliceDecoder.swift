// slice_segment_data() (H.265 7.3.8): the CTU loop with tiles and wavefront entry points,
// SAO syntax (7.3.8.3), coding_quadtree / coding_unit (7.3.8.4 – 7.3.8.5), PCM, the intra
// mode derivation (8.4.2, 8.4.3), transform_tree / transform_unit (7.3.8.8 – 7.3.8.10), QP
// derivation (8.6.1) and reconstruction: intra prediction and residuals per transform block.

import CodecCore
import Dispatch
import Synchronization

public enum HEVCDecodeError: Error, Equatable, Sendable {
    case unsupported(String)
    case malformed(String)
}

struct HEVCSliceDecoder {
    let sps: HEVCSPS
    let pps: HEVCPPS
    let header: HEVCSliceHeader
    let nal: HEVCNALUnit
    let pic: HEVCPicture
    let geom: HEVCGeometry
    var cabac: HEVCCABAC
    let sliceQp: Int
    let initType: Int
    /// SliceAddrRs: the first CTB of the slice (the independent segment) this segment belongs to.
    let sliceAddrRs: Int
    let sliceIndex: Int
    let inter: HEVCInterContext?
    /// The reference planes and weights motion compensation reads (P/B slices).
    let mcShared: HEVCMCShared

    var ctbAddrRs = 0, ctbAddrTs = 0
    // Quantisation group state (8.6.1).
    var qpY = 0
    var qpYPrev = 0
    var isCuQpDeltaCoded = false
    var cuQpDeltaVal = 0
    var xQg = 0, yQg = 0
    var firstQgInCtbRowOrTile = true
    /// The first quantisation group of a slice (dependent segments continue their slice's).
    var firstQgInSlice = true
    // The current coding unit.
    var cuBypass = false
    var cuIntra = true
    var intraLumaModes = [Int](repeating: 1, count: 4)
    var intraChromaMode = 0
    var partNxN = false
    /// WPP: contexts after the second CTB of the row above (9.3.2.4).
    var wppState: InlineArray<157, UInt8>?
    var wppStat: [Int] = [0, 0, 0, 0]
    /// Contexts at the end of this segment (for a following dependent segment).
    var endState = InlineArray<157, UInt8>(repeating: 0)
    var endStat: [Int] = []

    let qpBdOffsetY: Int, qpBdOffsetC: Int
    /// Scratch for one transform block (32x32 at most): levels / scaled coefficients, the
    /// vertical pass, the residual.
    /// The slice's nonzero transform coefficients, packed (see `residualCoding`); jobs name
    /// their runs in it. `coeffStart` is where the last block's run starts.
    var coeffPool: [Int32] = []
    var coeffStart = 0
    /// Reconstruction, recorded while parsing (it runs on the reconstruction stage).
    var mcJobs: [HEVCMCJob] = []
    var interResiduals: [HEVCResidualJob] = []
    var intraSteps: [HEVCIntraStep] = []
    var work = [Int32](repeating: 0, count: 1024)
    var resid = [Int32](repeating: 0, count: 1024)

    init(sps: HEVCSPS, pps: HEVCPPS, header: HEVCSliceHeader, nal: HEVCNALUnit, pic: HEVCPicture, geom: HEVCGeometry,
         sliceAddrRs: Int, sliceIndex: Int, dependentState: (state: InlineArray<157, UInt8>, stat: [Int])?, inter: HEVCInterContext?) throws(HEVCDecodeError) {
        guard !sps.implicitRdpcmEnabled, !sps.explicitRdpcmEnabled, !sps.extendedPrecisionProcessing, !sps.persistentRiceAdaptationEnabled,
              !sps.cabacBypassAlignmentEnabled, !pps.crossComponentPrediction, !pps.chromaQpOffsetListEnabled, sps.chromaArrayType != 3 || true
        else { throw .unsupported("range-extension coding tools") }
        guard sps.chromaFormatIdc <= 1 else { throw .unsupported("chroma format \(sps.chromaFormatIdc)") }
        self.sps = sps
        self.pps = pps
        self.header = header
        self.nal = nal
        self.pic = pic
        self.geom = geom
        self.sliceAddrRs = sliceAddrRs
        self.sliceIndex = sliceIndex
        self.inter = inter
        mcShared = inter?.shared(sps: sps, pps: pps, type: header.type)
            ?? HEVCMCShared(refIds: [], planes: [], weightW: [], weightO: [], weighted: false, lumaLog2Denom: 0, chromaLog2Denom: 0, comps: 1, subW: 1, subH: 1,
                            bitDepthLuma: 8, bitDepthChroma: 8)
        sliceQp = pps.initQp + header.qpDelta
        switch header.type {
        case .i: initType = 0
        case .p: initType = header.cabacInit ? 2 : 1
        case .b: initType = header.cabacInit ? 1 : 2
        }
        qpBdOffsetY = 6 * (sps.bitDepthLuma - 8)
        qpBdOffsetC = 6 * (sps.bitDepthChroma - 8)
        cabac = HEVCCABAC(rbsp: nal.rbsp, start: header.dataOffset, end: nal.rbsp.count)
        firstQgInSlice = !header.dependentSliceSegment
        xQg = -1
        if header.dependentSliceSegment, let dep = dependentState {
            cabac.state = dep.state
            cabac.statCoeff = dep.stat
        } else {
            cabac.initContexts(initType: initType, qp: sliceQp)
        }
        cabac.startEngine()
        qpY = sliceQp
        qpYPrev = sliceQp
    }

    // MARK: availability (6.4.1)

    /// z-scan availability of the luma location (xN, yN) for a block at (xC, yC).
    @inline(__always) func available(_ xC: Int, _ yC: Int, _ xN: Int, _ yN: Int) -> Bool {
        guard xN >= 0, yN >= 0, xN < sps.width, yN < sps.height else { return false }
        if geom.zOrder(xN, yN) > geom.zOrder(xC, yC) { return false }
        let ctbN = geom.ctbAddrRs(xN, yN)
        guard pic.ctbSliceAddr[ctbN] == sliceAddrRs, pic.ctbDecoded[ctbN] || ctbN == ctbAddrRs else { return false }
        guard geom.tileId[geom.rsToTs[ctbN]] == geom.tileId[ctbAddrTs] else { return false }
        return pic.predMode[pic.i4(xN, yN)] != 255
    }

    // MARK: CTU loop

    mutating func decode() throws(HEVCDecodeError) {
        ctbAddrTs = geom.rsToTs[header.segmentAddress]
        ctbAddrRs = header.segmentAddress
        var entry = 0
        // Entry points count payload bytes (emulation prevention included) from the data start.
        let rawStart = nal.payloadOffset(rbspOffset: header.dataOffset)
        let entryStarts = header.entryPointOffsets.reduce(into: [rawStart]) { $0.append($0.last! + $1) }.map { nal.rbspOffset(payloadOffset: $0) }
        while true {
            ctbAddrRs = geom.tsToRs[ctbAddrTs]
            let xCtb = (ctbAddrRs % geom.widthCtbs) << sps.log2CtbSize, yCtb = (ctbAddrRs / geom.widthCtbs) << sps.log2CtbSize
            let tileStart = ctbAddrTs == 0 || geom.tileId[ctbAddrTs] != geom.tileId[ctbAddrTs - 1]
            let rowStartInTile = geom.colBd.contains(ctbAddrRs % geom.widthCtbs)
            // WPP: the first CTB of a row takes the contexts saved after the second CTB above.
            if pps.entropyCodingSync && rowStartInTile && ctbAddrTs != geom.rsToTs[header.segmentAddress] || (pps.entropyCodingSync && rowStartInTile && header.dependentSliceSegment && ctbAddrRs == header.segmentAddress) {
                let xTR = xCtb + sps.ctbSize, yTR = yCtb - sps.ctbSize
                if yTR >= 0 && xTR < sps.width && availableCtb(xTR, yTR), let saved = wppState {
                    cabac.state = saved
                    cabac.statCoeff = wppStat
                } else if ctbAddrTs != geom.rsToTs[header.segmentAddress] || header.dependentSliceSegment {
                    cabac.initContexts(initType: initType, qp: sliceQp)
                }
            }
            if tileStart && ctbAddrTs != geom.rsToTs[header.segmentAddress] {
                cabac.initContexts(initType: initType, qp: sliceQp)
            }
            if (tileStart || (pps.entropyCodingSync && rowStartInTile)) { firstQgInCtbRowOrTile = true }
            pic.ctbSliceAddr[ctbAddrRs] = sliceAddrRs
            pic.ctbSliceIndex[ctbAddrRs] = Int16(sliceIndex)
            pic.ctbDeblockDisabled[ctbAddrRs] = header.deblockingFilterDisabled
            pic.ctbFilterAcrossSlices[ctbAddrRs] = header.loopFilterAcrossSlices
            pic.ctbBetaOffset[ctbAddrRs] = Int8(header.betaOffsetDiv2)
            pic.ctbTcOffset[ctbAddrRs] = Int8(header.tcOffsetDiv2)
            pic.ctbCbQpOffset[ctbAddrRs] = Int8(pps.cbQpOffset + header.cbQpOffset)
            pic.ctbCrQpOffset[ctbAddrRs] = Int8(pps.crQpOffset + header.crQpOffset)

            do {
                if header.saoLuma || header.saoChroma { try parseSAO(rx: xCtb >> sps.log2CtbSize, ry: yCtb >> sps.log2CtbSize) }
                try codingQuadtree(xCtb, yCtb, sps.log2CtbSize, 0)
            } catch {
                throw .malformed("\(error)")
            }
            pic.ctbDecoded[ctbAddrRs] = true
            let endOfSegment = cabac.terminate() == 1
            // WPP storage after the second CTB of a row in its tile (9.3.2.2 end).
            if pps.entropyCodingSync {
                let x = ctbAddrRs % geom.widthCtbs
                let tileColStart = geom.colBd.last(where: { $0 <= x }) ?? 0
                let tileWidth = (geom.colBd.first(where: { $0 > x }) ?? geom.widthCtbs) - tileColStart
                if x - tileColStart == 1 || (tileWidth == 1 && x == tileColStart) {
                    wppState = cabac.state
                    wppStat = cabac.statCoeff
                }
            }
            ctbAddrTs += 1
            if endOfSegment {
                endState = cabac.state
                endStat = cabac.statCoeff
                return
            }
            guard ctbAddrTs < geom.tsToRs.count else { throw .malformed("slice data past the last CTB") }
            let nextRs = geom.tsToRs[ctbAddrTs]
            let nextTileStart = geom.tileId[ctbAddrTs] != geom.tileId[ctbAddrTs - 1]
            let nextRowStart = pps.entropyCodingSync && geom.colBd.contains(nextRs % geom.widthCtbs)
            if (pps.tilesEnabled && nextTileStart) || nextRowStart {
                guard cabac.terminate() == 1 else { throw .malformed("end_of_subset_one_bit is 0") }
                entry += 1
                guard entry < entryStarts.count else { throw .malformed("missing entry point \(entry)") }
                cabac.restart(at: entryStarts[entry])
            }
        }
    }

    /// The whole CTB containing (x, y) is in this slice and tile and already decoded.
    func availableCtb(_ x: Int, _ y: Int) -> Bool {
        let rs = geom.ctbAddrRs(x, y)
        return pic.ctbDecoded[rs] && pic.ctbSliceAddr[rs] == sliceAddrRs && geom.tileId[geom.rsToTs[rs]] == geom.tileId[ctbAddrTs]
    }

    // MARK: SAO (7.3.8.3)

    mutating func parseSAO(rx: Int, ry: Int) throws(ParseFailure) {
        var mergeLeft = false, mergeUp = false
        if rx > 0 {
            let left = ctbAddrRs - 1
            if pic.ctbSliceAddr[left] == sliceAddrRs && geom.tileId[geom.rsToTs[left]] == geom.tileId[ctbAddrTs] {
                mergeLeft = cabac.decision(HEVCCtx.saoMerge) == 1
            }
        }
        if ry > 0 && !mergeLeft {
            let up = ctbAddrRs - geom.widthCtbs
            if pic.ctbSliceAddr[up] == sliceAddrRs && geom.tileId[geom.rsToTs[up]] == geom.tileId[ctbAddrTs] {
                mergeUp = cabac.decision(HEVCCtx.saoMerge) == 1
            }
        }
        let comps = sps.chromaArrayType != 0 ? 3 : 1
        if mergeLeft || mergeUp {
            let src = mergeLeft ? ctbAddrRs - 1 : ctbAddrRs - geom.widthCtbs
            for c in 0..<comps { pic.sao[c][ctbAddrRs] = pic.sao[c][src] }
            return
        }
        for c in 0..<comps {
            var s = HEVCSAO()
            guard (c == 0 && header.saoLuma) || (c > 0 && header.saoChroma) else { pic.sao[c][ctbAddrRs] = s; continue }
            if c == 2 {
                s.type = pic.sao[1][ctbAddrRs].type
                s.eoClass = pic.sao[1][ctbAddrRs].eoClass
            } else {
                s.type = cabac.decision(HEVCCtx.saoTypeIdx) == 0 ? 0 : (cabac.bypass() == 0 ? 1 : 2)
            }
            if s.type != 0 {
                let bitDepth = c == 0 ? sps.bitDepthLuma : sps.bitDepthChroma
                let cMax = (1 << (min(bitDepth, 10) - 5)) - 1
                var abs = [Int32](repeating: 0, count: 4)
                for i in 0..<4 {
                    var v = 0
                    while v < cMax && cabac.bypass() == 1 { v += 1 }
                    abs[i] = Int32(v)
                }
                if s.type == 1 {
                    for i in 0..<4 where abs[i] != 0 { if cabac.bypass() == 1 { abs[i] = -abs[i] } }
                    s.bandPosition = cabac.bypassBits(5)
                    s.offsets = abs
                } else {
                    s.offsets = [abs[0], abs[1], -abs[2], -abs[3]]
                    if c == 0 { s.eoClass = cabac.bypassBits(2) }
                    if c == 1 { s.eoClass = cabac.bypassBits(2) }
                }
                // log2SaoOffsetScale is 0 without the range extension.
                let shift = Int32(0)
                s.offsets = s.offsets.map { $0 << shift }
            }
            pic.sao[c][ctbAddrRs] = s
        }
    }

    // MARK: coding tree (7.3.8.4, 7.3.8.5)

    mutating func codingQuadtree(_ x0: Int, _ y0: Int, _ log2CbSize: Int, _ depth: Int) throws(ParseFailure) {
        let size = 1 << log2CbSize
        var split: Bool
        if x0 + size <= sps.width && y0 + size <= sps.height && log2CbSize > sps.log2MinCbSize {
            let l = available(x0, y0, x0 - 1, y0) && Int(pic.ctDepth[pic.i4(x0 - 1, y0)]) > depth
            let a = available(x0, y0, x0, y0 - 1) && Int(pic.ctDepth[pic.i4(x0, y0 - 1)]) > depth
            split = cabac.decision(HEVCCtx.splitCuFlag + (l ? 1 : 0) + (a ? 1 : 0)) == 1
        } else {
            split = log2CbSize > sps.log2MinCbSize
        }
        if pps.cuQpDeltaEnabled && log2CbSize >= sps.log2CtbSize - pps.diffCuQpDeltaDepth {
            isCuQpDeltaCoded = false
            cuQpDeltaVal = 0
        }
        if split {
            let x1 = x0 + (size >> 1), y1 = y0 + (size >> 1)
            try codingQuadtree(x0, y0, log2CbSize - 1, depth + 1)
            if x1 < sps.width { try codingQuadtree(x1, y0, log2CbSize - 1, depth + 1) }
            if y1 < sps.height { try codingQuadtree(x0, y1, log2CbSize - 1, depth + 1) }
            if x1 < sps.width && y1 < sps.height { try codingQuadtree(x1, y1, log2CbSize - 1, depth + 1) }
        } else {
            try codingUnit(x0, y0, log2CbSize, depth)
        }
    }

    /// The start of a quantisation group: qPY_PREV (8.6.1).
    mutating func startQuantizationGroup(_ x: Int, _ y: Int) {
        xQg = x
        yQg = y
        if firstQgInCtbRowOrTile || firstQgInSlice {
            qpYPrev = sliceQp
            firstQgInCtbRowOrTile = false
        } else {
            qpYPrev = qpY
        }
    }

    /// 8.6.1: QpY of the current coding unit from the prediction and CuQpDeltaVal.
    mutating func deriveQpY() -> Int {
        let qgCtb = geom.ctbAddrRs(xQg, yQg)
        let qpA = available(xQg, yQg, xQg - 1, yQg) && geom.ctbAddrRs(xQg - 1, yQg) == qgCtb ? Int(pic.qpY[pic.i4(xQg - 1, yQg)]) : qpYPrev
        let qpB = available(xQg, yQg, xQg, yQg - 1) && geom.ctbAddrRs(xQg, yQg - 1) == qgCtb ? Int(pic.qpY[pic.i4(xQg, yQg - 1)]) : qpYPrev
        let pred = (qpA + qpB + 1) >> 1
        return ((pred + cuQpDeltaVal + 52 + 2 * qpBdOffsetY) % (52 + qpBdOffsetY)) - qpBdOffsetY
    }

    mutating func codingUnit(_ x0: Int, _ y0: Int, _ log2CbSize: Int, _ depth: Int) throws(ParseFailure) {
        let size = 1 << log2CbSize
        // The quantisation group of this CU (8.6.1): its top-left on the Log2MinCuQpDeltaSize grid.
        // A new group starts when that position changes (nested quadtree nodes share one).
        let qgMask = (1 << (sps.log2CtbSize - pps.diffCuQpDeltaDepth)) - 1
        let qx = x0 & ~qgMask, qy = y0 & ~qgMask
        if qx != xQg || qy != yQg || firstQgInSlice {
            startQuantizationGroup(qx, qy)
            firstQgInSlice = false
        }
        cuBypass = false
        if pps.transquantBypassEnabled { cuBypass = cabac.decision(HEVCCtx.cuTransquantBypass) == 1 }
        var skip = false
        if header.type != .i {
            let l = available(x0, y0, x0 - 1, y0) && pic.predMode[pic.i4(x0 - 1, y0)] == 2
            let a = available(x0, y0, x0, y0 - 1) && pic.predMode[pic.i4(x0, y0 - 1)] == 2
            skip = cabac.decision(HEVCCtx.cuSkipFlag + (l ? 1 : 0) + (a ? 1 : 0)) == 1
        }
        pic.fill(&pic.ctDepth, x0, y0, size, size, UInt8(depth))
        qpY = deriveQpY()
        pic.fill(&pic.qpY, x0, y0, size, size, Int8(qpY))
        pic.fill(&pic.bypass, x0, y0, size, size, cuBypass)
        pic.fill(&pic.nonZeroCoeff, x0, y0, size, size, false)
        markEdges(x0, y0, size, size, tu: true)
        if skip {
            pic.fill(&pic.predMode, x0, y0, size, size, UInt8(2))
            guard let inter else { throw ParseFailure(offset: 0, rule: "cu_skip_flag", reason: .invalid("inter in an intra-only decode")) }
            try inter.predictionUnit(&self, x0, y0, size, size, log2CbSize: log2CbSize, partIdx: 0, merge: true)
            return
        }
        cuIntra = true
        if header.type != .i { cuIntra = cabac.decision(HEVCCtx.predModeFlag) == 1 }
        pic.fill(&pic.predMode, x0, y0, size, size, UInt8(cuIntra ? 1 : 0))
        var partMode = 0    // 0 2Nx2N, 1 2NxN, 2 Nx2N, 3 NxN, 4 2NxnU, 5 2NxnD, 6 nLx2N, 7 nRx2N
        if !cuIntra || log2CbSize == sps.log2MinCbSize {
            partMode = try parsePartMode(intra: cuIntra, log2CbSize: log2CbSize)
        }
        partNxN = cuIntra && partMode == 3
        var rqtRootCbf = true
        if cuIntra {
            var pcm = false
            if partMode == 0 && sps.pcmEnabled && log2CbSize >= sps.log2MinPcmCbSize && log2CbSize <= sps.log2MaxPcmCbSize {
                pcm = cabac.terminate() == 1
            }
            if pcm {
                try pcmSample(x0, y0, log2CbSize)
                pic.fill(&pic.intraMode, x0, y0, size, size, UInt8(1))
                if sps.pcmLoopFilterDisabled { pic.fill(&pic.bypass, x0, y0, size, size, true) }
                return
            }
            try intraModes(x0, y0, log2CbSize, nxn: partNxN)
        } else {
            guard let inter else { throw ParseFailure(offset: 0, rule: "pred_mode_flag", reason: .invalid("inter in an intra-only decode")) }
            let merged = try inter.predictionUnits(&self, x0, y0, log2CbSize: log2CbSize, partMode: partMode)
            if !(partMode == 0 && merged) { rqtRootCbf = cabac.decision(HEVCCtx.rqtRootCbf) == 1 }
        }
        if rqtRootCbf {
            let maxDepth = cuIntra ? sps.maxTransformHierarchyDepthIntra + (partNxN ? 1 : 0) : sps.maxTransformHierarchyDepthInter
            try transformTree(x0, y0, x0, y0, log2CbSize, 0, 0, maxDepth: maxDepth, partMode: partMode, parentCbf: (true, true))
        }
        // QpY may have changed with a cu_qp_delta in this CU.
        pic.fill(&pic.qpY, x0, y0, size, size, Int8(qpY))
    }

    mutating func parsePartMode(intra: Bool, log2CbSize: Int) throws(ParseFailure) -> Int {
        if intra { return cabac.decision(HEVCCtx.partMode) == 1 ? 0 : 3 }
        if cabac.decision(HEVCCtx.partMode) == 1 { return 0 }
        let minCb = log2CbSize == sps.log2MinCbSize
        if minCb {
            if cabac.decision(HEVCCtx.partMode + 1) == 1 { return 1 }    // 2NxN
            if log2CbSize == 3 { return 2 }                              // Nx2N (no NxN inter at 8x8)
            return cabac.decision(HEVCCtx.partMode + 2) == 1 ? 2 : 3
        }
        let horizontal = cabac.decision(HEVCCtx.partMode + 1) == 1      // 1: 2NxN family
        if !sps.ampEnabled { return horizontal ? 1 : 2 }
        if cabac.decision(HEVCCtx.partMode + 3) == 1 { return horizontal ? 1 : 2 }
        let second = cabac.bypass()
        return horizontal ? (second == 0 ? 4 : 5) : (second == 0 ? 6 : 7)
    }

    mutating func pcmSample(_ x0: Int, _ y0: Int, _ log2CbSize: Int) throws(ParseFailure) {
        cabac.pcmStart()
        let n = 1 << log2CbSize
        let sl = sps.bitDepthLuma - sps.pcmBitDepthLuma, sc = sps.bitDepthChroma - sps.pcmBitDepthChroma
        var samples: [UInt16] = []
        for _ in 0..<(n * n) { samples.append(UInt16(cabac.rawBits(sps.pcmBitDepthLuma) << sl)) }
        if sps.chromaArrayType != 0 {
            let cw = n / sps.subWidthC, chh = n / sps.subHeightC
            for _ in 0..<(2 * cw * chh) { samples.append(UInt16(cabac.rawBits(sps.pcmBitDepthChroma) << sc)) }
        }
        intraSteps.append(.pcm(x: x0, y: y0, log2Size: log2CbSize, samples: samples))
        cabac.startEngine()
    }

    // MARK: intra modes (7.3.8.5, 8.4.2, 8.4.3)

    mutating func intraModes(_ x0: Int, _ y0: Int, _ log2CbSize: Int, nxn: Bool) throws(ParseFailure) {
        let nParts = nxn ? 4 : 1
        let pb = nxn ? (1 << log2CbSize) / 2 : 1 << log2CbSize
        var prev = [Bool](repeating: false, count: 4)
        for i in 0..<nParts { prev[i] = cabac.decision(HEVCCtx.prevIntraLumaPred) == 1 }
        for i in 0..<nParts {
            let xP = x0 + (i & 1) * pb, yP = y0 + (i >> 1) * pb
            var mpmIdx = -1, rem = 0
            if prev[i] { mpmIdx = cabac.bypass() == 0 ? 0 : (cabac.bypass() == 0 ? 1 : 2) } else { rem = cabac.bypassBits(5) }
            // Candidates A (left) and B (above, not across the CTB's top), 8.4.2.
            func cand(_ xN: Int, _ yN: Int, above: Bool) -> Int {
                guard available(xP, yP, xN, yN) else { return 1 }
                let k = pic.i4(xN, yN)
                guard pic.predMode[k] == 1 else { return 1 }
                if above && yN < (yP >> sps.log2CtbSize) << sps.log2CtbSize { return 1 }
                return Int(pic.intraMode[k])
            }
            let a = cand(xP - 1, yP, above: false), b = cand(xP, yP - 1, above: true)
            var list: [Int]
            if a == b {
                list = a < 2 ? [0, 1, 26] : [a, 2 + ((a + 29) % 32), 2 + ((a - 2 + 1) % 32)]
            } else {
                let c = a != 0 && b != 0 ? 0 : (a != 1 && b != 1 ? 1 : 26)
                list = [a, b, c]
            }
            var mode: Int
            if mpmIdx >= 0 { mode = list[mpmIdx] } else {
                list.sort()
                mode = rem
                for m in list where mode >= m { mode += 1 }
            }
            intraLumaModes[i] = mode
            pic.fill(&pic.intraMode, xP, yP, pb, pb, UInt8(mode))
        }
        if !nxn { for i in 1..<4 { intraLumaModes[i] = intraLumaModes[0] } }
        if sps.chromaArrayType != 0 {
            let v = cabac.decision(HEVCCtx.intraChromaPredMode) == 0 ? 4 : cabac.bypassBits(2)
            let luma = intraLumaModes[0]
            if v == 4 { intraChromaMode = luma } else {
                let m = [0, 26, 10, 1][v]
                intraChromaMode = m == luma ? 34 : m
            }
        }
    }

    // MARK: transform tree (7.3.8.8 – 7.3.8.10)

    mutating func transformTree(_ x0: Int, _ y0: Int, _ xBase: Int, _ yBase: Int, _ log2Size: Int, _ depth: Int, _ blkIdx: Int, maxDepth: Int,
                       partMode: Int, parentCbf: (Bool, Bool)) throws(ParseFailure) {
        var split: Bool
        if log2Size <= sps.log2MaxTbSize && log2Size > sps.log2MinTbSize && depth < maxDepth && !(partNxN && depth == 0) {
            split = cabac.decision(HEVCCtx.splitTransformFlag + 5 - log2Size) == 1
        } else {
            let interSplit = sps.maxTransformHierarchyDepthInter == 0 && !cuIntra && partMode != 0 && depth == 0
            split = log2Size > sps.log2MaxTbSize || (partNxN && depth == 0) || interSplit
        }
        var cbfCb = false, cbfCr = false
        if log2Size > 2 && sps.chromaArrayType != 0 {
            if depth == 0 || parentCbf.0 { cbfCb = cabac.decision(HEVCCtx.cbfChroma + depth) == 1 }
            if depth == 0 || parentCbf.1 { cbfCr = cabac.decision(HEVCCtx.cbfChroma + depth) == 1 }
        } else if sps.chromaArrayType != 0 && log2Size == 2 && depth > 0 {
            cbfCb = parentCbf.0
            cbfCr = parentCbf.1
        }
        if split {
            let h = 1 << (log2Size - 1)
            try transformTree(x0, y0, x0, y0, log2Size - 1, depth + 1, 0, maxDepth: maxDepth, partMode: partMode, parentCbf: (cbfCb, cbfCr))
            try transformTree(x0 + h, y0, x0, y0, log2Size - 1, depth + 1, 1, maxDepth: maxDepth, partMode: partMode, parentCbf: (cbfCb, cbfCr))
            try transformTree(x0, y0 + h, x0, y0, log2Size - 1, depth + 1, 2, maxDepth: maxDepth, partMode: partMode, parentCbf: (cbfCb, cbfCr))
            try transformTree(x0 + h, y0 + h, x0, y0, log2Size - 1, depth + 1, 3, maxDepth: maxDepth, partMode: partMode, parentCbf: (cbfCb, cbfCr))
        } else {
            var cbfLuma = true
            if cuIntra || depth != 0 || cbfCb || cbfCr { cbfLuma = cabac.decision(HEVCCtx.cbfLuma + (depth == 0 ? 1 : 0)) == 1 }
            markEdges(x0, y0, 1 << log2Size, 1 << log2Size, tu: true)
            try transformUnit(x0, y0, xBase, yBase, log2Size, depth, blkIdx, cbfLuma: cbfLuma, cbfCb: cbfCb, cbfCr: cbfCr)
        }
    }

    mutating func transformUnit(_ x0: Int, _ y0: Int, _ xBase: Int, _ yBase: Int, _ log2Size: Int, _ depth: Int, _ blkIdx: Int,
                       cbfLuma: Bool, cbfCb: Bool, cbfCr: Bool) throws(ParseFailure) {
        let chroma4x4Deferred = sps.chromaArrayType == 1 && log2Size == 2
        let anyChroma = sps.chromaArrayType != 0 && (cbfCb || cbfCr)
        if cbfLuma || anyChroma {
            if pps.cuQpDeltaEnabled && !isCuQpDeltaCoded {
                var v = 0
                while v < 5 && cabac.decision(HEVCCtx.cuQpDeltaAbs + (v == 0 ? 0 : 1)) == 1 { v += 1 }
                if v == 5 {
                    var k = 0
                    while cabac.bypass() == 1 { k += 1; guard k < 32 else { throw ParseFailure(offset: 0, rule: "cu_qp_delta_abs", reason: .invalid("suffix")) } }
                    v += (1 << k) - 1 + cabac.bypassBits(k)
                }
                if v > 0 && cabac.bypass() == 1 { v = -v }
                guard (-(26 + qpBdOffsetY / 2)...(25 + qpBdOffsetY / 2)).contains(v) else { throw ParseFailure(offset: 0, rule: "cu_qp_delta", reason: .invalid("\(v)")) }
                isCuQpDeltaCoded = true
                cuQpDeltaVal = v
                qpY = deriveQpY()
            }
        }
        let n = 1 << log2Size
        // Luma: predict (intra), then add the residual.
        let lumaMode = cuIntra ? intraLumaModes[partNxN ? partIndex(x0, y0) : 0] : nil
        if cuIntra { predictIntra(cIdx: 0, x: x0, y: y0, log2Size: log2Size, mode: lumaMode!) }
        if cbfLuma {
            let ts = try residualCoding(log2Size: log2Size, cIdx: 0, intraMode: lumaMode, bypass: cuBypass)
            pic.fill(&pic.nonZeroCoeff, x0, y0, n, n, true)
            addResidual(transformSkip: ts, cIdx: 0, x: x0, y: y0, log2Size: log2Size, intraDST: cuIntra && log2Size == 2)
        }
        guard sps.chromaArrayType != 0 else { return }
        if !chroma4x4Deferred {
            let log2C = log2Size - 1, xc = x0 / 2, yc = y0 / 2
            for c in 1...2 {
                let cbf = c == 1 ? cbfCb : cbfCr
                if cuIntra { predictIntra(cIdx: c, x: xc, y: yc, log2Size: log2C, mode: intraChromaMode) }
                if cbf {
                    let ts = try residualCoding(log2Size: log2C, cIdx: c, intraMode: cuIntra ? intraChromaMode : nil, bypass: cuBypass)
                    addResidual(transformSkip: ts, cIdx: c, x: xc, y: yc, log2Size: log2C, intraDST: false)
                }
            }
        } else if blkIdx == 3 {
            let xc = xBase / 2, yc = yBase / 2
            for c in 1...2 {
                let cbf = c == 1 ? cbfCb : cbfCr
                if cuIntra { predictIntra(cIdx: c, x: xc, y: yc, log2Size: 2, mode: intraChromaMode) }
                if cbf {
                    let ts = try residualCoding(log2Size: 2, cIdx: c, intraMode: cuIntra ? intraChromaMode : nil, bypass: cuBypass)
                    addResidual(transformSkip: ts, cIdx: c, x: xc, y: yc, log2Size: 2, intraDST: false)
                }
            }
        }
    }

    /// Which NxN partition a luma location falls in (the CU is the 2x2 of partitions around it).
    func partIndex(_ x: Int, _ y: Int) -> Int {
        // The CU of an NxN intra split is min CB size; partitions are half of it.
        let half = (1 << sps.log2MinCbSize) >> 1
        let cuX = (x >> sps.log2MinCbSize) << sps.log2MinCbSize, cuY = (y >> sps.log2MinCbSize) << sps.log2MinCbSize
        return (x - cuX >= half ? 1 : 0) + (y - cuY >= half ? 2 : 0)
    }

    /// Transform and prediction block edges on the 8x8 deblocking grid's 4x4 units.
    mutating func markEdges(_ x: Int, _ y: Int, _ w: Int, _ h: Int, tu: Bool) {
        let ey = tu ? \HEVCPicture.tuEdgeH : \HEVCPicture.puEdgeH
        let ex = tu ? \HEVCPicture.tuEdgeV : \HEVCPicture.puEdgeV
        for yy in stride(from: y, to: min(y + h, sps.height), by: 4) { pic[keyPath: ex][pic.i4(x, yy)] = 1 }
        for xx in stride(from: x, to: min(x + w, sps.width), by: 4) { pic[keyPath: ey][pic.i4(xx, y)] = 1 }
    }

    // MARK: reconstruction

    /// 8.4.4.2, recorded: the prediction runs on the reconstruction stage.
    mutating func predictIntra(cIdx: Int, x: Int, y: Int, log2Size: Int, mode: Int) {
        intraSteps.append(.predict(cIdx: cIdx, x: x, y: y, log2Size: log2Size, mode: mode, ctbRs: ctbAddrRs, ctbTs: ctbAddrTs))
    }

    /// The residual in `coeff` as a job: added now (I slices), or recorded.
    mutating func addResidual(transformSkip: Bool, cIdx: Int, x: Int, y: Int, log2Size: Int, intraDST: Bool) {
        let n = 1 << log2Size
        let bitDepth = cIdx == 0 ? sps.bitDepthLuma : sps.bitDepthChroma
        var qp: Int
        if cIdx == 0 { qp = qpY + qpBdOffsetY } else {
            let off = cIdx == 1 ? pps.cbQpOffset + header.cbQpOffset : pps.crQpOffset + header.crQpOffset
            let qpi = max(-qpBdOffsetC, min(57, qpY + off))
            let qpc: Int
            if sps.chromaArrayType == 1 {
                if qpi < 30 { qpc = qpi } else if qpi > 43 { qpc = qpi - 6 } else { qpc = [29, 30, 31, 32, 33, 33, 34, 34, 35, 35, 36, 36, 37, 37][qpi - 30] }
            } else { qpc = min(qpi, 51) }
            qp = qpc + qpBdOffsetC
        }
        var factors: [Int32]?
        if !cuBypass && sps.scalingListEnabled && !(transformSkip && n > 4) {
            let list = pps.scalingList ?? sps.scalingList ?? .default
            factors = HEVCTransform.scalingFactors(list, log2Size: log2Size, matrixId: (cuIntra ? 0 : 3) + cIdx)
        }
        let job = HEVCResidualJob(cIdx: cIdx, x: x, y: y, log2Size: log2Size, start: Int32(coeffStart), count: Int32(coeffPool.count - coeffStart), qp: qp, bitDepth: bitDepth,
                                  transformSkip: transformSkip, bypass: cuBypass, dst: intraDST && cIdx == 0, factors: factors)
        if cuIntra { intraSteps.append(.residual(job)) } else { interResiduals.append(job) }
    }

    /// What this segment recorded for the reconstruction stage.
    func recorded() -> HEVCSliceWork {
        HEVCSliceWork(pps: pps, sliceAddrRs: sliceAddrRs, mc: mcShared, mcJobs: mcJobs, interResiduals: interResiduals, intraSteps: intraSteps,
                      coeffs: coeffPool)
    }
}

/// One transform block's residual as plain data.
struct HEVCResidualJob: Sendable {
    var cIdx: Int, x: Int, y: Int, log2Size: Int
    /// The block's run in its slice's coefficient pool.
    var start: Int32, count: Int32
    var qp: Int, bitDepth: Int
    var transformSkip: Bool, bypass: Bool, dst: Bool
    var factors: [Int32]?

    /// TransCoeffLevel as a dense n×n block (raster).
    func levels(_ pool: [Int32]) -> [Int32] {
        let n = 1 << log2Size
        var d = [Int32](repeating: 0, count: n * n)
        let p = pool.span
        do {
            var ds = d.mutableSpan
            var k = Int(start)
            let end = k + Int(count)
            while k < end {
                let e = p[k]
                ds[Int(e & 0xFFFF)] = e >> 16
                k += 1
            }
        }
        return d
    }

    /// 8.6.2 – 8.6.4: dequantisation and the inverse transform, with a reusable work buffer.
    static func residual(_ j: HEVCResidualJob, _ pool: [Int32], _ work: inout [Int32]) -> [Int32] {
        var d = j.levels(pool)
        if j.bypass { return d }
        let n = 1 << j.log2Size
        HEVCTransform.dequantize(&d, log2Size: j.log2Size, qp: j.qp, bitDepth: j.bitDepth, factors: j.factors)
        if work.count < n * n { work = [Int32](repeating: 0, count: 1024) }
        var r = [Int32](repeating: 0, count: n * n)
        HEVCTransform.inverse(d, into: &r, work: &work, log2Size: j.log2Size, bitDepth: j.bitDepth, dst4x4: j.dst, transformSkip: j.transformSkip)
        return r
    }
}
