// The one audited `unsafe` in SignalUI (approved 2026-11-05; Tools/lint-codecs.sh allows
// exactly this line): macOS 27 offers no safe way to write samples into an AVAudioPCMBuffer.
// `mutableChannelData` hands out a bounds-checked MutableSpan; it is @unsafe only because the
// buffer is a shared reference. Here the buffer is created in this function, written once,
// and only then shared (scheduled), so no other access can overlap the writes.

import AVFAudio

enum PCMBuffer {
    /// A non-interleaved float32 buffer of `frames` frames from interleaved samples (already
    /// validated by the caller: `samples.count == frames · format.channelCount`).
    static func make(format: AVAudioFormat, interleaved samples: [Float], frames: Int) -> AVAudioPCMBuffer? {
        let channels = Int(format.channelCount)
        guard frames > 0, samples.count == frames * channels, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0 ..< channels {
            switch unsafe buffer.mutableChannelData(c) {
            case .float(var span):
                guard span.count >= frames else { return nil }
                for i in 0 ..< frames { span[i] = samples[i * channels + c] }
            default:
                return nil
            }
        }
        return buffer
    }
}
