/// A frame as the renderer takes it.
public struct VideoPlanes: Sendable, Equatable {
    public var width: Int, height: Int
    public var y: [UInt8], u: [UInt8], v: [UInt8]
    public var fullRange: Bool
    /// matrix_coefficients (1 BT.709, 5/6 BT.601, 9 BT.2020, 2 unspecified: by size).
    public var matrix: Int
    /// transfer_characteristics (16 PQ, 18 HLG: shown tone-mapped to SDR; others SDR gamma).
    public var transfer: Int
    public var time: Double
    /// 8: a byte per sample; 9–12: two (little-endian), keeping 10-bit HDR's precision.
    public var bitDepth: Int
    /// The size the video was decoded at (larger than `width` x `height` when the media service
    /// scaled the frame to the view showing it).
    public var decodedWidth: Int, decodedHeight: Int

    public init(width: Int, height: Int, y: [UInt8], u: [UInt8], v: [UInt8], fullRange: Bool, matrix: Int, time: Double, transfer: Int = 1, bitDepth: Int = 8,
                decodedWidth: Int? = nil, decodedHeight: Int? = nil) {
        self.transfer = transfer
        self.bitDepth = bitDepth
        self.width = width
        self.height = height
        self.decodedWidth = decodedWidth ?? width
        self.decodedHeight = decodedHeight ?? height
        self.y = y
        self.u = u
        self.v = v
        self.fullRange = fullRange
        self.matrix = matrix
        self.time = time
    }

    public var isValid: Bool {
        guard (1...8192).contains(width), (1...8192).contains(height) else { return false }
        let cw = (width + 1) / 2, ch = (height + 1) / 2, b = bitDepth > 8 ? 2 : 1
        return (8...12).contains(bitDepth) && y.count == width * height * b
            && u.count == cw * ch * b && v.count == cw * ch * b && (width...8192).contains(decodedWidth) && (height...8192).contains(decodedHeight)
    }
}

/// A packed RGBA frame (remote call video, already rotated by ringrtc).
public struct RGBAFrame: Sendable, Equatable {
    public var width: Int, height: Int
    public var pixels: [UInt8]
    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
    public var isValid: Bool { width > 0 && height > 0 && width <= 8192 && height <= 8192 && pixels.count == width * height * 4 }
}


extension VideoRenderer {
    /// The shader's colour handling: BT.601, BT.709, BT.2020 SDR, BT.2020 HLG / PQ (to SDR).
    public enum Colour: Int, Sendable { case bt601 = 0, bt709 = 1, bt2020 = 2, hlg = 3, pq = 4 }

    public static func colour(matrix: Int, transfer: Int, height: Int) -> Colour {
        if matrix == 9 || matrix == 10 { return transfer == 18 ? .hlg : transfer == 16 ? .pq : .bt2020 }
        return matrix == 1 || (matrix == 2 && height > 576) ? .bt709 : .bt601
    }

    public enum Fit: Sendable { case contain, cover }
}
