/***********************************************************************
Copyright (c) 2006-2011, Skype Limited. All rights reserved.
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
- Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.
- Neither the name of Internet Society, IETF or IETF Trust, nor the
names of specific contributors, may be used to endorse or promote
products derived from this software without specific prior written
permission.
THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
***********************************************************************/

import Foundation

/// Mono Opus at the 48 kHz RTP clock. Fullband speech combines the SILK base
/// with a CELT upper band. High-frequency audio can use CELT across all bands.
struct OpusSpeechEncoder {
    private struct Frame {
        let gainCodes: [Int]
        let vector: Int
        let pulses: [Int]
        let pitch: Pitch?
    }

    private struct Pitch {
        let lag: Int
        let period: Int
        let indices: [Int]
        var taps: [[Double]] { indices.map { OpusSpeechEncoder.pitchTables[period][$0] } }
    }
    private var transform = CELTEncoder()
    private var previousCELT = false
    private var lastFrame: Frame?
    private var lastFrameBytes = 0
    private var quantizerScale = 1.0
    private var lossFraction: UInt8 = 0
    private var quietSamples = 0
    private var dtx = false
    private var skipped: UInt32 = 0
    private var lastGain = 10
    private var filterTail = [Double](repeating: 0, count: 60)
    private var history = [Double](repeating: 0, count: 320)
    private var shortHistory: [Double]
    private(set) var lowDataMode: Bool
    private var order: Int { shortHistory.count }
    private var subframe: Int { lowDataMode ? 40 : 80 }

    init(lowDataMode: Bool = false) {
        self.lowDataMode = lowDataMode
        shortHistory = [Double](repeating: 0, count: lowDataMode ? 10 : 16)
    }

    mutating func setLowDataMode(_ low: Bool) {
        if low != lowDataMode {
            let loss = lossFraction, skipped = skipped, dtx = dtx
            self = Self(lowDataMode: low)
            lossFraction = loss
            self.skipped = skipped
            self.dtx = dtx
        }
    }

    mutating func setPacketLoss(_ fraction: UInt8) { lossFraction = fraction }

    mutating func beginTalkspurt() {
        let loss = lossFraction
        self = Self(lowDataMode: lowDataMode)
        lossFraction = loss
    }

    /// Send an occasional DTX packet during silence. RTP sequence numbers count transmitted
    /// packets while timestamps continue to count every captured sample.
    mutating func transmission(_ samples: [Int16], targetBytes: Int? = nil) throws -> (payload: Data, skipped: UInt32, marker: Bool)? {
        let priorDTX = dtx, gap = skipped
        let payload = try encode(samples, targetBytes: targetBytes)
        dtx = payload.count == 1
        if dtx && priorDTX && gap + UInt32(samples.count) < 19_200 {
            skipped = gap + UInt32(samples.count)
            return nil
        }
        skipped = 0
        return (payload, gap, priorDTX && !dtx)
    }

    /// Takes 20 or 60 ms of signed 48 kHz mono PCM. For 60 ms, Opus code 3 bundles three
    /// 20 ms frames, with a separate encoded size for each of the first two frames.
    mutating func encode(_ samples: [Int16], targetBytes: Int? = nil) throws -> Data {
        guard samples.count == 960 || samples.count == 2880 else { throw OpusPacket.Failure.invalidPacket }
        let target = targetBytes ?? samples.count / 12
        let frameCount = samples.count / 960
        guard (32*frameCount...80*frameCount).contains(target) else { throw OpusPacket.Failure.invalidPacket }
        let frameBytes = (target - (frameCount == 1 ? 2 : 2 + frameCount-1)) / frameCount
        if samples.allSatisfy({ $0.magnitude <= 48 }) {
            quietSamples = min(48_000, quietSamples + samples.count)
            if quietSamples >= 9600 {
                // A zero-byte SILK frame signals DTX. Preserve its actual duration on the RTP clock.
                lastFrame = nil
                return Data([UInt8(lowDataMode ? 0x08 : 0x48) + (samples.count == 2880 ? 0x10 : 0)])
            }
        } else {
            if quietSamples >= 9600 { beginTalkspurt() }
            quietSamples = 0
        }
        var spectra: [[Double]] = []
        if !lowDataMode {
            for i in stride(from: 0, to: samples.count, by: 960) { spectra.append(transform.analyze(samples[i..<i+960])) }
        }
        let highFraction = CELTEncoder.highBandFraction(spectra)
        // Keep SILK's previous-frame redundancy when only the speech band is
        // active on a lossy link. Unvoiced high-frequency audio needs the MDCT.
        if !lowDataMode && highFraction > 0.65 && lossFraction < 5 {
            let payloads = try spectra.map { spectrum in
                var coder = OpusRangeEncoder()
                return try CELTEncoder.encode(spectrum, start: 0, bytes: frameBytes, range: &coder)
            }
            previousCELT = true
            lastFrame = nil
            return Self.packet(payloads, toc: 0xf8, target: target)
        }
        if previousCELT {
            let analysis = transform
            beginTalkspurt()
            transform = analysis
        }
        let hybrid = !lowDataMode && (lossFraction < 5 || highFraction > 0.015)
        let input = filterTail + samples.map(Double.init)
        let decimation = lowDataMode ? 6 : 3
        let taps = lowDataMode ? Self.narrowFilter : Self.wideFilter
        var frames: [[UInt8]] = []
        for start in stride(from: 0, to: samples.count, by: 960) {
            var speech: [Double] = []
            speech.reserveCapacity(960 / decimation)
            for phase in stride(from: start, to: start + 960, by: decimation) {
                var filtered = 0.0
                for i in taps.indices { filtered += input[phase + i] * taps[i] }
                speech.append(filtered)
            }
            // RFC 6716 transmits the preceding frame's redundancy in the first frame
            // of the next packet. RTCP's loss fraction is in units of 1/256.
            let protection = lossFraction >= 5
            let protectedBudget = hybrid ? 24 : 37
            let silkBudget = hybrid ? min(50, frameBytes-16) : min(77, frameBytes)
            let budget = protection && start + 960 == samples.count ? min(protectedBudget,silkBudget) : silkBudget
            let redundant = start == 0 && protection && lastFrameBytes <= protectedBudget+1 ? lastFrame : nil
            let encoded = try encodeFrame(speech, budget: budget)
            if hybrid || redundant != nil {
                var coder = OpusRangeEncoder()
                try coder.symbol(1, [128, 0])
                try coder.symbol(redundant == nil ? 0 : 1, [128, 0])
                if let redundant { try write(redundant, to: &coder) }
                try write(encoded.frame, to: &coder)
                if hybrid {
                    let frameBytes = max(frameBytes, (coder.bitsUsed+7)/8 + 16)
                    try coder.bit(false, logProbability: 12) // no separate CELT transition frame
                    frames.append(try CELTEncoder.encode(spectra[start/960], start: 17, bytes: frameBytes, range: &coder))
                } else { frames.append(try coder.finish()) }
            } else { frames.append(encoded.bytes) }
            lastFrame = encoded.frame
            lastFrameBytes = encoded.bytes.count
        }
        filterTail = Array(input.suffix(60))
        return Self.packet(frames, toc: lowDataMode ? 0x08 : hybrid ? 0x78 : 0x48, target: target)
    }

    /// Fit each 20 ms contribution into RingRTC's 32 kb/s budget. Retry from the
    /// identical prediction history, retaining the finest quantizer that fits.
    private mutating func encodeFrame(_ speech: [Double], budget: Int) throws -> (frame: Frame, bytes: [UInt8]) {
        let original = history + speech
        let predictors = lowDataMode ? Self.narrowPredictors : Self.widePredictors
        let vector = Self.choosePredictor(shortHistory + speech, predictors: predictors)
        let lpc = predictors[vector]
        var whitened = [Double](repeating: 0, count: original.count)
        for i in order..<original.count {
            whitened[i] = original[i] - Self.prediction(lpc, original, at: i)
        }
        let pitch = choosePitch(whitened)
        let taps = pitch?.taps
        var levels: [Double] = [], peaks: [Double] = []
        for part in 0..<4 {
            let start = history.count + part * subframe
            var power = 0.0, peak = 0.0
            for i in start..<start + subframe {
                var value = whitened[i]
                if let pitch, let taps {
                    for j in 0..<5 { value -= taps[part][j] * whitened[i - pitch.lag + 2 - j] }
                }
                power += value * value
                peak = max(peak, abs(value))
            }
            levels.append(sqrt(power / Double(subframe)))
            peaks.append(peak)
        }
        let savedHistory = history, savedShort = shortHistory, savedGain = lastGain
        var scale = max(0.35, quantizerScale * 0.80)
        var lower = 0.0
        var best: (frame: Frame, bytes: [UInt8], history: [Double], short: [Double], gain: Int, scale: Double)?
        for attempt in 0..<9 {
            history = savedHistory
            shortHistory = savedShort
            lastGain = savedGain
            let frame = analyze(speech, vector: vector, lpc: lpc, levels: levels, peaks: peaks,
                                pitch: pitch, whitened: whitened, scale: scale)
            var coder = OpusRangeEncoder()
            try coder.symbol(1, [128, 0])
            try coder.symbol(0, [128, 0])
            try write(frame, to: &coder)
            let bytes = try coder.finish()
            if bytes.count <= budget {
                best = (frame, bytes, history, shortHistory, lastGain, scale)
                if bytes.count + 3 >= budget || scale - lower < 0.14 { break }
                scale = 0.5 * (scale + lower)
            } else {
                lower = scale
                if let best { scale = 0.5 * (scale + best.scale) }
                else {
                    if attempt == 8 {
                        quantizerScale = min(12, scale)
                        return (frame, bytes)
                    }
                    let ratio = Double(bytes.count) / Double(budget)
                    scale *= max(1.25, ratio * ratio)
                }
            }
        }
        guard let best else { throw OpusPacket.Failure.invalidPacket }
        history = best.history
        shortHistory = best.short
        lastGain = best.gain
        quantizerScale = min(12, best.scale)
        return (best.frame, best.bytes)
    }

    /// Estimate the pitch period on the LPC residual. Select the five-tap SILK LTP
    /// codebook vector separately for each subframe, sharing its period class.
    private func choosePitch(_ residual: [Double]) -> Pitch? {
        let first = history.count, last = residual.count
        let rate = subframe / 5
        var lag = rate * 2, score = 0.0, energy = 1.0
        for i in stride(from: first, to: last, by: 2) { energy += residual[i] * residual[i] }
        for period in (rate * 2)...(rate * 18 - 1) {
            var xy = 0.0, yy = 1.0
            for i in stride(from: first, to: last, by: 2) {
                xy += residual[i] * residual[i-period]
                yy += residual[i-period] * residual[i-period]
            }
            let candidate = xy / sqrt(energy * yy)
            if candidate > score * 1.002 { lag = period; score = candidate }
        }
        guard score > 0.4 else { return nil }
        var errors = [Double](repeating: 0, count: 3)
        var indices = [[Int]](repeating: [], count: 3)
        for part in 0..<4 {
            // Form the five-by-five correlation matrix once for all 56 codebook vectors.
            var cross = [Double](repeating: 0, count: 5)
            var autocorrelation = [Double](repeating: 0, count: 25)
            let start = first + part * subframe
            for i in stride(from: start, to: start + subframe, by: 2) {
                for k in 0..<5 {
                    let sample = residual[i-lag+2-k]
                    cross[k] += residual[i] * sample
                    for j in 0...k { autocorrelation[5*k+j] += sample * residual[i-lag+2-j] }
                }
            }
            for (period, table) in Self.pitchTables.enumerated() {
                var best = 0, least = Double.infinity
                for (index, taps) in table.enumerated() {
                    var error = 0.0
                    for k in 0..<5 {
                        var covariance = taps[k] * autocorrelation[5*k+k] - 2 * cross[k]
                        for j in 0..<k { covariance += 2 * taps[j] * autocorrelation[5*k+j] }
                        error += covariance * taps[k]
                    }
                    if error < least { best = index; least = error }
                }
                indices[period].append(best)
                errors[period] += least
            }
        }
        guard let best = errors.indices.min(by: { errors[$0] < errors[$1] }), errors[best] < -energy * 0.20 else { return nil }
        return Pitch(lag: lag, period: best, indices: indices[best])
    }

    private static let pitchTables = [SILKTables.LTP_gain_vq_0, SILKTables.LTP_gain_vq_1, SILKTables.LTP_gain_vq_2].map { table in
        stride(from: 0, to: table.count, by: 5).map { start in table[start..<start+5].map { Double($0) / 128 } }
    }

    /// RFC 6716 code 3 padding counts the padding-length byte itself. Keeping
    /// padding outside the SILK frame prevents a decoder from mistaking it for CELT redundancy.
    private static func packet(_ frames: [[UInt8]], toc: UInt8, target: Int) -> Data {
        var lengths: [UInt8] = []
        for frame in frames.dropLast() {
            if frame.count < 252 { lengths.append(UInt8(frame.count)) }
            else {
                let low = 252 + frame.count % 4
                lengths.append(UInt8(low))
                lengths.append(UInt8((frame.count-low)/4))
            }
        }
        let payload = frames.reduce(0) { $0+$1.count }
        if frames.count == 1, payload+1 >= target { return Data([toc]+frames[0]) }
        let extra = max(0, target-(2+lengths.count+payload))
        var header = UInt8(frames.count)
        if frames.count > 1 { header |= 128 }
        if extra > 0 { header |= 64 }
        var packet = Data([toc | 3,header])
        var padding = extra
        while padding > 255 { packet.append(255); padding -= 255 }
        if padding > 0 { packet.append(UInt8(padding-1)) }
        packet.append(contentsOf:lengths)
        for frame in frames { packet.append(contentsOf:frame) }
        if packet.count < target { packet.append(Data(repeating:0,count:target-packet.count)) }
        return packet
    }

    private static let narrowFilter = lowpass(hz: 3400)
    private static let wideFilter = lowpass(hz: 7300)

    private static func lowpass(hz: Double) -> [Double] {
        let cutoff = hz / 48000
        let taps = (0...60).map { i -> Double in
            let x = Double(i - 30)
            let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            let phase = 2 * Double.pi * Double(i) / 60
            return sinc * (0.42 - 0.5 * cos(phase) + 0.08 * cos(2 * phase))
        }
        let sum = taps.reduce(0, +)
        return taps.map { $0 / sum }
    }

    private mutating func analyze(_ speech: [Double], vector: Int, lpc: [Double], levels: [Double],
                                  peaks: [Double], pitch: Pitch?, whitened: [Double], scale: Double) -> Frame {
        var codes: [Int] = [], gains: [Double] = []
        for part in 0..<4 {
            let wanted = max(peaks[part]/100,levels[part]*scale)
            if part == 0 {
                lastGain = Self.nearestGain(wanted, minimum: max(0, lastGain - 16))
                codes.append(lastGain)
            } else {
                let target = Self.nearestGain(wanted, minimum: 0)
                let threshold = lastGain + 8
                let delta = target - lastGain
                let step = max(-4, min(36, delta > threshold ? threshold + (delta - threshold + 1) / 2 : delta))
                codes.append(step + 4)
                lastGain = max(0, min(63, lastGain + (step > threshold ? 2 * step - threshold : step)))
            }
            gains.append(Self.gainSteps[lastGain])
        }
        var reconstructed = shortHistory
        var residual = whitened.prefix(history.count).map { min(32767, max(-32768, $0.rounded())) * (15565.0 / 16384) }
        var pcm: [Double] = []
        let taps = pitch?.taps
        let offset = (pitch == nil ? 100.0 : 32.0) / 1024
        var pulses: [Int] = []
        var seed: Int32 = 0
        for i in speech.indices {
            let gain = gains[i / subframe]
            let predicted = Self.prediction(lpc, reconstructed, at: reconstructed.count)
            var long = 0.0
            if let pitch, let taps {
                for j in 0..<5 { long += taps[i/subframe][j] * residual[residual.count-pitch.lag+2-j] }
            }
            seed = seed &* 196_314_165 &+ 907_633_515
            let sign = seed < 0 ? -1.0 : 1.0
            let t = history.count + i
            var sourceResidual = whitened[t]
            if let pitch, let taps {
                for j in 0..<5 { sourceResidual -= taps[i/subframe][j] * whitened[t-pitch.lag+2-j] }
            }
            // Shape quantization error using both the unquantized and reconstructed history.
            // A fully closed prediction loop amplifies noise for narrow formants at 32 kb/s.
            let closed = speech[i] - predicted - long
            let desired = sign * (sourceResidual * 0.65 + closed * 0.35) / gain - offset
            let adjusted = desired + (desired >= 0 ? 80.0 : -80.0) / 1024
            let pulse = Int(max(-127, min(127, adjusted.rounded())))
            var excitation = Double(pulse) + offset
            if pulse != 0 { excitation -= (pulse > 0 ? 80.0 : -80.0) / 1024 }
            let sample = long + sign * gain * excitation
            residual.append(sample)
            reconstructed.append(predicted + sample)
            pcm.append(min(32767, max(-32768, (predicted + sample).rounded())))
            pulses.append(pulse)
            seed = seed &+ Int32(pulse)
        }
        shortHistory = Array(reconstructed.suffix(order))
        history = Array((history + pcm).suffix(320))
        return Frame(gainCodes: codes, vector: vector, pulses: pulses, pitch: pitch)
    }

    private func write(_ frame: Frame, to coder: inout OpusRangeEncoder) throws {
        try coder.symbol(frame.pitch == nil ? 0 : 2, SILKTables.type_offset_VAD_iCDF)
        try coder.symbol(frame.gainCodes[0] >> 3, SILKTables.gain_iCDF, offset: frame.pitch == nil ? 8 : 16)
        try coder.symbol(frame.gainCodes[0] & 7, SILKTables.uniform8_iCDF)
        for delta in frame.gainCodes.dropFirst() { try coder.symbol(delta, SILKTables.delta_gain_iCDF) }
        try coder.symbol(frame.vector, lowDataMode ? SILKTables.NLSF_CB1_iCDF_NB_MB : SILKTables.NLSF_CB1_iCDF_WB, offset: frame.pitch == nil ? 0 : 32)
        let selectors = lowDataMode ? SILKTables.NLSF_CB2_SELECT_NB_MB : SILKTables.NLSF_CB2_SELECT_WB
        let residuals = lowDataMode ? SILKTables.NLSF_CB2_iCDF_NB_MB : SILKTables.NLSF_CB2_iCDF_WB
        for i in 0..<order {
            let selection = selectors[(frame.vector * order + i) / 2]
            let table = Int((selection >> (i.isMultiple(of: 2) ? 1 : 5)) & 7)
            try coder.symbol(4, residuals, offset: 9 * table)
        }
        try coder.symbol(4, SILKTables.NLSF_interpolation_factor_iCDF)
        if let pitch = frame.pitch {
            let rate = subframe / 5, index = pitch.lag - 2 * rate
            try coder.symbol(index / (rate / 2), SILKTables.pitch_lag_iCDF)
            try coder.symbol(index % (rate / 2), lowDataMode ? SILKTables.uniform4_iCDF : SILKTables.uniform8_iCDF)
            try coder.symbol(0, lowDataMode ? SILKTables.pitch_contour_NB_iCDF : SILKTables.pitch_contour_iCDF)
            try coder.symbol(pitch.period, SILKTables.LTP_per_index_iCDF)
            let table = [SILKTables.LTP_gain_iCDF_0, SILKTables.LTP_gain_iCDF_1, SILKTables.LTP_gain_iCDF_2][pitch.period]
            for tap in pitch.indices { try coder.symbol(tap, table) }
            try coder.symbol(0, SILKTables.LTPscale_iCDF)
        }
        try coder.symbol(0, SILKTables.uniform4_iCDF)
        try Self.writePulses(frame.pulses, voiced: frame.pitch != nil, to: &coder)
    }

    private static func prediction(_ coefficients: [Double], _ samples: [Double], at index: Int) -> Double {
        var result = 0.0
        for j in coefficients.indices { result += coefficients[j] * samples[index - 1 - j] }
        return result
    }

    /// Pick the stage-one NLSF vector with the least prediction error over the frame.
    /// Evaluating alternate samples limits the work at call time.
    private static func choosePredictor(_ samples: [Double], predictors: [[Double]]) -> Int {
        var best = 0
        var bestError = Double.infinity
        // At call bitrates, previous reconstructed samples contain quantization error.
        // Penalize predictors that would amplify that error into the next excitation.
        let noise = samples.reduce(0.0) { $0 + $1 * $1 } * 0.009
        for (index, lpc) in predictors.enumerated() {
            var energy = lpc.reduce(0.0) { $0 + $1 * $1 } * noise
            for i in stride(from: lpc.count, to: samples.count, by: 2) {
                let residual = samples[i] - prediction(lpc, samples, at: i)
                energy += residual * residual
                if energy >= bestError { break }
            }
            if energy < bestError { bestError = energy; best = index }
        }
        return best
    }

    private static func nearestGain(_ target: Double, minimum: Int) -> Int {
        var best = minimum
        for i in minimum..<gainSteps.count {
            if abs(gainSteps[i] - target) < abs(gainSteps[best] - target) { best = i }
        }
        return best
    }

    private static let narrowPredictors = predictors(SILKTables.NLSF_CB1_NB_MB_Q8, order: 10)
    private static let widePredictors = predictors(SILKTables.NLSF_CB1_WB_Q8, order: 16)

    private static func predictors(_ table: [UInt8], order: Int) -> [[Double]] {
        (0..<32).map { row in
            let values = table[(row * order)..<((row + 1) * order)].map { Int($0) << 7 }
            return SILKSynthesis.predictorQ12(values).map { Double($0) / 4096 }
        }
    }
    private static let gainSteps = (0..<64).map { Double(SILKSynthesis.gainQ16($0)) / 65536 }

    /// RFC 6716 §4.2.7.8.6–8. Encode each sixteen-sample block as a binary tree of
    /// unsigned pulse counts, followed by the lower bits and then the signs.
    private static func writePulses(_ pulses: [Int], voiced: Bool, to coder: inout OpusRangeEncoder) throws {
        struct Block {
            let tree: [[Int]]
            let shift: Int
            var total: Int { tree[4][0] }
        }
        let limits = [8, 10, 12, 16]
        var blocks: [Block] = []
        for start in stride(from: 0, to: pulses.count, by: 16) {
            let magnitudes = pulses[start..<start + 16].map(abs)
            var shift = 0
            while true {
                var tree = [magnitudes.map { $0 >> shift }]
                for level in 0..<4 {
                    let children = tree[level]
                    let sums = stride(from: 0, to: children.count, by: 2).map { children[$0] + children[$0 + 1] }
                    if sums.contains(where: { $0 > limits[level] }) { break }
                    tree.append(sums)
                }
                if tree.count == 5 {
                    blocks.append(Block(tree: tree, shift: shift))
                    break
                }
                shift += 1
            }
        }
        func symbolCost(_ value: Int, _ table: [UInt8], at offset: Int) -> Double {
            let upper = value == 0 ? 256 : Int(table[offset + value - 1])
            return -log2(Double(upper - Int(table[offset + value])) / 256)
        }
        var bestRate = 0, bestCost = Double.infinity
        for rate in 0..<9 {
            var cost = symbolCost(rate, SILKTables.rate_levels_iCDF, at: voiced ? 9 : 0)
            for block in blocks {
                cost += symbolCost(block.shift == 0 ? block.total : 17, SILKTables.pulses_per_block_iCDF, at: rate * 18)
            }
            if cost < bestCost { bestRate = rate; bestCost = cost }
        }
        try coder.symbol(bestRate, SILKTables.rate_levels_iCDF, offset: voiced ? 9 : 0)
        for block in blocks {
            var row = bestRate
            for _ in 0..<block.shift {
                try coder.symbol(17, SILKTables.pulses_per_block_iCDF, offset: row * 18)
                row = 9
            }
            try coder.symbol(block.total, SILKTables.pulses_per_block_iCDF, offset: row * 18)
        }
        let tables = [SILKTables.shell_code_table0, SILKTables.shell_code_table1, SILKTables.shell_code_table2, SILKTables.shell_code_table3]
        func split(_ tree: [[Int]], level: Int, index: Int, coder: inout OpusRangeEncoder) throws {
            let total = tree[level][index]
            guard level > 0, total > 0 else { return }
            let left = 2 * index
            try coder.symbol(tree[level - 1][left], tables[level - 1], offset: Int(SILKTables.shell_code_table_offsets[total]))
            try split(tree, level: level - 1, index: left, coder: &coder)
            try split(tree, level: level - 1, index: left + 1, coder: &coder)
        }
        for block in blocks { try split(block.tree, level: 4, index: 0, coder: &coder) }
        for (index, block) in blocks.enumerated() where block.shift > 0 {
            for pulse in pulses[index * 16..<index * 16 + 16] {
                for bit in (0..<block.shift).reversed() {
                    try coder.symbol((abs(pulse) >> bit) & 1, SILKTables.lsb_iCDF)
                }
            }
        }
        for (index, block) in blocks.enumerated() where block.total > 0 {
            let probability = SILKTables.sign_iCDF[(voiced ? 28 : 14) + min(6, block.total)]
            for pulse in pulses[index * 16..<index * 16 + 16] where pulse != 0 {
                try coder.symbol(pulse > 0 ? 1 : 0, [probability, 0])
            }
        }
    }
}
