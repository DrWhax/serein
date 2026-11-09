// MediaProcessing over SignalCodecs: the service side. Formats are sniffed from the bytes
// (never trusted from a content type); every decoder runs with its default limits.

import Blurhash
import CodecCore
import EncodeJPEG
import EncodePNG
import EncodeWebP
import Foundation
import ImageBMP
import ImageGIF
import ImageJPEG
import ImagePNG
import ImageWebP
import MediaXPCInterface
import MetadataStrip

public struct MediaDecoder: MediaProcessing {
    public init() {}

    public enum Format: Equatable, Sendable { case png, jpeg, gif, webp, bmp, ico }

    public static func sniff(_ b: [UInt8]) -> Format? {
        func starts(_ p: [UInt8], at o: Int = 0) -> Bool { b.count >= o + p.count && Array(b[o..<(o + p.count)]) == p }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) { return .gif }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) { return .webp }
        if starts([0x42, 0x4D]) { return .bmp }
        if starts([0x00, 0x00, 0x01, 0x00]) { return .ico }
        return nil
    }

    /// The decoded image (its still frame) and whether it animates.
    public static func decode(_ bytes: Data) throws -> (PixelBuffer, animated: Bool) {
        let b = Array(bytes)
        guard let format = sniff(b) else { throw MediaProcessingError.unsupportedFormat }
        do {
            switch format {
            case .png: return still(try PNGDecoder.decode(b))
            case .jpeg: return (try JPEGDecoder.decode(b), false)
            case .gif: return still(try GIFDecoder.decode(b))
            case .webp: return still(try WebPDecoder.decode(b))
            case .bmp: return (try BMPDecoder.decode(b), false)
            case .ico: return (try ICODecoder.decode(b), false)
            }
        } catch {
            throw MediaProcessingError.undecodable("\(format): \(error)")
        }
    }

    static func still(_ d: DecodedImage) -> (PixelBuffer, animated: Bool) {
        if case .animated = d { return (d.stillImage, true) }
        return (d.stillImage, false)
    }

    /// `processImage`: an animated PNG passes as-is (square, 10…512px, looping forever, ≤ 300 KiB);
    /// any other still image is drawn contained and centred on a transparent 512px square and
    /// encoded as (lossless) WebP. Other animations are refused.
    public func stickerImage(_ bytes: Data) async throws -> StickerImage {
        let b = Array(bytes)
        if Self.sniff(b) == .png, let decoded = try? PNGDecoder.decode(b), case .animated(let anim, _) = decoded {
            guard anim.width == anim.height else { return StickerImage(data: Data(), contentType: "", refusal: .notSquare) }
            guard bytes.count <= StickerImage.maxBytes else { return StickerImage(data: Data(), contentType: "", refusal: .tooLarge) }
            guard anim.width >= StickerImage.minSize else { return StickerImage(data: Data(), contentType: "", refusal: .dimensionsTooSmall) }
            guard anim.width <= StickerImage.size else { return StickerImage(data: Data(), contentType: "", refusal: .dimensionsTooLarge) }
            guard anim.loopCount == 0 else { return StickerImage(data: Data(), contentType: "", refusal: .animated) }
            let still = decoded.stillImage
            return StickerImage(data: bytes, contentType: "image/png", previewWidth: still.width, previewHeight: still.height, previewRGBA: Data(still.rgba))
        }
        let image: PixelBuffer
        do {
            let (still, animated) = try Self.decode(bytes)
            if animated { return StickerImage(data: Data(), contentType: "", refusal: .animated) }
            image = still
        } catch {
            return StickerImage(data: Data(), contentType: "", refusal: .errorProcessing)
        }
        let size = StickerImage.size
        let scale = Double(size) / Double(max(image.width, image.height))
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        let scaled = w == image.width && h == image.height ? image : Scaler.resample(image, width: w, height: h)
        var canvas = [UInt8](repeating: 0, count: size * size * 4)
        let dx = (size - w) / 2, dy = (size - h) / 2
        for y in 0..<h {
            for x in 0..<w {
                let s = (y * w + x) * 4, d = ((y + dy) * size + x + dx) * 4
                canvas[d] = scaled.rgba[s]; canvas[d + 1] = scaled.rgba[s + 1]; canvas[d + 2] = scaled.rgba[s + 2]; canvas[d + 3] = scaled.rgba[s + 3]
            }
        }
        let webp = WebPEncoder.encodeLossless(PixelBuffer(width: size, height: size, rgba: canvas))
        guard webp.count <= StickerImage.maxBytes else { return StickerImage(data: Data(), contentType: "", refusal: .tooLarge) }
        return StickerImage(data: Data(webp), contentType: "image/webp", previewWidth: size, previewHeight: size, previewRGBA: Data(canvas))
    }

    public func imageInfo(_ bytes: Data) async throws -> ImageInfo {
        let (image, animated) = try Self.decode(bytes)
        guard image.width > 0, image.height > 0 else { throw MediaProcessingError.undecodable("empty image") }
        // imageToBlurHash: loadImage scaled into 200×200, then 4×3 components.
        let fit = Self.fitSize(width: image.width, height: image.height, max: MediaConstants.blurHashMaxDimension)
        let small = Scaler.resample(image, width: fit.width, height: fit.height)
        return ImageInfo(width: image.width, height: image.height, blurHash: Blurhash.encode(small, xComponents: 4, yComponents: 3),
                         isAnimated: animated)
    }

    public func thumbnail(_ bytes: Data, size: Int) async throws -> Thumbnail {
        let (image, _) = try Self.decode(bytes)
        guard image.width > 0, image.height > 0, size > 0 else { throw MediaProcessingError.undecodable("empty image") }
        let square = Scaler.cover(image, size: size)
        return Thumbnail(png: Data(PNGEncoder.encode(square)), width: size, height: size)
    }

    public func displayImage(_ bytes: Data, maxDimension: Int) async throws -> DisplayImage {
        guard (1...4096).contains(maxDimension) else { throw MediaProcessingError.undecodable("bad maxDimension") }
        let (image, _) = try Self.decode(bytes)
        guard image.width > 0, image.height > 0 else { throw MediaProcessingError.undecodable("empty image") }
        let fit = Self.fitSize(width: image.width, height: image.height, max: maxDimension)
        let scaled = fit.width == image.width && fit.height == image.height ? image : Scaler.resample(image, width: fit.width, height: fit.height)
        return DisplayImage(width: scaled.width, height: scaled.height, rgba: Data(scaled.rgba), originalWidth: image.width,
                            originalHeight: image.height)
    }

    public func scaleForSending(_ bytes: Data, contentType: String, level: MediaQualityLevel) async throws -> ScaledImage {
        let (image, _) = try Self.decode(bytes)
        let d = level.data
        // At or under the threshold: re-encoded in its own type (canvasToBlob), dropping
        // metadata; types we have no encoder for go out as PNG.
        if bytes.count <= d.thresholdSize {
            if contentType == "image/jpeg" {
                return ScaledImage(data: Data(JPEGEncoder.encode(image, quality: 92)), contentType: "image/jpeg", width: image.width, height: image.height)
            }
            return ScaledImage(data: Data(PNGEncoder.encode(image)), contentType: "image/png", width: image.width, height: image.height)
        }
        func jpeg(_ dimensions: Int) -> ScaledImage {
            let fit = Self.fitSize(width: image.width, height: image.height, max: dimensions)
            let scaled = fit.width == image.width && fit.height == image.height ? image : Scaler.resample(image, width: fit.width, height: fit.height)
            return ScaledImage(data: Data(JPEGEncoder.encode(Self.flattened(scaled), quality: d.quality)), contentType: "image/jpeg",
                               width: fit.width, height: fit.height)
        }
        for dimensions in MediaQualityLevel.scalableDimensions where d.maxDimensions >= dimensions {
            let out = jpeg(dimensions)
            if out.data.count <= d.size { return out }
        }
        return jpeg(MediaQualityLevel.minDimensions)
    }

    public func stripMetadata(_ bytes: Data, contentType: String) async throws -> Data {
        // BMP and ICO carry no metadata.
        if ["image/bmp", "image/x-ms-bmp", "image/x-icon", "image/vnd.microsoft.icon"].contains(contentType.lowercased()) { return bytes }
        guard let kind = MetadataStrip.kind(contentType: contentType) else { throw MediaProcessingError.unsupportedFormat }
        do {
            return Data(try MetadataStrip.strip(Array(bytes), kind: kind))
        } catch {
            throw MediaProcessingError.undecodable("metadata: \(error)")
        }
    }

    /// A canvas exported as JPEG composites transparency onto black.
    static func flattened(_ p: PixelBuffer) -> PixelBuffer {
        var rgba = p.rgba
        var i = 0
        while i < rgba.count {
            let a = Int(rgba[i + 3])
            if a < 255 {
                rgba[i] = UInt8(Int(rgba[i]) * a / 255); rgba[i + 1] = UInt8(Int(rgba[i + 1]) * a / 255); rgba[i + 2] = UInt8(Int(rgba[i + 2]) * a / 255)
                rgba[i + 3] = 255
            }
            i += 4
        }
        return PixelBuffer(width: p.width, height: p.height, rgba: rgba)
    }

    /// Scale-down-only fit (blueimp-load-image `maxWidth`/`maxHeight`).
    static func fitSize(width: Int, height: Int, max m: Int) -> (width: Int, height: Int) {
        guard width > m || height > m else { return (width, height) }
        let k = min(Double(m) / Double(width), Double(m) / Double(height))
        return (Swift.max(1, Int((Double(width) * k).rounded())), Swift.max(1, Int((Double(height) * k).rounded())))
    }
}

/// Area-averaging (box) resampling in premultiplied alpha, plus the cover crop.
public enum Scaler {
    public static func resample(_ src: PixelBuffer, width: Int, height: Int) -> PixelBuffer {
        resample(src, srcX: 0, srcY: 0, srcW: Double(src.width), srcH: Double(src.height), width: width, height: height)
    }

    /// `makeImageThumbnail`: cover-scale to size×size, then centre-crop.
    public static func cover(_ src: PixelBuffer, size: Int) -> PixelBuffer {
        let k = max(Double(size) / Double(src.width), Double(size) / Double(src.height))
        let cropW = Double(size) / k, cropH = Double(size) / k
        return resample(src, srcX: (Double(src.width) - cropW) / 2, srcY: (Double(src.height) - cropH) / 2,
                        srcW: cropW, srcH: cropH, width: size, height: size)
    }

    static func resample(_ src: PixelBuffer, srcX: Double, srcY: Double, srcW: Double, srcH: Double, width: Int, height: Int) -> PixelBuffer {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let sx = srcW / Double(width), sy = srcH / Double(height)
        let p = src.rgba
        for oy in 0..<height {
            let y0 = srcY + Double(oy) * sy, y1 = y0 + sy
            for ox in 0..<width {
                let x0 = srcX + Double(ox) * sx, x1 = x0 + sx
                var r = 0.0, g = 0.0, b = 0.0, a = 0.0, area = 0.0
                var y = Int(y0.rounded(.down))
                while Double(y) < y1, y < src.height {
                    let wy = min(Double(y + 1), y1) - max(Double(y), y0)
                    if y >= 0, wy > 0 {
                        var x = Int(x0.rounded(.down))
                        while Double(x) < x1, x < src.width {
                            let wx = min(Double(x + 1), x1) - max(Double(x), x0)
                            if x >= 0, wx > 0 {
                                let w = wx * wy, i = (y * src.width + x) * 4
                                let alpha = Double(p[i + 3]) / 255
                                r += Double(p[i]) * alpha * w; g += Double(p[i + 1]) * alpha * w; b += Double(p[i + 2]) * alpha * w
                                a += alpha * w; area += w
                            }
                            x += 1
                        }
                    }
                    y += 1
                }
                let o = (oy * width + ox) * 4
                guard area > 0, a > 0 else { continue }
                out[o] = UInt8(min(255, (r / a).rounded()))
                out[o + 1] = UInt8(min(255, (g / a).rounded()))
                out[o + 2] = UInt8(min(255, (b / a).rounded()))
                out[o + 3] = UInt8(min(255, (a / area * 255).rounded()))
            }
        }
        return PixelBuffer(width: width, height: height, rgba: out)
    }
}
