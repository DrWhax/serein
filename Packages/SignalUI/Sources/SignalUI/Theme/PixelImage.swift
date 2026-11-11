// Pixel images without ImageIO or pointer APIs: an RGBA8 buffer is handed to a Metal shader
// (`ShaderLibrary` data argument) that resamples it into the view's frame. Bundled images are
// PNGs (photos as shipped, complex SVGs rasterised at 2× by Tools/gen-images.mjs) decoded by
// SignalCodecs' Swift PNG decoder. An animated image (a GIF, APNG or animated WebP the media
// service decoded) carries all its frames and plays them as Chromium's `<img>` does.

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
    /// Every frame, when the image animates (`pixels` is the first).
    public let animation: RGBAAnimation?

    public init(width: Int, height: Int, pixels: Data, scale: CGFloat = 1) {
        precondition(pixels.count == width * height * 4, "RGBA8 buffer size")
        self.width = width
        self.height = height
        self.pixels = pixels
        self.scale = scale
        self.animation = nil
    }

    /// `frames`: each frame's pixels one after another; `delays` in milliseconds as encoded;
    /// `plays`: 0 forever. One frame is a still image.
    public init(width: Int, height: Int, frames: Data, delays: [Int], plays: Int, scale: CGFloat = 1) {
        let n = width * height * 4
        precondition(!delays.isEmpty && frames.count == n * delays.count, "RGBA8 frames size")
        let split = (0..<delays.count).map { i in frames.subdata(in: frames.startIndex + i * n ..< frames.startIndex + (i + 1) * n) }
        self.width = width
        self.height = height
        self.pixels = split[0]
        self.scale = scale
        self.animation = delays.count > 1 ? RGBAAnimation(frames: split, delays: delays, plays: plays) : nil
    }

    /// The first frame only.
    public var still: RGBAImage { animation == nil ? self : RGBAImage(width: width, height: height, pixels: pixels, scale: scale) }

    /// Bytes the pixels take (every frame).
    public var byteCount: Int { animation.map { $0.frames.count * pixels.count } ?? pixels.count }

    public init(_ buffer: PixelBuffer, scale: CGFloat = 1) {
        self.init(width: buffer.width, height: buffer.height, pixels: Data(buffer.rgba), scale: scale)
    }

    public var size: CGSize { CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale) }
}

/// An animation's frames and timing. Compared by identity (the frames are not compared).
public final class RGBAAnimation: Sendable, Hashable {
    public let frames: [Data]
    /// Each frame's duration in milliseconds, after Chromium's clamp (`DeferredImageDecoder::
    /// FrameDurationAtIndex`): 10 ms or less is shown for 100 ms.
    public let durations: [Int]
    /// Times the animation plays; 0 (or more than an Int can count in milliseconds) is forever.
    public let plays: Int
    let starts: [Int]
    let total: Int
    /// When the last play ends, in milliseconds (nil: never).
    let end: Int?

    init(frames: [Data], delays: [Int], plays: Int) {
        precondition(frames.count == delays.count && frames.count > 1)
        self.frames = frames
        durations = delays.map { $0 <= 10 ? 100 : $0 }
        var starts: [Int] = [], t = 0
        for d in durations {
            starts.append(t)
            t += d
        }
        self.starts = starts
        total = t
        self.plays = max(plays, 0)
        let (product, overflow) = total.multipliedReportingOverflow(by: self.plays)
        end = self.plays == 0 || overflow ? nil : product
    }

    public static func == (a: RGBAAnimation, b: RGBAAnimation) -> Bool { a === b }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }

    /// The frame shown `ms` milliseconds after the animation started; after the last play, the
    /// last frame stays.
    public func frame(atMilliseconds ms: Int) -> Int {
        if let end, ms >= end { return frames.count - 1 }
        let t = max(ms, 0) % total
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// When the frame shown at `ms` gives way to the next (nil: it stays).
    public func nextChange(afterMilliseconds ms: Int) -> Int? {
        let ms = max(ms, 0)
        if let end, ms >= end { return nil }
        let i = frame(atMilliseconds: ms)
        let next = ms / total * total + starts[i] + durations[i]
        if let end, next >= end { return nil }
        return next
    }

    /// The frame for a date, `start` being when the animation began.
    func frame(at date: Date, start: Date) -> Int {
        frame(atMilliseconds: Int((date.timeIntervalSince(start) * 1000).rounded()))
    }
}

/// The dates an animation's frames change on.
struct AnimationSchedule: TimelineSchedule {
    let start: Date
    let animation: RGBAAnimation

    func entries(from: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var first = true
        var ms = max(0, Int((from.timeIntervalSince(start) * 1000).rounded(.down)))
        return AnyIterator {
            if first {
                first = false
                return from
            }
            guard let next = animation.nextChange(afterMilliseconds: ms) else { return nil }
            ms = next
            return start.addingTimeInterval(Double(next) / 1000)
        }
    }
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
        if let animation = image.animation {
            AnimatedPixelImage(image: image, animation: animation, fit: fit, snapsOutward: snapsOutward, snapsContentRect: snapsContentRect)
                .id(ObjectIdentifier(animation))
        } else {
            still
        }
    }

    var still: some View {
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

/// Plays an animation from when it first appears.
struct AnimatedPixelImage: View {
    let image: RGBAImage
    let animation: RGBAAnimation
    let fit: ObjectFit
    let snapsOutward: Bool
    let snapsContentRect: Bool
    @State private var start = Date()

    var body: some View {
        TimelineView(AnimationSchedule(start: start, animation: animation)) { context in
            let i = animation.frame(at: context.date, start: start)
            PixelImage(RGBAImage(width: image.width, height: image.height, pixels: animation.frames[i], scale: image.scale),
                       fit: fit, snapsOutward: snapsOutward, snapsContentRect: snapsContentRect)
        }
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

extension EnvironmentValues {
    /// A rebranded build's app logo, shown where upstream draws signal-logo.svg (the About
    /// window, the no-conversation splash). nil: upstream's Signal logo.
    @Entry public var brandLogo: RGBAImage? = nil
}
