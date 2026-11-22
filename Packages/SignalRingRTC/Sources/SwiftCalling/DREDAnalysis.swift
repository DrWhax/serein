// LPCNet cepstrum, pitch correlation and PitchDNN from Opus 1.6.1,
// dnn/lpcnet_enc.c, freq.c and pitchdnn.c. See LICENSE-Opus.txt.
import Foundation

struct DREDAnalysis {
    private let model: DREDModel
    private var decimator = DREDDecimator()
    private var input: [Float]
    private var previous = [Float](repeating: 0, count: 160)
    private var emphasis: Float = 0
    private var lastFFT = [SIMD2<Float>](repeating: .zero, count: 30)
    private var pitchMemory = [Float](repeating: 0, count: 16)
    private var excitation = [Float](repeating: 0, count: 256)
    private var lowpass = [Float](repeating: 0, count: 256)
    private var filterMemory: SIMD2<Float> = .zero
    private var pitchFilter: Float = 0
    private var conv1 = [Float](repeating: 0, count: 2*226)
    private var conv2 = [Float](repeating: 0, count: 2*4*226)
    private var gru = [Float](repeating: 0, count: 64)

    init(model: DREDModel, encoderDelay: Bool = true) {
        self.model = model
        input = [Float](repeating: 0, count: encoderDelay ? 11 : 0)
    }

    mutating func features(_ samples: [Int16]) -> [[Float]] {
        input += decimator.convert(samples)
        var result = [[Float]](), offset = 0
        while offset + 160 <= input.count {
            let frame = Array(input[offset..<offset+160])
            result.append(analyze(frame))
            offset += 160
        }
        input.removeFirst(offset)
        return result
    }

    /// Direct 16 kHz frontend, as used by the native LPCNet analyzer.
    mutating func analyze(_ frame: [Float]) -> [Float] {
        guard frame.count == 160 else { return [] }
        let signal = frame.map { x in
            let value = x + emphasis
            emphasis = -0.85*x
            return value
        }
        let aligned = Array(previous.suffix(80)) + signal.prefix(80)
        let spectrum = Self.spectrum(previous + signal)
        previous = signal
        let power = spectrum.map { $0.x*$0.x + $0.y*$0.y }
        var instant = [Float](repeating: 0, count: 88)
        func logAmplitude(_ bin: Int) -> Float { min(1, max(-1, (10*log10(1e-15 + power[bin])-6)/64)) }
        instant[0] = logAmplitude(0)
        for k in 1..<30 {
            let a = spectrum[k], b = lastFFT[k]
            var product = SIMD2(a.x*b.x + a.y*b.y, a.y*b.x - a.x*b.y)
            product /= sqrt(1e-15 + product.x*product.x + product.y*product.y)
            instant[3*k-2] = product.x
            instant[3*k-1] = product.y
            instant[3*k] = logAmplitude(k)
        }
        lastFFT = Array(spectrum.prefix(30))
        let bandPowers = Self.bands(power)
        var logMax: Float = -2, follow: Float = -2
        let logs = bandPowers.map { energy in
            let value = max(logMax-8, follow-2.5, log10(1e-2+energy))
            logMax = max(logMax, value)
            follow = max(follow-2.5, value)
            return value
        }
        var cepstrum = [Float](repeating: 0, count: 18)
        for k in 0..<18 {
            for j in 0..<18 { cepstrum[k] += logs[j] * Self.dct[j*18+k] }
            cepstrum[k] /= 3
        }
        cepstrum[0] -= 4
        // DCT and inverse DCT are orthonormal: reuse the original limited log bands.
        let lpc = Self.lpc(from: logs)
        let x = pitchMemory + aligned
        pitchMemory = Array(aligned.suffix(16))
        for i in 0..<160 {
            var residual = x[16+i]
            for j in 0..<16 { residual += lpc[j] * x[15+i-j] }
            excitation.append(residual + 0.7*pitchFilter)
            pitchFilter = residual
            let y = residual + filterMemory.x
            let first = (Float(-0.84946) + 1.54220)*residual + filterMemory.y + 1.54220*filterMemory.x
            let second = (Float(1) - 0.70781)*residual + 1e-30 - 0.70781*filterMemory.x
            filterMemory = SIMD2(first, second)
            lowpass.append(y)
        }
        let energy = Self.dot(excitation, 256, 256)
        var lagEnergy = Double(Self.dot(excitation, 0, 0))
        var correlations = [Float](repeating: 0, count: 224)
        for i in correlations.indices {
            correlations[i] = 2 * Self.dot(excitation, 256, i) / Float(1 + Double(energy) + lagEnergy)
            let a = Double(excitation[i+160]), b = Double(excitation[i])
            lagEnergy += a*a - b*b
        }
        let pitch = pitch(instant: instant, correlations: correlations)
        let period = Int(max(32, min(256, (256 / exp2(pitch + 1.5)).rounded())))
        let xy = Self.dot(lowpass, 256, 256-period)
        let xx = Self.dot(lowpass, 256, 256), yy = Self.dot(lowpass, 256-period, 256-period)
        let correlation = xy / sqrt(1 + xx*yy)
        excitation.removeFirst(160)
        lowpass.removeFirst(160)
        return cepstrum + [pitch, log1p(exp(5*correlation))/log1p(exp(Float(5))) - 0.5]
    }

    private mutating func pitch(instant: [Float], correlations: [Float]) -> Float {
        let phase1 = model["dense_if_upsampler_1"].apply(instant, .tanh)
        let phase2 = model["dense_if_upsampler_2"].apply(phase1, .tanh)
        let a = Self.convolve([0] + correlations + [0], history: &conv1,
                              layer: model.pitchConvolutions[0], inputs: 1, outputs: 4)
        let b = Self.convolve(a, history: &conv2, layer: model.pitchConvolutions[1], inputs: 4, outputs: 1)
        let vector = model["dense_downsampler"].apply(b[1...224] + phase2, .tanh)
        model.gru("gru_1", input: vector, state: &gru)
        let logits = model["dense_final_upsampler"].apply(gru, .linear)
        var best = 0, maxValue: Float = -1
        for i in 0..<180 where logits[i] > maxValue { maxValue = logits[i]; best = i }
        var numerator: Float = 0, denominator: Float = 0
        for i in max(0, best-2)...min(179, best+2) {
            let p = exp(logits[i])
            numerator += p * Float(i)
            denominator += p
        }
        return numerator / denominator / 60 - 1.5
    }

    /// Three temporal taps × three lags; zero-padded edges between channel planes.
    private static func convolve(_ input: [Float], history: inout [Float],
                                 layer: (weights: [Float], bias: [Float]), inputs: Int, outputs: Int) -> [Float] {
        let window = history + input
        history = Array(window.suffix(history.count))
        var output = [Float](repeating: 0, count: outputs*226)
        for c in 0..<outputs {
            for j in 0..<224 {
                var value = layer.bias[c]
                for m in 0..<inputs {
                    for t in 0..<3 {
                        let k = ((c*inputs + m)*3 + t)*3, i = (t*inputs + m)*226+j
                        value += layer.weights[k]*window[i] + layer.weights[k+1]*window[i+1] + layer.weights[k+2]*window[i+2]
                    }
                }
                output[c*226+1+j] = DREDModel.tanhApprox(value)
            }
        }
        return output
    }

    static let dct: [Float] = (0..<324).map { i in
        let k = i % 18
        return k == 0 ? sqrt(0.5) : Float(cos(.pi*(Double(i/18)+0.5)*Double(k)/18))
    }
    private static let edges = [0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 136, 160]
    private static let compensation: [Float] = [0.8,1,1,1,1,1,1,1,0.666667,0.5,0.5,0.5,0.333333,0.25,0.25,0.2,0.166667,0.173913]
    private static let window: [Float] = (0..<320).map { i in
        let angle = Double.pi * (Double(min(i,319-i))+0.5)/320
        return Float(sin(0.5 * .pi * pow(sin(angle), 2)))
    }
    private static let roots: [SIMD2<Float>] = (0..<320).map { i in
        let angle = -2*Double.pi*Double(i)/320
        return SIMD2(Float(cos(angle)), Float(sin(angle)))
    }

    /// Mixed-radix FFT of 5 × 64 samples. The 1/N normalization matches Opus.
    static func spectrum(_ input: [Float], windowed: Bool = true) -> [SIMD2<Float>] {
        var rows = [SIMD2<Float>](repeating: .zero, count: 320)
        for row in 0..<5 {
            var reversed = 0
            for i in 0..<64 {
                let pos = 5*i+row
                rows[64*row+reversed].x = (windowed ? window[pos] : 1) * input[pos] / 320
                var bit = 32
                while bit > 0 && reversed & bit != 0 { reversed ^= bit; bit >>= 1 }
                reversed ^= bit
            }
            var size = 2
            while size <= 64 {
                let half = size/2
                for start in stride(from: row*64, to: (row+1)*64, by: size) {
                    for j in 0..<half {
                        let a = rows[start+j], b = rows[start+j+half], w = roots[j*320/size]
                        let v = SIMD2(b.x*w.x - b.y*w.y, b.x*w.y + b.y*w.x)
                        rows[start+j] = a + v
                        rows[start+j+half] = a - v
                    }
                }
                size *= 2
            }
        }
        return (0...160).map { k in
            var sum = rows[k % 64]
            for row in 1..<5 {
                let x = rows[row*64 + k%64], w = roots[(row*k)%320]
                sum += SIMD2(x.x*w.x - x.y*w.y, x.x*w.y + x.y*w.x)
            }
            return sum
        }
    }

    static func bands(_ power: [Float]) -> [Float] {
        var result = [Float](repeating: 0, count: 18)
        for b in 0..<17 {
            let size = edges[b+1] - edges[b]
            for j in 0..<size {
                let fraction = Float(j)/Float(size), p = power[edges[b]+j]
                result[b] += (1-fraction)*p
                result[b+1] += fraction*p
            }
        }
        result[0] *= 2
        result[17] *= 2
        return result
    }

    /// Autocorrelation of the reconstructed spectrum and Levinson-Durbin recursion.
    private static func lpc(from logs: [Float]) -> [Float] {
        let values = zip(logs, compensation).map { pow(10, $0.0) * $0.1 }
        var spectrum = [Float](repeating: 0, count: 160)
        for b in 0..<17 {
            let size = edges[b+1] - edges[b]
            for j in 0..<size {
                let f = Float(j)/Float(size)
                spectrum[edges[b]+j] = (1-f)*values[b] + f*values[b+1]
            }
        }
        var ac = [Float](repeating: spectrum[0], count: 17)
        for lag in ac.indices {
            for k in 1..<160 { ac[lag] += 2*spectrum[k]*roots[(lag*k)%320].x }
            ac[lag] *= 1 - 6e-5*Float(lag*lag)
        }
        ac[0] += ac[0]*1e-4 + 320.0/12/38
        var taps = [Float](repeating: 0, count: 16), error = ac[0]
        for i in 0..<16 {
            var sum = ac[i+1]
            for j in 0..<i { sum += taps[j] * ac[i-j] }
            let r = -sum/error
            taps[i] = r
            for j in 0..<((i+1)/2) {
                let a = taps[j], b = taps[i-1-j]
                taps[j] = a + r*b
                taps[i-1-j] = b + r*a
            }
            error -= r*r*error
            if error < 0.001*ac[0] { break }
        }
        return taps
    }

    private static func dot(_ x: [Float], _ a: Int, _ b: Int) -> Float {
        var sum: Float = 0
        for i in 0..<160 { sum += x[a+i]*x[b+i] }
        return sum
    }
}
