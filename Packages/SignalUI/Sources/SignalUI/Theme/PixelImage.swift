// Pixel images without ImageIO or pointer APIs: an RGBA8 buffer is handed to a Metal shader
// (`ShaderLibrary` data argument) that resamples it into the view's frame. Bundled images are
// PNGs (photos as shipped, complex SVGs rasterised at 2× by Tools/gen-images.mjs) decoded by
// SignalCodecs' Swift PNG decoder.

import CodecCore
import Foundation
import ImagePNG
import SwiftUI
import Synchronization

/// An RGBA8 image with straight alpha, row-major, top row first.
public struct RGBAImage: Sendable, Hashable {
    public let width: Int
    public let height: Int
    public let pixels: Data
    /// Pixels per point of the source (2 for @2x assets); sets the natural size.
    public let scale: CGFloat

    public init(width: Int, height: Int, pixels: Data, scale: CGFloat = 1) {
        precondition(pixels.count == width * height * 4, "RGBA8 buffer size")
        self.width = width
        self.height = height
        self.pixels = pixels
        self.scale = scale
    }

    public init(_ buffer: PixelBuffer, scale: CGFloat = 1) {
        self.init(width: buffer.width, height: buffer.height, pixels: Data(buffer.rgba), scale: scale)
    }

    public var size: CGSize { CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale) }
}

/// CSS `object-fit`.
public enum ObjectFit: Sendable { case fill, contain, cover }

/// Draws an `RGBAImage` into its frame (`object-fit`, centred).
public struct PixelImage: View {
    let image: RGBAImage
    let fit: ObjectFit
    let snapsOutward: Bool
    let snapsContentRect: Bool
    @Environment(\.displayScale) var displayScale

    /// `snapsOutward`: draw into the fitted rect rounded outward to device pixels, as Chromium
    /// paints a lone `<img>` (the Lightbox's); the view's origin must be pixel-aligned.
    /// `snapsContentRect`: an `<img>`/`<video>` with `object-fit`, whose content rect Blink
    /// snaps to whole CSS pixels (not a CSS `background-size` image, which is not snapped).
    public init(_ image: RGBAImage, fit: ObjectFit = .fill, snapsOutward: Bool = false, snapsContentRect: Bool = false) {
        self.image = image
        self.fit = fit
        self.snapsOutward = snapsOutward
        self.snapsContentRect = snapsContentRect
    }

    public var body: some View {
        GeometryReader { geo in
            let natural = Self.rect(for: image.size, in: geo.size, fit: fit)
            let fitted = snapsContentRect ? Self.snapped(natural, origin: geo.frame(in: .global).origin, fit: fit) : natural
            let rect = snapsOutward ? Self.outward(fitted, scale: displayScale) : fitted
            Rectangle()
                .fill(ShaderLibrary.bundle(.module).pixelImage(
                    .data(image.pixels), .float(Float(image.width)), .float(Float(image.height)),
                    .float(Float(rect.minX)), .float(Float(rect.minY)), .float(Float(rect.width)), .float(Float(rect.height)),
                    .float(Float(displayScale))))
        }
        .clipped()
        .accessibilityHidden(true)
    }

    static func outward(_ r: CGRect, scale: CGFloat) -> CGRect {
        let x0 = (r.minX * scale + 1e-6).rounded(.down) / scale, y0 = (r.minY * scale + 1e-6).rounded(.down) / scale
        let x1 = (r.maxX * scale - 1e-6).rounded(.up) / scale, y1 = (r.maxY * scale - 1e-6).rounded(.up) / scale
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Blink pixel-snaps an object-fit replaced content rect: its edges, in page coordinates,
    /// to whole CSS pixels (rounded half up).
    static func snapped(_ r: CGRect, origin: CGPoint, fit: ObjectFit) -> CGRect {
        guard fit != .fill else { return r }
        func snap(_ v: CGFloat, _ o: CGFloat) -> CGFloat { (v + o + 0.5).rounded(.down) - o }
        let x0 = snap(r.minX, origin.x), y0 = snap(r.minY, origin.y), x1 = snap(r.maxX, origin.x), y1 = snap(r.maxY, origin.y)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static func rect(for natural: CGSize, in box: CGSize, fit: ObjectFit) -> CGRect {
        guard natural.width > 0, natural.height > 0, fit != .fill else { return CGRect(origin: .zero, size: box) }
        let sx = box.width / natural.width, sy = box.height / natural.height
        let k = fit == .contain ? min(sx, sy) : max(sx, sy)
        let size = CGSize(width: natural.width * k, height: natural.height * k)
        return CGRect(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2, width: size.width, height: size.height)
    }
}

/// Images shipped in Resources/Images (`name.png`, or `name@2x.png` for rasterised SVGs).
public enum BundledImage {
    private static let cache = Mutex<[String: RGBAImage]>([:])

    public static func named(_ name: String) -> RGBAImage? {
        if let hit = cache.withLock({ $0[name] }) { return hit }
        guard let dir = Bundle.module.url(forResource: "Images", withExtension: nil) else { return nil }
        var image: RGBAImage?
        for (file, scale) in [("\(name)@2x.png", 2.0), ("\(name).png", 1.0)] {
            let url = dir.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url), let decoded = try? PNGDecoder.decode([UInt8](data)) else { continue }
            image = RGBAImage(decoded.stillImage, scale: scale)
            break
        }
        if let image { cache.withLock { $0[name] = image } }
        return image
    }
}
