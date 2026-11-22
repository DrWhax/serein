import Foundation

/// 48 kHz mono capture processing, following echo cancellation. Four 5 ms hops
/// fit the capture packet. The overlap-add filter adds a fixed 5 ms of delay.
struct MicrophoneProcessing: Sendable {
    private static let hop = 240
    private static let fftSize = 512
    private static let window = (0..<480).map { sin((Double($0) + 0.5) * .pi / 480) }
    private static let roots = (0..<256).map { i in
        SIMD2(cos(-2 * .pi * Double(i) / 512), sin(-2 * .pi * Double(i) / 512))
    }

    // 75 Hz second-order Butterworth high-pass, bilinear transform at 48 kHz.
    private static let pole = tan(Double.pi * 75 / 48_000)
    private static let b0 = 1 / (1 + sqrt(2) * pole + pole * pole)
    private static let a1 = 2 * (pole * pole - 1) * b0
    private static let a2 = (1 - sqrt(2) * pole + pole * pole) * b0
    private var z1 = 0.0, z2 = 0.0
    private var history = [Double](repeating: 0, count: hop)
    private var overlap = [Double](repeating: 0, count: hop)
    // Narrow bands in the speech region and wider bands at high frequencies.
    private static let bandEdges = [0, 2, 4, 6, 8, 11, 14, 18, 23, 29, 36, 45, 56, 70, 88, 110, 138, 173, 216, 257]
    private var noise = [Double](repeating: 0, count: bandEdges.count - 1)
    private var smooth = [Double](repeating: 0, count: bandEdges.count - 1)
    private var gains = [Double](repeating: 1, count: bandEdges.count - 1)
    private var level = 0.0, gain = 1.0
    private var limiter = 1.0
    private var initialized = false

    mutating func process(_ samples: [Int16]) -> [Int16] {
        guard samples.count == 960 else { return samples }
        var result = [Int16]()
        result.reserveCapacity(samples.count)
        for start in stride(from: 0, to: samples.count, by: Self.hop) {
            var spectrum = [SIMD2<Double>](repeating: .zero, count: Self.fftSize)
            for i in 0..<Self.hop {
                let x = Double(samples[start+i])
                let y = Self.b0 * x + z1
                z1 = -2 * Self.b0 * x - Self.a1 * y + z2
                z2 = Self.b0 * x - Self.a2 * y
                spectrum[i].x = history[i] * Self.window[i]
                history[i] = y
                spectrum[i+Self.hop].x = y * Self.window[i+Self.hop]
            }
            Self.transform(&spectrum, inverse: false)
            let voiced = suppress(&spectrum)
            Self.transform(&spectrum, inverse: true)
            var hop = [Double](repeating: 0, count: Self.hop)
            for i in hop.indices {
                hop[i] = overlap[i] + spectrum[i].x * Self.window[i]
                overlap[i] = spectrum[i+Self.hop].x * Self.window[i+Self.hop]
            }
            level(hop, active: voiced, into: &result)
        }
        return result
    }

    /// Track background power more quickly during noise-only windows. A local
    /// spectral valley limits initial contamination by a sustained pitched voice.
    private mutating func suppress(_ bins: inout [SIMD2<Double>]) -> Bool {
        var powers = noise
        var energy = 0.0, logEnergy = 0.0
        for b in powers.indices {
            let range = Self.bandEdges[b]..<Self.bandEdges[b+1]
            var power = 0.0
            for k in range {
                let v = bins[k]
                let p = v.x * v.x + v.y * v.y
                power += p
                if (2...80).contains(k) { energy += p; logEnergy += log(max(1, p)) }
            }
            powers[b] = power / Double(range.count)
        }
        // White noise's finite-window spectral flatness is about 0.56; voiced
        // speech has concentrated harmonics. Relative band SNR also detects onsets.
        let flatness = exp(logEnergy / 79) / max(1, energy / 79)
        var excited = 0, tonal = false
        for b in powers.indices {
            smooth[b] = initialized ? 0.8 * smooth[b] + 0.2 * powers[b] : powers[b]
            if !initialized {
                let neighborhood = max(0, b-2)...min(powers.count-1, b+2)
                noise[b] = max(1, powers[neighborhood].min() ?? 1)
            }
            if b > 0 && b < 14 {
                if smooth[b] > 5 * max(1, noise[b]) { excited += 1 }
                for k in Self.bandEdges[b]..<Self.bandEdges[b+1] {
                    let v = bins[k]
                    if v.x*v.x + v.y*v.y > 15 * max(40_000, noise[b]) { tonal = true }
                }
            }
        }
        let voiced = energy > 79 * 40_000 && (flatness < 0.20 || (flatness < 0.56 && tonal) || (flatness < 0.40 && excited >= 4))
        for b in powers.indices {
            let floor = max(1, noise[b])
            let update: Double
            if smooth[b] < floor { update = 0.10 }
            else if voiced { update = 0.0003 }
            else { update = 0.035 }
            noise[b] += update * (smooth[b] - noise[b])
            // Smooth the Wiener gain to keep weak consonants and avoid musical noise.
            let snr = max(0, smooth[b] / max(1, noise[b]) - 1)
            let target = max(0.18, snr / (snr + 1.5))
            gains[b] += (target > gains[b] ? 0.55 : 0.12) * (target - gains[b])
            let range = Self.bandEdges[b]..<Self.bandEdges[b+1]
            for k in range {
                bins[k] *= gains[b]
                if k != 0 && k != Self.fftSize / 2 { bins[Self.fftSize-k] *= gains[b] }
            }
        }
        initialized = true
        return voiced
    }

    /// Estimate speech level only on active windows. Keep background gain stable in
    /// pauses. Peak protection uses the whole hop and releases over about 150 ms.
    private mutating func level(_ samples: [Double], active: Bool, into output: inout [Int16]) {
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count))
        let oldGain = gain
        if active && rms > 20 {
            if level == 0 { level = rms }
            level += (rms > level ? 0.12 : 0.025) * (rms - level)
            let wanted = min(8, max(0.20, 2600 / max(1, level)))
            gain += (wanted < gain ? 0.12 : 0.006) * (wanted - gain)
        }
        let peak = samples.reduce(1.0) { max($0, abs($1)) }
        let ceiling = min(1, 30_000 / (peak * max(gain, oldGain)))
        limiter = min(ceiling, limiter + 0.032 * (1 - limiter))
        for i in samples.indices {
            let fraction = Double(i+1) / Double(samples.count)
            let scaled = samples[i] * (oldGain + fraction * (gain-oldGain)) * limiter
            output.append(Int16(clamping: Int(scaled.rounded())))
        }
    }

    private static func transform(_ values: inout [SIMD2<Double>], inverse: Bool) {
        var reversed = 0
        for i in 1..<fftSize {
            var bit = fftSize / 2
            while reversed & bit != 0 { reversed ^= bit; bit >>= 1 }
            reversed ^= bit
            if i < reversed { values.swapAt(i, reversed) }
        }
        var size = 2
        while size <= fftSize {
            let half = size / 2
            for start in stride(from: 0, to: fftSize, by: size) {
                for k in 0..<half {
                    let root = roots[k * fftSize / size]
                    let imag = inverse ? -root.y : root.y
                    let a = values[start+k], b = values[start+k+half]
                    let product = SIMD2(root.x*b.x - imag*b.y, root.x*b.y + imag*b.x)
                    values[start+k] = a + product
                    values[start+k+half] = a - product
                }
            }
            size *= 2
        }
        if inverse { for i in values.indices { values[i] /= Double(fftSize) } }
    }
}
