#if os(Linux)
import CLinuxMicrophone
import Foundation
import MediaXPCInterface

/// ALSA is opened only in the voice-note service, with mono float capture at 48 kHz.
final class MicrophoneEngine: Sendable {
    let handle: UInt64

    init() throws {
        handle = serein_microphone_open()
        guard handle != 0 else { throw MediaProcessingError.undecodable("microphone unavailable") }
    }

    func stop() { serein_microphone_close(handle) }
    deinit { stop() }
}

struct MicSamples: Sendable {
    let stream: AsyncStream<[Float]>

    init(_ microphone: MicrophoneEngine) {
        // The encoder pulls one block at a time. Device buffering bounds the
        // input even when encoding or delivery to the app falls behind.
        stream = AsyncStream(unfolding: {
            let deadline = ContinuousClock.now + VoiceNoteRecorder.unwatched
            var block = [Float](repeating: 0, count: 2048)
            while !Task.isCancelled && ContinuousClock.now < deadline {
                let frames: Int32 = {
                    var output = block.mutableSpan
                    return serein_microphone_read(microphone.handle, &output)
                }()
                if frames < 0 { return nil }
                if frames > 0 { return Array(block.prefix(Int(frames))) }
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return nil }
            }
            return nil
        })
    }
}

extension VoiceNoteRecorder {
    public func record() async throws -> UUID {
        guard recording == nil else { throw MediaProcessingError.undecodable("already recording") }
        let engine = try MicrophoneEngine()
        let id = try await sessions.start(sampleRate: 48_000)
        let samples = MicSamples(engine)
        recording = Recording(id: id, engine: engine, samples: samples)
        recording?.pump = Task { await pump(id, samples, rate: 48_000) }
        return id
    }
}
#endif
