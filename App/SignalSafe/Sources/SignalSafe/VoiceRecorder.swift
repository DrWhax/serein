// Recording voice notes (upstream's audioRecorder duck and RecordingComposer). The app never
// opens the microphone (Serein.sb denies it): SignalVoiceNoteEncoder.xpc, which has the
// microphone and no network, records it and encodes the note with its Swift MP3 encoder
// (LAME-compatible VBR, as upstream); the app polls its levels for the bars and finishes or
// cancels it. Sent as an audio/mpeg attachment flagged as a voice message. The recorder replaces
// the composer: the timer, the live level bars, Cancel and Send (Escape cancels). It stops at an
// hour, as upstream (the service stops it).

import Foundation
import MediaXPCInterface
import SignalCore
import SignalUI

/// The recorder's state: the voice-note service's recording, when it started, and the level bars.
struct VoiceRecording {
    var session: UUID?
    var startedAt = Date()
    var peaks: [RecordingPeak] = []
    var error: ErrorDialogAudioRecorderType?
}

@MainActor extension SignalSession {
    static let maxRecording: TimeInterval = 60 * 60
    static let voiceMessageFlag = 1    // AttachmentPointer.Flags.VOICE_MESSAGE

    /// `startRecording`: the service asks for the microphone (once) and starts recording; the
    /// levels are polled ten times a second (the service stops a recording nobody polls).
    func startRecording() {
        guard recording == nil, selectedConversationId != nil else { return }
        stopAudio()
        let media = media
        Task { [weak self] in
            let id: UUID
            do { id = try await media.recordVoiceNote() } catch {
                Self.trace("recording failed: \(error)")
                return
            }
            guard let self, self.recording == nil else { return await media.cancelVoiceNote(id) }
            self.recording = VoiceRecording(session: id)
            self.recorderTask = Task { [weak self] in
                var index = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let p = try? await media.voiceNoteProgress(id) else { continue }
                    guard let self, self.recording?.session == id else { return }
                    for level in p.levels {
                        index += 1
                        // The level bar: the chunk's RMS on 0…255.
                        self.recording?.peaks.append(RecordingPeak(value: Double(min(255, level * 255 * 4)), index: index))
                    }
                    if let peaks = self.recording?.peaks, peaks.count > 200 { self.recording?.peaks.removeFirst(peaks.count - 200) }
                    if p.stopped {
                        if p.timedOut { self.recording?.error = .timeout }
                        return
                    }
                }
            }
        }
    }

    /// Stops polling the recording (the service keeps it until it is finished or cancelled).
    func stopRecorderPolling() -> Task<Void, Never>? {
        let task = recorderTask
        recorderTask = nil
        task?.cancel()
        return task
    }

    /// Cancel (Escape): nothing is kept.
    func cancelRecording() {
        guard let r = recording else { return }
        recording = nil
        let task = stopRecorderPolling(), media = media
        Task {
            await task?.value
            if let id = r.session { await media.cancelVoiceNote(id) }
        }
    }

    /// Send: the note is finished by the encoder and sent like an attachment (a voice message).
    func sendRecording() {
        guard let r = recording, let id = r.session, let session = signalSession, let c = selectedConversation else { return cancelRecording() }
        recording = nil
        let task = stopRecorderPolling(), media = media
        let quoting = quotedMessageId
        quotedMessageId = nil
        Task {
            await task?.value
            do {
                let note = try await media.finishVoiceNote(id)
                let a = OutgoingAttachment(data: note.data, contentType: "audio/mpeg", flags: Self.voiceMessageFlag)
                if c.kind == .group, let key = c.masterKey {
                    _ = try await session.messenger.sendGroupMessage("", attachments: [a], quoting: quoting, masterKey: key)
                } else if let to = c.serviceId {
                    _ = try await session.messenger.sendMessage("", attachments: [a], quoting: quoting, to: to)
                }
            } catch {
                Self.trace("voice note failed: \(error)")
            }
        }
    }
}
