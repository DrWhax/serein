// Windowed-sinc sample-rate conversion for the encoder's input (microphone PCM at 44.1/48 kHz
// → the encoder's output rate, as LAME resamples when its lowpass allows a lower rate).
// Kaiser-windowed sinc, 32 taps each side, 1024 phases; the kernel is centred, so output
// sample n is the input at time n · inRate/outRate (no delay).

import CodecCore

struct MP3Resampler: Sendable {
    let inRate: Int, outRate: Int
    static let halfTaps = 32, phases = 1024
    let kernel: [Float]          // phases × (2·halfTaps), tap j ↔ offset j − halfTaps + 1
    var buffer: [Float]          // input; buffer[0] is absolute input index `base`
    var base = -MP3Resampler.halfTaps
    var produced = 0             // output samples produced

    init(inRate: Int, outRate: Int, cutoffHz: Double) {
        self.inRate = inRate
        self.outRate = outRate
        let fc = min(cutoffHz, Double(min(inRate, outRate)) / 2) / Double(inRate)   // cycles per input sample
        let beta = 8.0
        func i0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0
            for k in 1 ..< 40 { term *= (x / 2) * (x / 2) / Double(k * k); sum += term }
            return sum
        }
        let h = Self.halfTaps
        var k = [Float](repeating: 0, count: Self.phases * 2 * h)
        for p in 0 ..< Self.phases {
            let frac = Double(p) / Double(Self.phases)
            var row = [Double](repeating: 0, count: 2 * h)
            var sum = 0.0
            for j in 0 ..< 2 * h {
                let t = Double(j - h + 1) - frac
                let sinc = t == 0 ? 2 * fc : LibM.sin(2 * Double.pi * fc * t) / (Double.pi * t)
                let r = t / Double(h)
                let w = abs(r) >= 1 ? 0 : i0(beta * (1 - r * r).squareRoot()) / i0(beta)
                row[j] = sinc * w
                sum += row[j]
            }
            for j in 0 ..< 2 * h { k[p * 2 * h + j] = Float(row[j] / sum) }
        }
        kernel = k
        buffer = Array(repeating: 0, count: Self.halfTaps)
    }

    /// Appends input and returns the output samples it completes.
    mutating func process(_ input: [Float]) -> [Float] {
        buffer += input
        var out: [Float] = []
        let h = Self.halfTaps
        let available = base + buffer.count       // absolute index one past the last input
        while true {
            // Output n is at input time t = n · in/out.
            let num = produced * inRate
            let i0 = num / outRate
            let frac = Double(num % outRate) / Double(outRate)
            guard i0 + h < available else { break }
            let phase = min(Self.phases - 1, Int((frac * Double(Self.phases)).rounded(.down)))
            var acc: Float = 0
            let row = phase * 2 * h
            for j in 0 ..< 2 * h { acc += buffer[i0 - h + 1 + j - base] * kernel[row + j] }
            out.append(acc)
            produced += 1
        }
        // Keep what the next outputs need.
        let next = (produced * inRate) / outRate - h + 1
        if next - base > 4096 {
            buffer.removeFirst(next - base)
            base = next
        }
        return out
    }

    /// Output samples for the remaining input (zeros after the end).
    mutating func flush(totalInput: Int) -> [Float] {
        let wanted = (totalInput * outRate + inRate - 1) / inRate
        var out: [Float] = []
        while produced < wanted {
            let more = process(Array(repeating: 0, count: Self.halfTaps * 2))
            out += more.prefix(wanted - (produced - more.count))
        }
        return out
    }
}
