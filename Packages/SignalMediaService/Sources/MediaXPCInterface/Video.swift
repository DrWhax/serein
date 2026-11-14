// Video requests and results for the media service: metadata, the poster frame upstream
// takes for sending (makeVideoScreenshot: the first frame, rotated, as PNG), and playback
// sessions that hand out decoded frames (I420) in display order, scaled down in the service to
// the size the player shows them at (VideoFit), so full-size frames never cross the process
// boundary only to be shrunk on the GPU.

import Foundation

public struct VideoInfo: Codable, Equatable, Sendable {
    /// Display size: after cropping and rotation.
    public var width: Int
    public var height: Int
    /// Clockwise rotation the player applies to the decoded frames (0, 90, 180, 270).
    public var rotation: Int
    public var duration: Double
    public var hasAudio: Bool
    /// `isVideoGoodForStories`: H.264 (avc1) and at most 30.999 s.
    public var goodForStories: Bool

    public init(width: Int, height: Int, rotation: Int, duration: Double, hasAudio: Bool, goodForStories: Bool) {
        self.width = width
        self.height = height
        self.rotation = rotation
        self.duration = duration
        self.hasAudio = hasAudio
        self.goodForStories = goodForStories
    }

    public func validated() throws -> VideoInfo {
        guard (1 ... 8192).contains(width), (1 ... 8192).contains(height), [0, 90, 180, 270].contains(rotation),
              duration.isFinite, duration >= 0, duration < 48 * 3600 else { throw MediaProcessingError.invalidResult }
        return self
    }
}

public struct VideoPoster: Codable, Equatable, Sendable {
    /// image/png, display size.
    public var png: Data
    public var width: Int
    public var height: Int
    public var duration: Double

    public init(png: Data, width: Int, height: Int, duration: Double) {
        self.png = png
        self.width = width
        self.height = height
        self.duration = duration
    }

    public func validated() throws -> VideoPoster {
        guard !png.isEmpty, (1 ... 8192).contains(width), (1 ... 8192).contains(height), duration.isFinite, duration >= 0 else {
            throw MediaProcessingError.invalidResult
        }
        return self
    }
}

/// The most a player shows of a video: its view in backing pixels, in display orientation (after
/// the track's rotation). Contained, the frame needs to fit inside it; covering, to cover it.
public struct VideoFit: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var cover: Bool

    public init(width: Int, height: Int, cover: Bool = false) {
        self.width = width
        self.height = height
        self.cover = cover
    }

    /// Frames are scaled only when this fit shows them at half their size or less: nearer to
    /// their size the GPU's own filtering shows them as well, and the copying saved would not
    /// pay for the scaling.
    public static let largestScale = 0.5

    /// The frame size (even, at least 2x2, never larger than the decoded `width` x `height`) the
    /// service sends for this fit with `rotation`: the size it is shown at, or the decoded size
    /// when that is less than twice as large.
    public func frameSize(width w: Int, height h: Int, rotation: Int) -> (width: Int, height: Int) {
        let tw = Double(max(1, rotation % 180 == 0 ? width : height)), th = Double(max(1, rotation % 180 == 0 ? height : width))
        guard w > 2, h > 2 else { return (w, h) }
        let s = cover ? max(tw / Double(w), th / Double(h)) : min(tw / Double(w), th / Double(h))
        guard s <= Self.largestScale else { return (w, h) }
        func even(_ v: Double, _ limit: Int) -> Int { min(limit, max(2, Int((v / 2).rounded()) * 2)) }
        return (even(Double(w) * s, w), even(Double(h) * s, h))
    }

    public func validated() throws -> VideoFit {
        guard (16 ... 16384).contains(width), (16 ... 16384).contains(height) else { throw MediaProcessingError.invalidResult }
        return self
    }
}

/// A decoded frame: I420 planes of the coded (cropped, unrotated) size, or smaller when scaled to
/// the player's VideoFit, one byte per sample (8-bit) or two (little-endian, `bitDepth` bits:
/// 10/12-bit video keeps its precision).
public struct VideoFrame: Codable, Equatable, Sendable {
    /// Presentation time in seconds.
    public var time: Double
    public var width: Int
    public var height: Int
    /// The size it was decoded at, before any scaling (at least `width` x `height`).
    public var decodedWidth: Int
    public var decodedHeight: Int
    public var y: Data, u: Data, v: Data
    /// Y′CbCr range and matrix (VUI matrix_coefficients: 1 BT.709, 5/6 BT.601, 9 BT.2020).
    public var fullRange: Bool
    public var matrix: Int
    /// VUI transfer_characteristics (16 PQ, 18 HLG; the renderer tone-maps those to SDR).
    public var transfer: Int
    public var bitDepth: Int

    public init(time: Double, width: Int, height: Int, y: Data, u: Data, v: Data, fullRange: Bool, matrix: Int, transfer: Int = 1, bitDepth: Int = 8,
                decodedWidth: Int? = nil, decodedHeight: Int? = nil) {
        self.transfer = transfer
        self.bitDepth = bitDepth
        self.time = time
        self.width = width
        self.height = height
        self.decodedWidth = decodedWidth ?? width
        self.decodedHeight = decodedHeight ?? height
        self.y = y
        self.u = u
        self.v = v
        self.fullRange = fullRange
        self.matrix = matrix
    }

    public func validated() throws -> VideoFrame {
        let cw = (width + 1) / 2, ch = (height + 1) / 2, b = bitDepth > 8 ? 2 : 1
        guard (8 ... 12).contains(bitDepth), (2 ... 8192).contains(width), (2 ... 8192).contains(height), width % 2 == 0, height % 2 == 0,
              y.count == width * height * b, u.count == cw * ch * b, v.count == cw * ch * b, time.isFinite, (0...255).contains(matrix), (0...255).contains(transfer),
              (width ... 8192).contains(decodedWidth), (height ... 8192).contains(decodedHeight)
        else { throw MediaProcessingError.invalidResult }
        return self
    }
}

public enum VideoLimits {
    /// Open videos at once (the GIF picker plays a preview per visible tile).
    public static let maxSessions = 24
    public static let maxFramesPerRequest = 8
}
