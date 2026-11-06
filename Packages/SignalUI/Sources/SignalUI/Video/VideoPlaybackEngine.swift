// Video playback: pulls decoded frames (display order) from a source — in the app, a media
// service session — keeps a few queued, and presents the latest frame whose time has come.
// The clock is the audio engine's play head when the video has sound (A/V sync: late
// frames are skipped, never the audio), otherwise the host clock. GIF-flag MP4s loop.

import Foundation

/// Decoded frames of one video, in display order.
public protocol VideoFrameSource: Sendable {
    /// Up to `count` next frames; empty at the end.
    func frames(_ count: Int) async throws -> [VideoPlanes]
    /// Restarts at the sync frame at or before `seconds` (earlier frames follow it).
    func seek(to seconds: Double) async throws
    /// Releases the session (the engine no longer reads).
    func close() async
}

extension VideoFrameSource {
    public func close() async {}
}

@MainActor
@Observable
public final class VideoPlaybackEngine {
    public static let queueTarget = 6
    public static let batch = 4

    public private(set) var isPlaying = false
    public private(set) var isLoaded = false
    public private(set) var duration: Double = 0
    /// Clockwise rotation the frames are shown with.
    public private(set) var rotation = 0
    /// Time of the frame on screen.
    public private(set) var currentTime: Double = 0
    public private(set) var lastError: String?
    /// Completed loops (GIF playback).
    public private(set) var loopCount = 0
    public var isLooping = false

    /// The frame on screen, for a view that attaches later.
    @ObservationIgnored public private(set) var currentFrame: VideoPlanes?
    /// Called with every frame to show.
    @ObservationIgnored public var onFrame: ((VideoPlanes) -> Void)?
    @ObservationIgnored public var onEnded: (() -> Void)?

    @ObservationIgnored public let audio: AudioPlaybackEngine?
    @ObservationIgnored let now: @MainActor () -> Double
    @ObservationIgnored let autoDrive: Bool
    @ObservationIgnored var source: (any VideoFrameSource)?
    @ObservationIgnored var queue: [VideoPlanes] = []
    @ObservationIgnored var sourceEnded = false
    /// Time of the last frame queued since the source last (re)started: frames must increase.
    @ObservationIgnored var lastQueuedTime = -Double.infinity
    @ObservationIgnored var fetching = false
    @ObservationIgnored var generation = 0
    /// Host-clock anchor: media time `anchorMedia` at host time `anchorHost`.
    @ObservationIgnored var anchorHost = 0.0
    @ObservationIgnored var anchorMedia = 0.0
    @ObservationIgnored var audioActive = false
    @ObservationIgnored var driver: Task<Void, Never>?

    /// `audio`: the engine playing the video's sound (loaded by the caller), the master clock.
    /// `now`/`autoDrive: false` let tests step the engine by hand.
    public init(audio: AudioPlaybackEngine? = nil, now: (@MainActor () -> Double)? = nil, autoDrive: Bool = true) {
        self.audio = audio
        let start = ContinuousClock.now
        self.now = now ?? { let d = ContinuousClock.now - start; return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18 }
        self.autoDrive = autoDrive
    }

    /// Prepares `source` and shows its first frame.
    public func load(_ source: any VideoFrameSource, duration: Double, rotation: Int) async {
        stop()
        generation += 1
        self.source = source
        self.duration = max(0, duration)
        self.rotation = [0, 90, 180, 270].contains(rotation) ? rotation : 0
        queue = []
        sourceEnded = false
        lastQueuedTime = -.infinity
        fetching = false
        loopCount = 0
        lastError = nil
        currentFrame = nil
        anchorMedia = 0
        isLoaded = true
        await fill(generation)
        present(at: 0)
    }

    public func play() async {
        guard isLoaded, !isPlaying else { return }
        if sourceEnded && queue.isEmpty { await seek(to: 0) }
        isPlaying = true
        anchorHost = now()
        anchorMedia = currentTime
        if let audio, audio.isLoaded, currentTime < (audio.duration ?? 0) {
            await audio.seek(to: currentTime)
            await audio.play()
            audioActive = audio.isPlaying
        }
        guard isPlaying else { return }
        if autoDrive { startDriver() }
    }

    /// Stops and releases the source.
    public func unload() async {
        stop()
        generation += 1
        let s = source
        source = nil
        queue = []
        isLoaded = false
        await s?.close()
    }

    public func togglePlayback() async {
        if isPlaying { pause() } else { await play() }
    }

    public func pause() {
        guard isPlaying else { return }
        currentTime = mediaTime
        stop()
    }

    func stop() {
        isPlaying = false
        driver?.cancel()
        driver = nil
        if audioActive { audio?.pause() }
        audioActive = false
    }

    /// Shows the frame at `seconds` (and keeps playing if playing).
    public func seek(to seconds: Double) async {
        guard isLoaded, let source else { return }
        let wasPlaying = isPlaying
        stop()
        generation += 1
        let gen = generation
        let t = min(max(0, seconds), duration)
        queue = []
        sourceEnded = false
        lastQueuedTime = -.infinity
        fetching = false
        do { try await source.seek(to: t) } catch { lastError = "\(error)"; return }
        guard gen == generation else { return }
        // Decode forward from the sync frame until the frame for `t` is known.
        while gen == generation, !sourceEnded, queue.last.map({ $0.time <= t }) ?? true {
            await fetch(gen)
            present(at: t, show: false)
        }
        guard gen == generation else { return }
        present(at: t)
        currentTime = t
        if let f = currentFrame { onFrame?(f) }
        if let audio, audio.isLoaded { await audio.seek(to: t) }
        if wasPlaying { await play() }
    }

    /// Media time now.
    var mediaTime: Double {
        guard isPlaying else { return currentTime }
        if audioActive, let audio {
            if audio.isPlaying { return audio.currentTime }
            // The sound ended first: continue on the host clock from there.
            audioActive = false
            anchorHost = now()
            anchorMedia = audio.currentTime
        }
        return anchorMedia + (now() - anchorHost)
    }

    /// Presents the latest queued frame due at `t`; returns whether one was taken.
    @discardableResult
    func present(at t: Double, show: Bool = true) -> Bool {
        var pick: VideoPlanes?
        while let f = queue.first, f.time <= t + 0.002 { pick = queue.removeFirst() }
        // Nothing on screen yet and the first frame starts later: show it now.
        if pick == nil, currentFrame == nil, !queue.isEmpty { pick = queue.removeFirst() }
        guard let pick else { return false }
        currentFrame = pick
        if show {
            currentTime = pick.time
            onFrame?(pick)
        }
        return true
    }

    /// One step of playback: presents what is due, refills, handles the end. Returns the
    /// media time of the next frame (nil: waiting for frames or stopped).
    @discardableResult
    public func step() async -> Double? {
        guard isPlaying else { return nil }
        let gen = generation
        let t = mediaTime
        present(at: t)
        if queue.count < Self.queueTarget && !sourceEnded { await fill(gen) }
        guard gen == generation, isPlaying else { return nil }
        // The last frame stays up until the duration (at most a second past it).
        let last = currentFrame?.time ?? 0
        if queue.isEmpty && sourceEnded && t >= max(last, min(duration, last + 1)) {
            if isLooping, let source {
                generation += 1
                let g = generation
                do { try await source.seek(to: 0) } catch { lastError = "\(error)"; stop(); return nil }
                guard g == generation else { return nil }
                sourceEnded = false
                lastQueuedTime = -.infinity
                loopCount += 1
                anchorHost = now()
                anchorMedia = 0
                await fill(g)
                present(at: 0)
                return queue.first?.time
            }
            currentTime = duration
            stop()
            onEnded?()
            return nil
        }
        return queue.first?.time
    }

    func fill(_ gen: Int) async {
        while gen == generation, !sourceEnded, queue.count < Self.queueTarget {
            let before = queue.count
            await fetch(gen)
            if queue.count == before { break }
        }
    }

    func fetch(_ gen: Int) async {
        guard let source, !fetching else { return }
        fetching = true
        defer { if gen == generation { fetching = false } }
        do {
            let batch = try await source.frames(Self.batch)
            guard gen == generation else { return }
            // Only well-formed frames, in increasing time order, reach the renderer.
            if batch.isEmpty { sourceEnded = true }
            for f in batch where f.isValid && f.time.isFinite && f.time > lastQueuedTime {
                queue.append(f)
                lastQueuedTime = f.time
            }
        } catch {
            guard gen == generation else { return }
            lastError = "\(error)"
            sourceEnded = true
        }
    }

    func startDriver() {
        driver?.cancel()
        driver = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isPlaying else { return }
                let next = await self.step()
                guard self.isPlaying else { return }
                // Sleep until the next frame is due (at most a display refresh when waiting).
                let wait = next.map { min(max($0 - self.mediaTime, 0.002), 0.05) } ?? 0.008
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }
}
