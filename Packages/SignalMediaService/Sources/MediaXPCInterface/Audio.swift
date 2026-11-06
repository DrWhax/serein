// Audio requests and results for the media service, and the waveform math shared by the
// service (attachments) and the app (the recording level meter).

import Foundation

/// Port of ts/util/waveformBuilder.std.ts: the `audioWaveform` of SignalService.proto, at most
/// 100 mean-square bins of the (interleaved) samples, compacted by halving, as 0…255 levels.
public struct WaveformBuilder: Sendable {
    public static let maxSize = 100
    static let half = maxSize / 2
    var waveform = [Double](repeating: 0, count: maxSize)
    var length = 0
    var shift = 0

    public init() {}

    public mutating func push(_ sample: Float) {
        var index = length >> shift
        if index >= Self.maxSize {
            for i in 0 ..< Self.half { waveform[i] = (waveform[2 * i] + waveform[2 * i + 1]) / 2 }
            for i in Self.half ..< Self.maxSize { waveform[i] = 0 }
            shift += 1
            index = Self.half
        }
        waveform[index] += Double(sample) * Double(sample) / Double(1 << shift)
        length += 1
    }

    public func collect() -> [Int] {
        var w = waveform
        var n = length >> shift
        let last = length % (1 << shift)
        if last != 0 {
            w[n] = w[n] * Double(1 << shift) / Double(last)
            n += 1
        }
        return (0 ..< n).map { toPeak(w[$0]) }
    }
}

/// `toPeak`: a mean square → 0…255 over a −60 dB noise bed.
public func toPeak(_ meanSquare: Double) -> Int {
    let noiseBed = -60.0
    let db = meanSquare > 0 ? 10 * log10(meanSquare) : -Double.infinity
    let v = max(0, db - noiseBed) / -noiseBed
    return Int((v * 255).rounded(.toNearestOrAwayFromZero))
}

public enum AudioLimits {
    /// `MAX_AUDIO_DURATION` (VoiceNotesPlaybackContext): longer audio gets no waveform.
    public static let maxWaveformDuration: Double = 15 * 60
    /// Bounds on what the service may return.
    public static let sampleRates = 8000 ... 96000
    public static let maxChannels = 2
    public static let maxChunkFrames = 96000 * 30
}

/// A stretch of decoded audio: float32 little-endian samples, channels interleaved, in the
/// stream's presentation timeline (encoder delay, priming and padding removed).
public struct AudioChunk: Codable, Equatable, Sendable {
    public var sampleRate: Int
    public var channels: Int
    /// Frames in the whole stream.
    public var totalFrames: Int
    public var startFrame: Int
    public var samples: Data

    public init(sampleRate: Int, channels: Int, totalFrames: Int, startFrame: Int, samples: Data) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.totalFrames = totalFrames
        self.startFrame = startFrame
        self.samples = samples
    }

    public var frameCount: Int { samples.count / 4 / max(1, channels) }
    public var duration: Double { Double(totalFrames) / Double(max(1, sampleRate)) }

    public func validated(requestedStart: Int, maxFrames: Int) throws -> AudioChunk {
        guard AudioLimits.sampleRates.contains(sampleRate), (1 ... AudioLimits.maxChannels).contains(channels),
              samples.count % (4 * channels) == 0, totalFrames >= 0, startFrame == requestedStart,
              frameCount <= min(maxFrames, AudioLimits.maxChunkFrames), startFrame + frameCount <= totalFrames || frameCount == 0
        else { throw MediaProcessingError.invalidResult }
        return self
    }

    /// The samples as floats.
    public var floats: [Float] {
        var out = [Float](repeating: 0, count: samples.count / 4)
        var i = 0
        for k in out.indices {
            let b0 = UInt32(samples[samples.startIndex + i]), b1 = UInt32(samples[samples.startIndex + i + 1])
            let b2 = UInt32(samples[samples.startIndex + i + 2]), b3 = UInt32(samples[samples.startIndex + i + 3])
            out[k] = Float(bitPattern: b0 | b1 << 8 | b2 << 16 | b3 << 24)
            i += 4
        }
        return out
    }
}

/// `computeWaveform`'s result for an audio attachment.
public struct AudioSummary: Codable, Equatable, Sendable {
    /// 0…255 levels, at most 100; empty when the audio is longer than 15 minutes.
    public var waveform: [Int]
    public var duration: Double
    public var sampleRate: Int
    public var channels: Int

    public init(waveform: [Int], duration: Double, sampleRate: Int, channels: Int) {
        self.waveform = waveform
        self.duration = duration
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public func validated() throws -> AudioSummary {
        guard waveform.count <= WaveformBuilder.maxSize, waveform.allSatisfy({ (0 ... 255).contains($0) }),
              duration.isFinite, duration >= 0, duration < 24 * 3600,
              AudioLimits.sampleRates.contains(sampleRate), (1 ... AudioLimits.maxChannels).contains(channels)
        else { throw MediaProcessingError.invalidResult }
        return self
    }
}

/// A finished voice note (upstream's AudioRecorder result).
public struct VoiceNote: Codable, Equatable, Sendable {
    /// audio/mpeg, starting with the Xing/LAME tag frame.
    public var data: Data
    public var waveform: [Int]
    public var duration: Double

    public init(data: Data, waveform: [Int], duration: Double) {
        self.data = data
        self.waveform = waveform
        self.duration = duration
    }

    public func validated() throws -> VoiceNote {
        guard !data.isEmpty, waveform.count <= WaveformBuilder.maxSize, waveform.allSatisfy({ (0 ... 255).contains($0) }),
              duration.isFinite, duration >= 0 else { throw MediaProcessingError.invalidResult }
        return self
    }
}
