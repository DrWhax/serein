// Common decoder outputs. Pixels are 8-bit RGBA, straight (non-premultiplied)
// alpha, row-major, no row padding.

public struct PixelBuffer: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(width >= 0 && height >= 0 && rgba.count == width * height * 4)
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    /// Fully transparent black canvas.
    public init(transparentWidth width: Int, height: Int) {
        self.init(width: width, height: height, rgba: [UInt8](repeating: 0, count: width * height * 4))
    }

    public func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let i = (y * width + x) * 4
        return (rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3])
    }
}

public struct AnimationFrame: Sendable, Equatable {
    /// Fully composited canvas for this frame.
    public var image: PixelBuffer
    /// Display duration as encoded. Players apply browser-style clamping.
    public var delayMilliseconds: Int

    public init(image: PixelBuffer, delayMilliseconds: Int) {
        self.image = image
        self.delayMilliseconds = delayMilliseconds
    }
}

public struct AnimatedImage: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var frames: [AnimationFrame]
    /// 0 = loop forever.
    public var loopCount: Int

    public init(width: Int, height: Int, frames: [AnimationFrame], loopCount: Int) {
        self.width = width
        self.height = height
        self.frames = frames
        self.loopCount = loopCount
    }
}

public enum DecodedImage: Sendable, Equatable {
    case still(PixelBuffer)
    case animated(AnimatedImage, poster: PixelBuffer)

    /// The image to show when animation is off (or as the poster frame).
    public var stillImage: PixelBuffer {
        switch self {
        case .still(let p): return p
        case .animated(_, let poster): return poster
        }
    }
}

/// SignalSafe resource limits applied by every decoder *before* allocation.
public struct DecodeLimits: Sendable, Equatable {
    public var maxDimension: Int = 16_384
    public var maxPixels: Int = 64 * 1024 * 1024
    public var maxFrames: Int = 4_096
    /// Upper bound on the memory of all composited animation frames.
    public var maxAnimationBytes: Int = 512 * 1024 * 1024
    public var maxInputBytes: Int = 256 * 1024 * 1024

    public init() {}
    public static let `default` = DecodeLimits()

    public func checkDimensions(width: Int, height: Int, at offset: Int, rule: String) throws(ParseFailure) {
        guard width > 0, height > 0 else {
            throw ParseFailure(offset: offset, rule: rule, reason: .invalid("zero dimension \(width)x\(height)"))
        }
        guard width <= maxDimension, height <= maxDimension, width * height <= maxPixels else {
            throw ParseFailure(offset: offset, rule: rule, reason: .limitExceeded("dimensions \(width)x\(height)"))
        }
    }
}

/// An 8-bit RGB palette entry.
public struct RGB8: Sendable, Equatable, Hashable {
    public var r, g, b: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}
