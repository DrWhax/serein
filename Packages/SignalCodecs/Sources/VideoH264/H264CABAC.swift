// CABAC (H.264 9.3): context initialisation from (m, n) at SliceQPY (9.3.1.1), the arithmetic
// decoding engine (9.3.1.2, 9.3.3.2: decision, bypass, terminate), and the binarisations and
// context selection of every syntax element (9.3.2, 9.3.3.1), following the context index
// numbering of Table 9-34. Reads past the slice data yield zero bits; slices end by
// end_of_slice_flag or the macroblock count.

import CodecCore

struct CABACDecoder {
    /// The slice data and the next bit to read (past the end: zeros).
    let bytes: [UInt8]
    var bitPos: Int
    var range: UInt32 = 510
    var offset: UInt32 = 0
    /// pStateIdx << 1 | valMPS per context.
    var state: [UInt8]
    /// mb_qp_delta of the previous macroblock in decoding order was non-zero.
    var lastQpDeltaNonZero = false
    var positions = [Int](repeating: 0, count: 64)

    init(rbsp: [UInt8], bitPosition: Int, sliceType: H264SliceType, cabacInitIdc: Int, sliceQP: Int) {
        bytes = rbsp
        // cabac_alignment_one_bit until byte aligned.
        bitPos = (bitPosition + 7) & ~7
        state = [UInt8](repeating: 0, count: 1024)
        let qp = clip3(0, 51, sliceQP)
        for ctx in 0 ..< 1024 {
            let m: Int, n: Int
            if sliceType == .i { m = Int(H264Tables.cabacInitI[ctx * 2]); n = Int(H264Tables.cabacInitI[ctx * 2 + 1]) }
            else { m = Int(H264Tables.cabacInitPB[cabacInitIdc * 2048 + ctx * 2]); n = Int(H264Tables.cabacInitPB[cabacInitIdc * 2048 + ctx * 2 + 1]) }
            let pre = clip3(1, 126, ((m * qp) >> 4) + n)
            state[ctx] = pre <= 63 ? UInt8((63 - pre) << 1) : UInt8(((pre - 64) << 1) | 1)
        }
        startEngine()
    }

    mutating func startEngine() {
        range = 510
        offset = 0
        for _ in 0 ..< 9 { offset = offset << 1 | readBit() }
    }

    @inline(__always) mutating func readBit() -> UInt32 {
        let byte = bitPos >> 3
        let v: UInt32 = byte < bytes.count ? UInt32(bytes[byte] >> UInt8(7 - (bitPos & 7))) & 1 : 0
        bitPos += 1
        return v
    }

    @inline(__always) mutating func decision(_ ctx: Int) -> Int {
        let s = state[ctx]
        let p = Int(s >> 1), mps = Int(s & 1)
        let lps = UInt32(H264Tables.rangeTabLPS[p * 4 + Int((range >> 6) & 3)])
        range -= lps
        var bin: Int
        if offset >= range {
            bin = 1 - mps
            offset -= range
            range = lps
            let np = Int(H264Tables.transIdxLPS[p])
            state[ctx] = UInt8(np << 1 | (p == 0 ? 1 - mps : mps))
        } else {
            bin = mps
            state[ctx] = UInt8(min(p + 1, 62) << 1 | mps)
        }
        while range < 256 {
            range <<= 1
            offset = offset << 1 | readBit()
        }
        return bin
    }

    @inline(__always) mutating func bypass() -> Int {
        offset = offset << 1 | readBit()
        if offset >= range { offset -= range; return 1 }
        return 0
    }

    mutating func terminate() -> Int {
        range -= 2
        if offset >= range { return 1 }
        while range < 256 {
            range <<= 1
            offset = offset << 1 | readBit()
        }
        return 0
    }

    /// After an I_PCM mb_type: the PCM samples start at the next byte after the final bit the
    /// encoder flushed (one bit beyond what the engine has read).
    mutating func pcmStart() {
        _ = readBit()
        bitPos = (bitPos + 7) & ~7
    }

    mutating func byte() -> UInt8 {
        let i = bitPos >> 3
        bitPos += 8
        return i < bytes.count ? bytes[i] : 0
    }

    // MARK: residual blocks (9.3.2.7, 9.3.3.1.3)

    static let sigOffset = [105, 105 + 15, 105 + 29, 105 + 44, 105 + 47, 402]
    static let lastOffset = [166, 166 + 15, 166 + 29, 166 + 44, 166 + 47, 417]
    static let absOffset = [227, 227 + 10, 227 + 20, 227 + 30, 227 + 39, 426]
    static let cbfBase = [85, 89, 93, 97, 101, 1012]
    static let level1Ctx: [Int] = [1, 2, 3, 4, 0, 0, 0, 0]
    static let levelGt1Ctx: [Int] = [5, 5, 5, 5, 6, 7, 8, 9]
    static let transition: [[Int]] = [[1, 2, 3, 3, 4, 5, 6, 7], [4, 4, 4, 4, 5, 6, 7, 7]]

    /// residual_block_cabac(): `cbfInc` is the coded_block_flag context increment (nil for
    /// 8x8 blocks, which have no flag in 4:2:0). Levels into `out[0 ..< maxNumCoeff]` in list
    /// order; returns the number of non-zero coefficients.
    mutating func residualBlock(cat: Int, cbfInc: Int?, maxNumCoeff: Int, into out: inout [Int32]) -> Int {
        if let inc = cbfInc {
            guard decision(Self.cbfBase[cat] + inc) == 1 else { return 0 }
        }
        var count = 0
        let sig = Self.sigOffset[cat], last = Self.lastOffset[cat]
        var i = 0
        var ended = false
        while i < maxNumCoeff - 1 {
            let sInc = cat == 5 ? Int(H264Tables.significantCoeffFlagOffset8x8[i]) : cat == 3 ? min(i, 2) : i
            if decision(sig + sInc) == 1 {
                positions[count] = i
                count += 1
                let lInc = cat == 5 ? Int(H264Tables.lastCoeffFlagOffset8x8[i]) : cat == 3 ? min(i, 2) : i
                if decision(last + lInc) == 1 { ended = true; break }
            }
            i += 1
        }
        if !ended {
            positions[count] = maxNumCoeff - 1
            count += 1
        }
        let abs = Self.absOffset[cat]
        var node = 0
        var k = count
        while k > 0 {
            k -= 1
            let pos = positions[k]
            var level: Int32
            if decision(abs + Self.level1Ctx[node]) == 0 {
                node = Self.transition[0][node]
                level = 1
            } else {
                let ctx = abs + (cat == 3 ? min(Self.levelGt1Ctx[node], 8) : Self.levelGt1Ctx[node])
                node = Self.transition[1][node]
                var a: Int32 = 2
                while a < 15 && decision(ctx) == 1 { a += 1 }
                if a >= 15 {
                    var j = 0
                    while bypass() == 1 && j < 23 { j += 1 }
                    var v: Int32 = 1
                    while j > 0 { j -= 1; v = v * 2 + Int32(bypass()) }
                    a = v + 14
                }
                level = a
            }
            out[pos] = bypass() == 1 ? -level : level
        }
        return count
    }
}
