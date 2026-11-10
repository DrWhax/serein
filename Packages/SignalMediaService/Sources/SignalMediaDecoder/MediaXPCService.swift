// The service side of MediaXPC: each request decoded, run on MediaDecoder, and the result
// encoded back. One decoder for the service's life (voice-note and video sessions live in it).

import Foundation
import MediaXPCInterface

public final class MediaXPCHandler: NSObject, MediaXPCProtocol, Sendable {
    let decoder = MediaDecoder()
    /// Bounded concurrency and queue; a request past its budget (plus grace) ends the process
    /// (Containment.swift).
    let gate: RequestGate

    public init(gate: RequestGate = RequestGate()) { self.gate = gate }

    public func handle(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        let decoder = decoder, gate = gate
        Task {
            do {
                let decoded = try MediaXPCWire.decode(MediaRequest.self, request, maxBytes: MediaRequest.maxBytes)
                // Recording is SignalVoiceNoteEncoder.xpc's (VoiceNoteEncoder), never this process's.
                guard !decoded.isVoiceNote else { throw MediaProcessingError.unsupportedFormat }
                reply(try await gate.run(budget: decoded.budget) { try await Self.run(decoded, decoder) }, nil)
            } catch {
                reply(nil, String(describing: error))
            }
        }
    }

    static func run(_ request: MediaRequest, _ d: MediaDecoder) async throws -> Data {
        switch request {
        case .stickerImage(let b): return try MediaXPCWire.encode(try await d.stickerImage(b))
        case .displayImage(let b, let max): return try MediaXPCWire.encode(try await d.displayImage(b, maxDimension: max))
        case .imageInfo(let b): return try MediaXPCWire.encode(try await d.imageInfo(b))
        case .thumbnail(let b, let size): return try MediaXPCWire.encode(try await d.thumbnail(b, size: size))
        case .scaleForSending(let b, let type, let level): return try MediaXPCWire.encode(try await d.scaleForSending(b, contentType: type, level: level))
        case .stripMetadata(let b, let type): return try MediaXPCWire.encode(try await d.stripMetadata(b, contentType: type))
        case .convertHEIC(let b): return try MediaXPCWire.encode(try await d.convertHEIC(b))
        case .audioSummary(let b): return try MediaXPCWire.encode(try await d.audioSummary(b))
        case .decodeAudio(let b, let start, let max): return try MediaXPCWire.encode(try await d.decodeAudio(b, startFrame: start, maxFrames: max))
        case .startVoiceNote(let rate): return try MediaXPCWire.encode(try await d.startVoiceNote(sampleRate: rate))
        case .appendVoiceNote(let id, let samples):
            try await d.appendVoiceNote(id, samples: samples)
            return try MediaXPCWire.encode(MediaEmpty())
        case .finishVoiceNote(let id): return try MediaXPCWire.encode(try await d.finishVoiceNote(id))
        case .cancelVoiceNote(let id):
            await d.cancelVoiceNote(id)
            return try MediaXPCWire.encode(MediaEmpty())
        case .videoInfo(let b): return try MediaXPCWire.encode(try await d.videoInfo(b))
        case .posterFrame(let b): return try MediaXPCWire.encode(try await d.posterFrame(b))
        case .openVideo(let b):
            let (session, info) = try await d.openVideo(b)
            return try MediaXPCWire.encode(OpenedVideo(session: session, info: info))
        case .videoFrames(let id, let count): return MediaXPCWire.encodeFrames(try await d.videoFrames(id, count: count))
        case .seekVideo(let id, let seconds):
            try await d.seekVideo(id, to: seconds)
            return try MediaXPCWire.encode(MediaEmpty())
        case .closeVideo(let id):
            await d.closeVideo(id)
            return try MediaXPCWire.encode(MediaEmpty())
        }
    }
}

/// Accepts connections (only from a process signed as `peer` says, when given) and exports one
/// handler (shared state) to each.
public final class MediaXPCListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    let handler: MediaXPCHandler
    let peer: String?
    public init(peer: String? = nil, handler: MediaXPCHandler = MediaXPCHandler()) {
        self.peer = peer
        self.handler = handler
    }
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let peer { connection.setCodeSigningRequirement(peer) }
        connection.exportedInterface = NSXPCInterface(with: MediaXPCProtocol.self)
        connection.exportedObject = handler
        connection.resume()
        return true
    }
}
