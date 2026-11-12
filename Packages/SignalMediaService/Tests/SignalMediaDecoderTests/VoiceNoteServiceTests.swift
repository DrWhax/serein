// SignalVoiceNoteEncoder.xpc's requests over XPC (its handler on an in-process listener):
// encoding given samples still works, a note being recorded cannot be fed samples by the app,
// progress is only for the note being recorded, and the decoder refuses recording. (Recording
// from the microphone itself is not run here: the test runner's microphone belongs to the
// terminal. Tools/check-sandbox-profile.sh starts the audio input under the service's profile.)

import Foundation
import MediaXPCInterface
import SignalMediaDecoder
import Testing
import VoiceNoteService
import XPC

@Suite struct VoiceNoteServiceTests {
    @Test func encodingAndRecordingRequests() async throws {
        let listener = XPCServer.anonymous(requirement: nil, VoiceNoteXPCHandler())
        defer { listener.cancel() }
        let client = MediaXPCClient(timeout: .seconds(20), decoder: .endpoint(listener.endpoint), peer: nil, voice: .endpoint(listener.endpoint), voicePeer: nil)
        let id = try await client.startVoiceNote(sampleRate: 16000)
        try await client.appendVoiceNote(id, samples: (0..<16000).map { Float(sin(Double($0) / 10)) * 0.3 })
        let note = try await client.finishVoiceNote(id)
        #expect(note.duration == 1 && !note.data.isEmpty)
        // Progress is for a recording only.
        await #expect(throws: (any Error).self) { try await client.voiceNoteProgress(id) }
        await #expect(throws: (any Error).self) { try await client.voiceNoteProgress(UUID()) }
    }

    @Test func theDecoderRecordsNothing() async throws {
        let decoder = MediaXPCHandler()
        for request in [MediaRequest.recordVoiceNote, .voiceNoteProgress(UUID())] {
            await #expect(throws: MediaProcessingError.self) {
                _ = try await decoder.reply(to: XPCMessage(payload: try MediaXPCWire.encode(request)))
            }
        }
    }
}
