// The encoder's hybrid analysis filterbank (ISO/IEC 11172-3 Annex C.1.3 and C.1.5.3): the
// 32-band polyphase analysis filter (window C = D / 32), frequency inversion of odd
// subbands, the MDCT over 36 (long) or 3 × 12 (short) subband samples with the block-type
// windows the decoder uses, and the encoder's alias-reduction butterflies (the inverse of
// the decoder's). Its output, run through MP3Decoder's synthesis, reconstructs the input
// (AudioMP3Tests checks this to float precision).

import CodecCore

struct MP3Analysis: Sendable {
    /// The last 512 input samples (ring), newest at `offset`.
    var x = [Float](repeating: 0, count: 512)
    var offset = 0
    /// Per subband, the previous granule's 18 subband samples.
    var previous = [Float](repeating: 0, count: 32 * 18)

    static let window: [Float] = MP3Decoder.synthesisWindow.map { $0 / 32 }
    /// M[i][k] = cos((2i + 1)(k − 16)π/64).
    static let matrix: [Float] = (0 ..< 32 * 64).map { idx in
        let i = idx / 64, k = idx % 64
        return Float(LibM.cos(Double(2 * i + 1) * Double(k - 16) * Double.pi / 64))
    }
    static let mdctLongCos: [Float] = (0 ..< 18 * 36).map { idx in
        let k = idx / 36, n = idx % 36
        return Float(LibM.cos(Double.pi / 72 * Double(2 * n + 1 + 18) * Double(2 * k + 1)))
    }
    static let mdctShortCos: [Float] = (0 ..< 6 * 12).map { idx in
        let k = idx / 12, n = idx % 12
        return Float(LibM.cos(Double.pi / 24 * Double(2 * n + 1 + 6) * Double(2 * k + 1)))
    }
    /// MDCT normalisation so that the decoder's (unnormalised) IMDCT reconstructs the input.
    static let longScale: Float = 1.0 / 9, shortScale: Float = 1.0 / 3

    /// 32 new PCM samples → 32 subband samples.
    mutating func filter(_ pcm: ArraySlice<Float>) -> [Float] {
        precondition(pcm.count == 32)
        // X[31…0] = the next 32 samples (X[0] newest).
        for (i, s) in pcm.enumerated() {
            offset = (offset - 1) & 511
            x[offset] = s
            _ = i
        }
        var y = [Float](repeating: 0, count: 64)
        for i in 0 ..< 64 {
            var acc: Float = 0
            for j in 0 ..< 8 {
                let n = i + 64 * j
                acc += Self.window[n] * x[(offset + n) & 511]
            }
            y[i] = acc
        }
        var s = [Float](repeating: 0, count: 32)
        for i in 0 ..< 32 {
            var acc: Float = 0
            for k in 0 ..< 64 { acc += Self.matrix[i * 64 + k] * y[k] }
            s[i] = acc
        }
        return s
    }

    /// One granule: 576 PCM samples → its subband samples, `[slot][subband]` (18 × 32).
    mutating func subbands(_ pcm: ArraySlice<Float>) -> [Float] {
        precondition(pcm.count == 576)
        var out = [Float](repeating: 0, count: 576)
        let start = pcm.startIndex
        for slot in 0 ..< 18 {
            let s = filter(pcm[start + slot * 32 ..< start + slot * 32 + 32])
            for sb in 0 ..< 32 {
                // Frequency inversion: odd subbands, odd time samples.
                out[slot * 32 + sb] = (sb & 1 == 1 && slot & 1 == 1) ? -s[sb] : s[sb]
            }
        }
        return out
    }

    /// MDCT of a granule's subband samples (from `subbands`) with block type `blockType`
    /// (0 normal, 1 start, 2 short, 3 stop) → 576 lines in the decoder's order (for short
    /// blocks: subband, line, window — the order after the decoder's reorder).
    mutating func mdct(_ sub: [Float], blockType: Int) -> [Float] {
        var xr = [Float](repeating: 0, count: 576)
        var z = [Float](repeating: 0, count: 36)
        for sb in 0 ..< 32 {
            for n in 0 ..< 18 {
                z[n] = previous[sb * 18 + n]
                z[18 + n] = sub[n * 32 + sb]
                previous[sb * 18 + n] = sub[n * 32 + sb]
            }
            if blockType == 2 {
                for w in 0 ..< 3 {
                    for k in 0 ..< 6 {
                        var acc: Float = 0
                        for n in 0 ..< 12 { acc += MP3Decoder.shortWindow[n] * z[6 + 6 * w + n] * Self.mdctShortCos[k * 12 + n] }
                        xr[sb * 18 + 3 * k + w] = acc * Self.shortScale
                    }
                }
            } else {
                let win = MP3Decoder.windows[blockType]
                for k in 0 ..< 18 {
                    var acc: Float = 0
                    for n in 0 ..< 36 { acc += win[n] * z[n] * Self.mdctLongCos[k * 36 + n] }
                    xr[sb * 18 + k] = acc * Self.longScale
                }
            }
        }
        if blockType != 2 {
            // Alias reduction: the inverse of the decoder's butterflies.
            for sb in 1 ..< 32 {
                let base = 18 * sb
                for j in 0 ..< 8 {
                    let a = xr[base - 1 - j], b = xr[base + j]
                    let (cs, ca) = MP3Decoder.antialias[j]
                    xr[base - 1 - j] = a * cs + b * ca
                    xr[base + j] = b * cs - a * ca
                }
            }
        }
        return xr
    }
}
