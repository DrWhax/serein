// slice_data() and macroblock_layer() (H.264 7.3.4, 7.3.5) over either entropy coding: the
// syntax and its semantics are shared; CAVLC and CABAC differ in how each element is read
// (H264Entropy). Motion is derived and every macroblock reconstructed as it is parsed.

import CodecCore

/// A partition: position, size, prediction (bit 0 L0, bit 1 L1; 0 = direct 8x8), MV
/// prediction shape, and its 8x8 sub-macroblock (−1 for macroblock partitions).
struct InterPart { var x: Int, y: Int, w: Int, h: Int, pred: Int, shape: Int, sub: Int }

struct SliceRefs: Sendable {
    var lists: [[RefPicture?]]
    var currentPOC: Int
}

extension H264PictureDecoder {
    // MARK: slices

    mutating func decodeSliceCAVLC(_ h: H264SliceHeader, _ pps: H264PPS, _ r: inout H264Reader, slice: Int32, refs: SliceRefs) throws(ParseFailure) {
        let dq = dequantCache[pps.id] ?? dequant(pps)
        dequantCache[pps.id] = dq
        var qp = pps.picInitQp + h.qpDelta
        var mb = h.firstMb
        let total = st.mbs
        var more = true
        repeat {
            if h.type != .i {
                let run = try r.ue("mb_skip_run", 0 ... total - mb)
                for _ in 0 ..< run {
                    st.slice[mb] = slice
                    do { try decodeSkipMB(mb, h, pps, qp: qp, slice: slice, refs: refs) } catch { st.slice[mb] = -1; throw error }
                    mb += 1
                }
                if run > 0 { more = r.moreRBSPData() }
            }
            if more {
                guard mb < total else { throw r.fail("slice_data", "macroblocks past the end of the picture") }
                st.slice[mb] = slice
                do { try decodeMacroblock(mb, &r, h, pps, dq, &qp, slice: slice, refs: refs) } catch { st.slice[mb] = -1; throw error }
                more = r.moreRBSPData()
                mb += 1
            }
        } while more && mb < total
    }

    mutating func decodeSliceCABAC(_ h: H264SliceHeader, _ pps: H264PPS, _ r: H264Reader, rbsp: [UInt8], slice: Int32, refs: SliceRefs) throws(ParseFailure) {
        let dq = dequantCache[pps.id] ?? dequant(pps)
        dequantCache[pps.id] = dq
        var qp = pps.picInitQp + h.qpDelta
        var c = CABACDecoder(rbsp: rbsp, bitPosition: r.position, sliceType: h.type, cabacInitIdc: h.cabacInitIdc, sliceQP: qp)
        var mb = h.firstMb
        let total = st.mbs
        while true {
            guard mb < total else { throw ParseFailure(offset: 0, rule: "slice_data", reason: .invalid("macroblocks past the end of the picture")) }
            st.slice[mb] = slice
            var skipped = false
            if h.type != .i {
                let a = neighbour(mb, 0, slice: slice), b = neighbour(mb, 1, slice: slice)
                let inc = (a.map { !st.kind[$0].contains(.skip) } ?? false ? 1 : 0) + (b.map { !st.kind[$0].contains(.skip) } ?? false ? 1 : 0)
                skipped = c.decision((h.type == .b ? 24 : 11) + inc) == 1
            }
            do {
                if skipped {
                    c.noQpDelta()
                    try decodeSkipMB(mb, h, pps, qp: qp, slice: slice, refs: refs)
                } else {
                    try decodeMacroblock(mb, &c, h, pps, dq, &qp, slice: slice, refs: refs)
                }
            } catch {
                st.slice[mb] = -1
                throw error
            }
            mb += 1
            if c.terminate() == 1 { break }
        }
    }

    // MARK: macroblocks

    mutating func beginMacroblock(_ mb: Int) {
        for i in 0 ..< 24 { st.nnz[mb * 24 + i] = 0 }
        for i in 0 ..< 16 { st.intraModes[mb * 16 + i] = -1; st.mvdX[(0) * st.n16 + mb * 16 + i] = 0; st.mvdY[(0) * st.n16 + mb * 16 + i] = 0; st.mvdX[(1) * st.n16 + mb * 16 + i] = 0; st.mvdY[(1) * st.n16 + mb * 16 + i] = 0 }
        for i in 0 ..< 4 { st.directSub[mb * 4 + i] = 0 }
        st.codedDC[mb] = 0
        st.chromaPredMode[mb] = 0
        st.partCount[mb] = 0
        clearMotion(mb)
    }

    /// Records an inter partition for reconstruction.
    mutating func addPart(_ mb: Int, x: Int, y: Int, w: Int, h: Int) {
        let n = Int(st.partCount[mb])
        func code(_ v: Int) -> Int { v == 4 ? 0 : v == 8 ? 1 : 2 }
        st.parts[mb * 16 + n] = UInt8(x >> 2 | (y >> 2) << 2 | code(w) << 4 | code(h) << 6)
        st.partCount[mb] = UInt8(n + 1)
    }

    mutating func setQP(_ mb: Int, _ qp: Int, _ pps: H264PPS) {
        st.qp[mb] = Int8(qp)
        st.qpc[(0) * st.mbs + mb] = Int8(chromaQPTable[clip3(0, 51, qp + pps.chromaQpIndexOffset)])
        st.qpc[(1) * st.mbs + mb] = Int8(chromaQPTable[clip3(0, 51, qp + pps.secondChromaQpIndexOffset)])
    }

    mutating func decodeSkipMB(_ mb: Int, _ h: H264SliceHeader, _ pps: H264PPS, qp: Int, slice: Int32, refs: SliceRefs) throws(ParseFailure) {
        beginMacroblock(mb)
        st.motion.intra[mb] = false
        st.cbp[mb] = 0
        setQP(mb, qp, pps)
        if h.type == .b {
            st.kind[mb] = .bSkipped
            let d = try directMotion(mb, h, slice: slice, refs: refs.lists, currentPOC: refs.currentPOC)
            try applyDirect(mb, d, mask: 0xFFFF, h, pps, refs: refs.lists, currentPOC: refs.currentPOC)
            return
        }
        st.kind[mb] = .pSkipped
        let (mvx, mvy) = pSkipMV(mb, slice: slice)
        guard let ref = refs.lists[0].first ?? nil else { throw ParseFailure(offset: 0, rule: "P_Skip", reason: .invalid("no reference picture")) }
        setMotion(mb, x: 0, y: 0, w: 16, h: 16, list: 0, refIdx: 0, mvx: mvx, mvy: mvy, ref: ref)
        addPart(mb, x: 0, y: 0, w: 16, h: 16)
    }

    mutating func decodeMacroblock<E: H264Entropy>(_ mb: Int, _ e: inout E, _ h: H264SliceHeader, _ pps: H264PPS, _ dq: H264Dequant, _ qp: inout Int, slice: Int32, refs: SliceRefs) throws(ParseFailure) {
        beginMacroblock(mb)
        switch h.type {
        case .i:
            let a = neighbour(mb, 0, slice: slice), b = neighbour(mb, 1, slice: slice)
            func cond(_ n: Int?) -> Int { n.map { st.kind[$0].contains(.intra16x16) || st.kind[$0].contains(.pcm) ? 1 : 0 } ?? 0 }
            let t = try e.mbTypeI(ctxInc: cond(a) + cond(b))
            try decodeIntra(mb, mbType: t, &e, h, pps, dq, &qp, slice: slice)
        case .p:
            let t = try e.mbTypeP()
            if t >= 5 { try decodeIntra(mb, mbType: t - 5, &e, h, pps, dq, &qp, slice: slice) }
            else { try decodeInter(mb, pType: t, bType: -1, &e, h, pps, dq, &qp, slice: slice, refs: refs) }
        default:
            let a = neighbour(mb, 0, slice: slice), b = neighbour(mb, 1, slice: slice)
            func cond(_ n: Int?) -> Int { n.map { st.kind[$0].contains(.direct16x16) ? 0 : 1 } ?? 0 }
            let t = try e.mbTypeB(ctxInc: cond(a) + cond(b))
            if t >= 23 { try decodeIntra(mb, mbType: t - 23, &e, h, pps, dq, &qp, slice: slice) }
            else { try decodeInter(mb, pType: -1, bType: t, &e, h, pps, dq, &qp, slice: slice, refs: refs) }
        }
    }

    // MARK: CABAC neighbour contexts

    /// coded_block_pattern of a neighbour as the CABAC contexts see it.
    func cbpForContext(_ n: Int?) -> Int {
        guard let n else { return 0x0F }
        if st.kind[n].contains(.pcm) { return 0x2F }
        if st.kind[n].contains(.skip) { return 0 }
        return Int(st.cbp[n])
    }

    func transformCtx(_ mb: Int, slice: Int32) -> Int {
        (neighbour(mb, 0, slice: slice).map { st.kind[$0].contains(.transform8x8) ? 1 : 0 } ?? 0)
            + (neighbour(mb, 1, slice: slice).map { st.kind[$0].contains(.transform8x8) ? 1 : 0 } ?? 0)
    }

    func dcCbfInc(_ mb: Int, bit: Int, intra: Bool, slice: Int32) -> Int {
        func cond(_ n: Int?) -> Int {
            guard let n else { return intra ? 1 : 0 }
            if st.kind[n].contains(.pcm) { return 1 }
            if st.kind[n].contains(.skip) { return 0 }
            return Int(st.codedDC[n] >> UInt8(bit)) & 1
        }
        return cond(neighbour(mb, 0, slice: slice)) + 2 * cond(neighbour(mb, 1, slice: slice))
    }

    func lumaCbfInc(_ mb: Int, _ blk: Int, intra: Bool, slice: Int32) -> Int {
        func cond(_ left: Bool) -> Int {
            if left ? blk & 3 != 0 : blk >= 4 { return st.nnz[mb * 24 + (left ? blk - 1 : blk - 4)] > 0 ? 1 : 0 }
            guard let n = neighbour(mb, left ? 0 : 1, slice: slice) else { return intra ? 1 : 0 }
            if st.kind[n].contains(.pcm) { return 1 }
            if st.kind[n].contains(.skip) { return 0 }
            let nb = left ? blk + 3 : blk + 12
            let b8 = (nb >> 3) * 2 + ((nb & 3) >> 1)
            if Int(st.cbp[n]) & (1 << b8) == 0 { return 0 }
            return st.nnz[n * 24 + nb] > 0 ? 1 : 0
        }
        return cond(true) + 2 * cond(false)
    }

    func chromaCbfInc(_ mb: Int, _ c: Int, _ b: Int, intra: Bool, slice: Int32) -> Int {
        func cond(_ left: Bool) -> Int {
            if left ? b & 1 == 1 : b >= 2 { return st.nnz[mb * 24 + 16 + c * 4 + (left ? b - 1 : b - 2)] > 0 ? 1 : 0 }
            guard let n = neighbour(mb, left ? 0 : 1, slice: slice) else { return intra ? 1 : 0 }
            if st.kind[n].contains(.pcm) { return 1 }
            if st.kind[n].contains(.skip) { return 0 }
            if (st.cbp[n] >> 4) != 2 { return 0 }
            return st.nnz[n * 24 + 16 + c * 4 + (left ? b + 1 : b + 2)] > 0 ? 1 : 0
        }
        return cond(true) + 2 * cond(false)
    }

    /// ref_idx ctxIdxInc (9.3.3.1.1.6) for the partition whose top-left 4x4 is at (x, y).
    func refIdxCtx(_ mb: Int, x: Int, y: Int, list l: Int, slice: Int32, bSlice: Bool) -> Int {
        func cond(_ dx: Int, _ dy: Int) -> Int {
            let m = motionAt(mb, x + dx, y + dy, list: l, done: 0xFFFF, slice: slice)
            guard m.available, m.refIdx > 0 else { return 0 }
            if bSlice {
                // Direct-predicted neighbours do not count.
                let (nm, bx, by) = locate(mb, x + dx, y + dy)
                if st.kind[nm].contains(.direct16x16) || st.directSub[nm * 4 + (by >> 3) * 2 + (bx >> 3)] != 0 { return 0 }
            }
            return 1
        }
        return cond(-1, 0) + 2 * cond(0, -1)
    }

    /// The macroblock and in-MB position of a neighbouring luma position (for available ones).
    func locate(_ mb: Int, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        let w = st.widthMbs
        var m = mb, bx = x, by = y
        if y < 0 { m -= w; by += 16 }
        if x < 0 { m -= 1; bx += 16 } else if x >= 16 { m += 1; bx -= 16 }
        return (m, bx, by)
    }

    func mvdAbsSum(_ mb: Int, x: Int, y: Int, list l: Int, comp: Int, slice: Int32) -> Int {
        func at(_ dx: Int, _ dy: Int) -> Int {
            let px = x + dx, py = y + dy
            if px >= 0 && py >= 0 { return Int((comp == 0 ? st.mvdX : st.mvdY)[l * st.n16 + mb * 16 + (py >> 2) * 4 + (px >> 2)]) }
            guard let n = neighbour(mb, px < 0 ? 0 : 1, slice: slice) else { return 0 }
            let bx = px < 0 ? 15 : px, by = py < 0 ? 15 : py
            return Int((comp == 0 ? st.mvdX : st.mvdY)[l * st.n16 + n * 16 + (by >> 2) * 4 + (bx >> 2)])
        }
        return at(-1, 0) + at(0, -1)
    }

    mutating func storeMvd(_ mb: Int, x: Int, y: Int, w: Int, h: Int, list l: Int, _ mvd: (Int, Int)) {
        let ax = UInt8(min(abs(mvd.0), 127)), ay = UInt8(min(abs(mvd.1), 127))
        for by in stride(from: y, to: y + h, by: 4) {
            for bx in stride(from: x, to: x + w, by: 4) {
                st.mvdX[(l) * st.n16 + mb * 16 + (by >> 2) * 4 + (bx >> 2)] = ax
                st.mvdY[(l) * st.n16 + mb * 16 + (by >> 2) * 4 + (bx >> 2)] = ay
            }
        }
    }

    /// Stores a parsed ref_idx over its partition (for the contexts of later partitions).
    mutating func storeRefIdx(_ mb: Int, x: Int, y: Int, w: Int, h: Int, list l: Int, _ r: Int) {
        for by in stride(from: y, to: y + h, by: 8) { for bx in stride(from: x, to: x + w, by: 8) { st.motion.refIdx[(l) * st.motion.n4 + mb * 4 + (by >> 3) * 2 + (bx >> 3)] = Int8(r) } }
    }

    // MARK: intra

    mutating func decodeIntra<E: H264Entropy>(_ mb: Int, mbType: Int, _ e: inout E, _ h: H264SliceHeader, _ pps: H264PPS, _ dq: H264Dequant, _ qp: inout Int, slice: Int32) throws(ParseFailure) {
        guard mbType <= 25 else { throw ParseFailure(offset: 0, rule: "mb_type", reason: .invalid("\(mbType)")) }
        st.motion.intra[mb] = true
        if mbType == 25 {
            e.pcmStart()
            let base = st.levelBase(mb)
            for i in 0 ..< 384 { st.levels[base + i] = Int32(try e.pcmByte()) }
            e.pcmEnd()
            e.noQpDelta()
            st.kind[mb] = .pcmDecoded
            setQP(mb, 0, pps)
            for i in 0 ..< 24 { st.nnz[mb * 24 + i] = 16 }
            st.cbp[mb] = 0x2F
            st.codedDC[mb] = 7
            return
        }
        var kind: MBKind = [.decoded]
        var cbp = 0, i16Mode = 0
        var modes = [Int](repeating: 2, count: 16)
        let constrained = pps.constrainedIntraPred
        if mbType == 0 {
            var t8 = false
            if pps.transform8x8Mode { t8 = try e.transform8x8(ctxInc: transformCtx(mb, slice: slice)) }
            kind.insert(t8 ? [.intra8x8, .transform8x8] : .intra4x4)
            st.kind[mb] = kind
            if t8 {
                for b8 in 0 ..< 4 {
                    let raster = (b8 >> 1) * 8 + (b8 & 1) * 2
                    let pred = predictedIntraMode(mb, raster, slice: slice, constrained: constrained)
                    var mode = pred
                    if !(try e.prevIntraMode()) { let rem = try e.remIntraMode(); mode = rem < pred ? rem : rem + 1 }
                    for k in [0, 1, 4, 5] { modes[raster + k] = mode; st.intraModes[mb * 16 + raster + k] = Int8(mode) }
                }
            } else {
                for k in 0 ..< 16 {
                    let raster = blkIdxToRaster[k]
                    let pred = predictedIntraMode(mb, raster, slice: slice, constrained: constrained)
                    var mode = pred
                    if !(try e.prevIntraMode()) { let rem = try e.remIntraMode(); mode = rem < pred ? rem : rem + 1 }
                    modes[raster] = mode
                    st.intraModes[mb * 16 + raster] = Int8(mode)
                }
            }
        } else {
            kind.insert(.intra16x16)
            st.kind[mb] = kind
            i16Mode = (mbType - 1) % 4
            st.i16Mode[mb] = UInt8(i16Mode)
            cbp = (((mbType - 1) / 4) % 3) << 4 | (mbType >= 13 ? 15 : 0)
        }
        func chromaCond(_ n: Int?) -> Int { n.map { st.kind[$0].isIntra && !st.kind[$0].contains(.pcm) && st.chromaPredMode[$0] != 0 ? 1 : 0 } ?? 0 }
        let chromaMode = try e.chromaPredMode(ctxInc: chromaCond(neighbour(mb, 0, slice: slice)) + chromaCond(neighbour(mb, 1, slice: slice)))
        st.chromaPredMode[mb] = UInt8(chromaMode)
        if mbType == 0 {
            cbp = try e.cbp(intra: true, left: cbpForContext(neighbour(mb, 0, slice: slice)), top: cbpForContext(neighbour(mb, 1, slice: slice)))
        }
        st.cbp[mb] = UInt8(cbp)
        if cbp != 0 || kind.contains(.intra16x16) {
            qp = (qp + (try e.qpDelta()) + 52) % 52
        } else {
            e.noQpDelta()
        }
        setQP(mb, qp, pps)
        try parseResidual(mb, cbp: cbp, &e, intra: true, slice: slice)
        _ = modes
        _ = i16Mode
    }

    // MARK: residual

    /// residual(): the levels into the macroblock's level store (raster within each block;
    /// see MBState.levels).
    mutating func parseResidual<E: H264Entropy>(_ mb: Int, cbp: Int, _ e: inout E, intra: Bool, slice: Int32) throws(ParseFailure) {
        let base = st.levelBase(mb)
        let zz = H264SPS.zigzag4
        let kind = st.kind[mb]
        var lv = [Int32](repeating: 0, count: 64)
        if kind.contains(.intra16x16) {
            for i in 0 ..< 16 { lv[i] = 0 }
            let n = try e.residual(cat: 0, nC: E.isCABAC ? 0 : lumaNC(mb, 0, slice: slice), cbfInc: E.isCABAC ? dcCbfInc(mb, bit: 0, intra: intra, slice: slice) : nil, maxNumCoeff: 16, into: &lv)
            if n > 0 { st.codedDC[mb] |= 1 }
            for k in 0 ..< 16 { st.levels[base + 384 + zz[k]] = lv[k] }
        }
        let t8 = kind.contains(.transform8x8)
        for b8 in 0 ..< 4 {
            let rasterBase = (b8 >> 1) * 8 + (b8 & 1) * 2
            guard cbp & (1 << b8) != 0 else { continue }
            if t8 {
                for i in 0 ..< 64 { st.levels[base + b8 * 64 + i] = 0 }
                if E.isCABAC {
                    for i in 0 ..< 64 { lv[i] = 0 }
                    let n = try e.residual(cat: 5, nC: 0, cbfInc: nil, maxNumCoeff: 64, into: &lv)
                    for j in 0 ..< 64 { st.levels[base + b8 * 64 + H264SPS.zigzag8[j]] = lv[j] }
                    for k in [0, 1, 4, 5] { st.nnz[mb * 24 + rasterBase + k] = UInt8(n) }
                    continue
                }
            }
            for k in 0 ..< 4 {
                let blk = rasterBase + [0, 1, 4, 5][k]
                for i in 0 ..< 16 { lv[i] = 0 }
                let i16 = kind.contains(.intra16x16)
                let n = try e.residual(cat: i16 ? 1 : 2, nC: E.isCABAC ? 0 : lumaNC(mb, blk, slice: slice),
                                       cbfInc: E.isCABAC ? lumaCbfInc(mb, blk, intra: intra, slice: slice) : nil, maxNumCoeff: i16 ? 15 : 16, into: &lv)
                st.nnz[mb * 24 + blk] = UInt8(n)
                if i16 {
                    st.levels[base + blk * 16] = 0
                    for j in 0 ..< 15 { st.levels[base + blk * 16 + zz[j + 1]] = lv[j] }
                } else if t8 {
                    for j in 0 ..< 16 { st.levels[base + b8 * 64 + H264SPS.zigzag8[4 * j + k]] = lv[j] }
                } else {
                    for j in 0 ..< 16 { st.levels[base + blk * 16 + zz[j]] = lv[j] }
                }
            }
        }
        if cbp >> 4 != 0 {
            for c in 0 ..< 2 {
                for i in 0 ..< 4 { lv[i] = 0 }
                let n = try e.residual(cat: 3, nC: -1, cbfInc: E.isCABAC ? dcCbfInc(mb, bit: 1 + c, intra: intra, slice: slice) : nil, maxNumCoeff: 4, into: &lv)
                if n > 0 { st.codedDC[mb] |= UInt8(2 << c) }
                for i in 0 ..< 4 { st.levels[base + 400 + c * 4 + i] = lv[i] }
            }
        }
        if cbp >> 4 == 2 {
            for c in 0 ..< 2 {
                for b in 0 ..< 4 {
                    for i in 0 ..< 15 { lv[i] = 0 }
                    let n = try e.residual(cat: 4, nC: E.isCABAC ? 0 : chromaNC(mb, c, b, slice: slice),
                                           cbfInc: E.isCABAC ? chromaCbfInc(mb, c, b, intra: intra, slice: slice) : nil, maxNumCoeff: 15, into: &lv)
                    st.nnz[mb * 24 + 16 + c * 4 + b] = UInt8(n)
                    let o = base + 256 + c * 64 + b * 16
                    st.levels[o] = 0
                    for j in 0 ..< 15 { st.levels[o + zz[j + 1]] = lv[j] }
                }
            }
        }
    }

    // MARK: inter

    /// A P (pType 0…4) or B (bType 0…22) macroblock.
    mutating func decodeInter<E: H264Entropy>(_ mb: Int, pType: Int, bType: Int, _ e: inout E, _ h: H264SliceHeader, _ pps: H264PPS, _ dq: H264Dequant, _ qp: inout Int, slice: Int32, refs: SliceRefs) throws(ParseFailure) {
        var kind: MBKind = [.inter, .decoded]
        st.motion.intra[mb] = false
        let isB = bType >= 0
        let numRef = [h.numRefIdxActive.l0, h.numRefIdxActive.l1]
        var noSubSmallerThan8x8 = true
        var parts: [InterPart] = []
        var subTypes = [Int](repeating: 0, count: 4)
        if !isB && pType < 3 {
            for (k, p) in pPartitions[pType].enumerated() {
                parts.append(InterPart(x: p.x, y: p.y, w: p.w, h: p.h, pred: 1, shape: pType == 1 ? 1 + k : pType == 2 ? 3 + k : 0, sub: -1))
            }
        } else if isB && bType == 0 {
            kind.insert(.direct16x16)
            if !sps.direct8x8Inference { noSubSmallerThan8x8 = false }
        } else if isB && bType < 22 {
            let t = bMBTypes[bType]
            for (k, p) in pPartitions[t.shape].enumerated() {
                parts.append(InterPart(x: p.x, y: p.y, w: p.w, h: p.h, pred: t.pred[k], shape: t.shape == 1 ? 1 + k : t.shape == 2 ? 3 + k : 0, sub: -1))
            }
        } else {
            kind.insert(.p8x8)
            for k in 0 ..< 4 {
                subTypes[k] = try e.subMbType(b: isB)
                if isB {
                    if subTypes[k] == 0 { st.directSub[mb * 4 + k] = 1; if !sps.direct8x8Inference { noSubSmallerThan8x8 = false } }
                    else if bSubTypes[subTypes[k]].layout != 0 { noSubSmallerThan8x8 = false }
                } else if subTypes[k] != 0 { noSubSmallerThan8x8 = false }
            }
            for k in 0 ..< 4 {
                let layout = isB ? bSubTypes[subTypes[k]].layout : subTypes[k]
                let pred = isB ? bSubTypes[subTypes[k]].pred : 1
                for sp in pSubPartitions[layout] {
                    parts.append(InterPart(x: (k & 1) * 8 + sp.x, y: (k >> 1) * 8 + sp.y, w: sp.w, h: sp.h, pred: pred, shape: 0, sub: k))
                }
            }
        }
        st.kind[mb] = kind
        // ref_idx per partition (8x8 sub-macroblocks share theirs), per list.
        var refIdx = [[Int]](repeating: [0, 0], count: parts.count)
        let refOnce = kind.contains(.p8x8)
        for l in 0 ..< 2 {
            var seen = Set<Int>()
            for (k, p) in parts.enumerated() where p.pred & (1 << l) != 0 {
                if refOnce {
                    if let first = parts.firstIndex(where: { $0.sub == p.sub }), first != k { refIdx[k][l] = refIdx[first][l]; continue }
                    guard !seen.contains(p.sub) else { continue }
                    seen.insert(p.sub)
                }
                if numRef[l] > 1 && !(pType == 4) {
                    let (bx, by, bw, bh) = refOnce ? ((p.sub & 1) * 8, (p.sub >> 1) * 8, 8, 8) : (p.x, p.y, p.w, p.h)
                    let r = try e.refIdx(ctxInc: E.isCABAC ? refIdxCtx(mb, x: bx, y: by, list: l, slice: slice, bSlice: isB) : 0, numRef: numRef[l])
                    refIdx[k][l] = r
                    storeRefIdx(mb, x: bx, y: by, w: bw, h: bh, list: l, r)
                } else if refOnce || true {
                    let (bx, by, bw, bh) = refOnce ? ((p.sub & 1) * 8, (p.sub >> 1) * 8, 8, 8) : (p.x, p.y, p.w, p.h)
                    storeRefIdx(mb, x: bx, y: by, w: bw, h: bh, list: l, 0)
                }
            }
        }
        // mvd per partition, per list.
        var mvd = [[(Int, Int)]](repeating: [(0, 0), (0, 0)], count: parts.count)
        for l in 0 ..< 2 {
            for (k, p) in parts.enumerated() where p.pred & (1 << l) != 0 {
                let dx = try e.mvd(comp: 0, absSum: E.isCABAC ? mvdAbsSum(mb, x: p.x, y: p.y, list: l, comp: 0, slice: slice) : 0)
                let dy = try e.mvd(comp: 1, absSum: E.isCABAC ? mvdAbsSum(mb, x: p.x, y: p.y, list: l, comp: 1, slice: slice) : 0)
                mvd[k][l] = (dx, dy)
                storeMvd(mb, x: p.x, y: p.y, w: p.w, h: p.h, list: l, (dx, dy))
            }
        }
        // Motion derivation and prediction, in partition order (direct 8x8s in their turn).
        for l in 0 ..< 2 { for b in 0 ..< 4 { st.motion.refIdx[(l) * st.motion.n4 + mb * 4 + b] = -1 } }
        var done: UInt16 = 0
        if isB && bType == 0 {
            let d = try directMotion(mb, h, slice: slice, refs: refs.lists, currentPOC: refs.currentPOC)
            try applyDirect(mb, d, mask: 0xFFFF, h, pps, refs: refs.lists, currentPOC: refs.currentPOC)
        } else {
            var direct: DirectMotions?
            var directDone = Set<Int>()
            for (k, p) in parts.enumerated() {
                if p.pred == 0 {
                    guard !directDone.contains(p.sub) else { continue }
                    directDone.insert(p.sub)
                    if direct == nil { direct = try directMotion(mb, h, slice: slice, refs: refs.lists, currentPOC: refs.currentPOC) }
                    let mask: UInt16 = p.sub == 0 ? 0x0033 : p.sub == 1 ? 0x00CC : p.sub == 2 ? 0x3300 : 0xCC00
                    try applyDirect(mb, direct!, mask: mask, h, pps, refs: refs.lists, currentPOC: refs.currentPOC)
                    done |= mask
                    continue
                }
                if isB {
                    try predictBPartition(mb, x: p.x, y: p.y, w: p.w, h: p.h, pred: p.pred, refIdx: refIdx[k], mvd: mvd[k], shape: p.shape, done: &done,
                                          hdr: h, pps, slice: slice, refs: refs.lists, currentPOC: refs.currentPOC)
                } else {
                    let r = refIdx[k][0]
                    guard r < refs.lists[0].count, let ref = refs.lists[0][r] else { throw ParseFailure(offset: 0, rule: "ref_idx_l0", reason: .invalid("no reference picture \(r)")) }
                    let (px, py) = predictMV(mb, x: p.x, y: p.y, w: p.w, refIdx: r, list: 0, shape: p.shape, done: done, slice: slice)
                    let mvx = px + mvd[k][0].0, mvy = py + mvd[k][0].1
                    setMotion(mb, x: p.x, y: p.y, w: p.w, h: p.h, list: 0, refIdx: r, mvx: mvx, mvy: mvy, ref: ref)
                    for by in stride(from: p.y, to: p.y + p.h, by: 4) { for bx in stride(from: p.x, to: p.x + p.w, by: 4) { done |= 1 << UInt16((by >> 2) * 4 + (bx >> 2)) } }
                    addPart(mb, x: p.x, y: p.y, w: p.w, h: p.h)
                }
            }
        }
        // Residual.
        let cbp = try e.cbp(intra: false, left: cbpForContext(neighbour(mb, 0, slice: slice)), top: cbpForContext(neighbour(mb, 1, slice: slice)))
        if cbp & 15 != 0 && pps.transform8x8Mode && noSubSmallerThan8x8 {
            if try e.transform8x8(ctxInc: transformCtx(mb, slice: slice)) { kind.insert(.transform8x8) }
        }
        st.kind[mb] = kind
        st.cbp[mb] = UInt8(cbp)
        if cbp != 0 { qp = (qp + (try e.qpDelta()) + 52) % 52 } else { e.noQpDelta() }
        setQP(mb, qp, pps)
        guard cbp != 0 else { return }
        try parseResidual(mb, cbp: cbp, &e, intra: false, slice: slice)
    }
}
