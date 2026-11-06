// CABAC for H.265 (9.3): context variables initialised from initValue at SliceQpY (9.3.2.2),
// the arithmetic decoding engine (9.3.4.3: decision, bypass, terminate — the same engine and
// tables as H.264), and the context layout: one block per syntax element, in the order of
// Table 9-4, with its initValues for initType 0 (I), 1 and 2 (Tables 9-5 … 9-37).

import CodecCore

/// Context blocks: offset into the state array and the number of contexts.
enum HEVCCtx {
    static let saoMerge = 0                 // 1
    static let saoTypeIdx = 1               // 1
    static let splitCuFlag = 2              // 3
    static let cuTransquantBypass = 5       // 1
    static let cuSkipFlag = 6               // 3
    static let predModeFlag = 9             // 1
    static let partMode = 10                // 4
    static let prevIntraLumaPred = 14       // 1
    static let intraChromaPredMode = 15     // 1
    static let rqtRootCbf = 16              // 1
    static let mergeFlag = 17               // 1
    static let mergeIdx = 18                // 1
    static let interPredIdc = 19            // 5
    static let refIdx = 24                  // 2
    static let mvpFlag = 26                 // 1
    static let splitTransformFlag = 27      // 3
    static let cbfLuma = 30                 // 2
    static let cbfChroma = 32               // 5
    static let absMvdGreater0 = 37          // 1
    static let absMvdGreater1 = 38          // 1
    static let cuQpDeltaAbs = 39            // 2
    static let transformSkipFlag = 41       // 2 (luma, chroma)
    static let lastSigCoeffXPrefix = 43     // 18
    static let lastSigCoeffYPrefix = 61     // 18
    static let codedSubBlockFlag = 79       // 4
    static let sigCoeffFlag = 83            // 44 (42 + 2 transform-skip contexts)
    static let coeffAbsLevelGreater1 = 127  // 24
    static let coeffAbsLevelGreater2 = 151  // 6
    static let count = 157    // HEVCCABAC.state's size

    /// initValue per context, for initType 0, 1, 2.
    static let initValues: [[UInt8]] = {
        func row(_ i: Int) -> [UInt8] {
            var v: [UInt8] = []
            func add(_ x: [UInt8]) { v += x }
            add([153])                                                   // sao_merge
            add([[200], [185], [160]][i])                                // sao_type_idx
            add([[139, 141, 157], [107, 139, 126], [107, 139, 126]][i])  // split_cu_flag
            add([154])                                                   // cu_transquant_bypass_flag
            add([[154, 154, 154], [197, 185, 201], [197, 185, 201]][i])  // cu_skip_flag (unused in I)
            add([[154], [149], [134]][i])                                // pred_mode_flag
            add([[184, 154, 154, 154], [154, 139, 154, 154], [154, 139, 154, 154]][i])  // part_mode
            add([[184], [154], [183]][i])                                // prev_intra_luma_pred_flag
            add([[63], [152], [152]][i])                                 // intra_chroma_pred_mode
            add([[154], [79], [79]][i])                                  // rqt_root_cbf
            add([[154], [110], [154]][i])                                // merge_flag
            add([[154], [122], [137]][i])                                // merge_idx
            add([95, 79, 63, 31, 31])                                    // inter_pred_idc
            add([153, 153])                                              // ref_idx
            add([168])                                                   // mvp_lx_flag
            add([[153, 138, 138], [124, 138, 94], [224, 167, 122]][i])   // split_transform_flag
            add([[111, 141], [153, 111], [153, 111]][i])                 // cbf_luma
            add([[94, 138, 182, 154, 154], [149, 107, 167, 154, 154], [149, 92, 167, 154, 154]][i])  // cbf_cb, cbf_cr
            add([[154], [140], [169]][i])                                // abs_mvd_greater0_flag
            add([[154], [198], [198]][i])                                // abs_mvd_greater1_flag
            add([154, 154])                                              // cu_qp_delta_abs
            add([139, 139])                                              // transform_skip_flag
            let last: [[UInt8]] = [
                [110, 110, 124, 125, 140, 153, 125, 127, 140, 109, 111, 143, 127, 111, 79, 108, 123, 63],
                [125, 110, 94, 110, 95, 79, 125, 111, 110, 78, 110, 111, 111, 95, 94, 108, 123, 108],
                [125, 110, 124, 110, 95, 94, 125, 111, 111, 79, 125, 126, 111, 111, 79, 108, 123, 93]]
            add(last[i]); add(last[i])                                   // last_sig_coeff_x/y_prefix
            add([[91, 171, 134, 141], [121, 140, 61, 154], [121, 140, 61, 154]][i])  // coded_sub_block_flag
            let sig: [[UInt8]] = [
                [111, 111, 125, 110, 110, 94, 124, 108, 124, 107, 125, 141, 179, 153, 125, 107, 125, 141, 179, 153, 125, 107, 125, 141,
                 179, 153, 125, 140, 139, 182, 182, 152, 136, 152, 136, 153, 136, 139, 111, 136, 139, 111, 141, 111],
                [155, 154, 139, 153, 139, 123, 123, 63, 153, 166, 183, 140, 136, 153, 154, 166, 183, 140, 136, 153, 154, 166, 183, 140,
                 136, 153, 154, 170, 153, 123, 123, 107, 121, 107, 121, 167, 151, 183, 140, 151, 183, 140, 140, 140],
                [170, 154, 139, 153, 139, 123, 123, 63, 124, 166, 183, 140, 136, 153, 154, 166, 183, 140, 136, 153, 154, 166, 183, 140,
                 136, 153, 154, 170, 153, 138, 138, 122, 121, 122, 121, 167, 151, 183, 140, 151, 183, 140, 140, 140]]
            add(sig[i])                                                  // sig_coeff_flag
            let g1: [[UInt8]] = [
                [140, 92, 137, 138, 140, 152, 138, 139, 153, 74, 149, 92, 139, 107, 122, 152, 140, 179, 166, 182, 140, 227, 122, 197],
                [154, 196, 196, 167, 154, 152, 167, 182, 182, 134, 149, 136, 153, 121, 136, 137, 169, 194, 166, 167, 154, 167, 137, 182],
                [154, 196, 167, 167, 154, 152, 167, 182, 182, 134, 149, 136, 153, 121, 136, 122, 169, 208, 166, 167, 154, 152, 167, 182]]
            add(g1[i])                                                   // coeff_abs_level_greater1_flag
            add([[138, 153, 136, 167, 152, 152], [107, 167, 91, 122, 107, 167], [107, 167, 91, 107, 107, 167]][i])  // greater2
            precondition(v.count == count)
            return v
        }
        return [row(0), row(1), row(2)]
    }()

    static let rangeTabLPS: [UInt8] = [
        128, 176, 208, 240,
        128, 167, 197, 227,
        128, 158, 187, 216,
        123, 150, 178, 205,
        116, 142, 169, 195,
        111, 135, 160, 185,
        105, 128, 152, 175,
        100, 122, 144, 166,
        95, 116, 137, 158,
        90, 110, 130, 150,
        85, 104, 123, 142,
        81, 99, 117, 135,
        77, 94, 111, 128,
        73, 89, 105, 122,
        69, 85, 100, 116,
        66, 80, 95, 110,
        62, 76, 90, 104,
        59, 72, 86, 99,
        56, 69, 81, 94,
        53, 65, 77, 89,
        51, 62, 73, 85,
        48, 59, 69, 80,
        46, 56, 66, 76,
        43, 53, 63, 72,
        41, 50, 59, 69,
        39, 48, 56, 65,
        37, 45, 54, 62,
        35, 43, 51, 59,
        33, 41, 48, 56,
        32, 39, 46, 53,
        30, 37, 43, 50,
        29, 35, 41, 48,
        27, 33, 39, 45,
        26, 31, 37, 43,
        24, 30, 35, 41,
        23, 28, 33, 39,
        22, 27, 32, 37,
        21, 26, 30, 35,
        20, 24, 29, 33,
        19, 23, 27, 31,
        18, 22, 26, 30,
        17, 21, 25, 28,
        16, 20, 23, 27,
        15, 19, 22, 25,
        14, 18, 21, 24,
        14, 17, 20, 23,
        13, 16, 19, 22,
        12, 15, 18, 21,
        12, 14, 17, 20,
        11, 14, 16, 19,
        11, 13, 15, 18,
        10, 12, 15, 17,
        10, 12, 14, 16,
        9, 11, 13, 15,
        9, 11, 12, 14,
        8, 10, 12, 14,
        8, 9, 11, 13,
        7, 9, 11, 12,
        7, 9, 10, 12,
        7, 8, 10, 11,
        6, 8, 9, 11,
        6, 7, 9, 10,
        6, 7, 8, 9,
        2, 2, 2, 2,
    ]
    static let transIdxLPS: [UInt8] = [
        0, 0, 1, 2, 2, 4, 4, 5, 6, 7, 8, 9, 9, 11, 11, 12,
        13, 13, 15, 15, 16, 16, 18, 18, 19, 19, 21, 21, 22, 22, 23, 24,
        24, 25, 26, 26, 27, 27, 28, 29, 29, 30, 30, 30, 31, 32, 32, 33,
        33, 33, 34, 34, 35, 35, 35, 36, 36, 36, 37, 37, 37, 38, 38, 63,
    ]
}

/// The engine's tables as fixed-size values, indexed by the whole context state
/// (pStateIdx << 1 | valMps): no branches for the transitions, and no Array subscripts (the
/// optimiser left those out of line in the large parsing functions).
struct HEVCCabacTables {
    /// codIRangeLPS at [state << 2 | qRangeIdx].
    var lps = InlineArray<512, UInt8>(repeating: 0)
    /// The state after an MPS / an LPS.
    var nextMPS = InlineArray<128, UInt8>(repeating: 0)
    var nextLPS = InlineArray<128, UInt8>(repeating: 0)
    /// Renormalisation shift after an LPS, by codIRangeLPS >> 3.
    var renorm = InlineArray<32, UInt8>(repeating: 0)

    static let shared: HEVCCabacTables = {
        var t = HEVCCabacTables()
        for s in 0..<128 {
            let p = s >> 1, mps = s & 1
            for q in 0..<4 { t.lps[s << 2 | q] = HEVCCtx.rangeTabLPS[p * 4 + q] }
            t.nextMPS[s] = UInt8(min(p + 1, 62) << 1 | mps)
            t.nextLPS[s] = UInt8(Int(HEVCCtx.transIdxLPS[p]) << 1 | (p == 0 ? 1 - mps : mps))
        }
        for i in 0..<32 { t.renorm[i] = HEVCCABAC.renormTable[i] }
        return t
    }()
}

/// The arithmetic decoder with a 16-bit window refilled a byte at a time (the same arithmetic
/// as 9.3.4.3: ivlOffset is `value` >> 7 relative to `range` << 7; `bitsNeeded` counts the
/// window bits not yet supplied, −8 … −1).
struct HEVCCABAC {
    let bytes: [UInt8]
    var pos: Int
    let end: Int
    var range: UInt32 = 510
    var value: UInt32 = 0
    var bitsNeeded = -8
    /// pStateIdx << 1 | valMps per context (inline storage: no copy-on-write per bin).
    var state = InlineArray<157, UInt8>(repeating: 0)
    /// StatCoeff (persistent Rice adaptation, 9.3.2.2): all zero without the range extension.
    var statCoeff = [0, 0, 0, 0]

    static let renormTable: [UInt8] = [6, 5, 4, 4, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]

    /// Engine over bytes [start, end) of the RBSP.
    init(rbsp: [UInt8], start: Int, end: Int) {
        bytes = rbsp
        pos = start
        self.end = min(end, rbsp.count)
    }

    /// The equivalent bit position of the 9.3.4.3 decoder (bits consumed into ivlOffset).
    var bitPos: Int { pos * 8 + bitsNeeded + 1 }

    /// 9.3.2.2: every context from its initValue at SliceQpY.
    mutating func initContexts(initType: Int, qp sliceQp: Int) {
        let qp = max(0, min(51, sliceQp))
        let values = HEVCCtx.initValues[initType]
        for i in 0 ..< HEVCCtx.count {
            let v = Int(values[i])
            let m = (v >> 4) * 5 - 45, n = ((v & 15) << 3) - 16
            let pre = max(1, min(126, ((m * qp) >> 4) + n))
            state[i] = pre <= 63 ? UInt8((63 - pre) << 1) : UInt8(((pre - 64) << 1) | 1)
        }
        statCoeff = [0, 0, 0, 0]
    }

    @inline(__always) mutating func nextByte() -> UInt32 {
        guard pos < end else { pos += 1; return 0 }
        let b = UInt32(bytes.span[pos])
        pos += 1
        return b
    }

    /// 9.3.2.5: (re)starts the arithmetic decoder at the current byte.
    mutating func startEngine() {
        range = 510
        value = nextByte() << 8
        value |= nextByte()
        bitsNeeded = -8
    }

    /// Restarts at a new entry point (byte offset into the RBSP).
    mutating func restart(at byte: Int) {
        pos = byte
        startEngine()
    }

    /// 9.3.4.3.2 without data-dependent branches: MPS / LPS by selects, renormalisation by
    /// counting leading zeros (codIRange back into [256, 510]); only the byte refill branches.
    @inline(__always) mutating func decision(_ ctx: Int) -> Int {
        let st = Int(state[ctx])
        let lps = UInt32(HEVCCabacTables.shared.lps[st << 2 | Int((range >> 6) & 3)])
        let rMPS = range &- lps
        let scaled = rMPS << 7
        let isLPS = value >= scaled
        let next = isLPS ? HEVCCabacTables.shared.nextLPS[st] : HEVCCabacTables.shared.nextMPS[st]
        state[ctx] = next
        value = isLPS ? value &- scaled : value
        let r = isLPS ? lps : rMPS
        let shift = UInt32(truncatingIfNeeded: r.leadingZeroBitCount &- 23)
        range = r << shift
        value <<= shift
        bitsNeeded &+= Int(shift)
        if bitsNeeded >= 0 {
            value |= nextByte() << UInt32(bitsNeeded)
            bitsNeeded -= 8
        }
        return (st & 1) ^ (isLPS ? 1 : 0)
    }

    @inline(__always) mutating func bypass() -> Int {
        value <<= 1
        bitsNeeded += 1
        if bitsNeeded >= 0 {
            bitsNeeded = -8
            value |= nextByte()
        }
        let scaled = range << 7
        if value >= scaled { value -= scaled; return 1 }
        return 0
    }

    /// `n` bypass bins, most significant first.
    @inline(__always) mutating func bypassBits(_ n: Int) -> Int {
        var v = 0
        for _ in 0 ..< n { v = v << 1 | bypass() }
        return v
    }

    /// end_of_slice_segment_flag, end_of_subset_one_bit, pcm_flag (9.3.4.3.5).
    mutating func terminate() -> Int {
        range -= 2
        let scaled = range << 7
        if value >= scaled { return 1 }
        if scaled < (256 << 7) {
            range = scaled >> 6
            value <<= 1
            bitsNeeded += 1
            if bitsNeeded == 0 {
                bitsNeeded = -8
                value |= nextByte()
            }
        }
        return 0
    }

    /// After pcm_flag (a terminate bin of 1): the PCM samples start at the next byte after the
    /// final bit the encoder flushed, one bit beyond what the engine has consumed.
    var rawBit = 0
    mutating func pcmStart() {
        rawBit = (bitPos + 1 + 7) & ~7
    }

    /// pcm_sample bits (read at bit level from `rawBit`), then `startEngine` after them.
    mutating func rawBits(_ n: Int) -> Int {
        var v = 0
        for _ in 0 ..< n {
            let byte = rawBit >> 3
            let b = byte < end ? Int(bytes[byte] >> UInt8(7 - (rawBit & 7))) & 1 : 0
            v = v << 1 | b
            rawBit += 1
        }
        pos = (rawBit + 7) >> 3
        return v
    }
}
