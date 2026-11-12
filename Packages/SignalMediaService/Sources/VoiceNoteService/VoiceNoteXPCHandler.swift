// SignalVoiceNoteEncoder.xpc's requests: recording from the microphone (VoiceNoteRecorder)
// and encoding (VoiceNoteEncoder's sessions). Apart from VoiceNoteEncoder so that the media
// decoder, which encodes test notes in process, links no recorder.

import Foundation
import MediaXPCInterface
import VoiceNoteEncoder

/// The service side: only voice-note requests; anything else is refused.
public final class VoiceNoteXPCHandler: XPCMessageHandler {
    let sessions = VoiceNoteSessions()
    let recorder: VoiceNoteRecorder
    let gate: RequestGate
    let onSessionEnd: @Sendable () -> Void

    /// `onSessionEnd`: after the app's session ends and any recording is discarded (the
    /// service exits; tests carry on).
    public init(gate: RequestGate = RequestGate(maxRunning: 2, maxWaiting: 16), onSessionEnd: @escaping @Sendable () -> Void = {}) {
        self.gate = gate
        self.onSessionEnd = onSessionEnd
        recorder = VoiceNoteRecorder(sessions: sessions)
    }

    public var maxRequestBytes: Int { VoiceNoteLimits.maxRequestBytes }

    public func sessionEnded() {
        let recorder = recorder, done = onSessionEnd
        Task {
            await recorder.cancelAll()
            done()
        }
    }

    public func reply(to request: XPCMessage) async throws -> XPCMessage {
        let decoded = try MediaXPCWire.decode(MediaRequest.self, try request.requirePayload(), maxBytes: VoiceNoteLimits.maxRequestBytes)
        let sessions = sessions, recorder = recorder
        return XPCMessage(payload: try await gate.run(budget: decoded.budget) { try await Self.run(decoded, sessions, recorder) })
    }

    static func run(_ request: MediaRequest, _ s: VoiceNoteSessions, _ recorder: VoiceNoteRecorder) async throws -> Data {
        switch request {
        case .startVoiceNote(let rate): return try MediaXPCWire.encode(try await s.start(sampleRate: rate))
        case .appendVoiceNote(let id, let samples):
            // Not into a note the microphone is recording.
            guard await !recorder.isRecording(id) else { throw MediaProcessingError.invalidResult }
            try await s.append(id, samples)
            return try MediaXPCWire.encode(MediaEmpty())
        case .finishVoiceNote(let id): return try MediaXPCWire.encode(try await recorder.finish(id))
        case .cancelVoiceNote(let id):
            await recorder.cancel(id)
            return try MediaXPCWire.encode(MediaEmpty())
        case .recordVoiceNote: return try MediaXPCWire.encode(try await recorder.record())
        case .voiceNoteProgress(let id): return try MediaXPCWire.encode(try await recorder.progress(id))
        default:
            throw MediaProcessingError.unsupportedFormat
        }
    }
}
