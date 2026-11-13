import AVFAudio
import Testing
@testable import SignalUI

private actor PlaybackGate {
    var entered = false
    var open = false
    var waiting: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        if open { return }
        await withCheckedContinuation { waiting = $0 }
    }
    enum Failure: Error { case timedOut }
    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !entered {
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func release() { open = true; waiting?.resume(); waiting = nil }
}

private actor RewindHeldVideo: VideoFrameSource {
    let gate: PlaybackGate
    init(_ gate: PlaybackGate) { self.gate = gate }
    func frames(_ count: Int) async throws -> [VideoPlanes] { [] }
    func seek(to seconds: Double) async throws { await gate.hold() }
}

@MainActor @Suite struct PlaybackCancellationTests {
    @Test(arguments: ["unload", "pause", "replace"])
    func cancelledRewindCannotRestartPlayback(_ change: String) async throws {
        let gate = PlaybackGate()
        let engine = VideoPlaybackEngine(now: { 0 }, autoDrive: false)
        await engine.load(RewindHeldVideo(gate), duration: 1, rotation: 0)
        let playing = Task { await engine.play() }
        do {
            try await gate.waitUntilEntered()
            switch change {
            case "unload": await engine.unload()
            case "pause": engine.pause()
            default: await engine.load(FakeVideo(count: 12), duration: 1, rotation: 0)
            }
            await gate.release()
            await playing.value
            #expect(!engine.isPlaying, "cancelled playback restarted after \(change)")
            if change == "unload" { #expect(!engine.isLoaded) }
        } catch { await gate.release(); await playing.value; throw error }
    }

    @Test func cancelledAudioLoadCannotInstallItsSource() async throws {
        let gate = PlaybackGate()
        let engine = AudioPlaybackEngine(offlineFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!)
        let loading = Task {
            try await engine.load { start, count in
                await gate.hold()
                return PCMChunk(sampleRate: 48000, channels: 2, totalFrames: 100, startFrame: start,
                                samples: Array(repeating: 0, count: min(count, 100) * 2))
            }
        }
        do {
            try await gate.waitUntilEntered()
            engine.pause()
            await gate.release()
            try await loading.value
            #expect(!engine.isLoaded, "cancelled load installed a late source")
            #expect(!engine.isPlaying)
            try await engine.load { start, count in
                PCMChunk(sampleRate: 48000, channels: 2, totalFrames: 100, startFrame: start,
                         samples: Array(repeating: 0, count: min(count, 100) * 2))
            }
            #expect(engine.isLoaded, "a new load after cancellation must succeed")
        } catch { await gate.release(); _ = await loading.result; throw error }
    }
}
