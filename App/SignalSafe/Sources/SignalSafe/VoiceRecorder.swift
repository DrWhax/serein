// Recording voice notes (upstream's audioRecorder duck and RecordingComposer): the microphone
// through AVAudioEngine (a tap of read-only buffers, read through spans), mono, streamed to the
// media service, whose Swift MP3 encoder writes the note (LAME-compatible VBR, as upstream);
// sent as an audio/mpeg attachment flagged as a voice message. The recorder replaces the
// composer: the timer, the live level bars, Cancel and Send (Escape cancels). It stops at an
// hour, as upstream.

import AVFAudio
import Foundation
import MediaXPCInterface
import SignalCore
import SignalUI

/// The recorder's state: the media service session, when it started, and the level bars.
struct VoiceRecording {
    var session: UUID?
    var startedAt = Date()
    var peaks: [RecordingPeak] = []
    var error: ErrorDialogAudioRecorderType?
}

/// Mic samples from the audio thread to the main actor, in order.
final class MicSamples: Sendable {
    let continuation: AsyncStream<[Float]>.Continuation
    let stream: AsyncStream<[Float]>
    init() { (stream, continuation) = AsyncStream<[Float]>.makeStream() }
}

@MainActor extension SignalSession {
    static let maxRecording: TimeInterval = 60 * 60
    static let voiceMessageFlag = 1    // AttachmentPointer.Flags.VOICE_MESSAGE

    /// `startRecording`: microphone permission, then the engine's tap and an encoder session.
    func startRecording() {
        guard recording == nil, selectedConversationId != nil else { return }
        stopAudio()
        Task { [weak self] in
            guard let self else { return }
            guard await AVAudioApplication.requestRecordPermission() else {
                Self.trace("recording: no microphone permission")
                return
            }
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { return Self.trace("recording: no input device") }
            guard let id = try? await media.startVoiceNote(sampleRate: Int(format.sampleRate)) else { return Self.trace("recording: encoder failed") }
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
                Self.trace("recording failed: \(error)")
                await media.cancelVoiceNote(id)
                return
            }
            recorderEngine = engine
            recording = VoiceRecording(session: id)
            let media = media
            recorderTask = Task { [weak self] in
                var pending: [Float] = []
                var index = 0
                for await chunk in samples.stream {
                    pending += chunk
                    // The level bar: RMS of the chunk on 0…255.
                    let rms = (chunk.reduce(0) { $0 + $1 * $1 } / Float(max(1, chunk.count))).squareRoot()
                    index += 1
                    self?.recording?.peaks.append(RecordingPeak(value: Double(min(255, rms * 255 * 4)), index: index))
                    if let peaks = self?.recording?.peaks, peaks.count > 200 { self?.recording?.peaks.removeFirst(peaks.count - 200) }
                    if pending.count >= Int(format.sampleRate) / 2 {
                        let batch = pending
                        pending = []
                        try? await media.appendVoiceNote(id, samples: batch)
                    }
                    if let started = self?.recording?.startedAt, Date().timeIntervalSince(started) >= Self.maxRecording {
                        self?.recording?.error = .timeout
                        self?.stopRecorderEngine()
                    }
                }
                if !pending.isEmpty { try? await media.appendVoiceNote(id, samples: pending) }
            }
            recorderSamples = samples
        }
    }

    func stopRecorderEngine() {
        recorderEngine?.inputNode.removeTap(onBus: 0)
        recorderEngine?.stop()
        recorderEngine = nil
        recorderSamples?.continuation.finish()
        recorderSamples = nil
    }

    /// Cancel (Escape): nothing is kept.
    func cancelRecording() {
        guard let r = recording else { return }
        stopRecorderEngine()
        recording = nil
        let task = recorderTask, media = media
        recorderTask = nil
        Task {
            await task?.value
            if let id = r.session { await media.cancelVoiceNote(id) }
        }
    }

    /// Send: the note is finished by the encoder and sent like an attachment (a voice message).
    func sendRecording() {
        guard let r = recording, let id = r.session, let session = signalSession, let c = selectedConversation else { return cancelRecording() }
        stopRecorderEngine()
        recording = nil
        let task = recorderTask, media = media
        recorderTask = nil
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
