// Audio playback for voice notes and audio attachments: the role of upstream's
// globalMessageAudio (one HTMLAudioElement shared by all messages) over AVAudioEngine.
// AVAudioEngine only plays PCM here; the PCM comes decoded from the sandboxed media service
// through `PCMSource` (chunks of the presentation timeline), so no Apple decoder touches
// attachment bytes. Rate changes keep the pitch (AVAudioUnitTimePitch), as <audio> does.
//
// Chunks of `chunkFrames` are fetched ahead of the play head (two scheduled at a time); a
// seek or pause drops what is scheduled and restarts from the new position.

import AVFAudio
import Foundation
import Observation

/// Decoded audio from the media service: interleaved float32 samples of [startFrame,
/// startFrame + frames) out of `totalFrames`.
public struct PCMChunk: Sendable, Equatable {
    public var sampleRate: Int
    public var channels: Int
    public var totalFrames: Int
    public var startFrame: Int
    public var samples: [Float]

    public init(sampleRate: Int, channels: Int, totalFrames: Int, startFrame: Int, samples: [Float]) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.totalFrames = totalFrames
        self.startFrame = startFrame
        self.samples = samples
    }

    public var frames: Int { channels > 0 ? samples.count / channels : 0 }
}

/// Fetches frames [start, start + count).
public typealias PCMSource = @Sendable (_ start: Int, _ count: Int) async throws -> PCMChunk

@MainActor
@Observable
public final class AudioPlaybackEngine {
    public static let chunkFrames = 48000 * 4

    public private(set) var isPlaying = false
    public private(set) var isLoaded = false
    /// Seconds; nil until loaded.
    public private(set) var duration: Double?
    public private(set) var lastError: String?
    /// At 1× the player feeds the mixer directly (exact samples, no time-pitch buffering, so
    /// the clock and pauses are immediate); other rates go through the time-pitch unit.
    public private(set) var playbackRate: Double = 1

    public func setPlaybackRate(_ rate: Double) async {
        let r = min(max(rate, 1.0 / 32), 32)
        guard r != playbackRate else { return }
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        playbackRate = r
        timePitch.rate = Float(r)
        if format != nil { try? route() }
        if wasPlaying { await play() }
    }

    func route() throws {
        guard let f = format else { return }
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(timePitch)
        if playbackRate == 1 {
            try engine.connectNode(player, to: engine.mainMixerNode, format: f)
        } else {
            try engine.connectNode(player, to: timePitch, format: f)
            try engine.connectNode(timePitch, to: engine.mainMixerNode, format: f)
        }
    }
    /// Called when playback reaches the end.
    @ObservationIgnored public var onEnded: (() -> Void)?

    @ObservationIgnored let engine = AVAudioEngine()
    @ObservationIgnored let player = AVAudioPlayerNode()
    @ObservationIgnored let timePitch = AVAudioUnitTimePitch()
    @ObservationIgnored var source: PCMSource?
    @ObservationIgnored var format: AVAudioFormat?
    @ObservationIgnored var totalFrames = 0
    /// Frame the player node's sample time 0 corresponds to.
    @ObservationIgnored var segmentStart = 0
    /// Next frame to fetch and schedule.
    @ObservationIgnored var scheduleCursor = 0
    @ObservationIgnored var scheduledAhead = 0
    /// Bumped on every load/seek/pause so stale fetches and completions are ignored.
    @ObservationIgnored var generation = 0
    @ObservationIgnored var pausedAt = 0
    @ObservationIgnored let manualRendering: Bool

    /// `offlineFormat`: render offline (tests) instead of to the output device.
    public init(offlineFormat: AVAudioFormat? = nil) {
        manualRendering = offlineFormat != nil
        engine.attach(player)
        engine.attach(timePitch)
        if let f = offlineFormat {
            try? engine.enableManualRenderingMode(.offline, format: f, maximumFrameCount: 4096)
        }
    }

    /// Prepares `source` (fetching its first chunk to learn the format and length).
    public func load(_ source: @escaping PCMSource, playbackRate: Double = 1) async throws {
        stopNode()
        isLoaded = false
        self.source = nil
        format = nil
        generation += 1
        let gen = generation
        let first = try await source(0, Self.chunkFrames)
        guard gen == generation else { return }
        guard first.sampleRate > 0, (1 ... 2).contains(first.channels), first.samples.count == first.frames * first.channels,
              let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(first.sampleRate), channels: AVAudioChannelCount(first.channels), interleaved: false)
        else { throw PlaybackError.invalidAudio }
        self.source = source
        format = f
        totalFrames = first.totalFrames
        duration = Double(first.totalFrames) / Double(first.sampleRate)
        self.playbackRate = min(max(playbackRate, 1.0 / 32), 32)
        timePitch.rate = Float(self.playbackRate)
        try route()
        segmentStart = 0
        pausedAt = 0
        scheduleCursor = 0
        isLoaded = true
        lastError = nil
    }

    public enum PlaybackError: Error { case invalidAudio, notLoaded }

    /// Seconds into the audio.
    public var currentTime: Double {
        guard let f = format else { return 0 }
        return Double(currentFrame) / f.sampleRate
    }

    var currentFrame: Int {
        guard isPlaying, let nodeTime = player.lastRenderTime, let t = player.playerTime(forNodeTime: nodeTime) else { return pausedAt }
        return min(totalFrames, segmentStart + max(0, Int(t.sampleTime)))
    }

    /// Starts (or resumes) playback once the chunk at the play head is scheduled, so the
    /// node's clock never counts a starved start.
    public func play() async {
        guard isLoaded, !isPlaying else { return }
        if pausedAt >= totalFrames { pausedAt = 0 }
        if !engine.isRunning {
            do { try engine.start() } catch { lastError = "\(error)"; return }
        }
        generation += 1
        let gen = generation
        segmentStart = pausedAt
        scheduleCursor = pausedAt
        scheduledAhead = 0
        isPlaying = true
        await scheduleChunk(gen)
        guard gen == generation, isPlaying else { return }
        do { try player.playAudio() } catch { lastError = "\(error)"; stopNode(); return }
        scheduleMore(gen)
    }

    public func pause() {
        if isPlaying { pausedAt = currentFrame }
        // Also invalidate a suspended load, before playback has become active.
        stopNode()
    }

    /// Moves the play head (keeps playing if playing).
    public func seek(to seconds: Double) async {
        guard let f = format else { return }
        let frame = min(max(0, Int(seconds * f.sampleRate)), totalFrames)
        let wasPlaying = isPlaying
        stopNode()
        pausedAt = frame
        if wasPlaying { await play() }
    }

    func stopNode() {
        generation += 1
        if isPlaying || player.isPlaying { player.stop() }
        isPlaying = false
        scheduledAhead = 0
    }

    /// Keeps two chunks scheduled ahead of the play head.
    func scheduleMore(_ gen: Int) {
        guard gen == generation, isPlaying else { return }
        while scheduledAhead < 2 && scheduleCursor < totalFrames {
            Task { @MainActor in await self.scheduleChunk(gen) }
            // `scheduleChunk` advances the cursor before it awaits.
            if scheduledAhead >= 2 { break }
            break
        }
    }

    /// Fetches and schedules the chunk at the cursor.
    func scheduleChunk(_ gen: Int) async {
        guard gen == generation, isPlaying, let source, let format, scheduleCursor < totalFrames else { return }
        let start = scheduleCursor
        let count = min(Self.chunkFrames, totalFrames - start)
        scheduleCursor += count
        scheduledAhead += 1
        do {
            let chunk = try await source(start, count)
            guard gen == generation else { return }
            guard chunk.startFrame == start, chunk.channels == Int(format.channelCount), chunk.frames <= count,
                  let buffer = PCMBuffer.make(format: format, interleaved: chunk.samples, frames: chunk.frames) else {
                lastError = "invalid audio chunk"
                finish(gen)
                return
            }
            let last = start + count >= totalFrames
            // Offline rendering has no playback clock: count rendered data instead.
            player.scheduleBuffer(buffer, completionCallbackType: manualRendering ? .dataRendered : .dataPlayedBack) { _ in
                Task { @MainActor in self.chunkPlayed(gen, last: last) }
            }
            if scheduledAhead < 2 { scheduleMore(gen) }
        } catch {
            guard gen == generation else { return }
            lastError = "\(error)"
            finish(gen)
        }
    }

    func chunkPlayed(_ gen: Int, last: Bool) {
        guard gen == generation else { return }
        scheduledAhead -= 1
        if last { finish(gen); return }
        scheduleMore(gen)
    }

    func finish(_ gen: Int) {
        guard gen == generation else { return }
        pausedAt = totalFrames
        stopNode()
        onEnded?()
    }

    // MARK: offline rendering (tests)

    /// Renders `frames` frames offline; returns the interleaved output.
    func renderOffline(frames: Int) throws -> [Float] {
        precondition(manualRendering)
        if !engine.isRunning { try engine.start() }
        var out: [Float] = []
        let f = engine.manualRenderingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 1024) else { return [] }
        var remaining = frames
        while remaining > 0 {
            let n = AVAudioFrameCount(min(1024, remaining))
            _ = try engine.renderOffline(n, to: buffer)
            let ro = AVReadOnlyAudioPCMBuffer(copying: buffer)
            let ch = Int(f.channelCount)
            var planes: [[Float]] = []
            for c in 0 ..< ch {
                switch ro.channelData(c) {
                case .float(let span):
                    var plane = [Float](repeating: 0, count: Int(buffer.frameLength))
                    for i in 0 ..< plane.count { plane[i] = span[i] }
                    planes.append(plane)
                default: planes.append([Float](repeating: 0, count: Int(buffer.frameLength)))
                }
            }
            for i in 0 ..< Int(buffer.frameLength) { for c in 0 ..< ch { out.append(planes[c][i]) } }
            remaining -= Int(n)
        }
        return out
    }
}
