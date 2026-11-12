// Playing voice notes and audio attachments in the timeline (upstream's globalMessageAudio and
// audioPlayer duck): one player for the app. The file is decoded to PCM in chunks by the
// sandboxed media decoder (our Swift MP3/AAC decoders); AVAudioEngine only plays the samples.
// The waveform and duration come from the media service too. Playing an incoming voice note
// marks it viewed (viewed sync, and a viewed receipt when read receipts are on); when one ends,
// the next voice note in the chat plays, as upstream does.

import Foundation
import MediaXPCInterface
import SignalCore
import SignalUI

@MainActor extension SignalSession {
    /// An audio attachment's waveform and duration (`computeWaveform`), once worked out.
    func audioWaveform(for a: SignalCore.MessageAttachment) -> AudioWaveform? {
        guard let path = a.path, a.isDownloaded, AttachmentPolicy.isAudio(a.contentType) else { return nil }
        if let hit = audioWaveforms[path] { return hit }
        guard let session = signalSession, !audioWaveformLoading.contains(path) else { return nil }
        audioWaveformLoading.insert(path)
        let store = session.attachmentStore, media = media
        Task {
            defer { audioWaveformLoading.remove(path) }
            guard let bytes = try? await Task.detached(operation: { try store.plaintext(of: a) }).value ?? nil,
                  let summary = try? await media.audioSummary(bytes), mediaIsAvailable(path: path) else { return }
            audioWaveforms[path] = AudioWaveform(waveform: summary.waveform, duration: summary.duration)
        }
        return nil
    }

    /// The bubble's player state, when this message's audio is the one playing (or paused).
    func activeAudio(_ m: TimelineMessage) -> AudioActive? {
        guard activeAudioMessageId == m.id else { return nil }
        return AudioActive(playing: audioPlaying, currentTime: audioTime, duration: audioEngine?.duration ?? 0, playbackRate: audioRate)
    }

    func audioControls(_ m: TimelineMessage) -> AudioControls {
        AudioControls(playMessage: { [weak self] position in self?.playAudio(m, at: position) },
                      setPosition: { [weak self] position in self?.seekAudio(to: position) },
                      setIsPlaying: { [weak self] playing in self?.setAudioPlaying(playing) },
                      setPlaybackRate: { [weak self] rate in self?.setAudioRate(rate) })
    }

    /// `loadVoiceNoteAudio` + play: this message's audio from `position` (0…1).
    func playAudio(_ m: TimelineMessage, at position: Double) {
        Self.trace("audio: play \(m.id) at \(position) (active \(activeAudioMessageId == m.id), engine playing \(audioEngine?.isPlaying ?? false))")
        guard let a = m.attachments.first?.attachment, AttachmentPolicy.isAudio(a.contentType), a.isDownloaded,
              let session = signalSession else { return }
        guard let path = a.path, mediaIsAvailable(path: path, messageId: m.id) else { return }
        let store = session.attachmentStore, media = media
        Task { [weak self] in
            guard let self else { return }
            let engine = audioEngine ?? AudioPlaybackEngine()
            audioEngine = engine
            if activeAudioMessageId != m.id {
                engine.pause()
                guard let bytes = try? await Task.detached(operation: { try store.plaintext(of: a) }).value ?? nil else { return }
                let source: PCMSource = { start, count in
                    let c = try await media.decodeAudio(bytes, startFrame: start, maxFrames: count)
                    return PCMChunk(sampleRate: c.sampleRate, channels: c.channels, totalFrames: c.totalFrames, startFrame: c.startFrame,
                                    samples: c.floats)
                }
                do {
                    try await engine.load(source, playbackRate: audioRate)
                } catch {
                    Self.trace("audio failed: \(error)")
                    return
                }
                guard let path = a.path, mediaIsAvailable(path: path, messageId: m.id) else {
                    engine.pause()
                    if audioEngine === engine { audioEngine = nil }
                    return
                }
                activeAudioMessageId = m.id
                activeAudioPath = path
                activeAudioAuthor = m.direction == .outgoing ? nil : m.author
                audioTime = 0
                engine.onEnded = { [weak self] in Task { @MainActor in self?.audioEnded(m.id) } }
                if m.direction == .incoming, !m.isViewed {
                    Task { _ = try? await session.messenger.markViewed(messageId: m.id) }
                }
            }
            if position > 0, let d = engine.duration { await engine.seek(to: position * d) }
            await engine.play()
            startAudioClock()
        }
    }

    func seekAudio(to position: Double) {
        guard let engine = audioEngine, let d = engine.duration else { return }
        audioTime = position * d
        Task { await engine.seek(to: position * d) }
    }

    func setAudioPlaying(_ playing: Bool) {
        Self.trace("audio: setPlaying(\(playing)) for \(activeAudioMessageId ?? "-"), engine \(audioEngine.map { $0.isPlaying ? "playing" : "paused" } ?? "none")")
        guard let engine = audioEngine else { return }
        if playing {
            Task {
                await engine.play()
                startAudioClock()
            }
        } else {
            engine.pause()
            audioPlaying = false
            audioTime = engine.currentTime
        }
    }

    func setAudioRate(_ rate: Double) {
        audioRate = rate
        guard let engine = audioEngine else { return }
        Task { await engine.setPlaybackRate(rate) }
    }

    /// Stops playback (the mini-player's close, `unloadMessageAudio`).
    func stopAudio() {
        audioEngine?.pause()
        audioEngine = nil
        audioClockTask?.cancel()
        activeAudioMessageId = nil
        activeAudioPath = nil
        activeAudioAuthor = nil
        audioPlaying = false
        audioTime = 0
    }

    /// The play head for the active bubble, ~20 times a second while playing.
    func startAudioClock() {
        audioClockTask?.cancel()
        audioClockTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let engine = self.audioEngine else { return }
                self.audioPlaying = engine.isPlaying
                self.audioTime = engine.currentTime
                if !engine.isPlaying { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// At the end: back to the start, then the next voice note in the chat (upstream plays
    /// consecutive voice notes).
    func audioEnded(_ id: String) {
        guard activeAudioMessageId == id else { return }
        audioPlaying = false
        audioTime = 0
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        if let next = messages[(i + 1)...].first(where: { $0.content == .voiceMessage }),
           next.attachments.first?.attachment.isDownloaded == true {
            playAudio(next, at: 0)
        }
    }
}
