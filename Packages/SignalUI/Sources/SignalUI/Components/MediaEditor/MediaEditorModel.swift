// The media editor's document (ts/mediaEditor/*, the state upstream keeps in a Fabric.js
// canvas): the background image's state (`ImageStateType`: rotation, flips, crop, canvas
// size) and the objects drawn over it (pencil paths, text, stickers, digital and analog
// clocks), all in canvas pixels at zoom 1, with Fabric's geometry: an object is its centre,
// angle (degrees, clockwise) and scale over its own size.
//
// The operations are upstream's: rotate (objects turn with the image), flip (the image
// only), crop (objects shift by the crop origin), reset (rotation and crop undone for the
// objects). One fix: upstream turns the crop rectangle into source coordinates with a
// per-angle table that ignores flips (Fabric flips after taking the source crop), so after
// a flip the wrong part of the image is kept; here the rectangle goes through the inverse of
// the image's transform, which equals the table when nothing is flipped.

import CoreGraphics
import Foundation

/// `ImageStateType`
public struct MediaEditorImageState: Sendable, Equatable {
    /// Clockwise quarter turns, in degrees (0, 90, 180, 270).
    public var angle = 0
    /// Top-left of the kept region in the source image (unrotated pixels).
    public var cropX: CGFloat = 0
    public var cropY: CGFloat = 0
    public var flipX = false
    public var flipY = false
    /// The canvas: the kept region as displayed (after rotation).
    public var width: CGFloat = 0
    public var height: CGFloat = 0

    public init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    /// The kept region's size in source orientation.
    var regionSize: CGSize { angle % 180 == 0 ? CGSize(width: width, height: height) : CGSize(width: height, height: width) }

    /// `drawFabricBackgroundImage`: region coordinates (0…regionSize, source orientation, before
    /// the flip) → canvas. Fabric places the image's top-left corner at (left, top) for the
    /// angle, rotates about it, and flips about the image's centre.
    var imageTransform: CGAffineTransform {
        let s = regionSize
        let origin: CGPoint = switch angle {
        case 90: CGPoint(x: width, y: 0)
        case 180: CGPoint(x: width, y: height)
        case 270: CGPoint(x: 0, y: height)
        default: .zero
        }
        var t = CGAffineTransform(translationX: origin.x, y: origin.y).rotated(by: CGFloat(angle) * .pi / 180)
        if flipX || flipY {
            t = t.translatedBy(x: s.width / 2, y: s.height / 2).scaledBy(x: flipX ? -1 : 1, y: flipY ? -1 : 1).translatedBy(x: -s.width / 2, y: -s.height / 2)
        }
        return t
    }

    var canReset: Bool { cropX != 0 || cropY != 0 || flipX || flipY || angle != 0 }
}

/// `TextStyle`
public enum MediaEditorTextStyle: String, Sendable, CaseIterable { case regular, highlight, outline }

/// `DrawTool`
public enum MediaEditorDrawTool: String, Sendable, CaseIterable { case pen, highlighter }

/// `DrawWidth`
public enum MediaEditorDrawWidth: Int, Sendable, CaseIterable {
    case thin = 2, regular = 4, medium = 12, heavy = 24
}

/// `DigitalClockStickerStyle`, in `getNextStyle` order.
public enum DigitalClockStyle: String, Sendable, CaseIterable {
    case white, black, light, dark, orange
    var next: DigitalClockStyle { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
    /// `getTextStyle`: (fill, textBackgroundColor)
    var colors: (fill: RGBA, background: RGBA?) {
        switch self {
        case .white: (RGBA(1, 1, 1), nil)
        case .black: (RGBA(0, 0, 0), nil)
        case .light: (RGBA(1, 1, 1), RGBA(1, 1, 1, 0.4))
        case .dark: (RGBA(1, 1, 1), RGBA(0, 0, 0, 0.4))
        case .orange: (RGBA(1, 0x76 / 255, 0x29 / 255), RGBA(0, 0, 0, 0.6))
        }
    }
}

/// `AnalogClockStickerStyle`, in `getNextStyle` order.
public enum AnalogClockStyle: String, Sendable, CaseIterable {
    case arabic = "Arabic", baton = "Baton", explorer = "Explorer", dive = "Dive"
    var next: AnalogClockStyle { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
}

/// `getAnalogTime`: hand angles in degrees.
public struct AnalogTime: Sendable, Equatable {
    public var hour: Double
    public var minute: Double
    public init(hour: Double, minute: Double) {
        self.hour = hour
        self.minute = minute
    }
    public init(date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = Double(c.minute ?? 0), h = (c.hour ?? 0) % 12
        minute = m * 6
        hour = Double(h) * 30 + 30 * m / 60
    }
}

public struct MediaEditorObject: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Pencil points relative to the centre; the stroke as drawn.
        case path(points: [CGPoint], color: RGBA, width: CGFloat, tool: MediaEditorDrawTool)
        case text(String, style: MediaEditorTextStyle, hue: Double, fontSize: CGFloat)
        case sticker(RGBAImage)
        case digitalTime(Date, style: DigitalClockStyle)
        case analogTime(AnalogTime, style: AnalogClockStyle)
    }
    public let id: Int
    public var kind: Kind
    public var center: CGPoint
    /// Degrees, clockwise.
    public var angle: Double = 0
    public var scale: CGFloat = 1

    /// Selectable, with controls (paths are not: `evented: false`).
    var isSelectable: Bool { if case .path = kind { false } else { true } }
    var isText: Bool { if case .text = kind { true } else { false } }
    var isClock: Bool {
        switch kind {
        case .digitalTime, .analogTime: true
        default: false
        }
    }

    /// Object → canvas.
    var transform: CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle * .pi / 180).scaledBy(x: scale, y: scale)
    }
}

/// One undo step: `{ canvasState, imageState }`.
public struct MediaEditorSnapshot: Sendable, Equatable {
    public var objects: [MediaEditorObject]
    public var image: MediaEditorImageState
}

/// `useFabricHistory`: snapshots (at most 1000) and the applied one. Undo never goes past the
/// first (the initial state).
public struct MediaEditorHistory: Sendable, Equatable {
    public static let limit = 1000
    public private(set) var snapshots: [MediaEditorSnapshot] = []
    public private(set) var highWatermark = 0

    public init() {}

    public var canUndo: Bool { highWatermark > 1 }
    public var canRedo: Bool { highWatermark < snapshots.count }
    public var current: MediaEditorSnapshot? { highWatermark > 0 ? snapshots[highWatermark - 1] : nil }

    public mutating func take(_ s: MediaEditorSnapshot) {
        if let c = current, c == s { return }
        snapshots = Array(snapshots.prefix(highWatermark)) + [s]
        if snapshots.count > Self.limit { snapshots.removeFirst(snapshots.count - Self.limit) }
        highWatermark = snapshots.count
    }

    public mutating func undo() -> MediaEditorSnapshot? {
        guard canUndo else { return nil }
        highWatermark -= 1
        return current
    }

    public mutating func redo() -> MediaEditorSnapshot? {
        guard canRedo else { return nil }
        highWatermark += 1
        return current
    }
}

/// The document operations.
public enum MediaEditorGeometry {
    /// The crop button's rotate: a quarter turn counter-clockwise (angle + 270), objects with it.
    public static func rotate(_ s: inout MediaEditorSnapshot) {
        let w = s.image.width
        for i in s.objects.indices {
            let c = s.objects[i].center
            s.objects[i].angle = (s.objects[i].angle + 270).truncatingRemainder(dividingBy: 360)
            s.objects[i].center = CGPoint(x: c.y, y: w - c.x)
        }
        s.image.angle = (s.image.angle + 270) % 360
        (s.image.width, s.image.height) = (s.image.height, s.image.width)
    }

    /// Flip: horizontal as displayed (the source's vertical axis when turned a quarter).
    public static func flip(_ s: inout MediaEditorSnapshot) {
        if s.image.angle % 180 != 0 { s.image.flipY.toggle() } else { s.image.flipX.toggle() }
    }

    /// `getNewImageStateFromCrop` + `moveFabricObjectsForCrop`, for a crop rectangle in canvas
    /// pixels (flip-aware; see the file comment).
    public static func crop(_ s: inout MediaEditorSnapshot, to rect: CGRect) {
        let local = rect.applying(s.image.imageTransform.inverted()).standardized
        s.image.cropX += local.minX
        s.image.cropY += local.minY
        s.image.width = rect.width
        s.image.height = rect.height
        for i in s.objects.indices {
            s.objects[i].center.x -= rect.minX
            s.objects[i].center.y -= rect.minY
        }
    }

    /// The Reset button: the full source, unrotated and unflipped; `moveFabricObjectsForReset`
    /// undoes the rotation and the crop for the objects.
    public static func reset(_ s: inout MediaEditorSnapshot, sourceWidth: CGFloat, sourceHeight: CGFloat) {
        let old = s.image
        for i in s.objects.indices {
            let c = s.objects[i].center
            let right = old.width - c.x, bottom = old.height - c.y
            var p: CGPoint = switch old.angle % 360 {
            case 90: CGPoint(x: c.y, y: right)
            case 180: CGPoint(x: right, y: bottom)
            case 270: CGPoint(x: bottom, y: c.x)
            default: c
            }
            p.x += old.cropX
            p.y += old.cropY
            s.objects[i].angle -= Double(old.angle)
            s.objects[i].center = p
        }
        s.image = MediaEditorImageState(width: sourceWidth, height: sourceHeight)
    }

    /// The crop rectangle a crop session starts with (`PADDING` 4 screen pixels, more on small
    /// images), for a preset: freeform, square, or 9:16.
    public static func initialCropRect(_ image: MediaEditorImageState, zoom: CGFloat, preset: MediaEditorCropPreset) -> CGRect {
        let padding = 4 / zoom
        var h = image.height - padding * max(440 / image.height, 2)
        var w = image.width - padding * max(440 / image.width, 2)
        switch preset {
        case .square: (w, h) = (min(w, h), min(w, h))
        case .vertical: w = h * 0.5625
        case .freeform: break
        }
        return CGRect(x: (image.width - w) / 2, y: (image.height - h) / 2, width: w, height: h)
    }

    /// `#containBounds`: inside the canvas less the padding, never larger than it started.
    public static func containCrop(_ r: CGRect, start: CGSize, image: MediaEditorImageState, zoom: CGFloat) -> CGRect {
        let padding = 4 / zoom
        let w = min(max(r.width, 1), start.width), h = min(max(r.height, 1), start.height)
        let x = min(max(r.minX, padding), max(padding, image.width - w - padding))
        let y = min(max(r.minY, padding), max(padding, image.height - h - padding))
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// `CropPreset`
public enum MediaEditorCropPreset: String, Sendable, CaseIterable { case freeform, square, vertical }

/// `ts/mediaEditor/util/color.std.ts`: the hue slider (0…100) as a colour: black up to 7,
/// white from 95, the hue wheel (0…338°) in between.
public enum MediaEditorColor {
    static func hsl(_ percentage: Double) -> (h: Double, s: Double, l: Double) {
        func ratio(_ min: Double, _ max: Double, _ v: Double) -> Double { (v - min) / (max - min) }
        if percentage <= 7 { return (0, 0.5, 0.5 * ratio(0, 7, percentage)) }
        if percentage >= 95 { return (0, 0, min(1, 0.5 + ratio(95, 100, percentage))) }
        return (338 * ratio(7, 95, percentage), 1, 0.5)
    }

    /// CSS hsl() → sRGB.
    public static func color(_ percentage: Double, alpha: Double = 1) -> RGBA {
        let (h, s, l) = hsl(percentage)
        let c = (1 - abs(2 * l - 1)) * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch hp {
        case ..<1: (c, x, 0)
        case ..<2: (x, c, 0)
        case ..<3: (0, c, x)
        case ..<4: (0, x, c)
        case ..<5: (x, 0, c)
        default: (c, 0, x)
        }
        let m = l - c / 2
        return RGBA(r + m, g + m, b + m, alpha)
    }

    /// `getRGBA` (the highlighter): the colour rounded to whole 0…255 components.
    public static func rgba(_ percentage: Double, alpha: Double) -> RGBA {
        let c = color(percentage)
        func q(_ v: Double) -> Double { (v * 255).rounded() / 255 }
        return RGBA(q(c.r), q(c.g), q(c.b), alpha)
    }

    /// `getTextStyleAttributes`: (fill, stroke, background)
    static func text(_ style: MediaEditorTextStyle, hue: Double) -> (fill: RGBA, stroke: RGBA?, background: RGBA?) {
        let c = color(hue), contrast = hue >= 95 ? RGBA(0, 0, 0) : RGBA(1, 1, 1)
        switch style {
        case .regular: return (c, nil, nil)
        case .highlight: return (contrast, nil, c)
        case .outline: return (contrast, c, nil)
        }
    }
}

/// Fabric's PencilBrush: points are decimated (`decimate` 0.4 canvas pixels at the zoom,
/// squared-distance test) and drawn as quadratic curves through the midpoints
/// (`convertPointsToSVGPath`, with its 1/1000-width nudges at both ends).
public enum MediaEditorPencil {
    public static func decimate(_ points: [CGPoint], distance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let d2 = distance * distance
        var out = [points[0]]
        var last = points[0]
        for p in points.dropFirst().dropLast() {
            let dx = p.x - last.x, dy = p.y - last.y
            if dx * dx + dy * dy >= d2 {
                out.append(p)
                last = p
            }
        }
        out.append(points[points.count - 1])
        return out
    }

    public static func path(_ points: [CGPoint], width: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard points.count >= 2 else {
            if let p = points.first { path.move(to: p); path.addLine(to: p) }
            return path
        }
        let w = width / 1000
        var p1 = points[0], p2 = points[1]
        func sign(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a < b ? -1 : a == b ? 0 : 1 }
        var sx: CGFloat = 1, sy: CGFloat = 0
        let many = points.count > 2
        if many {
            sx = sign(points[2].x, p2.x)
            sy = sign(points[2].y, p2.y)
        }
        path.move(to: CGPoint(x: p1.x - sx * w, y: p1.y - sy * w))
        var i = 1
        while i < points.count {
            if p1 != p2 {
                path.addQuadCurve(to: CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2), control: p1)
            }
            p1 = points[i]
            if i + 1 < points.count { p2 = points[i + 1] }
            i += 1
        }
        if many {
            let prev = points[i - 2]
            sx = p1.x > prev.x ? 1 : p1.x == prev.x ? 0 : -1
            sy = p1.y > prev.y ? 1 : p1.y == prev.y ? 0 : -1
        }
        path.addLine(to: CGPoint(x: p1.x + sx * w, y: p1.y + sy * w))
        return path
    }
}
