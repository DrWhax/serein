import AVFAudio
import Foundation
import Testing
@testable import SignalUI

@MainActor
@Suite struct AudioPlaybackEngineTests {
    nonisolated static let rate = 48000
    nonisolated static let total = rate * 3 + 123   // more than two chunks
    /// A stereo test signal: a tone, different per channel.
    nonisolated static func sample(_ i: Int, _ c: Int) -> Float { Float(0.5 * sin(Double(i) * (c == 0 ? 0.01 : 0.013))) }
    nonisolated static let source: PCMSource = { start, count in
        let n = max(0, min(count, total - start))
        var s = [Float](repeating: 0, count: n * 2)
        for i in 0 ..< n { s[2 * i] = sample(start + i, 0); s[2 * i + 1] = sample(start + i, 1) }
        return PCMChunk(sampleRate: rate, channels: 2, totalFrames: total, startFrame: start, samples: s)
    }

    func engine() -> AudioPlaybackEngine {
        AudioPlaybackEngine(offlineFormat: AVAudioFormat(standardFormatWithSampleRate: Double(Self.rate), channels: 2)!)
    }

    /// Renders, letting the scheduling tasks run between slices.
    func render(_ e: AudioPlaybackEngine, frames: Int) async throws -> [Float] {
        var out: [Float] = []
        var left = frames
        while left > 0 {
            for _ in 0 ..< 20 { await Task.yield() }
            let n = min(4096, left)
            out += try e.renderOffline(frames: n)
            left -= n
        }
        return out
    }

    @Test func playsTheSourceAndEnds() async throws {
        let e = engine()
        var ended = false
        e.onEnded = { ended = true }
        try await e.load(Self.source)
        #expect(e.duration == Double(Self.total) / Double(Self.rate))
        await e.play()
        let out = try await render(e, frames: Self.total + 8192)
        // At 1× the samples pass through unchanged.
        var worst: Float = 0
        for i in 0 ..< Self.total { for c in 0 ..< 2 { worst = max(worst, abs(out[2 * i + c] - Self.sample(i, c))) } }
        #expect(worst < 1e-6, "max error \(worst)")
        for _ in 0 ..< 50 { await Task.yield() }
        #expect(ended && !e.isPlaying)
    }

    @Test func clockSeekAndPause() async throws {
        let e = engine()
        try await e.load(Self.source)
        await e.play()
        _ = try await render(e, frames: 48000)
        #expect(abs(e.currentTime - 1.0) < 0.03, "\(e.currentTime)")
        await e.seek(to: 2.5)
        _ = try await render(e, frames: 4800)
        #expect(abs(e.currentTime - 2.6) < 0.03, "\(e.currentTime)")
        e.pause()
        let t = e.currentTime
        let silent = try await render(e, frames: 4800)
        #expect(!e.isPlaying && e.currentTime == t)
        #expect(silent.suffix(4000).allSatisfy { abs($0) < 1e-6 })
    }

    @Test func doubleSpeedTakesHalfTheTime() async throws {
        let e = engine()
        var ended = false
        e.onEnded = { ended = true }
        try await e.load(Self.source, playbackRate: 2)
        await e.play()
        _ = try await render(e, frames: Self.total / 2 + 9000)
        for _ in 0 ..< 50 { await Task.yield() }
        #expect(ended)
    }
}




extension AudioPlaybackEngineTests {
    @Test func rateChangeKeepsThePosition() async throws {
        let e = engine()
        try await e.load(Self.source)
        await e.play()
        _ = try await render(e, frames: 24000)
        let before = e.currentTime
        await e.setPlaybackRate(1.5)
        #expect(e.isPlaying && e.playbackRate == 1.5 && abs(e.currentTime - before) < 0.03)
        _ = try await render(e, frames: 24000)
        #expect(e.currentTime > before + 0.5, "\(e.currentTime)")
        await e.setPlaybackRate(1)
        _ = try await render(e, frames: 4096)
        #expect(e.isPlaying)
    }
}
