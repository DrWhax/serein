// MPEG-1/2/2.5 Layer III decoder (ISO/IEC 11172-3 2.4.3.4, 13818-3): side information,
// the bit reservoir, scalefactors (MPEG-1 with scfsi, LSF partitions incl. intensity
// stereo), Huffman big-values / count1 decoding, requantisation, M/S and intensity stereo,
// short-block reordering, alias reduction, IMDCT (36/12) with overlap, frequency inversion and
// the 32-band polyphase synthesis filterbank. Output: Float in [-1, 1], one array per channel.
//
//   side_info (MPEG-1) := main_data_begin:9 private:5|3 (scfsi:4){nch} (granule){2·nch}
//   side_info (LSF)    := main_data_begin:8 private:1|2 (granule){nch}
//   granule := part2_3_length:12 big_values:9{≤288} global_gain:8 scalefac_compress:4|9
//              window_switching:1 ( block_type:2{≠0} mixed:1 table_select:5{2} subblock_gain:3{3}
//                                 | table_select:5{3} region0_count:4 region1_count:3 )
//              [MPEG-1: preflag:1] scalefac_scale:1 count1table_select:1
//
// The reservoir and the handling of streams that over- or under-run their part2_3_length
// follow FFmpeg's decoder, so damaged streams sound the same as in other players. Every
// read is bounded: big_values ≤ 288, regions ≤ 576 lines, count1 stops at line 572, bits
// past the data read as zeros and stop at the granule's declared end.

public import CodecCore

public struct MP3Decoder: Sendable {
    /// Samples the decoder delays its output by (the hybrid filterbank: 528 + 1).
    public static let decoderDelay = 529

    public let lsf: Bool

    struct Granule: Sendable {
        var part23Length = 0, bigValues = 0, globalGain = 0, scalefacCompress = 0
        var blockType = 0, switchPoint = false
        var tableSelect = [0, 0, 0], subblockGain = [0, 0, 0]
        var regionSize = [0, 0, 0]
        var preflag = 0, scalefacScale = 0, count1Table = 0
        var scfsi = 0
        var longEnd = 22, shortStart = 13
        var scaleFactors = [Int](repeating: 0, count: 40)
        var hybrid = [Float](repeating: 0, count: 576)
    }

    var reservoir: [UInt8] = []

    /// Which coding tools the decoded stream used (for tests and diagnostics).
    public struct Statistics: Sendable, Equatable {
        public var shortBlocks = 0, mixedBlocks = 0, startStopBlocks = 0
        public var midSideGranules = 0, intensityGranules = 0
        public var scfsiGranules = 0, count1TableB = 0, crcFrames = 0, lostGranules = 0
        /// Bit i set: Huffman table_select i was used for a non-empty region.
        public var tablesUsed: UInt32 = 0
    }
    public private(set) var statistics = Statistics()
    /// Per channel: the second halves of the last IMDCTs, 32 subbands × 18.
    var overlap: [[Float]]
    /// Per channel: the synthesis filterbank's V vector (1024) and its rotation.
    var synthesisV: [[Float]]
    var synthesisOffset: [Int]

    /// State is kept for two channels whatever the first frame says: a stream may switch
    /// between mono and stereo modes.
    public init(lsf: Bool) {
        self.lsf = lsf
        overlap = Array(repeating: Array(repeating: 0, count: 576), count: 2)
        synthesisV = Array(repeating: Array(repeating: 0, count: 1024), count: 2)
        synthesisOffset = [0, 0]
    }

    public init(for stream: MP3Stream) {
        self.init(lsf: stream.frames.first?.header.lsf ?? false)
    }

    /// Decodes a frame into a fixed channel layout: a mono frame in a stereo stream plays on
    /// both channels, a stereo frame in a mono stream is averaged.
    public mutating func decode(_ frame: MP3Frame, channels: Int) throws(ParseFailure) -> [[Float]] {
        let pcm = try decode(frame)
        if pcm.count == channels { return pcm }
        if channels == 2 { return [pcm[0], pcm[0]] }
        return [zip(pcm[0], pcm[1]).map { ($0 + $1) * 0.5 }]
    }

    // MARK: tables

    static let huffman: [PrefixCodeTable?] = (0 ..< 16).map { i in
        i == 0 ? nil : PrefixCodeTable(codes: MP3Tables.huffCodes[i], lengths: MP3Tables.huffLengths[i], symbols: MP3Tables.huffSymbols[i])
    }
    static let quad: [PrefixCodeTable] = (0 ..< 2).map {
        PrefixCodeTable(codes: MP3Tables.quadCodes[$0], lengths: MP3Tables.quadBits[$0], rootBits: 6)
    }
    /// |q|^(4/3) for q ≤ 15 + 8191.
    static let pow43: [Float] = (0 ..< 8207).map { Float(LibM.pow(Double($0), 4.0 / 3.0)) }
    /// 2^((e − 400)/4) for the exponents FFmpeg forms (gain − scalefactors + 400).
    static let pow2: [Float] = (0 ..< 512).map { Float(LibM.pow(2.0, (Double($0) - 400) / 4)) }
    /// Band boundaries (in lines) from the sizes.
    static let bandIndexLong: [[Int]] = MP3Tables.bandSizeLong.map { sizes in
        var k = 0
        return [0] + sizes.map { k += Int($0); return k }
    }
    static let isRatio: [(Float, Float)] = (0 ..< 7).map { i in
        if i == 6 { return (1, 0) }
        let t = LibM.tan(Double(i) * Double.pi / 12)
        return (Float(t / (1 + t)), Float(1 / (1 + t)))
    }
    /// LSF intensity: [scalefac_compress & 1][is_pos] → (left, right).
    static let isRatioLSF: [[(Float, Float)]] = (0 ..< 2).map { j in
        (0 ..< 16).map { i in
            let f = Float(LibM.pow(2.0, Double(-(j + 1) * ((i + 1) >> 1)) / 4))
            return i & 1 == 1 ? (f, 1) : (1, f)
        }
    }
    static let antialias: [(cs: Float, ca: Float)] = [-0.6, -0.535, -0.33, -0.185, -0.095, -0.041, -0.0142, -0.0037].map { c in
        let d = (1 + c * c).squareRoot()
        return (Float(1 / d), Float(c / d))
    }
    static let imdctLongCos: [Float] = (0 ..< 36 * 18).map { idx in
        let i = idx / 18, k = idx % 18
        return Float(LibM.cos(Double.pi / 72 * Double(2 * i + 1 + 18) * Double(2 * k + 1)))
    }
    static let imdctShortCos: [Float] = (0 ..< 12 * 6).map { idx in
        let i = idx / 6, k = idx % 6
        return Float(LibM.cos(Double.pi / 24 * Double(2 * i + 1 + 6) * Double(2 * k + 1)))
    }
    /// Long windows by block type 0, 1, 3 (index 2 unused) and the short window.
    static let windows: [[Float]] = (0 ..< 4).map { t in
        (0 ..< 36).map { i in
            let sine = Float(LibM.sin(Double.pi / 36 * (Double(i) + 0.5)))
            let shortSlope = { (j: Int) in Float(LibM.sin(Double.pi / 12 * (Double(j) + 0.5))) }
            switch t {
            case 1: return i < 18 ? sine : i < 24 ? 1 : i < 30 ? shortSlope(i - 18) : 0
            case 3: return i < 6 ? 0 : i < 12 ? shortSlope(i - 6) : i < 18 ? 1 : sine
            default: return sine
            }
        }
    }
    static let shortWindow: [Float] = (0 ..< 12).map { Float(LibM.sin(Double.pi / 12 * (Double($0) + 0.5))) }
    /// N[i][k] = cos((16 + i)(2k + 1)π/64).
    static let synthesisMatrix: [Float] = (0 ..< 64 * 32).map { idx in
        let i = idx / 32, k = idx % 32
        return Float(LibM.cos(Double(16 + i) * Double(2 * k + 1) * Double.pi / 64))
    }
    static let synthesisWindow: [Float] = (0 ..< 512).map { i in
        let half = MP3Tables.synthesisWindowHalf
        let v: Int32 = i <= 256 ? half[i] : (i % 64 == 0 ? half[512 - i] : -half[512 - i])
        return Float(v) / 65536
    }

    func fail(_ rule: String, _ why: String) -> ParseFailure { ParseFailure(offset: 0, rule: rule, reason: .invalid(why)) }

    // MARK: frame

    /// Decodes one frame → `channels` arrays of 1152 (MPEG-1) or 576 (LSF) samples.
    public mutating func decode(_ frame: MP3Frame) throws(ParseFailure) -> [[Float]] {
        let h = frame.header
        let channels = h.channels
        guard h.lsf == lsf else { throw fail("mp3.header", "MPEG version changed mid-stream") }
        let bytes = frame.bytes.copyBytes()
        let sideStart = 4 + (h.hasCRC ? 2 : 0)
        let mainStart = sideStart + h.sideInfoLength
        guard bytes.count >= mainStart, bytes.count <= h.frameLength else { throw fail("mp3.frame", "frame shorter than its side information") }

        // Side information.
        var c = MSBBitCursor(bytes, bitPosition: sideStart * 8)
        let mainDataBegin = Int(c.bits(lsf ? 8 : 9))
        c.skip(lsf ? channels : (channels == 2 ? 3 : 5), "private_bits")
        let nGranules = lsf ? 1 : 2
        var granules = Array(repeating: Array(repeating: Granule(), count: nGranules), count: channels)
        if !lsf { for ch in 0 ..< channels { granules[ch][1].scfsi = Int(c.bits(4)) } }
        if h.hasCRC { statistics.crcFrames += 1 }
        let joint = h.mode == .jointStereo && channels == 2
        let msStereo = joint && h.modeExtension & 2 != 0
        let intensity = joint && h.modeExtension & 1 != 0
        for gr in 0 ..< nGranules {
            for ch in 0 ..< channels {
                var g = granules[ch][gr]
                g.part23Length = Int(c.bits(12))
                g.bigValues = Int(c.bits(9))
                guard g.bigValues <= 288 else { throw fail("granule.big_values", "\(g.bigValues) > 288") }
                g.globalGain = Int(c.bits(8))
                // M/S only: the 1/√2 of the M/S matrix folded into the gain (as FFmpeg does).
                if msStereo && !intensity { g.globalGain -= 2 }
                g.scalefacCompress = Int(c.bits(lsf ? 9 : 4))
                if c.bit() == 1 {
                    g.blockType = Int(c.bits(2))
                    guard g.blockType != 0 else { throw fail("granule.block_type", "0 with window switching") }
                    g.switchPoint = c.bit() == 1
                    g.tableSelect = [Int(c.bits(5)), Int(c.bits(5)), 0]
                    g.subblockGain = [Int(c.bits(3)), Int(c.bits(3)), Int(c.bits(3))]
                    let r = h.sampleRateIndex
                    let region0 = g.blockType == 2 ? (r == 8 ? 36 : 18) : (r <= 2 ? 18 : r != 8 ? 27 : 54)
                    g.regionSize = [region0, 288, 288]
                } else {
                    g.tableSelect = [Int(c.bits(5)), Int(c.bits(5)), Int(c.bits(5))]
                    let ra1 = Int(c.bits(4)), ra2 = Int(c.bits(3))
                    let idx = Self.bandIndexLong[h.sampleRateIndex]
                    g.regionSize = [idx[ra1 + 1] / 2, idx[min(ra1 + ra2 + 2, 22)] / 2, 288]
                }
                // Region ends → sizes, truncated to big_values.
                var prev = 0
                for i in 0 ..< 3 {
                    let k = min(g.regionSize[i], g.bigValues)
                    g.regionSize[i] = k - prev
                    prev = k
                }
                if g.blockType == 2 {
                    g.longEnd = g.switchPoint ? (h.sampleRateIndex <= 2 ? 8 : 6) : 0
                    g.shortStart = g.switchPoint ? 3 : 0
                }
                if !lsf { g.preflag = Int(c.bit()) }
                g.scalefacScale = Int(c.bit())
                g.count1Table = Int(c.bit())
                granules[ch][gr] = g
                switch g.blockType {
                case 2: if g.switchPoint { statistics.mixedBlocks += 1 } else { statistics.shortBlocks += 1 }
                case 1, 3: statistics.startStopBlocks += 1
                default: break
                }
                if g.scfsi != 0 && gr == 1 { statistics.scfsiGranules += 1 }
                statistics.count1TableB += g.count1Table
                for i in 0 ..< 3 where g.regionSize[i] > 0 { statistics.tablesUsed |= 1 << UInt32(g.tableSelect[i]) }
            }
        }
        if msStereo { statistics.midSideGranules += nGranules }
        if intensity { statistics.intensityGranules += nGranules }

        // Main data: the reservoir followed by this frame's bytes.
        let buffer = reservoir + bytes[mainStart...]
        let bufferBits = buffer.count * 8
        var samples = Array(repeating: [Float](repeating: 0, count: 576 * nGranules), count: channels)
        var gr = 0
        var lastBits = reservoir.count * 8
        // Granules whose data starts before what we hold are lost (the stream's start or a
        // gap): their output is only the previous overlap.
        while gr < nGranules && lastBits >> 3 < mainDataBegin {
            statistics.lostGranules += 1
            for ch in 0 ..< channels {
                lastBits += granules[ch][gr].part23Length
                granules[ch][gr].hybrid = Array(repeating: 0, count: 576)
                imdct(granules[ch][gr], channel: ch, into: &samples[ch], granule: gr)
            }
            gr += 1
        }
        var position = lastBits - 8 * mainDataBegin
        while gr < nGranules {
            for ch in 0 ..< channels {
                let start = position
                var cur = MSBBitCursor(buffer, bitPosition: max(0, start))
                readScaleFactors(&granules[ch], gr: gr, ch: ch, cursor: &cur, intensity: intensity)
                let exponents = exponentsFor(granules[ch][gr], sampleRateIndex: h.sampleRateIndex)
                let end2 = start + granules[ch][gr].part23Length
                huffmanDecode(&granules[ch][gr], exponents: exponents, cursor: &cur, end2: end2, endLimit: min(end2, bufferBits))
                position = end2
            }
            if joint {
                var left = granules[0][gr], right = granules[1][gr]
                stereo(&left, &right, ms: msStereo, intensity: intensity, sampleRateIndex: h.sampleRateIndex)
                granules[0][gr] = left
                granules[1][gr] = right
            }
            for ch in 0 ..< channels {
                reorder(&granules[ch][gr], sampleRateIndex: h.sampleRateIndex)
                antialias(&granules[ch][gr])
                imdct(granules[ch][gr], channel: ch, into: &samples[ch], granule: gr)
            }
            gr += 1
        }

        // Keep what follows the last granule (byte-aligned) for the next frames.
        let keepFrom = (max(0, position) + 7) / 8
        if keepFrom <= buffer.count {
            reservoir = Array(buffer[keepFrom...].suffix(512))
        } else {
            reservoir = Array(bytes[mainStart...].suffix(512))
        }

        // Synthesis: `samples` holds 18·granules time slots × 32 subbands per channel.
        var out = Array(repeating: [Float](repeating: 0, count: 576 * nGranules), count: channels)
        for ch in 0 ..< channels {
            for slot in 0 ..< 18 * nGranules {
                synthesize(samples[ch], slot: slot, channel: ch, into: &out[ch])
            }
        }
        return out
    }

    // MARK: scalefactors

    mutating func readScaleFactors(_ chGranules: inout [Granule], gr: Int, ch: Int, cursor c: inout MSBBitCursor, intensity: Bool) {
        var g = chGranules[gr]
        var sf = [Int](repeating: 0, count: 40)
        if !lsf {
            let slen1 = Int(MP3Tables.slen[0][g.scalefacCompress]), slen2 = Int(MP3Tables.slen[1][g.scalefacCompress])
            var j = 0
            if g.blockType == 2 {
                let n = g.switchPoint ? 17 : 18
                for _ in 0 ..< n { sf[j] = Int(c.bits(slen1)); j += 1 }
                for _ in 0 ..< 18 { sf[j] = Int(c.bits(slen2)); j += 1 }
            } else {
                let previous = chGranules[0].scaleFactors
                for k in 0 ..< 4 {
                    let n = k == 0 ? 6 : 5
                    if g.scfsi & (8 >> k) == 0 || gr == 0 {
                        let slen = k < 2 ? slen1 : slen2
                        for _ in 0 ..< n { sf[j] = Int(c.bits(slen)); j += 1 }
                    } else {
                        for _ in 0 ..< n { sf[j] = previous[j]; j += 1 }
                    }
                }
            }
        } else {
            let kind = g.blockType == 2 ? (g.switchPoint ? 2 : 1) : 0
            var slen = [0, 0, 0, 0]
            var table: Int
            func expand(_ v: Int, _ n1: Int, _ n2: Int, _ n3: Int) {
                var v = v
                if n3 != 0 { slen[3] = v % n3; v /= n3 } else { slen[3] = 0 }
                if n2 != 0 { slen[2] = v % n2; v /= n2 } else { slen[2] = 0 }
                if n1 != 0 { slen[1] = v % n1; v /= n1 } else { slen[1] = 0 }
                slen[0] = v
            }
            var v = g.scalefacCompress
            if intensity && ch == 1 {
                v >>= 1
                if v < 180 { expand(v, 6, 6, 0); table = 3 }
                else if v < 244 { expand(v - 180, 4, 4, 0); table = 4 }
                else { expand(v - 244, 3, 0, 0); table = 5 }
            } else {
                if v < 400 { expand(v, 5, 4, 4); table = 0 }
                else if v < 500 { expand(v - 400, 5, 4, 0); table = 1 }
                else { expand(v - 500, 3, 0, 0); table = 2; g.preflag = 1 }
            }
            var j = 0
            for k in 0 ..< 4 {
                for _ in 0 ..< Int(MP3Tables.lsfPartitions[table][kind][k]) where j < 40 {
                    sf[j] = Int(c.bits(slen[k])); j += 1
                }
            }
        }
        g.scaleFactors = sf
        chGranules[gr] = g
    }

    /// Per line: gain − scalefactor·2^(scale+1) (− subblock gain·8) + 400, as FFmpeg's
    /// exponents_from_scale_factors.
    func exponentsFor(_ g: Granule, sampleRateIndex r: Int) -> [Int] {
        var e = [Int](repeating: 0, count: 576)
        var p = 0
        let gain = g.globalGain - 210, shift = g.scalefacScale + 1
        for i in 0 ..< g.longEnd {
            let v = gain - ((g.scaleFactors[i] + (g.preflag != 0 ? Int(MP3Tables.pretab[i]) : 0)) << shift) + 400
            for _ in 0 ..< Int(MP3Tables.bandSizeLong[r][i]) where p < 576 { e[p] = v; p += 1 }
        }
        if g.shortStart < 13 {
            let gains = g.subblockGain.map { gain - ($0 << 3) }
            var k = g.longEnd
            for i in g.shortStart ..< 13 {
                let len = Int(MP3Tables.bandSizeShort[r][i])
                for w in 0 ..< 3 {
                    let v = gains[w] - (g.scaleFactors[min(k, 39)] << shift) + 400
                    k += 1
                    for _ in 0 ..< len where p < 576 { e[p] = v; p += 1 }
                }
            }
        }
        return e.map { min(max($0, 0), 511) }
    }

    // MARK: Huffman

    func huffmanDecode(_ g: inout Granule, exponents: [Int], cursor c: inout MSBBitCursor, end2: Int, endLimit: Int) {
        var x = [Float](repeating: 0, count: 576)
        var s = 0
        func value(_ q: Int, _ line: Int) -> Float { Self.pow43[q] * Self.pow2[exponents[line]] }
        regions: for region in 0 ..< 3 {
            var pairs = g.regionSize[region]
            guard pairs > 0 else { continue }
            let tableSelect = g.tableSelect[region]
            let tableIndex = Int(MP3Tables.huffTable[tableSelect]), linbits = Int(MP3Tables.huffLinbits[tableSelect])
            guard let table = Self.huffman[tableIndex] else { s += 2 * pairs; continue }
            while pairs > 0 {
                pairs -= 1
                if c.bitPosition >= endLimit { break }
                let sym = (try? table.decode(&c, "big_values")) ?? 0
                var a = sym >> 4, b = sym & 15
                if a == 15 && linbits > 0 { a += Int(c.bits(linbits)) }
                if a != 0 { x[s] = c.bit() == 1 ? -value(a, s) : value(a, s) }
                if b == 15 && linbits > 0 { b += Int(c.bits(linbits)) }
                if b != 0 { x[s + 1] = c.bit() == 1 ? -value(b, s + 1) : value(b, s + 1) }
                s += 2
            }
            if c.bitPosition >= endLimit && pairs > 0 { continue regions }
        }
        // count1: quadruples of −1/0/+1 until the granule's bits or the spectrum run out.
        let quad = Self.quad[g.count1Table]
        var lastPosition: Int?
        while s <= 572 {
            let pos = c.bitPosition
            if pos >= endLimit {
                if pos > end2, let last = lastPosition {
                    // Some encoders overstate the last quadruple: drop it.
                    s -= 4
                    for i in 0 ..< 4 { x[s + i] = 0 }
                    c.bitPosition = last
                }
                break
            }
            lastPosition = pos
            let code = (try? quad.decode(&c, "count1")) ?? 0
            for i in 0 ..< 4 where code & (8 >> i) != 0 {
                let v = Self.pow2[exponents[s + i]]
                x[s + i] = c.bit() == 1 ? -v : v
            }
            s += 4
        }
        if s < 576 { for i in s ..< 576 { x[i] = 0 } }
        g.hybrid = x
    }

    // MARK: stereo

    func stereo(_ g0: inout Granule, _ g1: inout Granule, ms: Bool, intensity: Bool, sampleRateIndex r: Int) {
        let invSqrt2: Float = 0.70710678118654752440
        guard intensity else {
            if ms {
                for i in 0 ..< 576 {
                    let a = g0.hybrid[i], b = g1.hybrid[i]
                    g0.hybrid[i] = a + b
                    g1.hybrid[i] = a - b
                }
            }
            return
        }
        let sfMax = lsf ? 16 : 7
        func ratio(_ sf: Int) -> (Float, Float) { lsf ? Self.isRatioLSF[g1.scalefacCompress & 1][sf] : Self.isRatio[sf] }
        func msBand(_ start: Int, _ len: Int) {
            guard ms else { return }
            for j in start ..< start + len {
                let a = g0.hybrid[j], b = g1.hybrid[j]
                g0.hybrid[j] = (a + b) * invSqrt2
                g1.hybrid[j] = (a - b) * invSqrt2
            }
        }
        func isBand(_ start: Int, _ len: Int, _ sf: Int) {
            let (v1, v2) = ratio(sf)
            for j in start ..< start + len {
                let a = g0.hybrid[j]
                g0.hybrid[j] = a * v1
                g1.hybrid[j] = a * v2
            }
        }
        var top = 576
        var nonZeroShort = [false, false, false]
        var k = (13 - g1.shortStart) * 3 + g1.longEnd - 3
        if g1.shortStart < 13 {
            for i in stride(from: 12, through: g1.shortStart, by: -1) {
                if i != 11 { k -= 3 }
                let len = Int(MP3Tables.bandSizeShort[r][i])
                for l in stride(from: 2, through: 0, by: -1) {
                    top -= len
                    var found = nonZeroShort[l]
                    if !found {
                        if g1.hybrid[top ..< top + len].contains(where: { $0 != 0 }) {
                            nonZeroShort[l] = true; found = true
                        } else {
                            let sf = g1.scaleFactors[max(0, min(39, k + l))]
                            if sf >= sfMax { found = true } else { isBand(top, len, sf) }
                        }
                    }
                    if found { msBand(top, len) }
                }
            }
        }
        var nonZero = nonZeroShort.contains(true)
        for i in stride(from: g1.longEnd - 1, through: 0, by: -1) {
            let len = Int(MP3Tables.bandSizeLong[r][i])
            top -= len
            guard top >= 0 else { break }
            var found = nonZero
            if !found {
                if g1.hybrid[top ..< top + len].contains(where: { $0 != 0 }) {
                    nonZero = true; found = true
                } else {
                    let sf = g1.scaleFactors[i == 21 ? 20 : i]
                    if sf >= sfMax { found = true } else { isBand(top, len, sf) }
                }
            }
            if found { msBand(top, len) }
        }
    }

    // MARK: reorder, alias reduction, IMDCT

    /// Short blocks: bitstream order (band, window, line) → (band, line, window).
    func reorder(_ g: inout Granule, sampleRateIndex r: Int) {
        guard g.blockType == 2 else { return }
        var p = g.switchPoint ? (r != 8 ? 36 : 72) : 0
        for i in g.shortStart ..< 13 {
            let len = Int(MP3Tables.bandSizeShort[r][i])
            guard p + 3 * len <= 576 else { break }
            var tmp = [Float](repeating: 0, count: 3 * len)
            for j in 0 ..< len { for w in 0 ..< 3 { tmp[3 * j + w] = g.hybrid[p + w * len + j] } }
            for j in 0 ..< 3 * len { g.hybrid[p + j] = tmp[j] }
            p += 3 * len
        }
    }

    func antialias(_ g: inout Granule) {
        let n: Int
        if g.blockType == 2 {
            guard g.switchPoint else { return }
            n = 1
        } else {
            n = 31
        }
        for sb in 1 ... n {
            let base = 18 * sb
            for j in 0 ..< 8 {
                let a = g.hybrid[base - 1 - j], b = g.hybrid[base + j]
                let (cs, ca) = Self.antialias[j]
                g.hybrid[base - 1 - j] = a * cs - b * ca
                g.hybrid[base + j] = a * ca + b * cs
            }
        }
    }

    /// IMDCT of every subband, overlap-add, frequency inversion → `out[slot·32 + sb]`.
    mutating func imdct(_ g: Granule, channel ch: Int, into out: inout [Float], granule gr: Int) {
        // Subbands past the last non-zero line only release their overlap.
        var last = 575
        while last >= 36 && g.hybrid[last] == 0 { last -= 1 }
        let sblimit = max(2, last / 18 + 1)
        let longEnd = g.blockType == 2 ? (g.switchPoint ? 2 : 0) : sblimit
        var ov = overlap[ch]
        var z = [Float](repeating: 0, count: 36)
        for sb in 0 ..< 32 {
            for i in 0 ..< 36 { z[i] = 0 }
            if sb < sblimit {
                let base = sb * 18
                if sb < longEnd {
                    let w = Self.windows[g.switchPoint && sb < 2 ? 0 : g.blockType]
                    for i in 0 ..< 36 {
                        var acc: Float = 0
                        for k in 0 ..< 18 { acc += g.hybrid[base + k] * Self.imdctLongCos[i * 18 + k] }
                        z[i] = acc * w[i]
                    }
                } else {
                    for w in 0 ..< 3 {
                        for i in 0 ..< 12 {
                            var acc: Float = 0
                            for k in 0 ..< 6 { acc += g.hybrid[base + 3 * k + w] * Self.imdctShortCos[i * 6 + k] }
                            z[6 + 6 * w + i] += acc * Self.shortWindow[i]
                        }
                    }
                }
            }
            for i in 0 ..< 18 {
                var v = z[i] + ov[sb * 18 + i]
                if sb & 1 == 1 && i & 1 == 1 { v = -v }
                out[(gr * 18 + i) * 32 + sb] = v
                ov[sb * 18 + i] = z[18 + i]
            }
        }
        overlap[ch] = ov
    }

    // MARK: synthesis

    mutating func synthesize(_ subbands: [Float], slot: Int, channel ch: Int, into out: inout [Float]) {
        var v = synthesisV[ch]
        var off = synthesisOffset[ch]
        off = (off - 64) & 1023
        for i in 0 ..< 64 {
            var acc: Float = 0
            for k in 0 ..< 32 { acc += Self.synthesisMatrix[i * 32 + k] * subbands[slot * 32 + k] }
            v[(off + i) & 1023] = acc
        }
        for j in 0 ..< 32 {
            var sum: Float = 0
            for i in 0 ..< 8 {
                sum += v[(off + 128 * i + j) & 1023] * Self.synthesisWindow[64 * i + j]
                sum += v[(off + 128 * i + 96 + j) & 1023] * Self.synthesisWindow[64 * i + 32 + j]
            }
            out[slot * 32 + j] = sum
        }
        synthesisV[ch] = v
        synthesisOffset[ch] = off
    }
}
