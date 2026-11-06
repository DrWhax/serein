// The two entropy codings behind one interface: CAVLC (Exp-Golomb + residual VLCs) and CABAC
// (9.3). The macroblock layer asks for syntax elements; context increments that depend on
// neighbouring macroblocks are computed by the picture decoder and passed in (CAVLC ignores
// them).

import CodecCore

protocol H264Entropy {
    static var isCABAC: Bool { get }
    /// I mb_type 0…25 (I slices).
    mutating func mbTypeI(ctxInc: Int) throws(ParseFailure) -> Int
    /// P: 0…4 inter (4 = P_8x8ref0, CAVLC only), 5…30 intra.
    mutating func mbTypeP() throws(ParseFailure) -> Int
    /// B: 0…22 inter, 23…48 intra.
    mutating func mbTypeB(ctxInc: Int) throws(ParseFailure) -> Int
    mutating func subMbType(b: Bool) throws(ParseFailure) -> Int
    mutating func transform8x8(ctxInc: Int) throws(ParseFailure) -> Bool
    mutating func prevIntraMode() throws(ParseFailure) -> Bool
    mutating func remIntraMode() throws(ParseFailure) -> Int
    mutating func chromaPredMode(ctxInc: Int) throws(ParseFailure) -> Int
    mutating func refIdx(ctxInc: Int, numRef: Int) throws(ParseFailure) -> Int
    mutating func mvd(comp: Int, absSum: Int) throws(ParseFailure) -> Int
    /// coded_block_pattern; `left`/`top`: the neighbours' patterns for the CABAC contexts.
    mutating func cbp(intra: Bool, left: Int, top: Int) throws(ParseFailure) -> Int
    mutating func qpDelta() throws(ParseFailure) -> Int
    /// A macroblock without mb_qp_delta (CABAC's context memory).
    mutating func noQpDelta()
    mutating func residual(cat: Int, nC: Int, cbfInc: Int?, maxNumCoeff: Int, into: inout [Int32]) throws(ParseFailure) -> Int
    mutating func pcmByte() throws(ParseFailure) -> UInt8
    mutating func pcmStart()
    mutating func pcmEnd()
}

extension H264Reader: H264Entropy {
    static var isCABAC: Bool { false }
    mutating func mbTypeI(ctxInc: Int) throws(ParseFailure) -> Int { try ue("mb_type", 0 ... 25) }
    mutating func mbTypeP() throws(ParseFailure) -> Int { try ue("mb_type", 0 ... 30) }
    mutating func mbTypeB(ctxInc: Int) throws(ParseFailure) -> Int { try ue("mb_type", 0 ... 48) }
    mutating func subMbType(b: Bool) throws(ParseFailure) -> Int { try ue("sub_mb_type", 0 ... (b ? 12 : 3)) }
    mutating func transform8x8(ctxInc: Int) throws(ParseFailure) -> Bool { try flag("transform_size_8x8_flag") }
    mutating func prevIntraMode() throws(ParseFailure) -> Bool { try flag("prev_intra_pred_mode_flag") }
    mutating func remIntraMode() throws(ParseFailure) -> Int { try u(3, "rem_intra_pred_mode") }
    mutating func chromaPredMode(ctxInc: Int) throws(ParseFailure) -> Int { try ue("intra_chroma_pred_mode", 0 ... 3) }
    mutating func refIdx(ctxInc: Int, numRef: Int) throws(ParseFailure) -> Int {
        let v = try te(numRef - 1, "ref_idx")
        guard v < numRef else { throw fail("ref_idx", "\(v) ≥ \(numRef)") }
        return v
    }
    mutating func mvd(comp: Int, absSum: Int) throws(ParseFailure) -> Int { comp == 0 ? try se("mvd", -8192 ... 8191) : try se("mvd", -2048 ... 2047) }
    mutating func cbp(intra: Bool, left: Int, top: Int) throws(ParseFailure) -> Int {
        let code = try ue("coded_block_pattern", 0 ... 47)
        return Int(intra ? golombToIntraCBP[code] : golombToInterCBP[code])
    }
    mutating func qpDelta() throws(ParseFailure) -> Int { try se("mb_qp_delta", -26 ... 25) }
    mutating func noQpDelta() {}
    mutating func residual(cat: Int, nC: Int, cbfInc: Int?, maxNumCoeff: Int, into: inout [Int32]) throws(ParseFailure) -> Int {
        try residualBlockCAVLC(nC: nC, maxNumCoeff: maxNumCoeff, into: &into, at: 0)
    }
    mutating func pcmByte() throws(ParseFailure) -> UInt8 { UInt8(try u(8, "pcm_sample")) }
    mutating func pcmStart() { alignToByte() }
    mutating func pcmEnd() {}
}

extension CABACDecoder: H264Entropy {
    static var isCABAC: Bool { true }

    /// The I part of mb_type (9.3.2.5): `base` 3 (I slice, with neighbour ctxInc) or the
    /// suffix offsets 17 (P) / 32 (B).
    mutating func intraType(base: Int, ctxInc: Int, intraSlice: Bool) -> Int {
        if intraSlice {
            if decision(base + ctxInc) == 0 { return 0 }
        } else if decision(base) == 0 {
            return 0
        }
        if terminate() == 1 { return 25 }
        let s = intraSlice ? base + 2 : base
        var t = 1 + 12 * decision(s + 1)
        if decision(s + 2) == 1 { t += 4 + 4 * decision(s + 2 + (intraSlice ? 1 : 0)) }
        t += 2 * decision(s + 3 + (intraSlice ? 1 : 0))
        t += decision(s + 3 + (intraSlice ? 2 : 0))
        return t
    }

    mutating func mbTypeI(ctxInc: Int) throws(ParseFailure) -> Int { intraType(base: 3, ctxInc: ctxInc, intraSlice: true) }

    mutating func mbTypeP() throws(ParseFailure) -> Int {
        if decision(14) == 0 {
            if decision(15) == 0 { return 3 * decision(16) }
            return 2 - decision(17)
        }
        return 5 + intraType(base: 17, ctxInc: 0, intraSlice: false)
    }

    mutating func mbTypeB(ctxInc: Int) throws(ParseFailure) -> Int {
        if decision(27 + ctxInc) == 0 { return 0 }
        if decision(27 + 3) == 0 { return 1 + decision(27 + 5) }
        var bits = decision(27 + 4) << 3
        bits |= decision(27 + 5) << 2
        bits |= decision(27 + 5) << 1
        bits |= decision(27 + 5)
        if bits < 8 { return bits + 3 }
        if bits == 13 { return 23 + intraType(base: 32, ctxInc: 0, intraSlice: false) }
        if bits == 14 { return 11 }
        if bits == 15 { return 22 }
        bits = bits << 1 | decision(27 + 5)
        return bits - 4
    }

    mutating func subMbType(b: Bool) throws(ParseFailure) -> Int {
        if !b {
            if decision(21) == 1 { return 0 }
            if decision(22) == 0 { return 1 }
            return decision(23) == 1 ? 2 : 3
        }
        if decision(36) == 0 { return 0 }
        if decision(37) == 0 { return 1 + decision(39) }
        var t = 3
        if decision(38) == 1 {
            if decision(39) == 1 { return 11 + decision(39) }
            t += 4
        }
        t += 2 * decision(39)
        t += decision(39)
        return t
    }

    mutating func transform8x8(ctxInc: Int) throws(ParseFailure) -> Bool { decision(399 + ctxInc) == 1 }
    mutating func prevIntraMode() throws(ParseFailure) -> Bool { decision(68) == 1 }
    mutating func remIntraMode() throws(ParseFailure) -> Int { decision(69) | decision(69) << 1 | decision(69) << 2 }

    mutating func chromaPredMode(ctxInc: Int) throws(ParseFailure) -> Int {
        if decision(64 + ctxInc) == 0 { return 0 }
        if decision(64 + 3) == 0 { return 1 }
        return decision(64 + 3) == 0 ? 2 : 3
    }

    mutating func refIdx(ctxInc: Int, numRef: Int) throws(ParseFailure) -> Int {
        var ctx = ctxInc, ref = 0
        while decision(54 + ctx) == 1 {
            ref += 1
            ctx = (ctx >> 2) + 4
            guard ref < 32 else { throw ParseFailure(offset: 0, rule: "ref_idx", reason: .invalid("too large")) }
        }
        guard ref < numRef else { throw ParseFailure(offset: 0, rule: "ref_idx", reason: .invalid("\(ref) ≥ \(numRef)")) }
        return ref
    }

    mutating func mvd(comp: Int, absSum: Int) throws(ParseFailure) -> Int {
        var base = comp == 0 ? 40 : 47
        let inc = absSum < 3 ? 0 : absSum <= 32 ? 1 : 2
        if decision(base + inc) == 0 { return 0 }
        var v = 1
        base += 3
        while v < 9 && decision(base) == 1 {
            if v < 4 { base += 1 }
            v += 1
        }
        if v >= 9 {
            var k = 3
            while bypass() == 1 {
                v += 1 << k
                k += 1
                guard k <= 24 else { throw ParseFailure(offset: 0, rule: "mvd", reason: .invalid("escape too long")) }
            }
            while k > 0 { k -= 1; v += bypass() << k }
        }
        return bypass() == 1 ? -v : v
    }

    mutating func cbp(intra: Bool, left: Int, top: Int) throws(ParseFailure) -> Int {
        var cbp = 0
        cbp |= decision(73 + ((left & 2) == 0 ? 1 : 0) + ((top & 4) == 0 ? 2 : 0))
        cbp |= decision(73 + ((cbp & 1) == 0 ? 1 : 0) + ((top & 8) == 0 ? 2 : 0)) << 1
        cbp |= decision(73 + ((left & 8) == 0 ? 1 : 0) + ((cbp & 1) == 0 ? 2 : 0)) << 2
        cbp |= decision(73 + ((cbp & 4) == 0 ? 1 : 0) + ((cbp & 2) == 0 ? 2 : 0)) << 3
        let ca = (left >> 4) & 3, cb = (top >> 4) & 3
        var ctx = (ca > 0 ? 1 : 0) + (cb > 0 ? 2 : 0)
        if decision(77 + ctx) == 0 { return cbp }
        ctx = 4 + (ca == 2 ? 1 : 0) + (cb == 2 ? 2 : 0)
        return cbp | (1 + decision(77 + ctx)) << 4
    }

    mutating func qpDelta() throws(ParseFailure) -> Int {
        var ctx = lastQpDeltaNonZero ? 1 : 0
        var v = 0
        while decision(60 + ctx) == 1 {
            ctx = 2 + (ctx >> 1)
            v += 1
            guard v <= 104 else { throw ParseFailure(offset: 0, rule: "mb_qp_delta", reason: .invalid("too large")) }
        }
        lastQpDeltaNonZero = v != 0
        return v & 1 == 1 ? (v + 1) >> 1 : -((v + 1) >> 1)
    }

    mutating func noQpDelta() { lastQpDeltaNonZero = false }

    mutating func residual(cat: Int, nC: Int, cbfInc: Int?, maxNumCoeff: Int, into: inout [Int32]) throws(ParseFailure) -> Int {
        residualBlock(cat: cat, cbfInc: cbfInc, maxNumCoeff: maxNumCoeff, into: &into)
    }

    mutating func pcmByte() throws(ParseFailure) -> UInt8 { byte() }
    mutating func pcmEnd() { startEngine() }
}
