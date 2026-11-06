// A psychoacoustic model for the encoder, computed on the MDCT lines (as fast encoders do,
// instead of a separate FFT): per scalefactor band, the energy, a masking threshold from
// the band energies spread over the Bark scale with Schroeder's spreading function, an
// offset from the granule's tonality (spectral flatness, Johnston's 14.5 + z dB tonal /
// 5.5 dB noise), floored by the absolute threshold of hearing (Terhardt). The result is the
// noise energy each band may carry ("xmin"), scaled by the VBR quality. Block switching uses
// a time-domain attack detector on high-passed energy.

import CodecCore

struct MP3Psychoacoustics: Sendable {
    let sampleRate: Int
    let sampleRateIndex: Int
    /// The allowed noise relative to the masking threshold, in dB (from the quality setting).
    let qualityOffsetDB: Double
    /// dB added to the ATH: 0 dBFS taken as 96 − 12 = 84 dB SPL (tuned as above; LAME's
    /// own calibration is similarly below the 96 dB of a 16-bit range).
    var athShiftDB: Double = 12
    /// Lines at or above this are removed (the encoder's lowpass).
    let cutoffLine: Int

    /// Total MDCT energy (Σ xr²) of one granule of a full-scale (±1) sine, long blocks and
    /// short blocks (per window): the 0 dBFS reference for the ATH (measured: the analysis
    /// maps a granule's Σ pcm² to Σ xr² · 288, and a window's to Σ xr² · 96).
    static let fullScaleLong: Double = 1
    static let fullScaleShort: Double = 1
    /// 0 dBFS taken as 96 dB SPL, LAME's ATH convention.
    static let fullScaleSPL = 96.0

    init(sampleRate: Int, sampleRateIndex: Int, quality: Int, lowpassHz: Double, offsetOverride: Double? = nil) {
        self.sampleRate = sampleRate
        self.sampleRateIndex = sampleRateIndex
        // Tuned on a voice-like signal against LAME -V7 at 32 kHz (55 kbps, 19 dB SNR): this
        // gives 57 kbps at 17 dB; each quality step is 1.5 dB of noise.
        qualityOffsetDB = offsetOverride ?? 2 + Double(quality - 7) * 1.5
        let nyquist = Double(sampleRate) / 2
        cutoffLine = min(576, Int((min(lowpassHz, nyquist * 0.97) / nyquist * 576).rounded()))
    }

    /// Tonality per band from the spectral flatness of the band and its neighbours (at least
    /// 12 lines) of a pseudo power spectrum (the MDCT line plus its neighbours' difference, a
    /// cheap stand-in for the phase-independent power), 0 (noise) … 1 (tone).
    func tonality(_ lines: [Float], bands bandList: [(Int, Int)]) -> [Double] {
        let n = lines.count
        var power = [Double](repeating: 0, count: n)
        for i in 0 ..< n {
            let l = i > 0 ? Double(lines[i - 1]) : 0, r = i + 1 < n ? Double(lines[i + 1]) : 0
            let d = (r - l) / 2
            power[i] = Double(lines[i]) * Double(lines[i]) + d * d + 1e-14
        }
        var tonality = [Double](repeating: 0, count: bandList.count)
        for (b, band) in bandList.enumerated() {
            var lo = band.0, hi = min(band.1, n)
            while hi - lo < 12 && (lo > 0 || hi < n) { lo = max(0, lo - 2); hi = min(n, hi + 2) }
            var logSum = 0.0, sum = 0.0
            for i in lo ..< hi { logSum += LibM.log10(power[i]); sum += power[i] }
            let count = Double(max(1, hi - lo))
            let sfmDB = 10 * (logSum / count - LibM.log10(sum / count))
            tonality[b] = min(max((Self.noiseFlatnessDB - sfmDB) / (Self.noiseFlatnessDB - Self.toneFlatnessDB), 0), 1)
        }
        return tonality
    }

    /// Flatness of white noise's pseudo spectrum (≈ −2 dB) and of a clearly tonal band.
    static let noiseFlatnessDB = -2.5, toneFlatnessDB = -15.0

    /// Johnston's tonal offset grows with Bark; capped (as ISO model 2's TMN) so weak high
    /// harmonics do not demand more SNR than a tone needs.
    static let maxTonalOffsetDB = 24.0

    /// ISO model 2's "minval": a floor on the signal-to-mask ratio, highest (24.5 dB) at the
    /// lowest frequencies, where precision is cheap (few lines) and the ear is sensitive.
    static func minimumSMR(_ z: Double) -> Double { max(0, 24.5 - max(0, z - 4) * 2.5) }

    static func bark(_ f: Double) -> Double { 13 * LibM.atan(0.00076 * f) + 3.5 * LibM.atan((f / 7500) * (f / 7500)) }

    /// Terhardt's absolute threshold of hearing, dB SPL.
    static func ath(_ f: Double) -> Double {
        let k = max(f, 20) / 1000
        return 3.64 * LibM.pow(k, -0.8) - 6.5 * LibM.exp(-0.6 * (k - 3.3) * (k - 3.3)) + 0.001 * k * k * k * k
    }

    /// Schroeder's spreading function as a power ratio; dz = maskee − masker in Bark.
    static func spreading(_ dz: Double) -> Double {
        let t = dz + 0.474
        let db = 15.81 + 7.5 * t - 17.5 * (1 + t * t).squareRoot()
        return LibM.pow(10, db / 10)
    }

    /// Bands (start, end) in lines: long (22) or short (13, per window, lines within the window).
    func bands(short: Bool) -> [(Int, Int)] {
        let sizes = short ? MP3Tables.bandSizeShort[sampleRateIndex] : MP3Tables.bandSizeLong[sampleRateIndex]
        var out: [(Int, Int)] = []
        var k = 0
        for s in sizes { out.append((k, k + Int(s))); k += Int(s) }
        return out
    }

    /// Allowed noise per band for one spectrum `lines` (576 long, or one 192-line short window).
    func allowedNoise(_ lines: [Float], short: Bool) -> [Double] {
        let bandList = bands(short: short)
        let n = lines.count
        let lineHz = Double(sampleRate) / 2 / Double(n)
        let energies = bandList.map { b in (b.0 ..< min(b.1, n)).reduce(0.0) { $0 + Double(lines[$1]) * Double(lines[$1]) } }
        let tonality = self.tonality(lines, bands: bandList)
        let z = bandList.map { Self.bark((Double($0.0 + $0.1) / 2) * lineHz) }
        let reference = short ? Self.fullScaleShort : Self.fullScaleLong
        var out = [Double](repeating: 0, count: bandList.count)
        for (b, band) in bandList.enumerated() {
            let width = Double(band.1 - band.0)
            var density = 0.0
            for (m, mb) in bandList.enumerated() where energies[m] > 0 {
                density += energies[m] / Double(mb.1 - mb.0) * Self.spreading(z[b] - z[m])
            }
            let offset = max(Self.minimumSMR(z[b]), tonality[b] * min(14.5 + z[b], Self.maxTonalOffsetDB) + (1 - tonality[b]) * 5.5)
            let masked = density * width * LibM.pow(10, (-offset + qualityOffsetDB) / 10)
            var athMin = Double.infinity
            for i in band.0 ..< band.1 { athMin = min(athMin, Self.ath((Double(i) + 0.5) * lineHz)) }
            let athEnergy = reference * LibM.pow(10, (athMin - Self.fullScaleSPL + athShiftDB) / 10)
            out[b] = max(masked, athEnergy)
        }
        return out
    }
}

/// Attack detection for block switching: the energy of the high-passed signal in 3 sub-blocks
/// per granule against the recent average.
struct MP3AttackDetector: Sendable {
    var history: [Double] = [0, 0, 0, 0, 0, 0]
    var last: Float = 0

    /// `samples`: the 576 PCM samples aligned with the granule's MDCT window centre.
    mutating func isAttack(_ samples: ArraySlice<Float>) -> Bool {
        var energies: [Double] = []
        var i = samples.startIndex
        for _ in 0 ..< 3 {
            var e = 0.0
            for _ in 0 ..< samples.count / 3 {
                let hp = samples[i] - last
                last = samples[i]
                e += Double(hp * hp)
                i += 1
            }
            energies.append(e)
        }
        var attack = false
        for e in energies {
            let mean = history.reduce(0, +) / Double(history.count)
            if e > 1e-3 && e > 10 * mean { attack = true }
            history.removeFirst()
            history.append(e)
        }
        return attack
    }
}
