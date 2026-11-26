/// Decoded audio from the media service: interleaved float32 samples of [startFrame,
/// startFrame + frames) out of `totalFrames`.
public struct PCMChunk: Sendable, Equatable {
    public var sampleRate: Int
    public var channels: Int
    public var totalFrames: Int
    public var startFrame: Int
    public var samples: [Float]

    public init(sampleRate: Int, channels: Int, totalFrames: Int, startFrame: Int, samples: [Float]) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.totalFrames = totalFrames
        self.startFrame = startFrame
        self.samples = samples
    }

    public var frames: Int { channels > 0 ? samples.count / channels : 0 }
}

/// Fetches frames [start, start + count).
public typealias PCMSource = @Sendable (_ start: Int, _ count: Int) async throws -> PCMChunk
