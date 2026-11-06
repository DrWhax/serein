// AAC-LC decoder (ISO/IEC 14496-3 subpart 4): raw_data_block syntax (4.4.2), noiseless
// decoding (4.6.3), dequantisation, M/S and intensity stereo, PNS (4.6.13), TNS (4.6.9), pulse
// data, and the filterbank. One `decode` call per access unit (an MP4 sample or one ADTS
// raw_data_block): 1024 samples per channel, Float in [-1, 1].
//
// Syntax (bit fields, MSB first):
//   raw_data_block := (id_syn_ele:3 element)* ID_END
//   SCE/LFE        := element_instance_tag:4 individual_channel_stream(0)
//   CPE            := tag:4 common_window:1 [ics_info ms_mask_present:2 [ms_used{max_sfb·groups}]] ics(cw) ics(cw)
//   ics            := global_gain:8 [ics_info] section_data scale_factor_data pulse:1 [pulse_data]
//                     tns:1 [tns_data] gain_control:1{0} spectral_data
//   ics_info       := reserved:1 window_sequence:2 window_shape:1
//                     (EIGHT_SHORT: max_sfb:4 grouping:7 | max_sfb:6 predictor_data_present:1{0})
//   FIL            := count:4 [== 15 → +esc:8 − 1] byte{count}      DSE := tag:4 align:1 count:8 [+8] byte{count}
// CCE (coupling), PCE, gain control and main/LTP prediction are refused.
// Everything read is bounded by max_sfb ≤ the band table and the spectrum's 1024 coefficients.

public import CodecCore

public struct AACDecoder: Sendable {
    public let config: AACConfig
    let swbLong: [Int], swbShort: [Int]
    let numSwbLong: Int, numSwbShort: Int
    let tnsMaxLong: Int, tnsMaxShort: Int
    static let imdctLong = IMDCT(coefficients: 1024)
    static let imdctShort = IMDCT(coefficients: 128)
    /// |q|^(4/3) for |q| ≤ 8191 + 15 (the largest escape plus the largest pulse).
    static let pow43: [Float] = (0..<8207).map { Float(LibM.pow(Double($0), 4.0 / 3.0)) }

    struct ChannelState: Sendable {
        var overlap = [Float](repeating: 0, count: 1024)
        var previousShape = 0
        var previousSequence = WindowSequence.onlyLong
    }
    var states: [ChannelState]
    var randomState: UInt32 = 0x1F2E_3D4C

    /// Which coding tools the decoded stream used (for tests and diagnostics).
    public struct Statistics: Sendable, Equatable {
        public var shortWindowFrames = 0, transitionFrames = 0
        public var midSideBands = 0, intensityBands = 0, noiseBands = 0
        public var tnsFilters = 0, pulses = 0, escapes = 0, kbdWindows = 0
    }
    public private(set) var statistics = Statistics()

    public init(config: AACConfig) {
        self.config = config
        let i = config.samplingIndex
        numSwbLong = Int(AACTables.numSwbLong[i])
        numSwbShort = Int(AACTables.numSwbShort[i])
        swbLong = AACTables.swbOffsetLong[i].prefix(numSwbLong + 1).map(Int.init)
        swbShort = AACTables.swbOffsetShort[i].prefix(numSwbShort + 1).map(Int.init)
        tnsMaxLong = Int(AACTables.tnsMaxBandsLong[i])
        tnsMaxShort = Int(AACTables.tnsMaxBandsShort[i])
        states = Array(repeating: ChannelState(), count: config.channels)
    }

    // MARK: per-channel syntax

    enum WindowSequence: Int { case onlyLong = 0, longStart = 1, eightShort = 2, longStop = 3 }

    struct ICSInfo {
        var sequence: WindowSequence = .onlyLong
        var shape = 0
        var maxSfb = 0
        var groupLengths: [Int] = [1]
        var numWindows: Int { sequence == .eightShort ? 8 : 1 }
    }

    struct TNSFilter { var length = 0; var order = 0; var downward = false; var coefficients: [Float] = [] }

    struct Channel {
        var info = ICSInfo()
        /// Per group·band (group-major).
        var bandTypes: [Int] = []
        var scalefactors: [Int] = []
        var spectrum = [Float](repeating: 0, count: 1024)
        var tns: [[TNSFilter]] = []   // per window
    }

    static let zeroBand = 0, noiseBand = 13, intensityOut = 14, intensityIn = 15

    func readICSInfo(_ r: inout MSBBitReader, isLFE: Bool) throws(ParseFailure) -> ICSInfo {
        var info = ICSInfo()
        _ = try r.bit("ics_info.reserved")
        guard let seq = WindowSequence(rawValue: Int(try r.bits(2, "ics_info.window_sequence"))) else { throw fail(r, "window_sequence", "") }
        info.sequence = seq
        info.shape = Int(try r.bit("ics_info.window_shape"))
        if seq == .eightShort {
            guard !isLFE else { throw fail(r, "ics_info", "short windows in an LFE") }
            info.maxSfb = Int(try r.bits(4, "ics_info.max_sfb"))
            let grouping = try r.bits(7, "ics_info.scale_factor_grouping")
            var lengths = [1]
            for b in (0..<7).reversed() {
                if (grouping >> UInt32(b)) & 1 == 1 { lengths[lengths.count - 1] += 1 } else { lengths.append(1) }
            }
            info.groupLengths = lengths
            guard info.maxSfb <= numSwbShort else { throw fail(r, "ics_info.max_sfb", "\(info.maxSfb) > \(numSwbShort)") }
        } else {
            info.maxSfb = Int(try r.bits(6, "ics_info.max_sfb"))
            guard info.maxSfb <= numSwbLong else { throw fail(r, "ics_info.max_sfb", "\(info.maxSfb) > \(numSwbLong)") }
            if try r.bit("ics_info.predictor_data_present") == 1 { throw fail(r, "ics_info.predictor_data_present", "prediction (main/LTP profile)") }
        }
        return info
    }

    func fail(_ r: MSBBitReader, _ rule: String, _ why: String) -> ParseFailure {
        ParseFailure(offset: r.bitPosition / 8, rule: rule, reason: .invalid(why))
    }

    mutating func readICS(_ r: inout MSBBitReader, commonInfo: ICSInfo?, isLFE: Bool) throws(ParseFailure) -> Channel {
        var ch = Channel()
        let globalGain = Int(try r.bits(8, "ics.global_gain"))
        if let commonInfo { ch.info = commonInfo } else { ch.info = try readICSInfo(&r, isLFE: isLFE) }
        let info = ch.info
        let short = info.sequence == .eightShort
        let groups = info.groupLengths.count

        // section_data
        ch.bandTypes = Array(repeating: 0, count: groups * info.maxSfb)
        let lenBits = short ? 3 : 5, esc = UInt32((1 << lenBits) - 1)
        for g in 0..<groups {
            var k = 0
            while k < info.maxSfb {
                let cb = Int(try r.bits(4, "section.sect_cb"))
                guard cb != 12 else { throw fail(r, "section.sect_cb", "reserved codebook 12") }
                var len = 0
                while true {
                    let inc = try r.bits(lenBits, "section.sect_len_incr")
                    len += Int(inc)
                    if inc != esc { break }
                }
                guard k + len <= info.maxSfb else { throw fail(r, "section", "runs past max_sfb") }
                for b in k..<(k + len) { ch.bandTypes[g * info.maxSfb + b] = cb }
                k += len
            }
        }

        // scale_factor_data
        ch.scalefactors = Array(repeating: 0, count: groups * info.maxSfb)
        var gain = globalGain, noise = globalGain - 90, intensity = 0
        var firstNoise = true
        for i in 0..<ch.bandTypes.count {
            switch ch.bandTypes[i] {
            case Self.zeroBand:
                ch.scalefactors[i] = 0
            case Self.intensityOut, Self.intensityIn:
                intensity += try AACHuffman.scalefactor.decode(&r, "scalefactor") - 60
                ch.scalefactors[i] = min(max(intensity, -155), 100)
            case Self.noiseBand:
                if firstNoise {
                    noise += Int(try r.bits(9, "dpcm_noise_nrg")) - 256
                    firstNoise = false
                } else {
                    noise += try AACHuffman.scalefactor.decode(&r, "scalefactor") - 60
                }
                ch.scalefactors[i] = min(max(noise, -155), 100)
            default:
                gain += try AACHuffman.scalefactor.decode(&r, "scalefactor") - 60
                guard (0...255).contains(gain) else { throw fail(r, "scalefactor", "\(gain) out of range") }
                ch.scalefactors[i] = gain
            }
        }

        // pulse_data (long windows only)
        var pulses: [(pos: Int, amp: Int)] = []
        if try r.bit("pulse_data_present") == 1 {
            guard !short else { throw fail(r, "pulse_data", "pulses in short windows") }
            let n = Int(try r.bits(2, "number_pulse")) + 1
            let startSfb = Int(try r.bits(6, "pulse_start_sfb"))
            guard startSfb < numSwbLong else { throw fail(r, "pulse_start_sfb", "\(startSfb)") }
            var pos = swbLong[startSfb]
            for i in 0..<n {
                pos += Int(try r.bits(5, "pulse_offset"))
                if i == 0, pos >= 1024 { throw fail(r, "pulse_offset", "") }
                guard pos < 1024 else { throw fail(r, "pulse_offset", "\(pos)") }
                pulses.append((pos, Int(try r.bits(4, "pulse_amp"))))
            }
        }

        // tns_data
        ch.tns = Array(repeating: [], count: info.numWindows)
        if try r.bit("tns_data_present") == 1 {
            let nFiltBits = short ? 1 : 2, lengthBits = short ? 4 : 6, orderBits = short ? 3 : 5
            for w in 0..<info.numWindows {
                let n = Int(try r.bits(nFiltBits, "tns.n_filt"))
                guard n > 0 else { continue }
                let coefRes = Int(try r.bit("tns.coef_res"))
                for _ in 0..<n {
                    var f = TNSFilter()
                    f.length = Int(try r.bits(lengthBits, "tns.length"))
                    f.order = Int(try r.bits(orderBits, "tns.order"))
                    guard f.order <= (short ? 7 : 12) else { throw fail(r, "tns.order", "\(f.order)") }
                    if f.order > 0 {
                        f.downward = try r.bit("tns.direction") == 1
                        let compress = Int(try r.bit("tns.coef_compress"))
                        let bits = coefRes + 3 - compress
                        let map = [AACTables.tnsMap03, AACTables.tnsMap04, AACTables.tnsMap13, AACTables.tnsMap14][2 * compress + coefRes]
                        for _ in 0..<f.order { f.coefficients.append(map[Int(try r.bits(bits, "tns.coef"))]) }
                    }
                    ch.tns[w].append(f)
                }
            }
        }
        if try r.bit("gain_control_data_present") == 1 { throw fail(r, "gain_control", "SSR gain control") }

        // spectral_data → quantised values, window-major (128 per short window).
        var quant = [Int32](repeating: 0, count: 1024)
        let offsets = short ? swbShort : swbLong
        var window = 0
        for (g, glen) in info.groupLengths.enumerated() {
            for sfb in 0..<info.maxSfb {
                let cb = ch.bandTypes[g * info.maxSfb + sfb]
                guard cb >= 1, cb <= 11 else { continue }
                let width = offsets[sfb + 1] - offsets[sfb]
                for w in 0..<glen {
                    let base = (window + w) * 128 + offsets[sfb]
                    try readBand(&r, codebook: cb, into: &quant, at: base, count: width)
                }
            }
            window += glen
        }
        statistics.pulses += pulses.count
        statistics.kbdWindows += info.shape
        statistics.tnsFilters += ch.tns.reduce(0) { $0 + $1.filter { $0.order > 0 }.count }
        statistics.noiseBands += ch.bandTypes.filter { $0 == Self.noiseBand }.count
        statistics.intensityBands += ch.bandTypes.filter { $0 >= Self.intensityOut }.count
        switch info.sequence {
        case .eightShort: statistics.shortWindowFrames += 1
        case .longStart, .longStop: statistics.transitionFrames += 1
        case .onlyLong: break
        }
        for p in pulses { quant[p.pos] = quant[p.pos] > 0 ? quant[p.pos] + Int32(p.amp) : quant[p.pos] - Int32(p.amp) }

        // Dequantisation and noise.
        window = 0
        for (g, glen) in info.groupLengths.enumerated() {
            for sfb in 0..<info.maxSfb {
                let idx = g * info.maxSfb + sfb
                let cb = ch.bandTypes[idx]
                let width = offsets[sfb + 1] - offsets[sfb]
                for w in 0..<glen {
                    let base = (window + w) * 128 + offsets[sfb]
                    switch cb {
                    case Self.noiseBand:
                        var energy: Float = 0
                        for k in 0..<width {
                            randomState = randomState &* 1_664_525 &+ 1_013_904_223
                            let v = Float(Int32(bitPattern: randomState))
                            ch.spectrum[base + k] = v
                            energy += v * v
                        }
                        let scale = LibM.powf(2, Float(ch.scalefactors[idx]) / 4) / energy.squareRoot()
                        for k in 0..<width { ch.spectrum[base + k] *= scale }
                    case 1...11:
                        let scale = LibM.powf(2, Float(ch.scalefactors[idx] - 100) / 4)
                        for k in 0..<width {
                            let q = quant[base + k]
                            let mag = Self.pow43[Int(min(q.magnitude, 8206))]
                            ch.spectrum[base + k] = (q < 0 ? -mag : mag) * scale
                        }
                    default:
                        break   // zero and intensity bands stay zero here
                    }
                }
            }
            window += glen
        }
        return ch
    }

    /// One band of spectral data (4.6.3.3): quads (books 1–4) or pairs (5–11), unsigned books
    /// followed by sign bits, book 11 by escape sequences.
    mutating func readBand(_ r: inout MSBBitReader, codebook cb: Int, into q: inout [Int32], at base: Int, count: Int) throws(ParseFailure) {
        let table = AACHuffman.spectral[cb - 1]
        let unsigned = [3, 4, 7, 8, 9, 10, 11].contains(cb)
        var k = 0
        while k < count {
            let idx = try table.decode(&r, "spectral_data")
            var values: [Int32]
            switch cb {
            case 1, 2: values = [Int32(idx / 27 - 1), Int32(idx / 9 % 3 - 1), Int32(idx / 3 % 3 - 1), Int32(idx % 3 - 1)]
            case 3, 4: values = [Int32(idx / 27), Int32(idx / 9 % 3), Int32(idx / 3 % 3), Int32(idx % 3)]
            case 5, 6: values = [Int32(idx / 9 - 4), Int32(idx % 9 - 4)]
            case 7, 8: values = [Int32(idx / 8), Int32(idx % 8)]
            case 9, 10: values = [Int32(idx / 13), Int32(idx % 13)]
            default: values = [Int32(idx / 17), Int32(idx % 17)]
            }
            if unsigned {
                for i in values.indices where values[i] != 0 { if try r.bit("sign_bits") == 1 { values[i] = -values[i] } }
            }
            if cb == 11 {
                for i in values.indices where values[i].magnitude == 16 {
                    statistics.escapes += 1
                    var n = 0
                    while try r.bit("escape_prefix") == 1 {
                        n += 1
                        guard n <= 8 else { throw fail(r, "escape", "prefix too long") }
                    }
                    let v = Int32((1 << (n + 4)) + Int(try r.bits(n + 4, "escape_word")))
                    values[i] = values[i] < 0 ? -v : v
                }
            }
            guard k + values.count <= count else { throw fail(r, "spectral_data", "past the band") }
            for v in values { q[base + k] = v; k += 1 }
        }
    }

    // MARK: stereo, TNS, filterbank

    func applyMidSide(_ l: inout Channel, _ rch: inout Channel, mask: [Bool]) {
        let info = l.info, offsets = info.sequence == .eightShort ? swbShort : swbLong
        var window = 0
        for (g, glen) in info.groupLengths.enumerated() {
            for sfb in 0..<info.maxSfb {
                let i = g * info.maxSfb + sfb
                guard mask[i], l.bandTypes[i] < Self.noiseBand, rch.bandTypes[i] < Self.noiseBand else { continue }
                for w in 0..<glen {
                    for k in (window + w) * 128 + offsets[sfb] ..< (window + w) * 128 + offsets[sfb + 1] {
                        let m = l.spectrum[k], s = rch.spectrum[k]
                        l.spectrum[k] = m + s
                        rch.spectrum[k] = m - s
                    }
                }
            }
            window += glen
        }
    }

    func applyIntensity(_ l: Channel, _ rch: inout Channel, mask: [Bool], msPresent: Bool) {
        let info = rch.info, offsets = info.sequence == .eightShort ? swbShort : swbLong
        var window = 0
        for (g, glen) in info.groupLengths.enumerated() {
            for sfb in 0..<info.maxSfb {
                let i = g * info.maxSfb + sfb
                let bt = rch.bandTypes[i]
                guard bt == Self.intensityOut || bt == Self.intensityIn else { continue }
                var c: Float = bt == Self.intensityIn ? 1 : -1
                if msPresent && mask[i] { c = -c }
                let scale = c * LibM.powf(0.5, Float(rch.scalefactors[i]) / 4)
                for w in 0..<glen {
                    for k in (window + w) * 128 + offsets[sfb] ..< (window + w) * 128 + offsets[sfb + 1] { rch.spectrum[k] = l.spectrum[k] * scale }
                }
            }
            window += glen
        }
    }

    func applyTNS(_ ch: inout Channel) {
        let info = ch.info, short = info.sequence == .eightShort
        let offsets = short ? swbShort : swbLong
        let mmm = min(short ? tnsMaxShort : tnsMaxLong, info.maxSfb)
        guard mmm > 0 else { return }
        for w in 0..<info.numWindows {
            var bottom = short ? numSwbShort : numSwbLong
            for f in ch.tns[w] {
                let top = bottom
                bottom = max(0, top - f.length)
                guard f.order > 0 else { continue }
                // Reflection coefficients → LPC (compute_lpc_coefs without normalisation).
                var lpc = [Float](repeating: 0, count: f.order)
                for i in 0..<f.order {
                    let r = -f.coefficients[i]
                    lpc[i] = r
                    for j in 0..<((i + 1) >> 1) {
                        let a = lpc[j], b = lpc[i - 1 - j]
                        lpc[j] = a + r * b
                        lpc[i - 1 - j] = b + r * a
                    }
                }
                let start = offsets[min(bottom, mmm)], end = offsets[min(top, mmm)]
                let size = end - start
                guard size > 0 else { continue }
                let inc = f.downward ? -1 : 1
                var pos = (f.downward ? end - 1 : start) + w * 128
                for m in 0..<size {
                    if m > 0 {
                        for i in 1...min(m, f.order) { ch.spectrum[pos] -= ch.spectrum[pos - i * inc] * lpc[i - 1] }
                    }
                    pos += inc
                }
            }
        }
    }

    /// IMDCT, windowing and overlap-add for one channel → 1024 samples.
    ///
    /// The left half is long only when the previous frame ended long and this one starts long;
    /// any other transition (including the invalid ones a broken encoder may produce) overlaps
    /// with the short-window slope, as FFmpeg does. The right half follows this frame's
    /// sequence; both halves of an overlap use the previous frame's window shape on the left
    /// and this frame's shape on the right (4.6.11.3.2).
    mutating func synthesize(_ ch: Channel, state s: Int) -> [Float] {
        var st = states[s]
        let info = ch.info
        var buf = [Float](repeating: 0, count: 2048)
        let prevLong = AACWindows.long(st.previousShape), curLong = AACWindows.long(info.shape)
        let prevShort = AACWindows.short(st.previousShape), curShort = AACWindows.short(info.shape)
        if info.sequence == .eightShort {
            for w in 0..<8 {
                let z = Self.imdctShort.transform(Array(ch.spectrum[w * 128 ..< (w + 1) * 128]))
                let left = w == 0 ? prevShort : curShort
                for n in 0..<128 {
                    buf[448 + w * 128 + n] += z[n] * left[n]
                    buf[448 + w * 128 + 128 + n] += z[128 + n] * curShort[128 + n]
                }
            }
        } else {
            let z = Self.imdctLong.transform(ch.spectrum)
            let leftLong = (st.previousSequence == .onlyLong || st.previousSequence == .longStop)
                && (info.sequence == .onlyLong || info.sequence == .longStart)
            if leftLong {
                for n in 0..<1024 { buf[n] = z[n] * prevLong[n] }
            } else {
                for n in 0..<128 { buf[448 + n] = z[448 + n] * prevShort[n] }
                for n in 576..<1024 { buf[n] = z[n] }
            }
            if info.sequence == .longStart {
                for n in 1024..<1472 { buf[n] = z[n] }
                for n in 0..<128 { buf[1472 + n] = z[1472 + n] * curShort[128 + n] }
            } else {
                for n in 1024..<2048 { buf[n] = z[n] * curLong[n] }
            }
        }
        var out = [Float](repeating: 0, count: 1024)
        for n in 0..<1024 {
            out[n] = (buf[n] + st.overlap[n]) / 32768
            st.overlap[n] = buf[1024 + n]
        }
        st.previousShape = info.shape
        st.previousSequence = info.sequence
        states[s] = st
        return out
    }

    // MARK: access units

    /// Decodes one access unit; returns `channels` arrays of 1024 samples.
    public mutating func decode(_ accessUnit: ByteSlice) throws(ParseFailure) -> [[Float]] {
        var r = MSBBitReader(accessUnit.copyBytes(), policy: .fail)
        var out: [[Float]] = []
        var channelIndex = 0
        let expected = config.channels
        var elements = 0
        while true {
            let id = Int(try r.bits(3, "id_syn_ele"))
            elements += 1
            guard elements <= 64 else { throw fail(r, "raw_data_block", "too many elements") }
            switch id {
            case 0, 3:   // SCE, LFE
                _ = try r.bits(4, "element_instance_tag")
                guard channelIndex < expected else { throw fail(r, "SCE", "more channels than configured") }
                var ch = try readICS(&r, commonInfo: nil, isLFE: id == 3)
                applyTNS(&ch)
                out.append(synthesize(ch, state: channelIndex))
                channelIndex += 1
            case 1:      // CPE
                _ = try r.bits(4, "element_instance_tag")
                guard channelIndex + 2 <= expected else { throw fail(r, "CPE", "more channels than configured") }
                let common = try r.bit("common_window") == 1
                var info: ICSInfo? = nil
                var mask: [Bool] = []
                var msPresent = false
                if common {
                    let i = try readICSInfo(&r, isLFE: false)
                    info = i
                    let ms = try r.bits(2, "ms_mask_present")
                    guard ms != 3 else { throw fail(r, "ms_mask_present", "reserved") }
                    msPresent = ms != 0
                    let n = i.groupLengths.count * i.maxSfb
                    if ms == 1 { for _ in 0..<n { mask.append(try r.bit("ms_used") == 1) } } else { mask = Array(repeating: ms == 2, count: n) }
                }
                var l = try readICS(&r, commonInfo: info, isLFE: false)
                var rc = try readICS(&r, commonInfo: info, isLFE: false)
                if common {
                    statistics.midSideBands += mask.filter { $0 }.count
                    if msPresent { applyMidSide(&l, &rc, mask: mask) }
                    applyIntensity(l, &rc, mask: mask, msPresent: msPresent)
                }
                applyTNS(&l)
                applyTNS(&rc)
                out.append(synthesize(l, state: channelIndex))
                out.append(synthesize(rc, state: channelIndex + 1))
                channelIndex += 2
            case 2:
                throw fail(r, "CCE", "coupling channel elements are not supported")
            case 4:      // DSE
                _ = try r.bits(4, "element_instance_tag")
                let align = try r.bit("data_byte_align_flag") == 1
                var count = Int(try r.bits(8, "count"))
                if count == 255 { count += Int(try r.bits(8, "esc_count")) }
                if align { r.alignToByte() }
                for _ in 0..<count { _ = try r.bits(8, "data_stream_byte") }
            case 5:
                throw fail(r, "PCE", "program config elements are not supported")
            case 6:      // FIL (SBR and fill data are skipped)
                var count = Int(try r.bits(4, "count"))
                if count == 15 { count += Int(try r.bits(8, "esc_count")) - 1 }
                for _ in 0..<count { _ = try r.bits(8, "fill_byte") }
            default:     // END
                guard channelIndex == expected else { throw fail(r, "raw_data_block", "\(channelIndex) of \(expected) channels") }
                return out
            }
        }
    }
}
