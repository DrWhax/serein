#if os(Linux)
import CLinuxPCM
import Foundation
import Observation

/// Plays the interleaved PCM supplied by the media service. ALSA tracks device
/// delay and SoundTouch preserves pitch across playback rate changes.
@MainActor @Observable public final class AudioPlaybackEngine {
    public static let chunkFrames = 48000 * 4
    public private(set) var isPlaying = false
    public private(set) var isLoaded = false
    public private(set) var duration: Double?
    public private(set) var lastError: String?
    public private(set) var playbackRate = 1.0
    public var isMuted = false
    @ObservationIgnored public var onEnded: (() -> Void)?

    public enum PlaybackError: Error { case invalidAudio, notLoaded, outputUnavailable }

    @ObservationIgnored private var source: PCMSource?
    @ObservationIgnored private var sampleRate = 0
    @ObservationIgnored private var channels = 0
    @ObservationIgnored private var totalFrames = 0
    @ObservationIgnored private var segmentStart = 0
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var stream: PCMOutput?
    @ObservationIgnored private var pump: Task<Void, Never>?

    public init() {}

    private final class PCMOutput {
        let handle: UInt64
        init(_ id: UInt64) { handle = id }
        deinit { serein_pcm_close(handle) }
    }

    public var currentTime: Double {
        guard sampleRate > 0 else { return 0 }
        let played = stream.map { Int(clamping: serein_pcm_played($0.handle)) } ?? 0
        return Double(segmentStart + min(totalFrames - segmentStart, played)) / Double(sampleRate)
    }

    public func load(_ source: @escaping PCMSource, playbackRate: Double = 1) async throws {
        pause()
        self.source = nil
        isLoaded = false
        duration = nil
        sampleRate = 0
        segmentStart = 0
        let version = generation
        let first = try await source(0, Self.chunkFrames)
        guard version == generation else { return }
        guard (8000...192000).contains(first.sampleRate), (1...2).contains(first.channels), first.totalFrames >= 0,
              first.startFrame == 0, first.samples.count % first.channels == 0,
              first.frames <= min(first.totalFrames, Self.chunkFrames), first.totalFrames == 0 || first.frames > 0,
              playbackRate.isFinite else { throw PlaybackError.invalidAudio }
        sampleRate = first.sampleRate
        channels = first.channels
        totalFrames = first.totalFrames
        self.source = source
        self.playbackRate = min(32, max(1.0 / 32, playbackRate))
        duration = Double(totalFrames) / Double(sampleRate)
        lastError = nil
        isLoaded = true
    }

    public func play() async {
        guard let source, isLoaded, !isPlaying else { return }
        if segmentStart == totalFrames { segmentStart = 0 }
        guard totalFrames > 0 else { onEnded?(); return }
        let id = serein_pcm_open(Int32(sampleRate), Int32(channels), playbackRate)
        guard id != 0 else { lastError = "Could not open the audio output"; return }
        stream = PCMOutput(id)
        generation &+= 1
        let version = generation
        isPlaying = true
        lastError = nil
        var cursor = segmentStart
        do {
            // Fetch the first chunk before returning. A suspended load or seek
            // cannot schedule samples into the stream replacing it.
            let initial = try await read(source, start: cursor)
            guard version == generation else { return }
            cursor += initial.frames
            pump = Task { [weak self] in
                var block = initial.samples, offset = 0
                var atEnd = false
                while !Task.isCancelled {
                    guard let self, self.generation == version, let handle = self.stream?.handle else { return }
                    let status = serein_pcm_pump(handle, self.isMuted ? 1 : 0)
                    do {
                        if status == 1 {
                            if offset == block.count && cursor < self.totalFrames {
                                let chunk = try await self.read(source, start: cursor)
                                guard version == self.generation else { return }
                                block = chunk.samples
                                cursor += chunk.frames
                                offset = 0
                            }
                            if offset < block.count {
                                let end = min(offset + 2048 * self.channels, block.count)
                                guard serein_pcm_append(handle, block.span.extracting(offset..<end)) == 0 else { throw PlaybackError.outputUnavailable }
                                offset = end
                            } else if !atEnd {
                                guard serein_pcm_finish(handle) == 0 else { throw PlaybackError.outputUnavailable }
                                atEnd = true
                            }
                        } else if status == 2 {
                            self.stop()
                            self.segmentStart = self.totalFrames
                            self.onEnded?()
                            return
                        } else if status < 0 {
                            throw PlaybackError.outputUnavailable
                        } else if status == 0 {
                            try await Task.sleep(for: .milliseconds(4))
                        } else {
                            await Task.yield()
                        }
                    } catch {
                        self.failed(error, version: version)
                        return
                    }
                }
            }
        } catch { failed(error, version: version) }
    }

    private func read(_ source: PCMSource, start: Int) async throws -> PCMChunk {
        let count = min(Self.chunkFrames, totalFrames - start)
        let chunk = try await source(start, count)
        guard chunk.sampleRate == sampleRate, chunk.channels == channels, chunk.totalFrames == totalFrames,
              chunk.startFrame == start, chunk.samples.count % channels == 0, (1...count).contains(chunk.frames) else {
            throw PlaybackError.invalidAudio
        }
        return chunk
    }

    private func failed(_ error: any Error, version: UInt64) {
        guard version == generation else { return }
        lastError = String(describing: error)
        pause()
    }

    public func pause() {
        if let stream { segmentStart += min(totalFrames - segmentStart, Int(clamping: serein_pcm_played(stream.handle))) }
        stop()
    }

    private func stop() {
        generation &+= 1
        pump?.cancel()
        pump = nil
        stream = nil
        isPlaying = false
    }

    public func seek(to seconds: Double) async {
        guard let duration, seconds.isFinite else { return }
        let resume = isPlaying
        stop()
        segmentStart = seconds >= duration ? totalFrames : Int(max(0, seconds) * Double(sampleRate))
        if resume { await play() }
    }

    public func setPlaybackRate(_ rate: Double) async {
        guard rate.isFinite else { return }
        let rate = min(32, max(1.0 / 32, rate))
        guard rate != playbackRate else { return }
        let resume = isPlaying
        pause()
        playbackRate = rate
        if resume { await play() }
    }
}
#endif
