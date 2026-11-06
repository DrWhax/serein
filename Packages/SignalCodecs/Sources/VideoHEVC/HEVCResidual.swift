// residual_coding() (H.265 7.3.8.11) with its binarisations and context selection
// (9.3.3.11 coeff_abs_level_remaining, 9.3.4.2.4 – 9.3.4.2.7): last significant position,
// coded sub-blocks, significance, greater1 / greater2 flags, signs (with sign data hiding),
// and remaining levels with the Rice parameter. Output: TransCoeffLevel, raster x + y·n.

import CodecCore

extension HEVCSliceDecoder {
    static let ctxIdxMap4x4: [Int] = [0, 1, 4, 5, 2, 3, 4, 5, 6, 6, 8, 8, 7, 7, 8, 8]

    /// 7.4.9.11 scanIdx: vertical (2) / horizontal (1) for intra 4x4 (and 8x8 luma) blocks by mode.
    func scanIdx(log2Size: Int, cIdx: Int, intraMode: Int?) -> Int {
        guard let m = intraMode, log2Size == 2 || (log2Size == 3 && (cIdx == 0 || sps.chromaArrayType == 3)) else { return 0 }
        if (6...14).contains(m) { return 2 }
        if (22...30).contains(m) { return 1 }
        return 0
    }

    /// Decodes TransCoeffLevel: the nonzero levels are appended to `coeffPool` from
    /// `coeffStart` (position x + y·n in the low 16 bits, the level in the high 16); returns
    /// transform_skip_flag.
    mutating func residualCoding(log2Size: Int, cIdx: Int, intraMode: Int?, bypass cuBypass: Bool) throws(ParseFailure) -> Bool {
        // The engine as a local value for the whole block (no class-property access per bin).
        var cabac = self.cabac
        // The coefficient pool too (taken, so appends are neither copied nor exclusivity-checked).
        var pool = self.coeffPool
        self.coeffPool = []
        coeffStart = pool.count
        defer {
            self.cabac = cabac
            self.coeffPool = pool
        }
        let n = 1 << log2Size
        var transformSkip = false
        if pps.transformSkipEnabled && !cuBypass && log2Size <= pps.log2MaxTransformSkipSize {
            transformSkip = cabac.decision(HEVCCtx.transformSkipFlag + (cIdx == 0 ? 0 : 1)) == 1
        }
        let ctxOffset: Int, ctxShift: Int
        if cIdx == 0 { ctxOffset = 3 * (log2Size - 2) + ((log2Size - 1) >> 2); ctxShift = (log2Size + 1) >> 2 }
        else { ctxOffset = 15; ctxShift = log2Size - 2 }
        let cMax = (log2Size << 1) - 1
        var px = 0
        while px < cMax && cabac.decision(HEVCCtx.lastSigCoeffXPrefix + ctxOffset + (px >> ctxShift)) == 1 { px += 1 }
        var py = 0
        while py < cMax && cabac.decision(HEVCCtx.lastSigCoeffYPrefix + ctxOffset + (py >> ctxShift)) == 1 { py += 1 }
        var lastX = px, lastY = py
        if px > 3 { let b = (px >> 1) - 1; lastX = (1 << b) * (2 + (px & 1)) + cabac.bypassBits(b) }
        if py > 3 { let b = (py >> 1) - 1; lastY = (1 << b) * (2 + (py & 1)) + cabac.bypassBits(b) }
        let scan = scanIdx(log2Size: log2Size, cIdx: cIdx, intraMode: intraMode)
        if scan == 2 { swap(&lastX, &lastY) }
        guard lastX < n, lastY < n else { throw ParseFailure(offset: cabac.bitPos / 8, rule: "last_sig_coeff", reason: .invalid("(\(lastX), \(lastY)) outside \(n)x\(n)")) }

        let log2Sb = log2Size - 2
        let sbBase = (log2Sb * 3 + scan) * 64, posBase = (2 * 3 + scan) * 64
        let sxArr = HEVCScan.flatX, syArr = HEVCScan.flatY
        let sx = sxArr.span, sy = syArr.span
        let sbW = 1 << log2Sb
        var lastSubBlock = (1 << (log2Sb * 2)) - 1
        while lastSubBlock > 0 && !(Int(sx[sbBase + lastSubBlock]) == lastX >> 2 && Int(sy[sbBase + lastSubBlock]) == lastY >> 2) { lastSubBlock -= 1 }
        var lastScanPos = 15
        while lastScanPos > 0 && !(Int(sx[posBase + lastScanPos]) == lastX & 3 && Int(sy[posBase + lastScanPos]) == lastY & 3) { lastScanPos -= 1 }

        // coded_sub_block_flag per sub-block (at most 8x8 of them): a bit set over x + y·8.
        var csbf: UInt64 = 0
        @inline(__always) func coded(_ x: Int, _ y: Int) -> Bool { x < sbW && y < sbW && csbf & (1 << UInt64(x + y * 8)) != 0 }
        var greater1Ctx = 1
        let signHidingAllowed = pps.signDataHiding && !cuBypass
        let tsCtx = sps.transformSkipContextEnabled && (transformSkip || cuBypass)

        var i = lastSubBlock
        while i >= 0 {
            defer { i -= 1 }
            let xS = Int(sx[sbBase + i]), yS = Int(sy[sbBase + i])
            var inferSbDcSig = false
            if i < lastSubBlock && i > 0 {
                let ctx = min(1, (coded(xS + 1, yS) ? 1 : 0) + (coded(xS, yS + 1) ? 1 : 0)) + (cIdx > 0 ? 2 : 0)
                if cabac.decision(HEVCCtx.codedSubBlockFlag + ctx) == 1 { csbf |= 1 << UInt64(xS + yS * 8) }
                inferSbDcSig = true
            } else {
                csbf |= 1 << UInt64(xS + yS * 8)
            }
            let prevCsbf = (coded(xS + 1, yS) ? 1 : 0) | (coded(xS, yS + 1) ? 2 : 0)
            // Bit nPos of `sig` / `g1` / `g2` / `sign` for scan position nPos of this sub-block.
            var sig: UInt16 = 0
            var startN = 15
            if i == lastSubBlock {
                startN = lastScanPos - 1
                sig |= 1 << UInt16(lastScanPos)
            }
            if coded(xS, yS) {
                var nPos = startN
                while nPos >= 0 {
                    defer { nPos -= 1 }
                    let xP = Int(sx[posBase + nPos]), yP = Int(sy[posBase + nPos])
                    if nPos > 0 || !inferSbDcSig {
                        let xC = (xS << 2) + xP, yC = (yS << 2) + yP
                        var sigCtx: Int
                        if tsCtx { sigCtx = cIdx == 0 ? 42 : 16 }
                        else if log2Size == 2 { sigCtx = Self.ctxIdxMap4x4[(yC << 2) + xC] }
                        else if xC + yC == 0 { sigCtx = 0 }
                        else {
                            switch prevCsbf {
                            case 0: sigCtx = xP + yP == 0 ? 2 : xP + yP < 3 ? 1 : 0
                            case 1: sigCtx = yP == 0 ? 2 : yP == 1 ? 1 : 0
                            case 2: sigCtx = xP == 0 ? 2 : xP == 1 ? 1 : 0
                            default: sigCtx = 2
                            }
                            if cIdx == 0 {
                                if xS + yS > 0 { sigCtx += 3 }
                                sigCtx += log2Size == 3 ? (scan == 0 ? 9 : 15) : 21
                            } else {
                                sigCtx += log2Size == 3 ? 9 : 12
                            }
                        }
                        if cabac.decision(HEVCCtx.sigCoeffFlag + (cIdx == 0 ? sigCtx : 27 + sigCtx)) == 1 {
                            sig |= 1 << UInt16(nPos)
                            inferSbDcSig = false
                        }
                    } else {
                        sig |= 1    // the DC of a coded sub-block with nothing else significant
                    }
                }
            }
            guard sig != 0 else { continue }
            var ctxSet = (i == 0 || cIdx > 0) ? 0 : 2
            if i != lastSubBlock && greater1Ctx == 0 { ctxSet += 1 }
            greater1Ctx = 1
            var g1: UInt16 = 0, g2: UInt16 = 0
            var numGreater1 = 0, lastGreater1Pos = -1
            let lastSig = 15 - sig.leadingZeroBitCount, firstSig = sig.trailingZeroBitCount
            var nPos = 15
            while nPos >= 0 {
                if sig & (1 << UInt16(nPos)) != 0 && numGreater1 < 8 {
                    numGreater1 += 1
                    if cabac.decision(HEVCCtx.coeffAbsLevelGreater1 + ctxSet * 4 + greater1Ctx + (cIdx > 0 ? 16 : 0)) == 1 {
                        g1 |= 1 << UInt16(nPos)
                        greater1Ctx = 0
                        if lastGreater1Pos == -1 { lastGreater1Pos = nPos }
                    } else if greater1Ctx > 0 && greater1Ctx < 3 {
                        greater1Ctx += 1
                    }
                }
                nPos -= 1
            }
            let signHidden = signHidingAllowed && lastSig - firstSig > 3
            if lastGreater1Pos != -1 && cabac.decision(HEVCCtx.coeffAbsLevelGreater2 + ctxSet + (cIdx > 0 ? 4 : 0)) == 1 {
                g2 |= 1 << UInt16(lastGreater1Pos)
            }
            var sign: UInt16 = 0
            nPos = 15
            while nPos >= 0 {
                if sig & (1 << UInt16(nPos)) != 0 && (!signHidden || nPos != firstSig) && cabac.bypass() == 1 { sign |= 1 << UInt16(nPos) }
                nPos -= 1
            }
            var numSig = 0, sumAbs = 0, cLastAbs = 0, cLastRice = 0
            nPos = 15
            while nPos >= 0 {
                defer { nPos -= 1 }
                let bit = UInt16(1) << UInt16(nPos)
                guard sig & bit != 0 else { continue }
                let base = 1 + (g1 & bit != 0 ? 1 : 0) + (g2 & bit != 0 ? 1 : 0)
                var absLevel = base
                if base == (numSig < 8 ? (nPos == lastGreater1Pos ? 3 : 2) : 1) {
                    let rice = min(cLastRice + (cLastAbs > 3 * (1 << cLastRice) ? 1 : 0), 4)
                    absLevel = base + (try Self.remaining(&cabac, rice: rice))
                    cLastAbs = absLevel
                    cLastRice = rice
                }
                let xC = (xS << 2) + Int(sx[posBase + nPos]), yC = (yS << 2) + Int(sy[posBase + nPos])
                var v = Int32(truncatingIfNeeded: min(absLevel, 32768))
                if sign & bit != 0 { v = -v }
                if signHidden {
                    sumAbs += absLevel
                    if nPos == firstSig && sumAbs % 2 == 1 { v = -v }
                }
                pool.append(Int32(truncatingIfNeeded: xC + yC * n) | (max(-32768, min(32767, v)) &<< 16))
                numSig += 1
            }
        }
        return transformSkip
    }

    /// coeff_abs_level_remaining (9.3.3.11): a unary prefix then a Rice / Exp-Golomb suffix.
    static func remaining(_ cabac: inout HEVCCABAC, rice: Int) throws(ParseFailure) -> Int {
        var prefix = 0
        while prefix < 32 && cabac.bypass() == 1 { prefix += 1 }
        guard prefix < 32 else { throw ParseFailure(offset: cabac.bitPos / 8, rule: "coeff_abs_level_remaining", reason: .invalid("prefix too long")) }
        if prefix <= 3 { return (prefix << rice) + cabac.bypassBits(rice) }
        let k = prefix - 3
        return (((1 << k) + 3 - 1) << rice) + cabac.bypassBits(k + rice)
    }
}
