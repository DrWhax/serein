// Constants (3, 6.10) and the geometry tables of the AV1 decoding process, as Int arrays.

enum AV1C {
    // Block sizes (6.10.4).
    static let block4x4 = 0, block8x8 = 3, block64x64 = 12, block128x128 = 15
    // Prediction modes.
    static let dcPred = 0, vPred = 1, hPred = 2, d45Pred = 3, d135Pred = 4, d113Pred = 5, d157Pred = 6, d203Pred = 7, d67Pred = 8
    static let smoothPred = 9, smoothVPred = 10, smoothHPred = 11, paethPred = 12, uvCflPred = 13
    // Partitions.
    static let partitionNone = 0, partitionHorz = 1, partitionVert = 2, partitionSplit = 3
    static let partitionHorzA = 4, partitionHorzB = 5, partitionVertA = 6, partitionVertB = 7, partitionHorz4 = 8, partitionVert4 = 9
    // Transform sizes.
    static let tx4x4 = 0, tx8x8 = 1, tx16x16 = 2, tx32x32 = 3, tx64x64 = 4
    static let tx16x32 = 9, tx32x16 = 10, tx32x64 = 11, tx64x32 = 12, tx16x64 = 17, tx64x16 = 18
    // Transform types.
    static let dctDct = 0, adstDct = 1, dctAdst = 2, adstAdst = 3, flipadstDct = 4, dctFlipadst = 5, flipadstFlipadst = 6
    static let adstFlipadst = 7, flipadstAdst = 8, idtx = 9, vDct = 10, hDct = 11, vAdst = 12, hAdst = 13, vFlipadst = 14, hFlipadst = 15
    // Transform sets.
    static let txSetDctOnly = 0, txSetIntra1 = 1, txSetIntra2 = 2, txSetInter1 = 1, txSetInter2 = 2, txSetInter3 = 3
    static let txModeSelect = 2
    static let restoreNone = 0, restoreWiener = 1, restoreSgrproj = 2, restoreSwitchable = 3

    static let num4x4W = AV1Tables.num4x4BlocksWide.map(Int.init)
    static let num4x4H = AV1Tables.num4x4BlocksHigh.map(Int.init)
    static let blockWidth = num4x4W.map { $0 * 4 }
    static let blockHeight = num4x4H.map { $0 * 4 }
    static let miWidthLog2 = AV1Tables.miWidthLog2.map(Int.init)
    static let miHeightLog2 = AV1Tables.miHeightLog2.map(Int.init)
    static let maxTxSizeRect = AV1Tables.maxTxSizeRect.map(Int.init)
    static let maxTxDepth = AV1Tables.maxTxDepth.map(Int.init)
    static let splitTxSize = AV1Tables.splitTxSize.map(Int.init)
    static let txWidth = AV1Tables.txWidth.map(Int.init)
    static let txHeight = AV1Tables.txHeight.map(Int.init)
    static let txWidthLog2 = AV1Tables.txWidthLog2.map(Int.init)
    static let txHeightLog2 = AV1Tables.txHeightLog2.map(Int.init)
    static let txSizeSqr = AV1Tables.txSizeSqr.map(Int.init)
    static let txSizeSqrUp = AV1Tables.txSizeSqrUp.map(Int.init)
    static let adjustedTxSize = AV1Tables.adjustedTxSize.map(Int.init)
    static let modeToTxfm = AV1Tables.modeToTxfm.map(Int.init)
    static let modeToAngle = AV1Tables.modeToAngle.map(Int.init)
    static let drIntraDerivative = AV1Tables.drIntraDerivative.map(Int.init)
    static let intraModeContext = AV1Tables.intraModeContext.map(Int.init)
    static let intraFilterTaps = AV1Tables.intraFilterTaps.map(Int.init)
    static let intraEdgeKernel = AV1Tables.intraEdgeKernel.map(Int.init)
    static let transformRowShift = AV1Tables.transformRowShift.map(Int.init)
    static let coeffBaseCtxOffset = AV1Tables.coeffBaseCtxOffset.map(Int.init)
    static let coeffBasePosCtxOffset = AV1Tables.coeffBasePosCtxOffset.map(Int.init)
    static let sigRefDiffOffset = AV1Tables.sigRefDiffOffset.map(Int.init)
    static let magRefOffset = AV1Tables.magRefOffsetWithTxClass.map(Int.init)
    static let paletteColorContext = AV1Tables.paletteColorContext.map(Int.init)
    static let paletteColorHashMultipliers = AV1Tables.paletteColorHashMultipliers.map(Int.init)
    static let filterIntraModeToIntraDir = AV1Tables.filterIntraModeToIntraDir.map(Int.init)
    static let txTypeInSetIntra = AV1Tables.txTypeInSetIntra.map(Int.init)
    static let txTypeInSetInter = AV1Tables.txTypeInSetInter.map(Int.init)
    static let txTypeIntraInvSet1 = AV1Tables.txTypeIntraInvSet1.map(Int.init)
    static let txTypeIntraInvSet2 = AV1Tables.txTypeIntraInvSet2.map(Int.init)
    static let txTypeInterInvSet1 = AV1Tables.txTypeInterInvSet1.map(Int.init)
    static let txTypeInterInvSet2 = AV1Tables.txTypeInterInvSet2.map(Int.init)
    static let txTypeInterInvSet3 = AV1Tables.txTypeInterInvSet3.map(Int.init)
    static let dcQLookup = AV1Tables.dcQlookup.map(Int.init)
    static let acQLookup = AV1Tables.acQlookup.map(Int.init)
    static let qmOffset = AV1Tables.qmOffset.map(Int.init)
    static let quantizerMatrix = AV1Tables.quantizerMatrix.map(Int.init)
    static let cos128Lookup = AV1Tables.cos128Lookup.map(Int.init)
    static let subpelFilters = AV1Tables.subpelFilters.map(Int.init)
    static let upscaleFilter = AV1Tables.upscaleFilter.map(Int.init)
    static let sgrParams = AV1Tables.sgrParams.map(Int.init)
    static let cdefUvDir = AV1Tables.cdefUvDir.map(Int.init)
    static let cdefDirections = AV1Tables.cdefDirections.map(Int.init)
    static let divTable = AV1Tables.divTable.map(Int.init)
    static let gaussianSequence = AV1Tables.gaussianSequence.map(Int.init)
    static let sizeGroup = AV1Tables.sizeGroup.map(Int.init)

    /// Partition_Subsize[ partition ][ bSize ].
    static let partitionSubsize = AV1Tables.partitionSubsize.map(Int.init)
    /// Subsampled_Size[ bSize ][ subX ][ subY ].
    static let subsampledSize = AV1Tables.subsampledSize.map(Int.init)

    static func planeResidualSize(_ bSize: Int, _ subX: Int, _ subY: Int) -> Int { subsampledSize[bSize * 4 + subX * 2 + subY] }

    /// Smooth weights for a dimension of 1 << log2.
    static let smWeights: [[Int]] = [[], [], AV1Tables.smWeightsTx4x4.map(Int.init), AV1Tables.smWeightsTx8x8.map(Int.init),
                                     AV1Tables.smWeightsTx16x16.map(Int.init), AV1Tables.smWeightsTx32x32.map(Int.init),
                                     AV1Tables.smWeightsTx64x64.map(Int.init)]

    static let txSizesAll = 19

    /// find_tx_size( w, h ).
    static func findTxSize(_ w: Int, _ h: Int) -> Int {
        for t in 0..<txSizesAll where txWidth[t] == w && txHeight[t] == h { return t }
        return 0
    }

    /// The scan order of a transform (get_scan).
    static func scan(_ txSz: Int, _ txType: Int) -> [Int] {
        if txSz == tx16x64 { return scans.default16x32 }
        if txSz == tx64x16 { return scans.default32x16 }
        if txSizeSqrUp[txSz] == tx64x64 { return scans.default32x32 }
        if txType == idtx { return scans.defaults[txSz] }
        let preferRow = txType == vDct || txType == vAdst || txType == vFlipadst
        let preferCol = txType == hDct || txType == hAdst || txType == hFlipadst
        if preferRow { return scans.mrow[txSz] }
        if preferCol { return scans.mcol[txSz] }
        return scans.defaults[txSz]
    }

    struct Scans: Sendable {
        let defaults: [[Int]], mrow: [[Int]], mcol: [[Int]]
        let default16x32: [Int], default32x16: [Int], default32x32: [Int]
    }

    static let scans: Scans = {
        func i(_ t: [UInt8]) -> [Int] { t.map(Int.init) }
        func i(_ t: [UInt16]) -> [Int] { t.map(Int.init) }
        let d32 = i(AV1Tables.defaultScan32x32)
        // Indexed by TX size: 4x4 8x8 16x16 32x32 64x64 4x8 8x4 8x16 16x8 16x32 32x16 32x64 64x32 4x16 16x4 8x32 32x8 16x64 64x16.
        let defaults: [[Int]] = [i(AV1Tables.defaultScan4x4), i(AV1Tables.defaultScan8x8), i(AV1Tables.defaultScan16x16), d32, d32,
                                 i(AV1Tables.defaultScan4x8), i(AV1Tables.defaultScan8x4), i(AV1Tables.defaultScan8x16), i(AV1Tables.defaultScan16x8),
                                 i(AV1Tables.defaultScan16x32), i(AV1Tables.defaultScan32x16), d32, d32, i(AV1Tables.defaultScan4x16),
                                 i(AV1Tables.defaultScan16x4), i(AV1Tables.defaultScan8x32), i(AV1Tables.defaultScan32x8), d32, d32]
        // get_mrow_scan / get_mcol_scan fall back to the 16x4 table for sizes they do not list.
        let mrow: [[Int]] = [i(AV1Tables.mrowScan4x4), i(AV1Tables.mrowScan8x8), i(AV1Tables.mrowScan16x16), i(AV1Tables.mrowScan16x4), i(AV1Tables.mrowScan16x4),
                             i(AV1Tables.mrowScan4x8), i(AV1Tables.mrowScan8x4), i(AV1Tables.mrowScan8x16), i(AV1Tables.mrowScan16x8),
                             i(AV1Tables.mrowScan16x4), i(AV1Tables.mrowScan16x4), i(AV1Tables.mrowScan16x4), i(AV1Tables.mrowScan16x4),
                             i(AV1Tables.mrowScan4x16), i(AV1Tables.mrowScan16x4), i(AV1Tables.mrowScan16x4), i(AV1Tables.mrowScan16x4),
                             i(AV1Tables.mrowScan16x4), i(AV1Tables.mrowScan16x4)]
        let mcol: [[Int]] = [i(AV1Tables.mcolScan4x4), i(AV1Tables.mcolScan8x8), i(AV1Tables.mcolScan16x16), i(AV1Tables.mcolScan16x4), i(AV1Tables.mcolScan16x4),
                             i(AV1Tables.mcolScan4x8), i(AV1Tables.mcolScan8x4), i(AV1Tables.mcolScan8x16), i(AV1Tables.mcolScan16x8),
                             i(AV1Tables.mcolScan16x4), i(AV1Tables.mcolScan16x4), i(AV1Tables.mcolScan16x4), i(AV1Tables.mcolScan16x4),
                             i(AV1Tables.mcolScan4x16), i(AV1Tables.mcolScan16x4), i(AV1Tables.mcolScan16x4), i(AV1Tables.mcolScan16x4),
                             i(AV1Tables.mcolScan16x4), i(AV1Tables.mcolScan16x4)]
        return Scans(defaults: defaults, mrow: mrow, mcol: mcol, default16x32: i(AV1Tables.defaultScan16x32),
                     default32x16: i(AV1Tables.defaultScan32x16), default32x32: d32)
    }()
}

@inline(__always) func round2(_ x: Int, _ n: Int) -> Int { n == 0 ? x : (x + (1 << (n - 1))) >> n }
@inline(__always) func round2Signed(_ x: Int, _ n: Int) -> Int { x >= 0 ? round2(x, n) : -round2(-x, n) }
@inline(__always) func clip3(_ lo: Int, _ hi: Int, _ x: Int) -> Int { x < lo ? lo : (x > hi ? hi : x) }

/// What a decode exercised (tests check that the fixtures cover every tool).
enum AV1Tool: Int, CaseIterable, Sendable {
    case paletteY, paletteUV, intrabc, cfl, filterIntra, angleDelta, edgeUpsample, edgeFilter, smooth, paeth, directional
    case lossless, qmatrix, segmentation, deltaQ, deltaLF, varTxSplit, tx64, golomb, idtx, adst, flipadst, wht
    case wiener, sgrproj, cdef, superres, filmGrain, sb128, multiTile, deblock
}
