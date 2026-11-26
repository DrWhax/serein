#if os(Linux)
import Foundation
import SignalUI

@MainActor extension SignalSession {
    func playRingtone() {
        guard ringtone == nil, accountSettings.callRingtoneNotification else { return }
        let url = URL(fileURLWithPath: "/opt/serein/share/sounds/ringtone_minimal.wav")
        guard let bytes = try? Data(contentsOf: url) else { return }
        let engine = AudioPlaybackEngine()
        ringtone = engine
        let media = media
        Task { [weak self, engine] in
            do {
                try await engine.load { start, count in
                    let chunk = try await media.decodeAudio(bytes, startFrame: start, maxFrames: count)
                    return PCMChunk(sampleRate: chunk.sampleRate, channels: chunk.channels, totalFrames: chunk.totalFrames,
                                    startFrame: chunk.startFrame, samples: chunk.floats)
                }
                guard self?.ringtone === engine else { return }
                engine.onEnded = { [weak self, weak engine] in
                    Task { @MainActor in
                        guard let engine, self?.ringtone === engine else { return }
                        await engine.play()
                    }
                }
                await engine.play()
            } catch {
                if self?.ringtone === engine { self?.ringtone = nil }
            }
        }
    }

    func stopRingtone() {
        ringtone?.onEnded = nil
        ringtone?.pause()
        ringtone = nil
    }
}
#endif
