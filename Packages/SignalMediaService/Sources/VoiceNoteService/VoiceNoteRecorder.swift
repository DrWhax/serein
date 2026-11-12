// Recording voice notes from the microphone (upstream's audioRecorder duck), here in
// SignalVoiceNoteEncoder.xpc rather than in the app: the app holds no microphone (Serein.sb
// denies it), so it asks this service, which has the microphone and no network, to record. The
// input goes through AVAudioEngine (a tap of read-only buffers, read through spans), mono, into
// a VoiceNoteSessions encoder session; the app polls the levels for its bars and finishes or
// cancels the note.
//
// The microphone is never left on: one recording at a time, stopped after an hour (as
// upstream), stopped and discarded when the app has not asked for progress in `unwatched`, and
// stopped when the app's session ends (VoiceNoteXPCHandler).

import AVFAudio
import Foundation
import MediaXPCInterface
import VoiceNoteEncoder

/// Microphone samples from the audio thread, in order.
final class MicSamples: Sendable {
    let continuation: AsyncStream<[Float]>.Continuation
    let stream: AsyncStream<[Float]>
    init() { (stream, continuation) = AsyncStream<[Float]>.makeStream() }
}

public actor VoiceNoteRecorder {
    struct Recording {
        let id: UUID
        let engine: AVAudioEngine
        let samples: MicSamples
        var pump: Task<Void, Never>?
        var levels: [Float] = []
        var seconds: Double = 0
        var stopped = false
        var timedOut = false
        var watched = ContinuousClock.now
    }
    let sessions: VoiceNoteSessions
    var recording: Recording?
    /// `MAX_RECORDING_DURATION`
    static let maxSeconds: Double = 60 * 60
    /// The app polls about ten times a second; this long without a poll, it is gone or stuck.
    static let unwatched: Duration = .seconds(10)

    public init(sessions: VoiceNoteSessions) { self.sessions = sessions }

    /// Permission (asked once; macOS shows the app's prompt), then the input's tap and an
    /// encoder session.
    public func record() async throws -> UUID {
        guard recording == nil else { throw MediaProcessingError.undecodable("already recording") }
        guard await AVAudioApplication.requestRecordPermission() else { throw MediaProcessingError.undecodable("no microphone permission") }
        guard recording == nil else { throw MediaProcessingError.undecodable("already recording") }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw MediaProcessingError.undecodable("no microphone") }
        let id = try await sessions.start(sampleRate: Int(format.sampleRate))
        let samples = MicSamples()
        do {
            try input.installAudioTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                guard case .float(let span) = buffer.channelData(0) else { return }
                let n = min(buffer.frameLength, span.count)
                var mono = [Float](repeating: 0, count: n)
                for i in 0..<n { mono[i] = span[i] }
                samples.continuation.yield(mono)
            }
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            await sessions.cancel(id)
            throw MediaProcessingError.undecodable("microphone: \(error)")
        }
        recording = Recording(id: id, engine: engine, samples: samples)
        let rate = Int(format.sampleRate)
        recording?.pump = Task { await self.pump(id, samples, rate: rate) }
        return id
    }

    /// Feeds the encoder half a second at a time and keeps each chunk's level.
    func pump(_ id: UUID, _ samples: MicSamples, rate: Int) async {
        var pending: [Float] = []
        for await chunk in samples.stream {
            pending += chunk
            let rms = (chunk.reduce(0) { $0 + $1 * $1 } / Float(max(1, chunk.count))).squareRoot()
            noted(id, chunk.count, rms, rate: rate)
            if pending.count >= rate / 2 {
                try? await sessions.append(id, pending)
                pending = []
            }
        }
        if !pending.isEmpty { try? await sessions.append(id, pending) }
    }

    func noted(_ id: UUID, _ count: Int, _ rms: Float, rate: Int) {
        guard var r = recording, r.id == id else { return }
        r.seconds += Double(count) / Double(rate)
        if r.levels.count < VoiceNoteProgress.maxLevels { r.levels.append(min(1, max(0, rms.isFinite ? rms : 0))) }
        recording = r
        if r.seconds >= Self.maxSeconds {
            recording?.timedOut = true
            stopInput()
        } else if ContinuousClock.now - r.watched > Self.unwatched {
            stopInput()
            Task { await self.cancel(id) }
        }
    }

    /// The microphone off (the recorded audio stays for `finish`).
    func stopInput() {
        guard let r = recording, !r.stopped else { return }
        r.engine.inputNode.removeTap(onBus: 0)
        r.engine.stop()
        r.samples.continuation.finish()
        recording?.stopped = true
    }

    public func isRecording(_ id: UUID) -> Bool { recording?.id == id }

    public func progress(_ id: UUID) throws -> VoiceNoteProgress {
        guard var r = recording, r.id == id else { throw MediaProcessingError.invalidResult }
        let p = VoiceNoteProgress(levels: r.levels, seconds: r.seconds, stopped: r.stopped, timedOut: r.timedOut)
        r.levels = []
        r.watched = .now
        recording = r
        return p
    }

    /// Stops recording and finishes the note.
    public func finish(_ id: UUID) async throws -> VoiceNote {
        guard let r = recording, r.id == id else { return try await sessions.finish(id) }
        stopInput()
        await r.pump?.value
        recording = nil
        return try await sessions.finish(id)
    }

    /// Stops recording and discards the note.
    public func cancel(_ id: UUID) async {
        if let r = recording, r.id == id {
            stopInput()
            await r.pump?.value
            recording = nil
        }
        await sessions.cancel(id)
    }

    /// The app went away: the microphone goes off and the recording is discarded.
    public func cancelAll() async {
        if let id = recording?.id { await cancel(id) }
    }
}
