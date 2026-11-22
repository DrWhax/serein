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

// SILK spectral and pitch synthesis, RFC 6716 sections 4.2.7.4–4.2.7.9.
// Reference algorithm and codebook attribution accompanies SILKTables.swift.
import Foundation

struct SILKSynthesis {
    private var gainIndex = 10
    private var lastPitch = 0
    private var previousFrequencies: [Int] = []
    /// Physical units across subframes, so changes in quantization gain do not rescale history.
    private var shortHistory = [Double](repeating: 0, count: 16)
    private var pcmHistory = [Int16](repeating: 0, count: 320)

    static func gainQ16(_ index: Int) -> Int {
        let logGain = min(3967, ((1_907_825 * index) >> 16) + 2090)
        if logGain == 3967 { return Int(Int32.max) }
        let power = 1 << (logGain >> 7)
        let fraction = logGain & 127
        let curve = fraction + ((fraction * (128 - fraction) * -174) >> 16)
        return power + (power >> 7) * curve
    }

    /// Convert a stabilized Q15 line spectral frequency vector to the Q12 LPC predictor.
    static func predictorQ12(_ frequencies: [Int]) -> [Int] {
        let count = frequencies.count
        let order = count == 16 ? [0,15,8,7,4,11,12,3,2,13,10,5,6,9,14,1] : [0,9,6,3,4,5,8,1,2,7]
        var roots = [Int](repeating: 0, count: count)
        for (i, frequency) in frequencies.enumerated() {
            let index = frequency >> 8
            let first = SILKTables.cosineQ12[index]
            let difference = SILKTables.cosineQ12[index+1] - first
            roots[order[i]] = (first * 256 + difference * (frequency & 255) + 8) >> 4
        }
        func polynomial(_ offset: Int) -> [Int] {
            var values = [Int](repeating: 0, count: count/2 + 1)
            values[0] = 65536
            values[1] = -roots[offset]
            for k in 1..<(count/2) {
                let root = roots[2*k+offset]
                values[k+1] = values[k-1] * 2 - ((root * values[k] + 32768) >> 16)
                if k >= 2 {
                    for i in (2...k).reversed() {
                        values[i] += values[i-2] - ((root * values[i-1] + 32768) >> 16)
                    }
                }
                values[1] -= root
            }
            return values
        }
        let even = polynomial(0), odd = polynomial(1)
        var combined = roots
        for i in 0..<(count/2) {
            let p = even[i+1] + even[i]
            let q = odd[i+1] - odd[i]
            combined[i] = -q-p
            combined[count-i-1] = q-p
        }
        func expand(_ values: inout [Int], factor: Int) {
            var chirp = factor
            for i in values.indices {
                values[i] = (values[i] * chirp) >> 16
                chirp += ((chirp * (factor - 65536) + 32768) >> 16)
            }
        }
        for _ in 0..<10 {
            guard let index = combined.indices.max(by: { abs(combined[$0]) < abs(combined[$1]) }) else { break }
            let peak = min(163838, (abs(combined[index]) + 16) >> 5)
            if peak <= 32767 { break }
            expand(&combined, factor: 65470 - ((peak-32767) << 14) / ((peak * (index+1)) >> 2))
        }
        var coefficients = combined.map { Int(Int16(clamping: ($0 + 16) >> 5)) }
        for i in 0..<16 {
            if stable(coefficients) { break }
            expand(&combined, factor: 65536 - (2 << i))
            coefficients = combined.map { Int(Int16(clamping: ($0 + 16) >> 5)) }
        }
        return coefficients
    }

    private static func stable(_ coefficients: [Int]) -> Bool {
        var a = coefficients.map { Double($0) / 4096 }
        var inverseGain = 1.0
        for i in a.indices.reversed() {
            let reflection = a[i]
            if abs(reflection) >= 0.99975 { return false }
            let scale = 1 - reflection * reflection
            inverseGain *= scale
            if inverseGain < 0.0001 { return false }
            let previous = a
            for j in 0..<i { a[j] = (previous[j] + reflection * previous[i-1-j]) / scale }
        }
        return true
    }

    mutating func render(_ frame: SILKParameters, pulses: [Int], conditional: Bool) -> [Int16] {
        let order = frame.frequencies.count
        let interpolated = !previousFrequencies.isEmpty && frame.interpolation < 4
        let last = Self.predictorQ12(frame.frequencies).map { Double($0) / 4096 }
        var first = last
        if interpolated {
            let frequencies = zip(previousFrequencies, frame.frequencies).map { $0 + ((($1-$0) * frame.interpolation) >> 2) }
            first = Self.predictorQ12(frequencies).map { Double($0) / 4096 }
        }
        previousFrequencies = frame.frequencies
        lastPitch = frame.lags.last ?? 0
        var seed = frame.seed
        let offset = (frame.type == 2 ? [32.0, 100] : [100.0, 240])[frame.offset] / 1024
        var buffer = pcmHistory
        var residual = [Double](repeating: 0, count: buffer.count)
        var short = shortHistory
        let block = pulses.count / frame.gainIndices.count
        for (k, value) in frame.gainIndices.enumerated() {
            if k == 0 && !conditional { gainIndex = max(value, gainIndex - 16) }
            else {
                let delta = value - 4
                let threshold = gainIndex + 8
                gainIndex += delta > threshold ? 2 * delta - threshold : delta
            }
            gainIndex = min(63, max(0, gainIndex))
            let gain = Double(Self.gainQ16(gainIndex)) / 65536
            let coefficients = k < 2 ? first : last
            let voiced = frame.type == 2
            let lag = voiced ? frame.lags[k] : 0
            if voiced && (k == 0 || (k == 2 && interpolated)) {
                // Re-whiten the signal that precedes this pitch period with the new LPC filter.
                let scale = k == 0 ? frame.pitchScale : 1
                for j in buffer.count-lag-2..<buffer.count {
                    var prediction = 0.0
                    for tap in 0..<order { prediction += coefficients[tap] * Double(buffer[j-tap-1]) }
                    residual[j] = scale * min(32767, max(-32768, (Double(buffer[j])-prediction).rounded()))
                }
            }
            for i in k*block..<(k+1)*block {
                seed = seed &* 196_314_165 &+ 907_633_515
                let pulse = pulses[i]
                let excitation = Double(pulse) - Double(pulse.signum()) * (80.0 / 1024) + offset
                var sample = (seed < 0 ? -excitation : excitation) * gain
                seed = seed &+ Int32(pulse)
                if voiced {
                    for tap in 0..<5 {
                        sample += frame.pitchTaps[k][tap] * residual[residual.count-lag+2-tap]
                    }
                }
                residual.append(sample)
                for tap in 0..<order { sample += coefficients[tap] * short[short.count-1-tap] }
                // The fixed-point SILK synthesis state saturates at signed Q14 before gain.
                sample = max(-131072 * gain, min((131072 - 1.0/16384) * gain, sample))
                short.append(sample)
                buffer.append(Int16(max(-32768, min(32767, sample.rounded()))))
            }
        }
        shortHistory = Array(short.suffix(16))
        pcmHistory = Array(buffer.suffix(320))
        return Array(buffer.suffix(pulses.count))
    }

    /// Continue a voiced pitch period across an erased frame, attenuating the signal.
    /// Unvoiced input fades over a 5 ms block. Preserve the synthesized history so the
    /// following good packet can predict from the signal the listener actually received.
    mutating func conceal(samples: Int, kilohertz: Int) -> [Int16] {
        let period = lastPitch > 0 ? lastPitch : 5 * kilohertz
        let gain = lastPitch > 0 ? 0.80 : 0.35
        var buffer = pcmHistory
        for _ in 0..<samples { buffer.append(Int16((Double(buffer[buffer.count-period]) * gain).rounded(.towardZero))) }
        pcmHistory = Array(buffer.suffix(320))
        shortHistory = buffer.suffix(16).map(Double.init)
        gainIndex = 10
        return Array(buffer.suffix(samples))
    }
}
