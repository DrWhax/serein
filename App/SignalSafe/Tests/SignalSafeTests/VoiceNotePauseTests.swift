// The app's voice-note glue (VoiceNotes.swift) with a real engine playing silence to the output
// device: the bubble's controls pause it, and the bubble then shows it paused.

import Foundation
import Testing
@testable import SignalCore
@testable import SignalSafe
@testable import SignalUI

@MainActor @Suite(.serialized) struct VoiceNotePauseTests {
    nonisolated static let silence: PCMSource = { start, count in
        let total = 48000 * 20
        let n = max(0, min(count, total - start))
        try? await Task.sleep(for: .milliseconds(30))
        return PCMChunk(sampleRate: 48000, channels: 1, totalFrames: total, startFrame: start, samples: [Float](repeating: 0, count: n))
    }

    @Test func theBubblesPauseStopsPlayback() async throws {
        let session = SignalSession()
        let engine = AudioPlaybackEngine()
        try await engine.load(Self.silence)
        session.audioEngine = engine
        session.activeAudioMessageId = "m1"
        let m = TimelineMessage(id: "m1", conversationId: "c1", direction: .incoming, body: "", sentAt: 0, receivedAt: 0, author: "a", status: nil,
                                hasAttachments: true, isDeleted: false, content: .voiceMessage)
        await engine.play()
        session.startAudioClock()
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.activeAudio(m)?.playing == true)
        session.audioControls(m).setIsPlaying(false)
        try await Task.sleep(for: .milliseconds(300))
        let t = session.audioTime
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.activeAudio(m)?.playing == false && !engine.isPlaying && session.audioTime == t)
    }
}
