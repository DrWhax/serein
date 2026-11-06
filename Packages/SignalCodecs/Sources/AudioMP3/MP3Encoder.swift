// A Layer III encoder for voice notes, matching upstream's recorder (LAME 3.100 in VBR-mtrh
// mode, VBR quality 7, at most 90 kbps, mono; Signal-Desktop/packages/lame/wrapper.c): mono
// MPEG-1 (32–48 kHz) or MPEG-2/2.5 (8–24 kHz) frames, variable bitrate with the bit
// reservoir, and a Xing/Info tag frame with LAME's extension (encoder delay and padding,
// so decoders trim them).
//
// Like LAME with these settings, input above 32 kHz is resampled to 32 kHz (the VBR-7
// lowpass of 14.9 kHz fits under its Nyquist frequency). Per granule: the hybrid analysis
// (MP3Analysis), block switching on attacks with start/stop windows (one granule of
// lookahead), a masking model on the MDCT lines (MP3Psychoacoustics), then a direct VBR
// quantiser: each band gets the coarsest step whose quantisation noise stays under its
// allowed noise; the global gain, subblock gains and scalefactors realise those steps
// within the bitstream's limits. Each frame takes the lowest bitrate that, with the
// reservoir, holds its granules; over the cap the granules are requantised with more noise.
//
// The API follows upstream's encoder wrapper: `encode` returns finished bytes as they become
// final (the first chunk starts with a placeholder tag frame), `flush` the rest, and
// `tagFrame()` the final tag frame to overwrite the placeholder with.

import CodecCore

public struct MP3Encoder: Sendable {
    /// Samples between an input sample and its reconstruction (analysis + synthesis).
    static let analysisDelay = 1057
    /// The delay to report in the tag: decoders add their own 529.
    public static let encoderDelay = analysisDelay - MP3Decoder.decoderDelay

    public let inputSampleRate: Int
    public let sampleRate: Int
    public let quality: Int
    public let maxBitrateKbps: Int
    let header: MP3Header
    let lowpassHz: Double

    var resampler: MP3Resampler?
    var pcm: [Float] = []                 // at the output rate, not yet analysed
    var pcmHistory: [Float] = Array(repeating: 0, count: 576)
    var analysis = MP3Analysis()
    var psycho: MP3Psychoacoustics
    var attacks = MP3AttackDetector()
    var inputSamples = 0                  // at the input rate
    var outputSamples = 0                 // at the output rate, fed to the analysis

    /// The analysed granule waiting for the next one's attack decision.
    var held: (sub: [Float], attack: Bool)?
    var previousBlockType = 0
    /// Testing: long blocks only.
    var allowShortBlocks = true
    var readyGranules: [QuantisedGranule] = []

    // Frame layout (main data positions are in the "main data stream" of all frames' areas).
    var mainStream: [UInt8] = []
    var mainStreamBase = 0
    var mainPosition = 0
    var areaStart = 0
    struct PendingFrame: Sendable { var headerAndSide: [UInt8]; var areaStart: Int; var capacity: Int }
    var pending: [PendingFrame] = []
    var emittedTag = false
    public private(set) var frameSizes: [Int] = []
    var musicCRC: UInt16 = 0
    var placeholderLength: Int
    /// Bytes of frame capacity no data could use (the reservoir was full).
    public private(set) var wastedBytes = 0
    var finished = false

    public enum Failure: Error, Sendable { case unsupportedSampleRate(Int) }

    public init(inputSampleRate: Int, quality: Int = 7, maxBitrateKbps: Int = 90) throws(Failure) {
        guard (8000 ... 192_000).contains(inputSampleRate) else { throw .unsupportedSampleRate(inputSampleRate) }
        self.inputSampleRate = inputSampleRate
        self.quality = min(max(quality, 0), 9)
        self.maxBitrateKbps = maxBitrateKbps
        // LAME's VBR lowpass by quality (lame.c, vbr_q 0…9).
        let lowpass: [Double] = [19500, 19000, 18600, 18000, 17500, 16000, 15600, 14900, 12500, 10000]
        lowpassHz = lowpass[self.quality]
        // LAME's optimum_samplefreq for that lowpass, at most the input rate.
        var suggested = 48000
        if lowpassHz <= 15960 { suggested = 44100 }
        if lowpassHz <= 15250 { suggested = 32000 }
        if lowpassHz <= 11220 { suggested = 24000 }
        let rates = MP3Header.sampleRates
        let out = rates.filter { $0 <= min(suggested, inputSampleRate) }.max() ?? 8000
        sampleRate = rates.contains(inputSampleRate) && inputSampleRate <= suggested ? inputSampleRate : out
        let index = rates.firstIndex(of: sampleRate)!
        let version: MP3Header.Version = index < 3 ? .mpeg1 : index < 6 ? .mpeg2 : .mpeg25
        header = MP3Header(version: version, hasCRC: false, bitrateKbps: 0, sampleRateIndex: index, padding: false, mode: .mono, modeExtension: 0)
        if sampleRate != inputSampleRate {
            resampler = MP3Resampler(inRate: inputSampleRate, outRate: sampleRate, cutoffHz: min(lowpassHz + 600, Double(sampleRate) / 2 * 0.95))
        }
        psycho = MP3Psychoacoustics(sampleRate: sampleRate, sampleRateIndex: index, quality: self.quality, lowpassHz: lowpassHz)
        placeholderLength = 0
        placeholderLength = tagFrameBitrate().length
    }

    var lsf: Bool { header.lsf }
    var granulesPerFrame: Int { lsf ? 1 : 2 }
    var maxMainDataBegin: Int { lsf ? 255 : 511 }
    var sideInfoLength: Int { lsf ? 9 : 17 }
    var bitrates: [Int] { (lsf ? MP3Header.bitratesV2 : MP3Header.bitratesV1).filter { $0 > 0 } }

    func frameLength(_ kbps: Int) -> Int { (lsf ? 72_000 : 144_000) * kbps / sampleRate }

    // MARK: input

    /// Encodes mono samples in [−1, 1]; returns the bytes that became final.
    public mutating func encode(_ samples: [Float]) -> [UInt8] {
        precondition(!finished)
        inputSamples += samples.count
        let converted = resampler?.process(samples) ?? samples
        return consume(converted)
    }

    /// Ends the stream: encodes what is buffered and returns the remaining bytes.
    public mutating func flush() -> [UInt8] {
        precondition(!finished)
        var out: [UInt8] = []
        if var r = resampler {
            out += consume(r.flush(totalInput: inputSamples))
            resampler = r
        }
        // Run the input through the filterbank's delay, then fill the last frame.
        let real = outputSamples + pcm.count
        let spf = granulesPerFrame * 576
        let needed = real + MP3Encoder.analysisDelay
        let total = ((needed + spf - 1) / spf) * spf
        out += consume(Array(repeating: 0, count: total - real + 576))   // + one granule of lookahead
        totalOutputSamples = real
        finished = true
        out += drainFrames(final: true)
        return out
    }

    var totalOutputSamples = 0

    mutating func consume(_ samples: [Float]) -> [UInt8] {
        pcm += samples
        var out: [UInt8] = []
        if !emittedTag {
            out += Array(repeating: 0, count: placeholderLength)
            emittedTag = true
        }
        while pcm.count >= 576 {
            let granule = Array(pcm.prefix(576))
            pcm.removeFirst(576)
            outputSamples += 576
            analyseGranule(granule)
            out += encodeReadyFrames()
        }
        return out
    }

    // MARK: granules

    mutating func analyseGranule(_ samples: [Float]) {
        let sub = analysis.subbands(samples[...])
        // The MDCT of this granule spans PCM ≈ [−256 − 288, +320) around its start; detect
        // attacks in the latest 576 samples centred on its second half.
        let window = Array(pcmHistory.suffix(256)) + samples.prefix(320)
        pcmHistory = samples
        let attack = attacks.isAttack(window[...]) && allowShortBlocks
        if let h = held {
            let type = blockType(attack: h.attack, nextAttack: attack)
            emit(sub: h.sub, blockType: type)
        }
        held = (sub, attack)
    }

    /// The window sequence (long → start → short… → stop → long), decided with one granule of
    /// lookahead: a granule before an attack starts the short blocks, so the attack granule
    /// itself is short.
    mutating func blockType(attack: Bool, nextAttack: Bool) -> Int {
        let afterStartOrShort = previousBlockType == 1 || previousBlockType == 2
        let t = afterStartOrShort ? (attack || nextAttack ? 2 : 3) : (attack || nextAttack ? 1 : 0)
        previousBlockType = t
        return t
    }

    mutating func emit(sub: [Float], blockType: Int) {
        var xr = analysis.mdct(sub, blockType: blockType)
        // Lowpass (with a short cosine roll-off below the cutoff).
        let cut = psycho.cutoffLine
        if blockType == 2 {
            let c = cut / 3
            for sb in 0 ..< 32 { for k in 0 ..< 6 { let line = sb * 6 + k; if line >= c { for w in 0 ..< 3 { xr[sb * 18 + 3 * k + w] = 0 } } } }
        } else if cut < 576 {
            for i in cut ..< 576 { xr[i] = 0 }
        }
        readyGranules.append(MP3Quantiser.quantise(xr, blockType: blockType, psycho: psycho, lsf: lsf, noiseBoostDB: 0))
    }

    // MARK: frames

    mutating func encodeReadyFrames() -> [UInt8] {
        var out: [UInt8] = []
        while readyGranules.count >= granulesPerFrame {
            var granules = Array(readyGranules.prefix(granulesPerFrame))
            readyGranules.removeFirst(granulesPerFrame)
            placeFrame(&granules)
            out += drainFrames(final: false)
        }
        return out
    }

    mutating func placeFrame(_ granules: inout [QuantisedGranule]) {
        var reservoir = areaStart - mainPosition
        if reservoir > maxMainDataBegin {
            wastedBytes += reservoir - maxMainDataBegin
            mainPosition = areaStart - maxMainDataBegin
            reservoir = maxMainDataBegin
        }
        let allowed = bitrates.filter { $0 <= maxBitrateKbps }
        let maxKbps = allowed.max() ?? bitrates[0]
        var boost = 0.0
        var data: (bytes: [UInt8], scfsi: Int) = ([], 0)
        var chosen = maxKbps
        while true {
            data = MP3Quantiser.mainData(&granules, lsf: lsf, sampleRateIndex: header.sampleRateIndex)
            let need = data.bytes.count - reservoir
            if let k = allowed.first(where: { frameLength($0) - 4 - sideInfoLength >= need }) { chosen = k; break }
            // Over the cap even with the reservoir: requantise with more noise.
            boost += 3
            for g in granules.indices {
                granules[g] = MP3Quantiser.quantise(granules[g].xr, blockType: granules[g].blockType, psycho: psycho, lsf: lsf, noiseBoostDB: boost)
            }
        }
        let length = frameLength(chosen)
        let capacity = length - 4 - sideInfoLength
        let mdb = areaStart - mainPosition
        // Header + side information.
        var h = header
        h.bitrateKbps = chosen
        var w = MSBBitWriter(capacity: 4 + sideInfoLength)
        writeHeader(h, to: &w)
        MP3Quantiser.writeSideInfo(granules, mainDataBegin: mdb, scfsi: data.scfsi, lsf: lsf, to: &w)
        // Main data into the stream.
        let end = mainPosition + data.bytes.count
        ensureMainStream(upTo: max(end, areaStart + capacity))
        for (i, b) in data.bytes.enumerated() { mainStream[mainPosition - mainStreamBase + i] = b }
        mainPosition = end
        pending.append(PendingFrame(headerAndSide: w.finish(), areaStart: areaStart, capacity: capacity))
        areaStart += capacity
    }

    mutating func ensureMainStream(upTo position: Int) {
        let n = position - mainStreamBase
        if mainStream.count < n { mainStream += Array(repeating: 0, count: n - mainStream.count) }
    }

    /// Frames whose main areas can no longer change.
    mutating func drainFrames(final: Bool) -> [UInt8] {
        var out: [UInt8] = []
        while let f = pending.first {
            let areaEnd = f.areaStart + f.capacity
            // Later frames' data starts at ≥ mainPosition and ≥ (their area − maxMainDataBegin).
            guard final || mainPosition >= areaEnd || areaStart - maxMainDataBegin >= areaEnd else { break }
            pending.removeFirst()
            let area = Array(mainStream[(f.areaStart - mainStreamBase) ..< (areaEnd - mainStreamBase)])
            let frame = f.headerAndSide + area
            frameSizes.append(frame.count)
            musicCRC = MP3Encoder.crc16(frame, musicCRC)
            out += frame
            // Drop consumed main-stream bytes.
            let drop = areaEnd - mainStreamBase
            if drop > 0 && drop <= mainStream.count && drop >= 8192 {
                mainStream.removeFirst(drop)
                mainStreamBase += drop
            }
        }
        return out
    }

    func writeHeader(_ h: MP3Header, to w: inout MSBBitWriter) {
        w.write(0x7FF, 11)
        w.write(h.version == .mpeg1 ? 3 : h.version == .mpeg2 ? 2 : 0, 2)
        w.write(1, 2)                                   // Layer III
        w.write(h.hasCRC ? 0 : 1, 1)
        let table = h.lsf ? MP3Header.bitratesV2 : MP3Header.bitratesV1
        w.write(table.firstIndex(of: h.bitrateKbps) ?? 0, 4)
        w.write(h.sampleRateIndex % 3, 2)
        w.write(h.padding ? 1 : 0, 1)
        w.write(0, 1)                                   // private
        w.write(h.mode.rawValue, 2)
        w.write(h.modeExtension, 2)
        w.write(0, 1)                                   // copyright
        w.write(1, 1)                                   // original
        w.write(0, 2)                                   // emphasis
    }

    // MARK: the tag frame

    /// The smallest frame that holds the Xing + LAME fields.
    func tagFrameBitrate() -> (kbps: Int, length: Int) {
        let needed = 4 + sideInfoLength + 120 + 36
        let k = bitrates.first { frameLength($0) >= needed } ?? bitrates.last!
        return (k, frameLength(k))
    }

    /// The Xing/Info + LAME tag frame for the finished stream (same length as the placeholder
    /// `encode` emitted first).
    public func tagFrame() -> [UInt8] {
        let (kbps, length) = tagFrameBitrate()
        var h = header
        h.bitrateKbps = kbps
        var w = MSBBitWriter(capacity: length)
        writeHeader(h, to: &w)
        for _ in 0 ..< sideInfoLength { w.write(0, 8) }
        var b = w.finish()
        func u32(_ v: Int) { b += [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }
        let frames = frameSizes.count
        let totalBytes = length + frameSizes.reduce(0, +)
        b += Array("Xing".utf8)
        u32(0x0F)                                       // frames, bytes, TOC, quality
        u32(frames)
        u32(totalBytes)
        // TOC: byte position (of 256) at each percent of the duration.
        var offsets: [Int] = []
        var acc = length
        for s in frameSizes { offsets.append(acc); acc += s }
        for i in 0 ..< 100 {
            let f = min(frames - 1, i * frames / 100)
            let pos = frames == 0 ? 0 : offsets[max(0, f)]
            b.append(UInt8(min(255, pos * 256 / max(1, totalBytes))))
        }
        u32(100 - 10 * quality)
        // LAME extension (Mp3 Info Tag rev 1): our encoder's name in the version field.
        b += Array("SgSafe1.0".utf8)
        b.append(0x04)                                  // revision 0, VBR method 4 (mtrh)
        b.append(UInt8(min(255, Int(lowpassHz / 100))))
        b += [0, 0, 0, 0]                               // peak (not measured)
        b += [0, 0, 0, 0]                               // radio / audiophile replay gain
        b.append(0)                                     // encoding flags, ATH type
        b.append(UInt8(min(255, bitrates.first!)))      // minimum bitrate
        let padding = frames * granulesPerFrame * 576 - totalOutputSamples - MP3Encoder.encoderDelay
        let d = MP3Encoder.encoderDelay, p = max(0, min(4095, padding))
        b += [UInt8(d >> 4), UInt8((d & 15) << 4 | p >> 8), UInt8(p & 0xFF)]
        let sourceFreq = inputSampleRate <= 32000 ? 0 : inputSampleRate <= 44100 ? 1 : inputSampleRate <= 48000 ? 2 : 3
        b.append(UInt8(sourceFreq << 6))                // noise shaping 0, mono, safe
        b.append(0)                                     // MP3 gain
        b += [0, 0]                                     // preset, surround
        u32(totalBytes)
        b += [UInt8(musicCRC >> 8), UInt8(musicCRC & 0xFF)]
        let tagCRC = MP3Encoder.crc16(b, 0)                // every byte before the CRC field
        b += [UInt8(tagCRC >> 8), UInt8(tagCRC & 0xFF)]
        if b.count < length { b += Array(repeating: 0, count: length - b.count) }
        return b
    }

    static func crc16(_ data: [UInt8], _ crc: UInt16) -> UInt16 { MP3Stream.crc16(data, crc) }
}
