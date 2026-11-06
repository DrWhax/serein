// The encoder's VBR quantiser (11172-3 2.4.3.4.7 in reverse, the approach of LAME's "mtrh"):
// for each scalefactor band, the coarsest exponent a (xr = ix^(4/3) · 2^((a − 210)/4)) whose
// quantisation noise stays within the band's allowed noise; then the global gain is the
// coarsest of them and the scalefactors (× 2 or × 4 with scalefac_scale, pretab with
// preflag) and short-block subblock gains make up the differences, within the slen limits
// (bands 0–10 / 0–5 short: ≤ 15, the rest ≤ 7) and the 8206 quantiser range. Bands whose
// energy is under their allowed noise are left empty.

import CodecCore

struct QuantisedGranule: Sendable {
    var xr: [Float]
    var blockType: Int
    var ix = [Int](repeating: 0, count: 576)       // bitstream order (short: band, window, line)
    var globalGain = 210
    var scaleFactors = [Int](repeating: 0, count: 39)   // long: 21; short: 12 bands × 3 windows
    var subblockGain = [0, 0, 0]
    var scalefacScale = 0
    var preflag = 0
    var scalefacCompress = 0
    var part2Bits = 0
    var layout = MP3HuffmanEncoder.Layout()
    var part23: Int { part2Bits + layout.bits }
}

enum MP3Quantiser {
    static let roundingBias: Float = 0.4054

    /// Quantised value of |x|^(3/4) at exponent a.
    @inline(__always) static func q(_ x34: Float, _ a: Int) -> Int {
        Int(x34 * Float(LibM.pow(2, -0.1875 * Double(a - 210))) + roundingBias)
    }

    /// Rounding thresholds in the x^(3/4) domain that pick the reconstruction level nearest in
    /// the linear domain (LAME's adj43): v rounds up past n + adj43[n].
    static let adj43: [Float] = (0 ..< 8207).map { n in
        let mid = 0.5 * (Double(MP3Decoder.pow43[n]) + Double(MP3Decoder.pow43[min(n + 1, 8206)]))
        return Float(LibM.pow(mid, 0.75) - Double(n))
    }

    /// The quantised value of v = |x|^(3/4) / step^(3/4) (nearest level in the linear domain).
    @inline(__always) static func level(_ v: Float) -> Int {
        let n = min(Int(v), 8206)
        return v - Float(n) >= adj43[n] ? min(n + 1, 8206) : n
    }

    static let inverseStep34: [Float] = (0 ..< 512).map { Float(LibM.pow(2, -0.1875 * (Double($0) - 210))) }
    static let step: [Float] = (0 ..< 512).map { Float(LibM.pow(2, 0.25 * (Double($0) - 210))) }

    /// Noise of the lines at exponent a, and the largest quantised value.
    static func noise(_ x: [Float], _ x34: [Float], _ lines: [Int], _ a: Int) -> (Double, Int) {
        let inv = inverseStep34[a], s = step[a]
        var n = 0.0, m = 0
        for i in lines {
            let v = level(x34[i] * inv)
            m = max(m, v)
            let rec = MP3Decoder.pow43[min(v, 8206)] * s
            let d = Double(x[i] - rec)
            n += d * d
        }
        return (n, m)
    }

    /// The coarsest exponent within `allowed` noise (nil: the band may be left empty), and
    /// the finest exponent the quantiser range permits.
    static func bandExponent(_ x: [Float], _ x34: [Float], _ lines: [Int], allowed: Double) -> (a: Int?, aMin: Int) {
        var energy = 0.0, peak34: Float = 0
        for i in lines { energy += Double(x[i]) * Double(x[i]); peak34 = max(peak34, x34[i]) }
        guard energy > allowed, peak34 > 0 else { return (nil, 0) }
        // ix ≤ 8206 ⇔ a ≥ 210 + 16/3 · log2(peak34 / 8205.6).
        let aMin = max(0, Int((210 + 16.0 / 3 * LibM.log10(Double(peak34) / 8205.6) / LibM.log10(2)).rounded(.up)))
        var lo = aMin, hi = 255
        if noise(x, x34, lines, lo).0 > allowed { return (lo, aMin) }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if noise(x, x34, lines, mid).0 <= allowed { lo = mid } else { hi = mid - 1 }
        }
        return (lo, aMin)
    }

    static func quantise(_ xr: [Float], blockType: Int, psycho: MP3Psychoacoustics, lsf: Bool, noiseBoostDB: Double) -> QuantisedGranule {
        var g = QuantisedGranule(xr: xr, blockType: blockType)
        let x = xr.map { abs($0) }
        let x34 = x.map { Float(LibM.pow(Double($0), 0.75)) }
        let boost = LibM.pow(10, noiseBoostDB / 10)
        let r = psycho.sampleRateIndex
        if blockType == 2 {
            quantiseShort(&g, x, x34, psycho: psycho, boost: boost, r: r)
        } else {
            quantiseLong(&g, x, x34, psycho: psycho, boost: boost, r: r, lsf: lsf)
        }
        g.layout = MP3HuffmanEncoder.layout(g.ix, blockType: blockType, sampleRateIndex: r)
        if g.part23 > 4095 {
            return quantise(xr, blockType: blockType, psycho: psycho, lsf: lsf, noiseBoostDB: noiseBoostDB + 3)
        }
        return g
    }

    static func quantiseLong(_ g: inout QuantisedGranule, _ x: [Float], _ x34: [Float], psycho: MP3Psychoacoustics, boost: Double, r: Int, lsf: Bool) {
        let bands = psycho.bands(short: false)
        let allowed = psycho.allowedNoise(g.xr, short: false).map { $0 * boost }
        var a = [Int?](repeating: nil, count: 22), aMin = [Int](repeating: 0, count: 22)
        for b in 0 ..< 22 {
            let e = bandExponent(x, x34, Array(bands[b].0 ..< bands[b].1), allowed: allowed[b])
            a[b] = e.a
            aMin[b] = e.aMin
        }
        guard var gg = a.compactMap({ $0 }).max() else { g.globalGain = 0; return }
        if let a21 = a[21] { gg = min(gg, a21) }
        // Scalefactor options: scale 0/1, preflag (MPEG-1 only), smallest part2 that fits.
        let limits = (0 ..< 21).map { $0 < 11 ? 15 : 7 }
        var best: (sf: [Int], scale: Int, pre: Int, gg: Int, bits: Int)?
        for scale in 0 ... 1 {
            for pre in 0 ... (lsf ? 0 : 1) {
                let shift = scale + 1
                var ggTry = gg
                // Lower the global gain until every band's need fits its limit (measured: at
                // equal bitrate this beats clipping the scalefactors by ≈ 1 dB SNR).
                for b in 0 ..< 21 {
                    if let ab = a[b] { ggTry = min(ggTry, ab + ((limits[b] + (pre == 1 ? Int(MP3Tables.pretab[b]) : 0)) << shift)) }
                }
                var sf = [Int](repeating: 0, count: 21)
                var ok = true
                for b in 0 ..< 21 {
                    guard let ab = a[b] else { continue }
                    let p = pre == 1 ? Int(MP3Tables.pretab[b]) : 0
                    let need = max(0, (ggTry - ab + (1 << shift) - 1) >> shift)
                    if pre == 1 && need < p { ok = false; break }
                    var v = max(0, need - p)
                    // Not finer than the quantiser range allows.
                    v = min(v, max(0, ((ggTry - aMin[b]) >> shift) - p))
                    sf[b] = min(v, limits[b])
                }
                guard ok else { continue }
                let bits = part2Long(sf, lsf: lsf).bits
                if best == nil || bits < best!.bits || (ggTry > best!.gg && bits <= best!.bits) { best = (sf, scale, pre, ggTry, bits) }
            }
        }
        guard let choice = best else { return }
        g.globalGain = choice.gg
        g.scalefacScale = choice.scale
        g.preflag = choice.pre
        for b in 0 ..< 21 { g.scaleFactors[b] = choice.sf[b] }
        let (compress, bits) = part2Long(choice.sf, lsf: lsf)
        g.scalefacCompress = compress
        g.part2Bits = bits
        let shift = choice.scale + 1
        for b in 0 ..< 22 {
            let p = (b < 21 && choice.pre == 1) ? Int(MP3Tables.pretab[b]) : 0
            let sfv = b < 21 ? choice.sf[b] : 0
            let ea = min(max(choice.gg - ((sfv + p) << shift), 0), 511)
            for i in bands[b].0 ..< bands[b].1 {
                if a[b] == nil { g.ix[i] = 0; continue }
                let v = level(x34[i] * inverseStep34[ea])
                g.ix[i] = g.xr[i] < 0 ? -v : v
            }
        }
    }

    static func quantiseShort(_ g: inout QuantisedGranule, _ x: [Float], _ x34: [Float], psycho: MP3Psychoacoustics, boost: Double, r: Int) {
        let bands = psycho.bands(short: true)
        // Lines of band b, window w in the analysis output (subband, line, window order):
        // short line k of window w lives at index (k / 6) · 18 + (k % 6) · 3 + w.
        func lines(_ b: Int, _ w: Int) -> [Int] { (bands[b].0 ..< bands[b].1).map { k in (k / 6) * 18 + (k % 6) * 3 + w } }
        var a = [[Int?]](repeating: [Int?](repeating: nil, count: 13), count: 3)
        var aMin = [[Int]](repeating: [Int](repeating: 0, count: 13), count: 3)
        for w in 0 ..< 3 {
            let window = (0 ..< 192).map { k in g.xr[(k / 6) * 18 + (k % 6) * 3 + w] }
            let allowed = psycho.allowedNoise(window, short: true).map { $0 * boost }
            for b in 0 ..< 13 {
                let e = bandExponent(x, x34, lines(b, w), allowed: allowed[b])
                a[w][b] = e.a
                aMin[w][b] = e.aMin
            }
        }
        guard let gg0 = a.flatMap({ $0 }).compactMap({ $0 }).max() else { g.globalGain = 0; return }
        let limits = (0 ..< 12).map { $0 < 6 ? 15 : 7 }
        var best: (sf: [Int], sbg: [Int], scale: Int, gg: Int, bits: Int)?
        for scale in 0 ... 1 {
            let shift = scale + 1
            var gg = gg0
            var sbg = [0, 0, 0]
            for w in 0 ..< 3 {
                let top = a[w].compactMap { $0 }.max() ?? gg
                sbg[w] = min(7, max(0, (gg - top) / 8))
            }
            // Band 12 has no scalefactor: its exponent is gg − 8·sbg.
            for w in 0 ..< 3 { if let a12 = a[w][12] { gg = min(gg, a12 + 8 * sbg[w]) } }
            for w in 0 ..< 3 { for b in 0 ..< 12 { if let ab = a[w][b] { gg = min(gg, ab + 8 * sbg[w] + (limits[b] << shift)) } } }
            var sf = [Int](repeating: 0, count: 36)
            for w in 0 ..< 3 {
                for b in 0 ..< 12 {
                    guard let ab = a[w][b] else { continue }
                    var need = max(0, (gg - 8 * sbg[w] - ab + (1 << shift) - 1) >> shift)
                    need = min(need, max(0, (gg - 8 * sbg[w] - aMin[w][b]) >> shift))
                    sf[b * 3 + w] = min(need, limits[b])
                }
            }
            let bits = part2Short(sf, lsf: psycho.sampleRateIndex >= 3).bits
            if best == nil || bits < best!.bits { best = (sf, sbg, scale, gg, bits) }
        }
        guard let c = best else { return }
        g.globalGain = c.gg
        g.subblockGain = c.sbg
        g.scalefacScale = c.scale
        for i in 0 ..< 36 { g.scaleFactors[i] = c.sf[i] }
        let lsf = psycho.sampleRateIndex >= 3
        let (compress, bits) = part2Short(c.sf, lsf: lsf)
        g.scalefacCompress = compress
        g.part2Bits = bits
        let shift = c.scale + 1
        // Bitstream order: band, window, line.
        var p = 0
        for b in 0 ..< 13 {
            for w in 0 ..< 3 {
                let sfv = b < 12 ? c.sf[b * 3 + w] : 0
                let ea = min(max(c.gg - 8 * c.sbg[w] - (sfv << shift), 0), 511)
                for i in lines(b, w) {
                    if a[w][b] == nil { g.ix[p] = 0 } else {
                        let v = level(x34[i] * inverseStep34[ea])
                        g.ix[p] = g.xr[i] < 0 ? -v : v
                    }
                    p += 1
                }
            }
        }
    }

    static func bitsFor(_ v: Int) -> Int { v == 0 ? 0 : (Int.bitWidth - v.leadingZeroBitCount) }

    /// scalefac_compress and part2 bits for long-block scalefactors.
    static func part2Long(_ sf: [Int], lsf: Bool, transmitted: [Bool] = [true, true, true, true]) -> (compress: Int, bits: Int) {
        if lsf {
            let parts = [0 ..< 6, 6 ..< 11, 11 ..< 16, 16 ..< 21]
            let s = parts.map { bitsFor($0.map { sf[$0] }.max() ?? 0) }
            let slen = [min(s[0], 4), min(s[1], 4), min(s[2], 3), min(s[3], 3)]
            let compress = ((slen[0] * 5 + slen[1]) * 4 + slen[2]) * 4 + slen[3]
            return (compress, 6 * slen[0] + 5 * slen[1] + 5 * slen[2] + 5 * slen[3])
        }
        let group = [0 ..< 6, 6 ..< 11, 11 ..< 16, 16 ..< 21]
        let m1 = (0 ..< 2).filter { transmitted[$0] }.flatMap { group[$0] }.map { sf[$0] }.max() ?? 0
        let m2 = (2 ..< 4).filter { transmitted[$0] }.flatMap { group[$0] }.map { sf[$0] }.max() ?? 0
        var best = (compress: 15, bits: Int.max)
        for c in 0 ..< 16 {
            let s1 = Int(MP3Tables.slen[0][c]), s2 = Int(MP3Tables.slen[1][c])
            guard m1 < 1 << s1, m2 < 1 << s2 else { continue }
            var bits = 0
            for k in 0 ..< 4 where transmitted[k] { bits += group[k].count * (k < 2 ? s1 : s2) }
            if bits < best.bits { best = (c, bits) }
        }
        return best
    }

    static func part2Short(_ sf: [Int], lsf: Bool) -> (compress: Int, bits: Int) {
        if lsf {
            let parts = [0 ..< 9, 9 ..< 18, 18 ..< 27, 27 ..< 36]
            let s = parts.map { bitsFor($0.map { sf[$0] }.max() ?? 0) }
            let slen = [min(s[0], 4), min(s[1], 4), min(s[2], 3), min(s[3], 3)]
            let compress = ((slen[0] * 5 + slen[1]) * 4 + slen[2]) * 4 + slen[3]
            return (compress, 9 * (slen[0] + slen[1] + slen[2] + slen[3]))
        }
        let m1 = sf[0 ..< 18].max() ?? 0, m2 = sf[18 ..< 36].max() ?? 0
        var best = (compress: 15, bits: Int.max)
        for c in 0 ..< 16 {
            let s1 = Int(MP3Tables.slen[0][c]), s2 = Int(MP3Tables.slen[1][c])
            guard m1 < 1 << s1, m2 < 1 << s2 else { continue }
            let bits = 18 * s1 + 18 * s2
            if bits < best.bits { best = (c, bits) }
        }
        return best
    }

    // MARK: bitstream

    /// The frame's main data (granules' scalefactors + Huffman data, byte-padded), with scfsi
    /// for MPEG-1 when granule 1 repeats granule 0's long-block scalefactor groups.
    static func mainData(_ granules: inout [QuantisedGranule], lsf: Bool, sampleRateIndex r: Int) -> (bytes: [UInt8], scfsi: Int) {
        var scfsi = 0
        if !lsf, granules.count == 2, granules[0].blockType != 2, granules[1].blockType != 2 {
            let group = [0 ..< 6, 6 ..< 11, 11 ..< 16, 16 ..< 21]
            var transmitted = [true, true, true, true]
            for k in 0 ..< 4 where group[k].allSatisfy({ granules[0].scaleFactors[$0] == granules[1].scaleFactors[$0] }) {
                scfsi |= 8 >> k
                transmitted[k] = false
            }
            if scfsi != 0 {
                let (c, bits) = part2Long(Array(granules[1].scaleFactors.prefix(21)), lsf: false, transmitted: transmitted)
                granules[1].scalefacCompress = c
                granules[1].part2Bits = bits
            }
        }
        var w = MSBBitWriter()
        for (gi, g) in granules.enumerated() {
            let start = w.bitCount
            writeScaleFactors(g, lsf: lsf, scfsi: gi == 1 ? scfsi : 0, to: &w)
            MP3HuffmanEncoder.write(g.ix, g.layout, blockType: g.blockType, sampleRateIndex: r, to: &w)
            precondition(w.bitCount - start == g.part23, "part2_3_length mismatch")
        }
        return (w.finish(), scfsi)
    }

    static func writeScaleFactors(_ g: QuantisedGranule, lsf: Bool, scfsi: Int, to w: inout MSBBitWriter) {
        if lsf {
            let c = g.scalefacCompress
            let slen = [c / 80, (c / 16) % 5, (c / 4) % 4, c % 4]
            let parts: [Range<Int>] = g.blockType == 2 ? [0 ..< 9, 9 ..< 18, 18 ..< 27, 27 ..< 36] : [0 ..< 6, 6 ..< 11, 11 ..< 16, 16 ..< 21]
            for (k, part) in parts.enumerated() {
                for i in part {
                    // Short blocks: the bitstream order is band-major (band, window).
                    w.write(g.scaleFactors[i], slen[k])
                }
            }
            return
        }
        let s1 = Int(MP3Tables.slen[0][g.scalefacCompress]), s2 = Int(MP3Tables.slen[1][g.scalefacCompress])
        if g.blockType == 2 {
            for i in 0 ..< 18 { w.write(g.scaleFactors[i], s1) }
            for i in 18 ..< 36 { w.write(g.scaleFactors[i], s2) }
            return
        }
        let group = [0 ..< 6, 6 ..< 11, 11 ..< 16, 16 ..< 21]
        for k in 0 ..< 4 where scfsi & (8 >> k) == 0 {
            for i in group[k] { w.write(g.scaleFactors[i], k < 2 ? s1 : s2) }
        }
    }

    static func writeSideInfo(_ granules: [QuantisedGranule], mainDataBegin: Int, scfsi: Int, lsf: Bool, to w: inout MSBBitWriter) {
        w.write(mainDataBegin, lsf ? 8 : 9)
        w.write(0, lsf ? 1 : 5)                         // private bits (mono)
        if !lsf { w.write(scfsi, 4) }
        for g in granules {
            w.write(g.part23, 12)
            w.write(g.layout.bigValues, 9)
            w.write(g.globalGain, 8)
            w.write(g.scalefacCompress, lsf ? 9 : 4)
            if g.blockType != 0 {
                w.write(1, 1)
                w.write(g.blockType, 2)
                w.write(0, 1)                           // no mixed blocks
                w.write(g.layout.tableSelect[0], 5)
                w.write(g.layout.tableSelect[1], 5)
                for s in g.subblockGain { w.write(s, 3) }
            } else {
                w.write(0, 1)
                for t in g.layout.tableSelect { w.write(t, 5) }
                w.write(g.layout.region0Count, 4)
                w.write(g.layout.region1Count, 3)
            }
            if !lsf { w.write(g.preflag, 1) }
            w.write(g.scalefacScale, 1)
            w.write(g.layout.count1Table, 1)
        }
    }
}
