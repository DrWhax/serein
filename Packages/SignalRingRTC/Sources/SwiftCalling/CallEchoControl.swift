import CoreMedia
import Synchronization

/// Far-end PCM is tagged with its presentation time on the host clock, including the renderer's
/// jitter buffer. Fit and subtract coherent echoes only. The near-end signal is never gated.
final class CallEchoControl: Sendable {
    private struct State: Sendable {
        var enabled: Bool
        var start: Int64 = 0
        var samples: [Int16] = []
        var delays: [Int] = []
        var age = 0
        var capture = MicrophoneProcessing()
    }
    private let state: Mutex<State>
    private static let maxDelay = 12_000  // 250 ms at 48 kHz
    static var hostFrame: Int64 { CMClock.hostTimeClock.time.convertScale(48_000, method: .default).value }

    // AEC measurements can isolate the canceller with all other capture processing bypassed.
    private let conditionMicrophone: Bool
    init(enabled: Bool, conditionMicrophone: Bool = true) {
        self.conditionMicrophone = conditionMicrophone
        state = Mutex(State(enabled: enabled))
    }

    func setEnabled(_ enabled: Bool) { state.withLock { $0 = State(enabled: enabled) } }
    func reset() { state.withLock { $0 = State(enabled: $0.enabled) } }

    func render(_ samples: [Int16], at frame: Int64) {
        state.withLock { s in
            guard s.enabled else { return }
            let gap = frame - s.start - Int64(s.samples.count)
            // Scheduling uses two clock reads. Absorb their sub-millisecond jitter for contiguous frames.
            if s.samples.isEmpty || gap < -48 || gap > 17_280 {
                s.start = frame
                s.samples = samples
                s.delays = []
            } else {
                if gap > 48 { s.samples += repeatElement(0, count: Int(gap)) }
                s.samples += samples
            }
            // 250 ms acoustic tail, 360 ms renderer lead and a 120 ms maximum decoded frame.
            if s.samples.count > 40_000 {
                let drop = s.samples.count - 36_000
                s.samples.removeFirst(drop)
                s.start += Int64(drop)
            }
        }
    }

    func capture(_ mic: [Int16], at frame: Int64) -> [Int16] {
        guard mic.count == 960 else { return mic }
        return state.withLock { s in
            guard s.enabled else { return mic }
            let residual = Self.cancel(mic, at: frame, state: &s)
            return conditionMicrophone ? s.capture.process(residual) : residual
        }
    }

    func process(_ mic: [Int16], at frame: Int64 = hostFrame - 960) -> [Int16] {
        guard mic.count == 960 else { return mic }
        return state.withLock { Self.cancel(mic, at: frame, state: &$0) }
    }

    private static func cancel(_ mic: [Int16], at frame: Int64, state s: inout State) -> [Int16] {
        guard s.enabled, !s.samples.isEmpty else { return mic }
        let start = frame - s.start
        guard start >= 0, start < Int64(s.samples.count + Self.maxDelay) else { return mic }
        let first = max(0, Int(start) - Self.maxDelay)
        let last = min(Int(start), s.samples.count - mic.count)
        guard first <= last else { return mic }

        // Find two independent correlated paths (direct sound and a reflection). Track a locked
        // delay in a small neighborhood most frames and periodically reacquire across the tail.
        var residual = mic.map(Double.init)
        var delays: [Int] = []
        for path in 0..<2 {
            var region = first...last
            if !s.age.isMultiple(of: 6), path < s.delays.count {
                let prediction = Int(start) - s.delays[path]
                let lower = max(first, prediction - 48), upper = min(last, prediction + 48)
                if lower <= upper { region = lower...upper }
            }
            guard let fit = Self.match(residual, reference: s.samples, region: region) else { break }
            delays.append(Int(start) - fit.index)
            for i in residual.indices { residual[i] -= fit.gain * Double(s.samples[fit.index + i]) }
        }
        s.age = (s.age + 1) % 6
        s.delays = delays
        guard !delays.isEmpty else { return mic }
        return residual.map { Int16(clamping: Int($0.rounded())) }
    }

    private static func match(_ mic: [Double], reference: [Int16], region: ClosedRange<Int>) -> (index: Int, gain: Double)? {
        // A 6 kHz envelope distinguishes delays cheaply; refine the winner at the original sample rate.
        let width = 8, count = mic.count / width
        var low = [Double](repeating: 0, count: count)
        var far = [Double](repeating: 0, count: (region.count + mic.count - 1) / width)
        for i in low.indices {
            for j in 0..<width { low[i] += mic[width * i + j] }
        }
        for i in far.indices {
            for j in 0..<width { far[i] += Double(reference[region.lowerBound + width * i + j]) }
        }
        var best = region.lowerBound, bestScore = 0.0
        for lag in 0...(far.count - count) {
            var dot = 0.0, energy = 1.0
            for i in low.indices {
                let x = far[lag + i]
                dot += x * low[i]
                energy += x * x
            }
            let score = dot * dot / energy
            if score > bestScore { bestScore = score; best = region.lowerBound + lag * width }
        }
        let nearEnergy = mic.reduce(0) { $0 + $1 * $1 }
        guard nearEnergy > Double(mic.count * 16) else { return nil }
        var winner: (Int, Double)?
        var explained = nearEnergy * 0.12
        for lag in max(region.lowerBound, best - width)...min(region.upperBound, best + width) {
            var dot = 0.0, energy = 1.0
            for i in mic.indices {
                let x = Double(reference[lag + i])
                dot += x * mic[i]
                energy += x * x
            }
            let score = dot * dot / energy
            let gain = dot / energy
            if score > explained, abs(gain) <= 3 {
                explained = score
                winner = (lag, gain)
            }
        }
        return winner
    }
}
