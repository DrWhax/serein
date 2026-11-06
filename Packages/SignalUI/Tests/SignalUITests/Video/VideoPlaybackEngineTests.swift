import AVFAudio
import Testing
@testable import SignalUI

/// 30 fps, sync frame every 10 frames; each frame's Y value is its index.
actor FakeVideo: VideoFrameSource {
    let count: Int
    var next = 0
    var seeks: [Double] = []
    init(count: Int) { self.count = count }
    func frames(_ n: Int) async throws -> [VideoPlanes] {
        let out = (next ..< min(count, next + n)).map { i in
            VideoPlanes(width: 4, height: 2, y: Array(repeating: UInt8(i), count: 8), u: [128, 128], v: [128, 128], fullRange: true, matrix: 1, time: Double(i) / 30)
        }
        next += out.count
        return out
    }
    func seek(to seconds: Double) async throws {
        seeks.append(seconds)
        next = (min(count - 1, Int((seconds * 30 + 1e-9).rounded(.down))) / 10) * 10
    }
}

@MainActor
final class Clock { var t = 0.0 }

@MainActor
@Suite struct VideoPlaybackEngineTests {
    func make(_ n: Int = 30) async -> (VideoPlaybackEngine, FakeVideo, Clock, Box) {
        let clock = Clock(), src = FakeVideo(count: n), shown = Box()
        let e = VideoPlaybackEngine(now: { clock.t }, autoDrive: false)
        e.onFrame = { shown.ids.append(Int($0.y[0])) }
        await e.load(src, duration: Double(n) / 30, rotation: 90)
        return (e, src, clock, shown)
    }

    @MainActor final class Box { var ids: [Int] = [] }

    @Test func playsInTimeAndSkipsLateFrames() async {
        let (e, _, clock, shown) = await make()
        #expect(e.currentFrame?.y[0] == 0 && e.rotation == 90)
        await e.play()
        // Steady 30 Hz ticks show every frame once.
        for k in 1 ... 5 { clock.t = Double(k) / 30; await e.step() }
        #expect(shown.ids == [0, 1, 2, 3, 4, 5])
        // A stall of 0.2 s: the frames that are late are skipped, the due one is shown.
        clock.t = 5.0 / 30 + 0.2
        await e.step()
        #expect(shown.ids.last == 11 && shown.ids.count == 7)
        // Pause holds the time.
        e.pause()
        clock.t += 5
        await e.step()
        #expect(abs(e.currentTime - 11.0 / 30) < 1e-9 && shown.ids.count == 7)
        await e.play()
        clock.t += 1.0 / 30
        await e.step()
        #expect(shown.ids.last == 12)
    }

    @Test func endsAfterTheLastFrame() async {
        let (e, _, clock, shown) = await make(12)
        var ended = 0
        e.onEnded = { ended += 1 }
        await e.play()
        var k = 0
        while e.isPlaying && k < 100 { k += 1; clock.t = Double(k) / 30; await e.step() }
        #expect(shown.ids == Array(0 ..< 12) && ended == 1 && e.currentTime == 12.0 / 30)
        #expect(k == 12, "stopped at tick \(k)")
        // Play again restarts from the beginning.
        await e.play()
        #expect(e.isPlaying && e.currentFrame?.y[0] == 0)
    }

    @Test func loops() async {
        let (e, src, clock, shown) = await make(12)
        e.isLooping = true
        await e.play()
        for k in 1 ... 30 { clock.t = Double(k) / 30; await e.step() }
        #expect(e.loopCount == 2 && e.isPlaying)
        #expect(shown.ids == Array(0 ..< 12) + Array(0 ..< 12) + Array(0 ..< 7), "\(shown.ids)")
        #expect(await src.seeks == [0, 0])
    }

    @Test func seeksToTheExactFrame() async {
        let (e, src, clock, shown) = await make()
        await e.seek(to: 17.0 / 30)
        // From sync frame 10, decoded forward; 17 is shown, not the sync frame.
        #expect(e.currentFrame?.y[0] == 17 && shown.ids.last == 17 && !e.isPlaying)
        #expect(await src.seeks == [17.0 / 30])
        await e.play()
        clock.t += 1.0 / 30
        await e.step()
        #expect(shown.ids.last == 18)
        // Seeking while playing keeps playing.
        await e.seek(to: 3.0 / 30)
        #expect(e.isPlaying && shown.ids.last == 3)
        clock.t += 1.0 / 30
        await e.step()
        #expect(shown.ids.last == 4)
    }

    /// With sound the audio play head is the clock: the host clock is ignored.
    @Test func followsTheAudioClock() async throws {
        let audio = AudioPlaybackEngine(offlineFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!)
        try await audio.load { start, count in
            let n = max(0, min(count, 48000 - start))
            return PCMChunk(sampleRate: 48000, channels: 2, totalFrames: 48000, startFrame: start, samples: Array(repeating: 0, count: n * 2))
        }
        let clock = Clock(), shown = Box()
        let e = VideoPlaybackEngine(audio: audio, now: { clock.t }, autoDrive: false)
        e.onFrame = { shown.ids.append(Int($0.y[0])) }
        await e.load(FakeVideo(count: 30), duration: 1, rotation: 0)
        await e.play()
        #expect(audio.isPlaying)
        clock.t = 10   // a host clock far ahead changes nothing
        for _ in 0 ..< 20 { await Task.yield() }
        _ = try audio.renderOffline(frames: 4096)
        _ = try audio.renderOffline(frames: 4096)
        _ = try audio.renderOffline(frames: 4096)   // 0.256 s
        await e.step()
        #expect(shown.ids.last == 7, "\(shown.ids) at audio \(audio.currentTime)")
        e.pause()
        #expect(!audio.isPlaying)
        // Seeking moves the sound too.
        await e.seek(to: 0.5)
        #expect(abs(audio.currentTime - 0.5) < 0.001 && shown.ids.last == 15)
    }

    /// Malformed or out-of-order frames from the source never reach the renderer.
    @Test func dropsInvalidFrames() async {
        actor Bad: VideoFrameSource {
            var sent = false
            func frames(_ n: Int) async throws -> [VideoPlanes] {
                guard !sent else { return [] }
                sent = true
                let ok = VideoPlanes(width: 2, height: 2, y: [1, 1, 1, 1], u: [128], v: [128], fullRange: true, matrix: 1, time: 0.1)
                var short = ok; short.y = [1]; short.time = 0.2
                var back = ok; back.time = 0.05
                var nan = ok; nan.time = .nan
                return [ok, short, back, nan]
            }
            func seek(to seconds: Double) async throws {}
        }
        let e = VideoPlaybackEngine(now: { 0 }, autoDrive: false)
        await e.load(Bad(), duration: 1, rotation: 45)
        #expect(e.currentFrame?.time == 0.1 && e.queue.isEmpty && e.rotation == 0)
    }
}
