// SignalVoiceNoteEncoder.xpc's work: voice notes recorded in the app are encoded to MP3 here,
// apart from the media decoder, so that nothing received (decoded in SignalMediaDecoder.xpc)
// ever shares a process with what the user is recording, and a decoder stopped by its
// watchdog cannot take a recording with it. It links the MP3 encoder and nothing that parses
// received data.

import AudioMP3
import Foundation
import MediaXPCInterface

/// Recording sessions (upstream's mp3Encoder worklet: the encoder plus the waveform of the
/// input samples).
public actor VoiceNoteSessions {
    struct Session {
        var encoder: MP3Encoder
        var waveform = WaveformBuilder()
        var bytes: [UInt8] = []
        var samples = 0
        let sampleRate: Int
    }
    var sessions: [UUID: Session] = [:]
    static let maxSessions = 4

    public init() {}

    public func start(sampleRate: Int) throws -> UUID {
        guard sessions.count < Self.maxSessions else { throw MediaProcessingError.undecodable("too many recordings") }
        guard let encoder = try? MP3Encoder(inputSampleRate: sampleRate) else { throw MediaProcessingError.unsupportedFormat }
        let id = UUID()
        sessions[id] = Session(encoder: encoder, sampleRate: sampleRate)
        return id
    }

    public func append(_ id: UUID, _ samples: [Float]) throws {
        guard var s = sessions[id] else { throw MediaProcessingError.invalidResult }
        let clean = samples.map { $0.isFinite ? min(max($0, -1), 1) : 0 }
        for v in clean { s.waveform.push(v) }
        s.samples += clean.count
        s.bytes += s.encoder.encode(clean)
        sessions[id] = s
    }

    public func finish(_ id: UUID) throws -> VoiceNote {
        guard var s = sessions.removeValue(forKey: id) else { throw MediaProcessingError.invalidResult }
        s.bytes += s.encoder.flush()
        let tag = s.encoder.tagFrame()
        for (i, b) in tag.enumerated() where i < s.bytes.count { s.bytes[i] = b }
        return VoiceNote(data: Data(s.bytes), waveform: s.waveform.collect(), duration: Double(s.samples) / Double(s.sampleRate))
    }

    public func cancel(_ id: UUID) { sessions[id] = nil }
}


/// The service side: only voice-note requests; anything else is refused.
public final class VoiceNoteXPCHandler: XPCMessageHandler {
    let sessions = VoiceNoteSessions()
    let gate: RequestGate

    public init(gate: RequestGate = RequestGate(maxRunning: 2, maxWaiting: 16)) { self.gate = gate }

    public var maxRequestBytes: Int { VoiceNoteLimits.maxRequestBytes }

    public func reply(to request: XPCMessage) async throws -> XPCMessage {
        let decoded = try MediaXPCWire.decode(MediaRequest.self, try request.requirePayload(), maxBytes: VoiceNoteLimits.maxRequestBytes)
        let sessions = sessions
        return XPCMessage(payload: try await gate.run(budget: decoded.budget) { try await Self.run(decoded, sessions) })
    }

    static func run(_ request: MediaRequest, _ s: VoiceNoteSessions) async throws -> Data {
        switch request {
        case .startVoiceNote(let rate): return try MediaXPCWire.encode(try await s.start(sampleRate: rate))
        case .appendVoiceNote(let id, let samples):
            try await s.append(id, samples)
            return try MediaXPCWire.encode(MediaEmpty())
        case .finishVoiceNote(let id): return try MediaXPCWire.encode(try await s.finish(id))
        case .cancelVoiceNote(let id):
            await s.cancel(id)
            return try MediaXPCWire.encode(MediaEmpty())
        default:
            throw MediaProcessingError.unsupportedFormat
        }
    }
}
