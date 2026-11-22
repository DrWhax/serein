// Feature-predictive loss concealment from Opus 1.6.1 dnn/lpcnet_plc.c,
// dnn/freq.c and dnn/burg.c. See LICENSE-Opus.txt.
import Foundation

/// The optional Signal model predicts speech when there is no redundant frame.
struct DeepPLC {
    private struct Network {
        var gru1 = [Float](repeating: 0, count: 192), gru2 = [Float](repeating: 0, count: 192)
    }
    private let model: DREDModel
    private var analysis: DREDAnalysis
    private var synthesis: DREDSynthesis
    private var network = Network(), backup0 = Network(), backup1 = Network()
    private var history = [Float](repeating: 0, count: 2400)
    private var analysisPosition = 2400, predictPosition = 2400
    private var analysisGap = true, losses = 0
    private var conditioning = [[Float]](repeating: [Float](repeating: 0, count: 20), count: 5)
    private var decimator = DREDDecimator(), resampler = SILKResampler()
    private var input = [Float](), output = [Int16]()

    init(model: DREDModel) {
        self.model = model
        analysis = DREDAnalysis(model: model, encoderDelay: false)
        synthesis = DREDSynthesis(model: model)
    }

    mutating func update(_ pcm: [Int16]) {
        output.removeAll(keepingCapacity: true)
        input += decimator.convert(pcm)
        var offset = 0
        while offset+160 <= input.count {
            let frame = input[offset..<offset+160].map { Float(Int16(clamping: Int($0.rounded()))) }
            update16k(frame)
            offset += 160
        }
        input.removeFirst(offset)
    }

    mutating func update16k(_ pcm: [Float]) {
        guard pcm.count == 160 else { return }
        if analysisPosition >= 160 { analysisPosition -= 160 } else { analysisGap = true }
        if predictPosition >= 160 { predictPosition -= 160 }
        history.removeFirst(160)
        history += pcm
        // Maintain the 16→48 kHz interpolator phase across normally decoded speech.
        var discard = [Int16]()
        resampler.append(pcm.map { Int16(clamping: Int($0.rounded())) }, kilohertz: 16, to: &discard)
        losses = 0
    }

    mutating func conceal(samples: Int) -> [Int16] {
        guard (1...5760).contains(samples) else { return [] }
        if !input.isEmpty {
            update16k(input + [Float](repeating: input.last ?? 0, count: 160-input.count))
            input.removeAll(keepingCapacity: true)
        }
        while output.count < samples {
            let frame = conceal16k()
            resampler.append(frame, kilohertz: 16, to: &output)
        }
        let result = Array(output.prefix(samples))
        output.removeFirst(samples)
        return result
    }

    mutating func conceal16k() -> [Int16] {
        let zeros = [Float](repeating: 0, count: 57)
        if losses == 0 {
            network = backup0
            var analyzed = 0
            while analysisPosition+160 <= history.count {
                let block = Array(history[analysisPosition..<analysisPosition+160])
                let features = analysis.analyze(block)
                if (!analysisGap || analyzed > 0) && analysisPosition >= predictPosition {
                    queue(features)
                    _ = predict(Self.burgFeatures(block) + features + [1])
                }
                analysisPosition += 160
                analyzed += 1
            }
            for _ in 0..<2 { let frame = predict(zeros); queue(frame) }
            synthesis.prime16k(pcm: Array(history.suffix(320)), features: conditioning)
            analysisGap = false
        }
        var features = predict(zeros)
        losses = min(1000, losses+1)
        let attenuation: [Float] = [0, 0, -0.2, -0.2, -0.4, -0.4, -0.8, -0.8, -1.6, -1.6]
        let decay = losses >= 10 ? -1.6 - 2*Float(losses-9) : attenuation[losses]
        features[0] = max(-15, features[0] + decay)
        let pcm = synthesis.synthesize16k(features)
        queue(features)
        if analysisPosition >= 160 { analysisPosition -= 160 } else { analysisGap = true }
        predictPosition = history.count
        history.removeFirst(160)
        history += pcm.map(Float.init)
        return pcm
    }

    private mutating func predict(_ input: [Float]) -> [Float] {
        backup0 = backup1
        backup1 = network
        let dense = model["plc_dense_in"].apply(input, .tanh)
        model.gru("plc_gru1", input: dense, state: &network.gru1)
        model.gru("plc_gru2", input: network.gru1, state: &network.gru2)
        return model["plc_dense_out"].apply(network.gru2, .linear)
    }

    private mutating func queue(_ frame: [Float]) { conditioning.removeFirst(); conditioning.append(frame) }

    private static func burgFeatures(_ frame: [Float]) -> [Float] {
        let a = cepstrum(Array(frame.prefix(80))), b = cepstrum(Array(frame.suffix(80)))
        return zip(a,b).map { ($0+$1)/2 } + zip(a,b).map(-)
    }

    private static func cepstrum(_ x: [Float]) -> [Float] {
        let difference = (1..<80).map { x[$0] - 0.85*x[$0-1] }
        let (coefficients, energy) = burg(difference)
        var impulse = [Float](repeating: 0, count: 320)
        impulse[0] = 1
        for i in 0..<16 { impulse[i+1] = -coefficients[i]*pow(0.995, Float(i+1)) }
        let inv = DREDAnalysis.spectrum(impulse, windowed: false).map { 1 / (1e-9 + $0.x*$0.x + $0.y*$0.y) }
        var logMax: Float = -2, follow: Float = -2
        let factor: Float = 0.45 * energy / (50*320*320*320)
        let logs = DREDAnalysis.bands(inv).map {
            let value = max(logMax-8, follow-2.5, log10(1e-2+$0*factor))
            logMax = max(logMax,value)
            follow = max(follow-2.5,value)
            return value
        }
        var result = [Float](repeating: 0, count: 18)
        for k in result.indices {
            for j in logs.indices { result[k] += logs[j] * DREDAnalysis.dct[j*18+k] }
            result[k] /= 3
        }
        result[0] -= 4
        return result
    }

    /// Modified Burg recursion, a single 79-sample subframe, LPC order 16.
    private static func burg(_ input: [Float]) -> ([Float], Float) {
        let x = input.map(Double.init), length = x.count
        let energy = x.reduce(0) { $0+$1*$1 }
        var left = [Double](repeating: 0, count: 16)
        for lag in 1...16 { for i in 0..<(length-lag) { left[lag-1] += x[i]*x[i+lag] } }
        var right = left, a = [Double](repeating: 0, count: 16)
        var forward = [Double](repeating: 0, count: 17), backward = forward
        forward[0] = energy*(1+1e-5) + 1e-9
        backward[0] = forward[0]
        var gain = 1.0, limited = false
        for n in 0..<16 {
            var f = x[n], b = x[length-n-1]
            for k in 0..<n {
                left[k] -= x[n]*x[n-k-1]
                right[k] -= x[length-n-1]*x[length-n+k]
                f += x[n-k-1]*a[k]
                b += x[length-n+k]*a[k]
            }
            for k in 0...n {
                forward[k] -= f*x[n-k]
                backward[k] -= b*x[length-n+k-1]
            }
            f = left[n]
            b = right[n]
            for k in 0..<n { f += right[n-k-1]*a[k]; b += left[n-k-1]*a[k] }
            forward[n+1] = f
            backward[n+1] = b
            var num = b, eb = backward[0], ef = forward[0]
            for k in 0..<n { num += backward[n-k]*a[k]; eb += backward[k+1]*a[k]; ef += forward[k+1]*a[k] }
            var r = -2*num/max(1e-18, ef+eb)
            let nextGain = gain*(1-r*r)
            if nextGain <= 0.001 {
                r = (num > 0 ? -1 : 1) * sqrt(max(0, 1-0.001/gain))
                gain = 0.001
                limited = true
            } else { gain = nextGain }
            for k in 0..<((n+1)/2) {
                let l = a[k], h = a[n-k-1]
                a[k] = l+r*h
                a[n-k-1] = h+r*l
            }
            a[n] = r
            if limited { break }
            for k in 0...n+1 {
                let old = forward[k]
                forward[k] += r*backward[n+1-k]
                backward[n+1-k] += r*old
            }
        }
        var residual: Double
        if limited { residual = gain*(energy - x.prefix(16).reduce(0){ $0+$1*$1 }) }
        else {
            residual = forward[0]
            var scale = 1.0
            for k in a.indices { residual += forward[k+1]*a[k]; scale += a[k]*a[k] }
            residual -= 1e-5*energy*scale
        }
        return (a.map { -Float($0) }, max(0, Float(residual)))
    }
}
