// FARGAN waveform synthesis from Opus 1.6.1, dnn/fargan.c.
// Copyright (c) 2023 Amazon. See LICENSE-Opus.txt.
import Foundation

/// Synthesize 10 ms of mono speech per decoded DRED feature frame.
struct DREDSynthesis {
    private let model: DREDModel
    private var condHistory = [Float](), excitationHistory = [Float]()
    private var pitch = [Float](repeating: 0, count: 256)
    private var state1 = [Float](repeating: 0, count: 160)
    private var state2 = [Float](repeating: 0, count: 128)
    private var state3 = [Float](repeating: 0, count: 128)
    private var previousPeriod = 91, emphasis: Float = 0
    private var primed = false
    private var resampler = SILKResampler()

    init(model: DREDModel) { self.model = model }

    /// Continue the last 20 ms of known playout, conditioning on five spectral frames.
    /// Earlier unavailable history at the beginning of a call is digital silence.
    mutating func prime(pcm: [Int16], features: [[Float]]) {
        let input = Array(pcm.suffix(960))
        var decimator = DREDDecimator()
        let padded = [Int16](repeating: 0, count: 960 - input.count) + input
        prime16k(pcm: decimator.convert(padded), features: features)
    }

    mutating func prime16k(pcm: [Float], features: [[Float]]) {
        guard pcm.count == 320 else { return }
        let previous = pcm.map { $0 / 32768 }
        var conditioning = [Float](), period = 0
        let history = Array(features.suffix(5))
        let zero = [Float](repeating: 0, count: 20)
        for frame in Array(repeating: zero, count: 5-history.count) + history {
            let feature = Self.valid(frame) ? frame : zero
            previousPeriod = period
            period = Self.period(feature)
            conditioning = condition(feature, period: period)
        }
        var excitation = [Float](repeating: 0, count: 320)
        for i in 1..<320 { excitation[i] = previous[i] - 0.85 * previous[i-1] }
        pitch.replaceSubrange(96..<256, with: excitation.prefix(160))
        for sub in 0..<4 {
            _ = subframe(Array(conditioning[sub*80..<sub*80+80]))
            let offset = 160 + sub*40
            pitch.replaceSubrange(216..<256, with: excitation[offset..<offset+40])
        }
        emphasis = previous[319]
        var discard = [Int16]()
        resampler.append(previous.map { Int16(clamping: Int(($0*32768).rounded())) }, kilohertz: 16, to: &discard)
        primed = true
    }

    mutating func synthesize(_ features: [Float]) -> [Int16] {
        let samples = synthesize16k(features)
        var output = [Int16]()
        resampler.append(samples, kilohertz: 16, to: &output)
        return output
    }

    mutating func synthesize16k(_ features: [Float]) -> [Int16] {
        guard Self.valid(features) else { return [Int16](repeating: 0, count: 160) }
        if !primed { prime(pcm: [], features: []) }
        let period = Self.period(features)
        let conditioning = condition(features, period: period)
        var samples = [Int16]()
        samples.reserveCapacity(160)
        for sub in 0..<4 {
            for value in subframe(Array(conditioning[sub*80..<sub*80+80])) {
                samples.append(Int16((0.5 + min(32767, max(-32767, 32768 * value))).rounded(.down)))
            }
        }
        previousPeriod = period
        return samples
    }

    private static func valid(_ frame: [Float]) -> Bool {
        frame.count == 20 && frame.allSatisfy { $0.isFinite && abs($0) <= 100 }
    }

    private static func period(_ features: [Float]) -> Int {
        Int(max(32, min(256, (256 / exp2(features[18] + 1.5)).rounded())))
    }

    private mutating func condition(_ frame: [Float], period: Int) -> [Float] {
        let offset = min(223, max(0, period - 32)) * 12
        let embedded = model["cond_net_pembed"].dense[offset..<offset+12]
        let input = model["cond_net_fdense1"].apply(frame + embedded, .tanh)
        let conv = model.convolution("cond_net_fconv1", input: input, history: &condHistory)
        return model["cond_net_fdense2"].apply(conv, .tanh)
    }

    private mutating func subframe(_ cond: [Float]) -> [Float] {
        let gain = exp(model["sig_net_cond_gain_dense"].apply(cond, .linear)[0])
        let inverse = 1 / (1e-5 + gain)
        let previous = pitch.suffix(40).map { min(1, max(-1, inverse * $0)) }
        var predicted = [Float](), pos = 256 - previousPeriod - 2
        for _ in 0..<44 {
            predicted.append(min(1, max(-1, inverse * pitch[max(0, pos)])))
            pos += 1
            if pos == 256 { pos -= previousPeriod }
        }
        let conv = model.convolution("sig_net_fwc0_conv", input: cond + predicted + previous, history: &excitationHistory)
        let excitation = model.glu("sig_net_fwc0_glu_gate", conv)
        let gates = model["sig_net_gain_dense_out"].apply(excitation, .sigmoid)
        func gated(_ i: Int) -> [Float] { predicted[2..<42].map { gates[i] * $0 } + previous }
        model.gru("sig_net_gru1", input: excitation + gated(0), state: &state1)
        let a = model.glu("sig_net_gru1_glu_gate", state1)
        model.gru("sig_net_gru2", input: a + gated(1), state: &state2)
        let b = model.glu("sig_net_gru2_glu_gate", state2)
        model.gru("sig_net_gru3", input: b + gated(2), state: &state3)
        let c = model.glu("sig_net_gru3_glu_gate", state3)
        let skip = model["sig_net_skip_dense"].apply(a + b + c + excitation + gated(3), .tanh)
        let output = model["sig_net_sig_dense_out"].apply(model.glu("sig_net_skip_glu_gate", skip), .tanh).map { $0 * gain }
        pitch.removeFirst(40)
        pitch += output
        return output.map { sample in
            emphasis = sample + 0.85 * emphasis
            return emphasis
        }
    }
}

/// Opus DRED's 48 kHz to 16 kHz elliptic input filter and decimation phase.
struct DREDDecimator {
    private static let b: [Float] = [0.005873358047, 0.012980854831, 0.014531340042, 0.014531340042,
                                     0.012980854831, 0.005873358047, 0.004523418224]
    private static let a: [Float] = [-3.878718597768, 7.748834257468, -9.653651699533, 8.007342726666,
                                     -4.379450178552, 1.463182111810, -0.231720677804]
    private var memory = [Float](repeating: 0, count: 8)
    private var phase = 0
    mutating func convert(_ pcm: [Int16]) -> [Float] {
        var output = [Float]()
        output.reserveCapacity((pcm.count+2)/3)
        for sample in pcm {
            let x = Float(sample), y = 0.004523418224 * x + memory[0]
            for tap in Self.b.indices { memory[tap] = memory[tap+1] + Self.b[tap]*x - Self.a[tap]*y }
            if phase == 0 { output.append(y) }
            phase = (phase + 1) % 3
        }
        return output
    }
}
