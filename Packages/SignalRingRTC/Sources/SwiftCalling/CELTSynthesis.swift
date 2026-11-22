import Foundation

/// The CELT inverse MDCT uses a 60–480 point complex FFT, followed by a 120-sample
/// time-domain alias canceling window. Keep overlap and the pitch filter across RTP packets.
struct CELTSynthesis {
    private var overlap = [Double](repeating: 0, count: 60)
    private var past = [Double](repeating: 0, count: 1026)
    private var previous = Filter(), current = Filter()
    private var preemphasis = 0.0
    private struct Filter {
        var period = 15
        var gain = 0.0
        var tapset = 0
    }
    private static let window: [Double] = (0..<120).map {
        let x = sin((Double($0) + 0.5) * .pi / 240)
        return sin(0.5 * .pi * x * x)
    }
    private static let roots: [SIMD2<Double>] = (0..<480).map {
        let angle = -2 * Double.pi * Double($0) / 480
        return SIMD2(cos(angle), sin(angle))
    }
    private static let trig = (0...3).map { lm in
        let n = 120 << lm
        return (0..<n).map { cos(.pi * (Double($0) + 0.125) / Double(n)) }
    }

    mutating func render(_ frame: CELTFrame, shapes: [[Double]]) -> [Int16] {
        let n = frame.samples
        var bins = [Double](repeating: 0, count: n)
        for c in 0..<frame.channels {
            for b in frame.start..<frame.end {
                let amplitude = exp2(min(32, frame.energies[c][b] + Double(CELTTables.meansQ4[b]) / 16)) / Double(frame.channels)
                for i in CELTTables.edges[b]<<frame.lm..<CELTTables.edges[b+1]<<frame.lm {
                    bins[i] += shapes[c][i] * amplitude
                }
            }
        }
        let blocks = frame.transient ? 1 << frame.lm : 1
        var pcm: [Double] = []
        pcm.reserveCapacity(n)
        for b in 0..<blocks {
            let block = (0..<(n/blocks)).map { bins[$0*blocks+b] }
            pcm += imdct(block, lm: frame.transient ? 0 : frame.lm)
        }
        let new = Filter(period: max(15, frame.period), gain: frame.gain, tapset: frame.tapset)
        var filtered = past + pcm
        Self.comb(&filtered, count: 120, start: past.count, old: previous, new: current)
        if n > 120 { Self.comb(&filtered, count: n-120, start: past.count+120, old: current, new: new) }
        past = Array(filtered.suffix(past.count))
        previous = n > 120 ? new : current
        current = new
        return filtered.suffix(n).map { sample in
            let value = sample + preemphasis
            preemphasis = 0.8500061 * value
            return Int16(clamping: Int(max(-32768, min(32767, value.rounded()))))
        }
    }

    private static func comb(_ buffer: inout [Double], count: Int, start: Int, old: Filter, new: Filter) {
        guard old.gain != 0 || new.gain != 0 else { return }
        let gains = [[0.306640625, 0.217041015625, 0.129638671875], [0.4638671875, 0.26806640625, 0], [0.7998046875, 0.10009765625, 0]]
        func delayed(_ index: Int, _ filter: Filter, _ samples: [Double]) -> Double {
            let at = index - filter.period, g = gains[filter.tapset]
            return filter.gain * (g[0] * samples[at] + g[1] * (samples[at-1] + samples[at+1]) + g[2] * (samples[at-2] + samples[at+2]))
        }
        for i in 0..<count {
            let mix = i < 120 ? window[i] * window[i] : 1
            let at = start + i
            let added = (1-mix) * delayed(at, old, buffer) + mix * delayed(at, new, buffer)
            buffer[at] += added
        }
    }

    /// Analysis is the transpose of the synthesis window and rotations, with
    /// the inverse FFT normalized by its length. The last 120 input samples
    /// overlap the next 20 ms microphone frame.
    static func analyze(_ time: [Double]) -> [Double] {
        let n = 960, half = 480, t = trig[3]
        var folded = Array(time[60..<1020])
        for i in 0..<60 {
            folded[59-i] = -window[i]*time[i] + window[119-i]*time[119-i]
            folded[n-60+i] = window[119-i]*time[n+i] + window[i]*time[n+119-i]
        }
        var input = [SIMD2<Double>](repeating: .zero, count: half)
        for i in 0..<half {
            let a = folded[2*i], b = folded[n-1-2*i]
            input[i] = SIMD2(a*t[half+i] - b*t[i], -(a*t[i] + b*t[half+i]))
        }
        var result = input, scratch = input
        fft(input, offset: 0, stride: 1, count: half, output: &result, scratch: &scratch, base: 0)
        var spectrum = [Double](repeating: 0, count: n)
        for i in 0..<half {
            let re = result[i].x / Double(half), im = -result[i].y / Double(half)
            spectrum[2*i] = re*t[i] + im*t[half+i]
            spectrum[n-1-2*i] = im*t[i] - re*t[half+i]
        }
        return spectrum
    }

    private mutating func imdct(_ x: [Double], lm: Int) -> [Double] {
        let n = x.count, half = n / 2, t = Self.trig[lm]
        var input = [SIMD2<Double>](repeating: .zero, count: half)
        for i in 0..<half {
            let a = x[2*i], b = x[n-1-2*i]
            input[i] = SIMD2(a*t[i] - b*t[half+i], b*t[i] + a*t[half+i])
        }
        var result = input, work = input
        Self.fft(input, offset: 0, stride: 1, count: half, output: &result, scratch: &work, base: 0)
        var time = [Double](repeating: 0, count: n+60)
        for i in 0..<half {
            let v = result[i]
            time[60+2*i] = v.y*t[i] + v.x*t[half+i]
            time[60+n-1-2*i] = v.y*t[half+i] - v.x*t[i]
        }
        for i in 0..<60 {
            let right = time[119-i], left = overlap[i]
            time[i] = left * Self.window[119-i] - right * Self.window[i]
            time[119-i] = left * Self.window[i] + right * Self.window[119-i]
        }
        overlap = Array(time.suffix(60))
        return Array(time.prefix(n))
    }

    private static func fft(_ signal: [SIMD2<Double>], offset: Int, stride: Int, count: Int,
                            output: inout [SIMD2<Double>], scratch: inout [SIMD2<Double>], base: Int) {
        if count == 1 { output[base] = signal[offset]; return }
        let radix = count.isMultiple(of: 4) ? 4 : count.isMultiple(of: 2) ? 2 : count.isMultiple(of: 3) ? 3 : 5
        let size = count / radix
        for j in 0..<radix {
            fft(signal, offset: offset+j*stride, stride: stride*radix, count: size, output: &output, scratch: &scratch, base: base+j*size)
        }
        for k in 0..<count {
            var sum = output[base + k % size]
            for j in 1..<radix {
                let p = output[base + j*size + k % size], w = roots[(k*j % count) * (480/count)]
                sum += SIMD2(p.x*w.x - p.y*w.y, p.x*w.y + p.y*w.x)
            }
            scratch[base+k] = sum
        }
        for i in base..<base+count { output[i] = scratch[i] }
    }
}
