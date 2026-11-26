#if os(Linux)
import Foundation
import Testing
@testable import SignalUI

@Suite @MainActor struct AudioOutputTests {
    @Test func invalidFormatAndPauseDuringLoad() async throws {
        let engine = AudioPlaybackEngine()
        await #expect(throws: AudioPlaybackEngine.PlaybackError.invalidAudio) {
            try await engine.load { _, _ in PCMChunk(sampleRate: 48000, channels: 0, totalFrames: 1, startFrame: 0, samples: []) }
        }
        try await engine.load { _, _ in
            await engine.pause()
            return PCMChunk(sampleRate: 48000, channels: 1, totalFrames: 1, startFrame: 0, samples: [0])
        }
        #expect(!engine.isLoaded && !engine.isPlaying)
    }

    // Docker sets ALSA's default output to its file plugin, backed by the null PCM.
    // The same output path used for desktop playback produces the samples on disk.
    @Test func deviceOutputAndTimeStretch() async throws {
        guard let capture = ProcessInfo.processInfo.environment["SEREIN_TEST_PCM_FILE"] else { return }
        let sampleRate = 48000, frames = 48000
        let wave = (0..<frames).map { Float(0.4 * sin(Double($0) * 2 * .pi * 440 / Double(sampleRate))) }
        let engine = AudioPlaybackEngine()
        for tempo in [1.0, 2.0] {
            try await engine.load({ start, count in
                let end = min(frames, start + count)
                return PCMChunk(sampleRate: sampleRate, channels: 1, totalFrames: frames, startFrame: start, samples: Array(wave[start..<end]))
            }, playbackRate: tempo)
            var ended = 0
            engine.onEnded = { ended += 1 }
            await engine.play()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while engine.isPlaying, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(engine.lastError == nil)
            #expect(ended == 1)
            #expect(engine.currentTime == 1)
            let data = try Data(contentsOf: URL(fileURLWithPath: capture))
            let output = stride(from: 0, to: data.count / 4 * 4, by: 4).map { i in
                let low = UInt32(data[i]) | UInt32(data[i+1]) << 8
                let high = UInt32(data[i+2]) << 16 | UInt32(data[i+3]) << 24
                return Float(bitPattern: low | high)
            }
            if tempo == 1 { #expect(output == wave) }
            else {
                #expect(abs(output.count - frames / 2) < 100)
                let rising = zip(output, output.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
                #expect(abs(rising - 220) < 5)
            }
        }
    }
}
#endif
