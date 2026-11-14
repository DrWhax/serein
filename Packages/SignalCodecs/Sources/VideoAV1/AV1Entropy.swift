// The symbol decoder (8.2) and the CDF context it adapts (init_non_coeff_cdfs /
// init_coeff_cdfs, 6.8.2). Every CDF lives in one flat array per tile; AV1CDFLayout gives
// each syntax element's offset. A CDF of N symbols is N + 1 entries: N increasing values
// ending in 32768, then the adaptation counter.

import CodecCore

/// Offsets of every CDF array in a tile's context, and the four default contexts (one per
/// coefficient-CDF q index class).
struct AV1CDFLayout: Sendable {
    // Non-coefficient CDFs.
    let intraFrameYMode: Int        // [5][5] × 14
    let uvModeCflNotAllowed: Int    // [13] × 14
    let uvModeCflAllowed: Int       // [13] × 15
    let angleDelta: Int             // [8] × 8
    let intrabc: Int                // 3
    let partition: [Int]            // bsl 1…5: [4] × 5 / 11 / 11 / 11 / 9
    let segmentId: Int              // [3] × 9
    let txDepth: [Int]              // maxTxDepth 1…4 → 8x8 [3]×3, 16 / 32 / 64 [3]×4
    let txfmSplit: Int              // [21] × 3
    let filterIntraMode: Int        // 6
    let filterIntra: Int            // [22] × 3
    let skip: Int                   // [3] × 3
    let mvJoint: Int                // [ctx 2] × 5
    let mvClass: Int                // [ctx 2][comp 2] × 12
    let mvClass0Bit: Int            // [2][2] × 3
    let mvClass0Fr: Int             // [2][2][2] × 5
    let mvClass0Hp: Int             // [2][2] × 3
    let mvFr: Int                   // [2][2] × 5
    let mvHp: Int                   // [2][2] × 3
    let mvSign: Int                 // [2][2] × 3
    let mvBit: Int                  // [2][2][10] × 3
    let paletteYMode: Int           // [7][3] × 3
    let paletteUVMode: Int          // [2] × 3
    let paletteYSize: Int           // [7] × 8
    let paletteUVSize: Int          // [7] × 8
    let paletteYColor: [Int]        // size 2…8: [5] × (n + 1)
    let paletteUVColor: [Int]
    let deltaQ: Int                 // 5
    let deltaLF: Int                // 5
    let deltaLFMulti: Int           // [4] × 5
    let intraTxSet1: Int            // [2][13] × 8
    let intraTxSet2: Int            // [3][13] × 6
    let interTxSet1: Int            // [2] × 17
    let interTxSet2: Int            // 13
    let interTxSet3: Int            // [4] × 3
    let cflSign: Int                // 9
    let cflAlpha: Int               // [6] × 17
    let useWiener: Int, useSgrproj: Int, restorationType: Int
    // Inter frames.
    let yMode: Int                  // [4] × 14
    let segmentIdPredicted: Int     // [3] × 3
    let isInter: Int                // [4] × 3
    let skipMode: Int               // [3] × 3
    let compMode: Int               // [5] × 3
    let compRefType: Int            // [5] × 3
    let uniCompRef: Int             // [3][3] × 3
    let compRef: Int                // [3][3] × 3
    let compBwdRef: Int             // [3][2] × 3
    let singleRef: Int              // [3][6] × 3
    let compoundMode: Int           // [8] × 9
    let newMv: Int                  // [6] × 3
    let zeroMv: Int                 // [2] × 3
    let refMv: Int                  // [6] × 3
    let drlMode: Int                // [3] × 3
    let interpFilter: Int           // [16] × 4
    let motionMode: Int             // [22] × 4
    let useObmc: Int                // [22] × 3
    let interIntra: Int             // [3] × 3
    let interIntraMode: Int         // [3] × 5
    let wedgeInterIntra: Int        // [22] × 3
    let wedgeIndex: Int             // [22] × 17
    let compGroupIdx: Int           // [6] × 3
    let compoundIdx: Int            // [6] × 3
    let compoundType: Int           // [22] × 3
    // Coefficient CDFs.
    let txbSkip: Int                // [5][13] × 3
    let eobPt: [Int]                // eobMultisize 0…4: [2][2] × (5 + m + 1); 5: [2] × 11; 6: [2] × 12
    let eobExtra: Int               // [5][2][9] × 3
    let dcSign: Int                 // [2][3] × 3
    let coeffBaseEob: Int           // [5][2][4] × 4
    let coeffBase: Int              // [5][2][42] × 5
    let coeffBr: Int                // [5][2][21] × 5
    /// The initial context for base_q_idx classes ≤ 20, ≤ 60, ≤ 120, > 120.
    let defaults: [[UInt16]]
    /// The index of every CDF's adaptation counter in a context.
    let counterPositions: [Int]

    static let shared = AV1CDFLayout()

    init() {
        var base: [UInt16] = []
        var counters: [Int] = []
        /// A table of CDFs (rows of N + 1: the values, then the adaptation counter).
        func add(_ t: [UInt16], dims: [Int] = [], copies: Int = 1) -> Int {
            let o = base.count
            let row = dims.last ?? t.count
            for _ in 0..<copies {
                var k = base.count + row - 1
                while k < base.count + t.count { counters.append(k); k += row }
                base += t
            }
            return o
        }
        intraFrameYMode = add(AV1Tables.defaultIntraFrameYModeCdf, dims: AV1Tables.defaultIntraFrameYModeCdfDims)
        uvModeCflNotAllowed = add(AV1Tables.defaultUvModeCflNotAllowedCdf, dims: AV1Tables.defaultUvModeCflNotAllowedCdfDims)
        uvModeCflAllowed = add(AV1Tables.defaultUvModeCflAllowedCdf, dims: AV1Tables.defaultUvModeCflAllowedCdfDims)
        angleDelta = add(AV1Tables.defaultAngleDeltaCdf, dims: AV1Tables.defaultAngleDeltaCdfDims)
        intrabc = add(AV1Tables.defaultIntrabcCdf)
        partition = [add(AV1Tables.defaultPartitionW8Cdf, dims: AV1Tables.defaultPartitionW8CdfDims), add(AV1Tables.defaultPartitionW16Cdf, dims: AV1Tables.defaultPartitionW16CdfDims), add(AV1Tables.defaultPartitionW32Cdf, dims: AV1Tables.defaultPartitionW32CdfDims),
                     add(AV1Tables.defaultPartitionW64Cdf, dims: AV1Tables.defaultPartitionW64CdfDims), add(AV1Tables.defaultPartitionW128Cdf, dims: AV1Tables.defaultPartitionW128CdfDims)]
        segmentId = add(AV1Tables.defaultSegmentIdCdf, dims: AV1Tables.defaultSegmentIdCdfDims)
        txDepth = [add(AV1Tables.defaultTx8x8Cdf, dims: AV1Tables.defaultTx8x8CdfDims), add(AV1Tables.defaultTx16x16Cdf, dims: AV1Tables.defaultTx16x16CdfDims), add(AV1Tables.defaultTx32x32Cdf, dims: AV1Tables.defaultTx32x32CdfDims), add(AV1Tables.defaultTx64x64Cdf, dims: AV1Tables.defaultTx64x64CdfDims)]
        txfmSplit = add(AV1Tables.defaultTxfmSplitCdf, dims: AV1Tables.defaultTxfmSplitCdfDims)
        filterIntraMode = add(AV1Tables.defaultFilterIntraModeCdf)
        filterIntra = add(AV1Tables.defaultFilterIntraCdf, dims: AV1Tables.defaultFilterIntraCdfDims)
        skip = add(AV1Tables.defaultSkipCdf, dims: AV1Tables.defaultSkipCdfDims)
        mvJoint = add(AV1Tables.defaultMvJointCdf, copies: 2)
        mvClass = add(AV1Tables.defaultMvClassCdf, dims: AV1Tables.defaultMvClassCdfDims, copies: 2)
        mvClass0Bit = add(AV1Tables.defaultMvClass0BitCdf, copies: 4)
        mvClass0Fr = add(AV1Tables.defaultMvClass0FrCdf, dims: AV1Tables.defaultMvClass0FrCdfDims, copies: 2)
        mvClass0Hp = add(AV1Tables.defaultMvClass0HpCdf, copies: 4)
        mvFr = add(AV1Tables.defaultMvFrCdf, dims: AV1Tables.defaultMvFrCdfDims, copies: 2)
        mvHp = add(AV1Tables.defaultMvHpCdf, copies: 4)
        mvSign = add(AV1Tables.defaultMvSignCdf, copies: 4)
        mvBit = add(AV1Tables.defaultMvBitCdf, dims: AV1Tables.defaultMvBitCdfDims, copies: 4)
        paletteYMode = add(AV1Tables.defaultPaletteYModeCdf, dims: AV1Tables.defaultPaletteYModeCdfDims)
        paletteUVMode = add(AV1Tables.defaultPaletteUvModeCdf, dims: AV1Tables.defaultPaletteUvModeCdfDims)
        paletteYSize = add(AV1Tables.defaultPaletteYSizeCdf, dims: AV1Tables.defaultPaletteYSizeCdfDims)
        paletteUVSize = add(AV1Tables.defaultPaletteUvSizeCdf, dims: AV1Tables.defaultPaletteUvSizeCdfDims)
        paletteYColor = [add(AV1Tables.defaultPaletteSize2YColorCdf, dims: AV1Tables.defaultPaletteSize2YColorCdfDims), add(AV1Tables.defaultPaletteSize3YColorCdf, dims: AV1Tables.defaultPaletteSize3YColorCdfDims), add(AV1Tables.defaultPaletteSize4YColorCdf, dims: AV1Tables.defaultPaletteSize4YColorCdfDims),
                         add(AV1Tables.defaultPaletteSize5YColorCdf, dims: AV1Tables.defaultPaletteSize5YColorCdfDims), add(AV1Tables.defaultPaletteSize6YColorCdf, dims: AV1Tables.defaultPaletteSize6YColorCdfDims), add(AV1Tables.defaultPaletteSize7YColorCdf, dims: AV1Tables.defaultPaletteSize7YColorCdfDims),
                         add(AV1Tables.defaultPaletteSize8YColorCdf, dims: AV1Tables.defaultPaletteSize8YColorCdfDims)]
        paletteUVColor = [add(AV1Tables.defaultPaletteSize2UvColorCdf, dims: AV1Tables.defaultPaletteSize2UvColorCdfDims), add(AV1Tables.defaultPaletteSize3UvColorCdf, dims: AV1Tables.defaultPaletteSize3UvColorCdfDims), add(AV1Tables.defaultPaletteSize4UvColorCdf, dims: AV1Tables.defaultPaletteSize4UvColorCdfDims),
                          add(AV1Tables.defaultPaletteSize5UvColorCdf, dims: AV1Tables.defaultPaletteSize5UvColorCdfDims), add(AV1Tables.defaultPaletteSize6UvColorCdf, dims: AV1Tables.defaultPaletteSize6UvColorCdfDims), add(AV1Tables.defaultPaletteSize7UvColorCdf, dims: AV1Tables.defaultPaletteSize7UvColorCdfDims),
                          add(AV1Tables.defaultPaletteSize8UvColorCdf, dims: AV1Tables.defaultPaletteSize8UvColorCdfDims)]
        deltaQ = add(AV1Tables.defaultDeltaQCdf)
        deltaLF = add(AV1Tables.defaultDeltaLfCdf)
        deltaLFMulti = add(AV1Tables.defaultDeltaLfCdf, copies: 4)
        intraTxSet1 = add(AV1Tables.defaultIntraTxTypeSet1Cdf, dims: AV1Tables.defaultIntraTxTypeSet1CdfDims)
        intraTxSet2 = add(AV1Tables.defaultIntraTxTypeSet2Cdf, dims: AV1Tables.defaultIntraTxTypeSet2CdfDims)
        interTxSet1 = add(AV1Tables.defaultInterTxTypeSet1Cdf, dims: AV1Tables.defaultInterTxTypeSet1CdfDims)
        interTxSet2 = add(AV1Tables.defaultInterTxTypeSet2Cdf)
        interTxSet3 = add(AV1Tables.defaultInterTxTypeSet3Cdf, dims: AV1Tables.defaultInterTxTypeSet3CdfDims)
        cflSign = add(AV1Tables.defaultCflSignCdf)
        cflAlpha = add(AV1Tables.defaultCflAlphaCdf, dims: AV1Tables.defaultCflAlphaCdfDims)
        useWiener = add(AV1Tables.defaultUseWienerCdf)
        useSgrproj = add(AV1Tables.defaultUseSgrprojCdf)
        restorationType = add(AV1Tables.defaultRestorationTypeCdf)
        yMode = add(AV1Tables.defaultYModeCdf, dims: AV1Tables.defaultYModeCdfDims)
        segmentIdPredicted = add(AV1Tables.defaultSegmentIdPredictedCdf, dims: AV1Tables.defaultSegmentIdPredictedCdfDims)
        isInter = add(AV1Tables.defaultIsInterCdf, dims: AV1Tables.defaultIsInterCdfDims)
        skipMode = add(AV1Tables.defaultSkipModeCdf, dims: AV1Tables.defaultSkipModeCdfDims)
        compMode = add(AV1Tables.defaultCompModeCdf, dims: AV1Tables.defaultCompModeCdfDims)
        compRefType = add(AV1Tables.defaultCompRefTypeCdf, dims: AV1Tables.defaultCompRefTypeCdfDims)
        uniCompRef = add(AV1Tables.defaultUniCompRefCdf, dims: AV1Tables.defaultUniCompRefCdfDims)
        compRef = add(AV1Tables.defaultCompRefCdf, dims: AV1Tables.defaultCompRefCdfDims)
        compBwdRef = add(AV1Tables.defaultCompBwdRefCdf, dims: AV1Tables.defaultCompBwdRefCdfDims)
        singleRef = add(AV1Tables.defaultSingleRefCdf, dims: AV1Tables.defaultSingleRefCdfDims)
        compoundMode = add(AV1Tables.defaultCompoundModeCdf, dims: AV1Tables.defaultCompoundModeCdfDims)
        newMv = add(AV1Tables.defaultNewMvCdf, dims: AV1Tables.defaultNewMvCdfDims)
        zeroMv = add(AV1Tables.defaultZeroMvCdf, dims: AV1Tables.defaultZeroMvCdfDims)
        refMv = add(AV1Tables.defaultRefMvCdf, dims: AV1Tables.defaultRefMvCdfDims)
        drlMode = add(AV1Tables.defaultDrlModeCdf, dims: AV1Tables.defaultDrlModeCdfDims)
        interpFilter = add(AV1Tables.defaultInterpFilterCdf, dims: AV1Tables.defaultInterpFilterCdfDims)
        motionMode = add(AV1Tables.defaultMotionModeCdf, dims: AV1Tables.defaultMotionModeCdfDims)
        useObmc = add(AV1Tables.defaultUseObmcCdf, dims: AV1Tables.defaultUseObmcCdfDims)
        interIntra = add(AV1Tables.defaultInterIntraCdf, dims: AV1Tables.defaultInterIntraCdfDims)
        interIntraMode = add(AV1Tables.defaultInterIntraModeCdf, dims: AV1Tables.defaultInterIntraModeCdfDims)
        wedgeInterIntra = add(AV1Tables.defaultWedgeInterIntraCdf, dims: AV1Tables.defaultWedgeInterIntraCdfDims)
        wedgeIndex = add(AV1Tables.defaultWedgeIndexCdf, dims: AV1Tables.defaultWedgeIndexCdfDims)
        compGroupIdx = add(AV1Tables.defaultCompGroupIdxCdf, dims: AV1Tables.defaultCompGroupIdxCdfDims)
        compoundIdx = add(AV1Tables.defaultCompoundIdxCdf, dims: AV1Tables.defaultCompoundIdxCdfDims)
        compoundType = add(AV1Tables.defaultCompoundTypeCdf, dims: AV1Tables.defaultCompoundTypeCdfDims)
        // Coefficient CDFs: each default table has the q class as its first dimension.
        let coeffTables: [[UInt16]] = [AV1Tables.defaultTxbSkipCdf, AV1Tables.defaultEobPt16Cdf, AV1Tables.defaultEobPt32Cdf, AV1Tables.defaultEobPt64Cdf,
                                       AV1Tables.defaultEobPt128Cdf, AV1Tables.defaultEobPt256Cdf, AV1Tables.defaultEobPt512Cdf, AV1Tables.defaultEobPt1024Cdf,
                                       AV1Tables.defaultEobExtraCdf, AV1Tables.defaultDcSignCdf, AV1Tables.defaultCoeffBaseEobCdf, AV1Tables.defaultCoeffBaseCdf,
                                       AV1Tables.defaultCoeffBrCdf]
        let coeffRows = [AV1Tables.defaultTxbSkipCdfDims, AV1Tables.defaultEobPt16CdfDims, AV1Tables.defaultEobPt32CdfDims, AV1Tables.defaultEobPt64CdfDims,
                         AV1Tables.defaultEobPt128CdfDims, AV1Tables.defaultEobPt256CdfDims, AV1Tables.defaultEobPt512CdfDims,
                         AV1Tables.defaultEobPt1024CdfDims, AV1Tables.defaultEobExtraCdfDims, AV1Tables.defaultDcSignCdfDims,
                         AV1Tables.defaultCoeffBaseEobCdfDims, AV1Tables.defaultCoeffBaseCdfDims, AV1Tables.defaultCoeffBrCdfDims].map { $0.last ?? 0 }
        var offsets: [Int] = []
        var o = base.count
        for (t, row) in zip(coeffTables, coeffRows) {
            offsets.append(o)
            var k = o + row - 1
            while k < o + t.count / 4 { counters.append(k); k += row }
            o += t.count / 4
        }
        txbSkip = offsets[0]
        eobPt = Array(offsets[1...7])
        eobExtra = offsets[8]
        dcSign = offsets[9]
        coeffBaseEob = offsets[10]
        coeffBase = offsets[11]
        coeffBr = offsets[12]
        var defaults: [[UInt16]] = []
        for q in 0..<4 {
            var ctx = base
            for t in coeffTables {
                let n = t.count / 4
                ctx += t[(q * n)..<((q + 1) * n)]
            }
            defaults.append(ctx)
        }
        self.defaults = defaults
        counterPositions = counters
    }

    /// load_cdfs (7.20): a saved context with every adaptation counter back at 0.
    func loaded(_ saved: [UInt16]) -> [UInt16] {
        var c = saved
        for k in counterPositions where k < c.count { c[k] = 0 }
        return c
    }
}

/// The symbol decoder over one tile's bytes, with the tile's CDF context.
struct AV1SymbolDecoder {
    let data: [UInt8]
    var bytePos: Int
    let byteEnd: Int
    /// Bits not yet consumed, MSB-aligned in `bitBuf`.
    var bitBuf: UInt64 = 0
    var bitCount = 0
    var symbolValue = 0
    var symbolRange = 0
    var symbolMaxBits = 0
    var cdf: [UInt16]
    let disableUpdate: Bool

    init(_ data: [UInt8], start: Int, size: Int, cdf: [UInt16], disableUpdate: Bool) throws(AV1DecodeError) {
        guard size >= 1, start + size <= data.count else { throw .malformed("tile size \(size)") }
        self.data = data
        self.bytePos = start
        self.byteEnd = start + size
        self.cdf = cdf
        self.disableUpdate = disableUpdate
        let numBits = min(size * 8, 15)
        let buf = read(numBits)
        let padded = buf << (15 - numBits)
        symbolValue = ((1 << 15) - 1) ^ padded
        symbolRange = 1 << 15
        symbolMaxBits = 8 * size - 15
    }

    /// The next `n` (≤ 24) bits of the tile data (the caller never asks past its end).
    @inline(__always)
    mutating func read(_ n: Int) -> Int {
        if n == 0 { return 0 }
        while bitCount < n {
            let b: UInt64 = bytePos < byteEnd ? UInt64(data[bytePos]) : 0
            bytePos += 1
            bitBuf |= b << UInt64(56 - bitCount)
            bitCount += 8
        }
        let v = Int(bitBuf >> UInt64(64 - n))
        bitBuf <<= UInt64(n)
        bitCount -= n
        return v
    }

    /// read_symbol( cdf ) for the CDF of `n` symbols at `at`.
    @inline(__always)
    mutating func symbol(_ at: Int, _ n: Int) -> Int {
        var cur = symbolRange
        var sym = -1
        var prev = 0
        let r8 = symbolRange >> 8
        let value = symbolValue
        do {
            let c = cdf.span
            repeat {
                sym += 1
                prev = cur
                let f = (1 << 15) - Int(c[at + sym])
                cur = ((r8 * (f >> 6)) >> 1) + 4 * (n - sym - 1)
            } while value < cur
        }
        renormalize(prev - cur, cur)
        if !disableUpdate {
            // One span for the whole update (no check per entry).
            var c = cdf.mutableSpan
            let count = Int(c[at + n])
            let rate = 3 + (count > 15 ? 1 : 0) + (count > 31 ? 1 : 0) + min(floorLog2(n), 2)
            for i in 0..<(n - 1) {
                let v = Int(c[at + i])
                c[at + i] = i >= sym ? UInt16(v + (((1 << 15) - v) >> rate)) : UInt16(v - (v >> rate))
            }
            if count < 32 { c[at + n] = UInt16(count + 1) }
        }
        return sym
    }

    @inline(__always)
    mutating func renormalize(_ range: Int, _ cur: Int) {
        symbolRange = range
        symbolValue -= cur
        let bits = 15 - floorLog2(symbolRange)
        symbolRange <<= bits
        let numBits = min(bits, max(0, symbolMaxBits))
        let newData = read(numBits)
        let padded = newData << (bits - numBits)
        symbolValue = padded ^ (((symbolValue + 1) << bits) - 1)
        symbolMaxBits -= bits
    }

    /// read_bool( ): a symbol with the fixed CDF {1 << 14, 1 << 15} (never adapted).
    @inline(__always)
    mutating func bool() -> Int {
        let r8 = symbolRange >> 8
        let cur = ((r8 * ((1 << 14) >> 6)) >> 1) + 4
        if symbolValue < cur {
            renormalize(cur, 0)
            return 1
        }
        renormalize(symbolRange - cur, cur)
        return 0
    }

    /// A symbol from a CDF built on the fly (split_or_horz / split_or_vert): not adapted.
    mutating func symbolFixed(_ cdf0: Int) -> Int {
        let r8 = symbolRange >> 8
        let cur = ((r8 * (((1 << 15) - cdf0) >> 6)) >> 1) + 4
        if symbolValue < cur {
            renormalize(cur, 0)
            return 1
        }
        renormalize(symbolRange - cur, cur)
        return 0
    }

    mutating func literal(_ n: Int) -> Int {
        var x = 0
        for _ in 0..<n { x = 2 * x + bool() }
        return x
    }

    /// NS(n) coded with read_literal (4.10.10).
    mutating func ns(_ n: Int) -> Int {
        guard n > 1 else { return 0 }
        var w = 0, x = n
        while x != 0 { x >>= 1; w += 1 }
        let m = (1 << w) - n
        let v = literal(w - 1)
        if v < m { return v }
        let extra = literal(1)
        return (v << 1) - m + extra
    }

    /// Whether the padding the encoder must have left is consistent (exit_symbol): at most 14
    /// padding bits used.
    var paddingValid: Bool { symbolMaxBits >= -14 }
}

@inline(__always)
func floorLog2(_ x: Int) -> Int {
    x <= 1 ? 0 : Int.bitWidth - 1 - x.leadingZeroBitCount
}
