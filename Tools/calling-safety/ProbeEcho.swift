import CoreAudio
import Foundation
import Synchronization

/// Emits the same quiet, speech-band maximum-length sequence on each pass. Its
/// autocorrelation has a single peak per period. Independent period averages
/// distinguish coherent acoustic leakage from unrelated ambient sound.
enum ProbeEcho {
    enum Failure: Error { case reductionNotDemonstrated, calibration }
    enum Inconclusive: String, Error {
        case noOutputDevice = "no default output device is available"
        case mutedOutput = "output is muted or its volume is zero"
        case noCapture = "fewer than four complete microphone periods"
        case weakReference = "the unprocessed echo was too quiet or inconsistent for a reliable comparison"
        case unstableReference = "the two unprocessed reference levels differed by more than 5 dB"
    }

    private static let chips: [Double] = {
        var state = 1
        return (0..<1023).map { _ in
            let bit = state & 1
            state = ((state << 1) & 1023) | (((state >> 9) ^ (state >> 6)) & 1)
            return bit == 0 ? -1.0 : 1.0
        }
    }()

    private static let probe: [Int16] = {
        var low = 0.0, bass = 0.0
        let cycle = chips.flatMap { [Double](repeating: $0, count: 8) }
        var output = [Int16]()
        for spin in 0..<2 {
            for sample in cycle {
                low += 0.30 * (sample - low)
                bass += 0.025 * (low - bass)
                if spin == 1 { output.append(Int16((1700 * (low - bass)).rounded())) }
            }
        }
        return output
    }()

    private struct Estimate {
        let power, noise, coherence, rms: Double
        var level: Double { ProbeEcho.db(power / (32768 * 32768)) }
        var usable: Bool { power > 6 * noise && level > -70 && coherence > 0.20 }
    }

    private static func db(_ power: Double) -> Double { 10 * log10(max(1e-12, power)) }
    private static func rounded(_ value: Double) -> String { String((value * 10).rounded() / 10) }

    private final class Capture: Sendable {
        private let data = Mutex<[Int16]?>(nil)
        func start() { data.withLock { $0 = [] } }
        func append(_ block: [Int16]) {
            data.withLock { state in
                guard state != nil, (state?.count ?? 0) < 96_000 else { return }
                state?.append(contentsOf: block)
            }
        }
        func finish() -> [Int16] { data.withLock { defer { $0 = nil }; return $0 ?? [] } }
    }

    private static func estimate(_ samples: [Int16]) throws -> Estimate {
        let n = chips.count, width = n * 8
        let periods = samples.count / width
        guard periods >= 4 else { throw Inconclusive.noCapture }
        var groups = [[Double]](repeating: .init(repeating: 0, count: n), count: 2)
        var counts = [0, 0], total = 0.0
        for k in 0..<periods {
            let g = k % 2
            counts[g] += 1
            for i in 0..<n {
                var x = 0.0
                for j in 0..<8 { x += Double(samples[k*width + i*8 + j]) / 8 }
                groups[g][i] += x
                total += x*x
            }
        }
        for g in 0..<2 {
            let mean = groups[g].reduce(0, +) / Double(n)
            for i in 0..<n { groups[g][i] = (groups[g][i] - mean) / Double(counts[g]) }
        }
        var response = [[Double]](repeating: .init(repeating: 0, count: n), count: 2)
        let code = chips + chips
        for lag in 0..<n {
            for g in 0..<2 {
                var sum = 0.0
                for i in 0..<n { sum += groups[g][i] * code[n + i - lag] }
                response[g][lag] = sum / Double(n)
            }
        }
        let combined = zip(response[0], response[1]).map { ($0 + $1) * 0.5 }
        let peak = combined.indices.max { abs(combined[$0]) < abs(combined[$1]) } ?? 0
        var power = 0.0, noise = 0.0
        // Include the direct path plus 10 ms of early reflections around its peak.
        for delay in -12...48 {
            let i = (peak + delay + n) % n
            let a = response[0][i], b = response[1][i]
            power += a*b
            noise += (a-b)*(a-b)/4
        }
        let rms = sqrt(total / Double(periods*n))
        return Estimate(power: max(0, power), noise: max(1e-9, noise),
                        coherence: abs(combined[peak]) / max(1, rms), rms: rms)
    }

    private static func block(_ index: Int, count: Int) -> [Int16] {
        (0..<960).map { i in
            let t = index*960+i, remain = (count-index)*960-i
            let envelope = min(1, Double(min(t, remain))/480)
            return Int16(Double(probe[t % probe.count])*envelope)
        }
    }

    private static func show(_ name: String, _ estimate: Estimate) {
        print("\(name) coherent echo \(rounded(estimate.level)) dBFS, repeat noise \(rounded(db(estimate.noise/(32768*32768)))) dBFS, reference correlation \(rounded(estimate.coherence)), captured RMS \(rounded(db(pow(estimate.rms/32768,2)))) dBFS")
    }

    private static func reduction(_ before: Estimate, _ enabled: Estimate, _ after: Estimate) throws -> Double {
        show("processing off (before)", before)
        show("processing on", enabled)
        show("processing off (after)", after)
        guard before.usable && after.usable else { throw Inconclusive.weakReference }
        guard abs(before.level - after.level) <= 5 else { throw Inconclusive.unstableReference }
        // Conservatively use the weaker baseline and bound attenuation by the enabled pass's noise floor.
        return db(min(before.power, after.power) / max(enabled.power, enabled.noise))
    }

    static func calibration() throws {
        let echo = CallEchoControl(enabled: true)
        var raw = [Int16](), processed = [Int16](), random: UInt32 = 21
        for b in 0..<80 {
            let source = block(b, count: 80), start = b*960
            echo.render(source, at: Int64(start))
            let mic = (0..<960).map { i -> Int16 in
                random = random &* 1_664_525 &+ 1_013_904_223
                let t = start+i
                let noise = Int(Int16(truncatingIfNeeded: random >> 16)) / 450
                let direct = t >= 480 ? Int(probe[(t-480) % probe.count]) / 3 : 0
                let reflection = t >= 879 ? Int(probe[(t-879) % probe.count]) / 6 : 0
                return Int16(direct + reflection + noise)
            }
            let clean = echo.process(mic, at: Int64(start))
            if b >= 12 { raw += mic; processed += clean }
        }
        let before = try estimate(raw), on = try estimate(processed)
        let attenuation = try reduction(before, on, before)
        print("Offline delayed two-path acoustic model, coherent echo reduction \(rounded(attenuation)) dB")
        guard attenuation >= 12 else { throw Failure.calibration }
        let silent = try estimate([Int16](repeating: 0, count: 6 * probe.count))
        let unrelated = try estimate((0..<6*probe.count).map { _ in
            random = random &* 1_664_525 &+ 1_013_904_223
            return Int16(truncatingIfNeeded: random >> 16) / 8
        })
        guard !silent.usable, !unrelated.usable else { throw Failure.calibration }
        print("Offline silence and independent microphone noise both produced an inconclusive reference.")

    }

    /// Query the selected output before opening either device. Some USB and virtual
    /// devices expose no volume controls. The measured-reference gate still applies.
    @discardableResult
    static func route() throws -> Bool {
        let hal = AudioHardwareSystem.shared
        let input = try hal.defaultInputDevice?.name ?? "unavailable"
        guard let device = try hal.defaultOutputDevice else { throw Inconclusive.noOutputDevice }
        let controls = ((try? device.controls) ?? []).filter { (try? $0.scope) == kAudioObjectPropertyScopeOutput }
        func controlsFor(_ kind: AudioClassID) -> [AudioHardwareControl] {
            let available = controls.filter { (try? $0.classID) == kind }
            let main = available.filter { (try? $0.element) == kAudioObjectPropertyElementMain }
            return main.isEmpty ? available : main
        }
        let mute = controlsFor(kAudioMuteControlClassID).map { try? $0.booleanValue }
        let volume = controlsFor(kAudioVolumeControlClassID).map { try? $0.volumeScalarValue }
        let muted = (try? device.isProcessOutputMuted) == true ||
                (!mute.isEmpty && mute.allSatisfy { $0 == true }) ||
                (!volume.isEmpty && volume.allSatisfy { $0 == 0 })
        let scalars = volume.compactMap { $0 }.map { rounded(Double($0) * 100) }.joined(separator: ", ")
        print("Acoustic route \(try device.name) → \(input). Output volume percent \(scalars.isEmpty ? "unavailable" : scalars), muted or zero \(muted).")
        return muted
    }

    static func check() async throws {
        if try route() { throw Inconclusive.mutedOutput }
        print("Playing three short broadband probes at up to −22 dBFS.")
        let echo = CallEchoControl(enabled: false, conditionMicrophone: false)
        let speaker = CallSpeaker(echo: echo), microphone = CallMicrophone(echo: echo)
        let recording = Capture()
        try await speaker.start()
        do {
            let blocks = try await microphone.start()
            let task = Task {
                for await block in blocks { recording.append(block) }
            }
            defer { task.cancel() }
            var results = [Estimate]()
            for enabled in [false, true, false] {
                echo.setEnabled(enabled)
                let origin = ContinuousClock.now
                let count = 83
                let offset = UInt32(results.count * 120_000)
                for i in 0..<count {
                    if i == 25 { recording.start() }
                    try await speaker.enqueue(block(i, count: count), timestamp: offset + UInt32(960*i))
                    try await Task.sleep(until: origin + .milliseconds((i+1)*20), clock: .continuous)
                }
                results.append(try estimate(recording.finish()))
                try await Task.sleep(for: .milliseconds(300))
            }
            let attenuation = try reduction(results[0], results[1], results[2])
            print("Physical coherent echo reduction \(rounded(attenuation)) dB")
            guard attenuation >= 3 else { throw Failure.reductionNotDemonstrated }
        } catch {
            await microphone.stop()
            await speaker.stop()
            throw error
        }
        await microphone.stop()
        await speaker.stop()
    }
}
