import AVFAudio
import Foundation

/// Keep the system input on AVAudioEngine's HAL path. AVCaptureSession is needed only when
/// the user chooses a different input, since AVAudioEngine owns its internal aggregate device.
final class EngineMicrophone {
    private let engine = AVAudioEngine()
    private let buffers = AsyncStream<AVReadOnlyAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingNewest(4))
    private var pump: Task<Void, Never>?
    private var observer: (any NSObjectProtocol)?

    init(sink: AsyncStream<[Int16]>.Continuation?, echo: CallEchoControl?, activity: CaptureActivity, changed: @escaping @Sendable () -> Void) throws {
        let input = engine.inputNode, format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let rate = Int(exactly: format.sampleRate), let pcm = MicrophonePCM(sampleRate: rate) else {
            throw CallMicrophone.Failure.unavailable
        }
        let source = buffers.continuation
        try input.installAudioTap(onBus: 0, bufferSize: 960, format: format) { buffer, _ in
            if sink != nil, (1...8192).contains(buffer.frameLength) { source.yield(buffer) }
        }
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                           object: engine, queue: nil) { _ in changed() }
        if let sink {
            pump = Task.detached { [stream = buffers.stream] in
                var pcm = pcm
                for await buffer in stream {
                    guard !Task.isCancelled else { break }
                    guard buffer.format.sampleRate == Double(rate), buffer.format.channelCount > 0,
                          case .float(let channel) = buffer.channelData(0), channel.count >= buffer.frameLength
                    else { changed(); return }
                    activity.received()
                    let frames = pcm.append(channel.extracting(0..<buffer.frameLength))
                    let start = CallEchoControl.hostFrame - Int64(frames.count * 960)
                    for (index, samples) in frames.enumerated() {
                        guard !Task.isCancelled else { return }
                        sink.yield(echo?.capture(samples, at: start + Int64(index * 960)) ?? samples)
                    }
                }
            }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        pump?.cancel()
        buffers.continuation.finish()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Rational input phase avoids drift across callback boundaries. Filter high-rate input before decimation.
struct MicrophonePCM {
    private let inputRate: Int
    private let lowpass: [Double]
    private var filterTail: [Double]
    private var previous: Double?
    private var phase = 0
    private var accumulating: [Int16] = []

    init?(sampleRate: Int) {
        guard (8000...192_000).contains(sampleRate) else { return nil }
        inputRate = sampleRate
        if sampleRate <= 48_000 {
            lowpass = [1]
        } else {
            let cutoff = 21_000.0 / Double(sampleRate)
            let taps = (0...48).map { i -> Double in
                let x = Double(i - 24)
                let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
                let angle = 2 * Double.pi * Double(i) / 48
                return sinc * (0.42 - 0.5 * cos(angle) + 0.08 * cos(2 * angle))
            }
            let gain = taps.reduce(0, +)
            lowpass = taps.map { $0 / gain }
        }
        filterTail = [Double](repeating: 0, count: lowpass.count - 1)
        accumulating.reserveCapacity(960)
    }

    mutating func append(_ input: Span<Float>) -> [[Int16]] {
        guard (1...8192).contains(input.count) else { return [] }
        var filtered = filterTail
        for i in 0..<input.count {
            let value = input[i]
            filtered.append(value.isFinite ? max(-1, min(1, Double(value))) : 0)
        }
        var blocks: [[Int16]] = []
        for i in 0..<input.count {
            var value = 0.0
            for j in lowpass.indices { value += filtered[i+j] * lowpass[j] }
            if let previous {
                while phase <= 48_000 {
                    let sample = previous + (value - previous) * Double(phase) / 48_000
                    accumulating.append(Int16(clamping: Int((sample * 32768).rounded())))
                    if accumulating.count == 960 {
                        blocks.append(accumulating)
                        accumulating.removeAll(keepingCapacity: true)
                    }
                    phase += inputRate
                }
                phase -= 48_000
            } else {
                accumulating.append(Int16(clamping: Int((value * 32768).rounded())))
                phase = inputRate
            }
            previous = value
        }
        filterTail = Array(filtered.suffix(lowpass.count - 1))
        return blocks
    }
}
