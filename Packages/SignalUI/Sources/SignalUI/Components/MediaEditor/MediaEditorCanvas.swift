// Draws a media editor document as Fabric.js does (the Fabric object classes in
// ts/mediaEditor), into a SwiftUI GraphicsContext: on screen at the fit zoom with the
// selection and crop overlays, and at zoom 1 for export.
//
// - The background: the source cropped, flipped and rotated (`drawFabricBackgroundImage`).
// - Paths: the pencil stroke (round caps and bevel joins; the highlighter square/miter at
//   half alpha, twice the width).
// - Text (`MediaEditorFabricIText`): Inter bold (the SemiBold face the CSS `bold` resolves
//   to), centred lines, Fabric's metrics (line height 1.16 × 1.13 × size, baseline at the
//   line's glyph box less 0.222 × size), a background per line (Highlight) or a 2-unit
//   stroke over the fill (Outline). Text is drawn with CoreText (stroke mode for Outline).
// - Stickers: the image at its natural size, scaled.
// - Digital clock: the time in Hatsuishi 72 and the day period in Inter 11 beside it, over
//   a 14-radius rounded box (the group's width doubled, as upstream sets it) in the
//   style's colour; analog clock: the 600-unit dial and its hands, drawn over it, rotated
//   by the time and the object's angle.
// - Overlays (screen pixels): a 1px white border round the selected object with the
//   delete (top left), resize (bottom right) and rotate (40px above) controls and, for
//   clocks, the "More styles" pill 20px below; the crop rectangle with its L-shaped
//   corners and the 40 % black outside it.
//
// Images become CGImages through CoreImage's raw-bitmap initialiser (CGImage's own takes a
// decode pointer), premultiplied first.

import AppKit
import CoreImage
import CoreText
import SwiftUI
import Synchronization

/// An RGBA image with its CGImage, made once.
public final class MediaEditorBitmap: Sendable, Equatable {
    public let image: RGBAImage
    let cgImage: CGImage?

    public init(_ image: RGBAImage) {
        self.image = image
        cgImage = Self.makeCGImage(image)
    }

    public static func == (a: MediaEditorBitmap, b: MediaEditorBitmap) -> Bool { a === b }

    static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    static func makeCGImage(_ img: RGBAImage) -> CGImage? {
        guard img.width > 0, img.height > 0 else { return nil }
        var px = [UInt8](img.pixels)
        var opaque = true
        for i in stride(from: 3, to: px.count, by: 4) where px[i] != 255 {
            opaque = false
            let a = UInt16(px[i])
            px[i - 3] = UInt8((UInt16(px[i - 3]) * a + 127) / 255)
            px[i - 2] = UInt8((UInt16(px[i - 2]) * a + 127) / 255)
            px[i - 1] = UInt8((UInt16(px[i - 1]) * a + 127) / 255)
        }
        _ = opaque
        let ci = CIImage(bitmapData: Data(px), bytesPerRow: img.width * 4, size: CGSize(width: img.width, height: img.height), format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return context.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}

extension RGBA {
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var swiftUIColor: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

/// Text metrics (Fabric's IText) and layout.
enum MediaEditorText {
    static let lineHeight: CGFloat = 1.16, sizeMult: CGFloat = 1.13, sizeFraction: CGFloat = 0.222

    static func font(_ size: CGFloat, name: String = AxoFonts.interName(weight: 700)) -> CTFont {
        AxoFonts.register()
        return CTFontCreateWithName(name as CFString, size, nil)
    }

    static func width(_ s: String, font: CTFont) -> CGFloat {
        guard !s.isEmpty else { return 0 }
        return NSAttributedString(string: s, attributes: [.font: font as NSFont]).size().width
    }

    /// Size of a text object (an empty one is the 2px cursor wide).
    static func size(_ text: String, fontSize: CGFloat) -> CGSize {
        let f = font(fontSize)
        let lines = text.components(separatedBy: "\n")
        let w = max(2, lines.map { width($0, font: f) }.max() ?? 0)
        let h = fontSize * sizeMult * (lineHeight * CGFloat(lines.count - 1) + 1)
        return CGSize(width: w, height: h)
    }

    /// Draws centred lines in object coordinates (the origin at the object's centre).
    static func draw(_ text: String, fontSize: CGFloat, fontName: String = AxoFonts.interName(weight: 700), fill: RGBA, stroke: RGBA?, strokeWidth: CGFloat = 2,
                     background: RGBA?, in cg: CGContext) {
        let f = font(fontSize, name: fontName)
        let lines = text.components(separatedBy: "\n")
        let size = self.size(text, fontSize: fontSize)
        let lineH = fontSize * sizeMult * lineHeight, glyphBox = fontSize * sizeMult
        var top = -size.height / 2
        for line in lines {
            let w = width(line, font: f)
            let left = -w / 2
            if let background, w > 0 {
                cg.setFillColor(background.cgColor)
                cg.fill(CGRect(x: left, y: top, width: w, height: glyphBox))
            }
            if !line.isEmpty {
                let baseline = top + glyphBox - fontSize * sizeFraction
                let attr = NSAttributedString(string: line, attributes: [.font: f as NSFont, .foregroundColor: NSColor(cgColor: fill.cgColor) ?? .white])
                let ct = CTLineCreateWithAttributedString(attr)
                cg.saveGState()
                cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                cg.textPosition = CGPoint(x: left, y: baseline)
                cg.setTextDrawingMode(.fill)
                CTLineDraw(ct, cg)
                if let stroke {
                    cg.textPosition = CGPoint(x: left, y: baseline)
                    cg.setTextDrawingMode(.stroke)
                    cg.setStrokeColor(stroke.cgColor)
                    cg.setLineWidth(strokeWidth)
                    cg.setLineJoin(.miter)
                    cg.setMiterLimit(4)
                    let strokeAttr = NSAttributedString(string: line, attributes: [.font: f as NSFont, .foregroundColor: NSColor(cgColor: stroke.cgColor) ?? .white])
                    CTLineDraw(CTLineCreateWithAttributedString(strokeAttr), cg)
                }
                cg.restoreGState()
            }
            top += lineH
        }
    }
}

/// The digital clock's parts (`MediaEditorFabricDigitalTimeSticker`).
struct DigitalClockLayout {
    var time: String
    var dayPeriod: String
    var timeSize: CGSize
    var daySize: CGSize
    /// Centres relative to the group's centre.
    var timeCenter: CGPoint
    var dayCenter: CGPoint
    /// The group's size (its width set to twice the texts' total).
    var size: CGSize

    static let timeFont = "Hatsuishi-Regular2", dayFont = "Inter-Regular"

    init(date: Date, locale: Locale = .current) {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("jmm")
        let full = f.string(from: date)
        let am = f.amSymbol ?? "AM", pm = f.pmSymbol ?? "PM"
        var period = "", t = full
        for s in [am, pm] where !s.isEmpty && full.contains(s) {
            period = s
            t = full.replacingOccurrences(of: s, with: "")
        }
        time = t.trimmingCharacters(in: .whitespaces)
        dayPeriod = period
        let tf = MediaEditorText.font(72, name: Self.timeFont), df = MediaEditorText.font(11, name: Self.dayFont)
        timeSize = CGSize(width: MediaEditorText.width(time, font: tf), height: 72 * MediaEditorText.sizeMult)
        daySize = CGSize(width: MediaEditorText.width(dayPeriod, font: df), height: 11 * MediaEditorText.sizeMult)
        let total = timeSize.width + daySize.width
        let day = CGPoint(x: total / 2 + daySize.width / 2, y: timeSize.height / 2 - daySize.height * 1.66)
        // The group's box from its children, then the children relative to its centre.
        let minX = min(-timeSize.width / 2, day.x - daySize.width / 2), maxX = max(timeSize.width / 2, day.x + daySize.width / 2)
        let minY = min(-timeSize.height / 2, day.y - daySize.height / 2), maxY = max(timeSize.height / 2, day.y + daySize.height / 2)
        let c = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        timeCenter = CGPoint(x: -c.x, y: -c.y)
        dayCenter = CGPoint(x: day.x - c.x, y: day.y - c.y)
        size = CGSize(width: total * 2, height: maxY - minY)
    }
}

/// The analog clock's hands (`drawHands`): (length, width) as fractions of the radius, and
/// the offset that pushes them past the centre.
enum AnalogClockHands {
    static func hands(_ style: AnalogClockStyle) -> (hour: (CGFloat, CGFloat), minute: (CGFloat, CGFloat), offset: CGFloat) {
        switch style {
        case .arabic: ((0.44, 0.049), (0.69, 0.036), 0.106)
        case .baton: ((0.44, 0.09), (0.69, 0.09), 0.106)
        case .explorer: ((0.44, 0.07), (0.69, 0.07), 0)
        case .dive: ((0.47, 0.095), (0.89, 0.095), 0)
        }
    }
}

extension MediaEditorObject {
    /// The object's own size (before `scale`).
    var size: CGSize {
        switch kind {
        case .path(let points, _, let width, let tool):
            let w = tool == .highlighter ? width : width
            let b = MediaEditorPencil.path(points, width: w).boundingBoxOfPath
            return CGSize(width: b.width + w, height: b.height + w)
        case .text(let s, _, _, let fontSize): return MediaEditorText.size(s, fontSize: fontSize)
        case .sticker(let img): return CGSize(width: img.width, height: img.height)
        case .digitalTime(let date, _): return DigitalClockLayout(date: date).size
        case .analogTime: return CGSize(width: 600, height: 600)
        }
    }

    /// Corners in canvas coordinates (tl, tr, br, bl).
    var corners: [CGPoint] {
        let s = size, t = transform
        return [CGPoint(x: -s.width / 2, y: -s.height / 2), CGPoint(x: s.width / 2, y: -s.height / 2),
                CGPoint(x: s.width / 2, y: s.height / 2), CGPoint(x: -s.width / 2, y: s.height / 2)].map { $0.applying(t) }
    }

    func contains(_ p: CGPoint) -> Bool {
        let l = p.applying(transform.inverted()), s = size
        return abs(l.x) <= s.width / 2 && abs(l.y) <= s.height / 2
    }
}

/// What the overlay shows.
struct MediaEditorOverlay {
    var selected: Int?
    var crop: CGRect?
    /// A text object being edited (drawn by the text field, not the canvas).
    var editing: Int?
}

/// Control positions (screen pixels) for a selected object.
struct MediaEditorControls {
    var delete: CGPoint
    var resize: CGPoint
    var rotate: CGPoint
    var rotateAnchor: CGPoint
    var moreStyles: CGPoint?

    init(_ o: MediaEditorObject, zoom: CGFloat) {
        let c = o.corners.map { CGPoint(x: $0.x * zoom, y: $0.y * zoom) }
        let a = o.angle * .pi / 180
        delete = c[0]
        resize = c[2]
        let topMid = CGPoint(x: (c[0].x + c[1].x) / 2, y: (c[0].y + c[1].y) / 2)
        let bottomMid = CGPoint(x: (c[2].x + c[3].x) / 2, y: (c[2].y + c[3].y) / 2)
        // offsetY rotates with the object.
        rotate = CGPoint(x: topMid.x + 40 * sin(a), y: topMid.y - 40 * cos(a))
        rotateAnchor = topMid
        moreStyles = o.isClock ? CGPoint(x: bottomMid.x - 20 * sin(a), y: bottomMid.y + 20 * cos(a)) : nil
    }
}

struct MediaEditorRenderer {
    let background: MediaEditorBitmap
    var moreStylesLabel = "More styles"

    /// Draws the document at `zoom` (canvas pixel → point).
    func draw(_ s: MediaEditorSnapshot, in ctx: GraphicsContext, zoom: CGFloat, overlay: MediaEditorOverlay = .init()) {
        var c = ctx
        c.scaleBy(x: zoom, y: zoom)
        drawBackground(s.image, in: c)
        for o in s.objects where o.id != overlay.editing { draw(o, in: c) }
        if let crop = overlay.crop { drawCrop(crop, image: s.image, in: ctx, zoom: zoom) }
        if let id = overlay.selected, let o = s.objects.first(where: { $0.id == id }) { drawSelection(o, in: ctx, zoom: zoom) }
    }

    func drawBackground(_ img: MediaEditorImageState, in ctx: GraphicsContext) {
        guard let cg = background.cgImage else { return }
        var c = ctx
        c.concatenate(img.imageTransform)
        let region = img.regionSize
        c.clip(to: Path(CGRect(origin: .zero, size: region)))
        let full = CGRect(x: -img.cropX, y: -img.cropY, width: CGFloat(background.image.width), height: CGFloat(background.image.height))
        c.draw(Image(decorative: cg, scale: 1).interpolation(.high), in: full)
    }

    func draw(_ o: MediaEditorObject, in ctx: GraphicsContext) {
        var c = ctx
        c.concatenate(o.transform)
        switch o.kind {
        case .path(let points, let color, let width, let tool):
            let p = Path(MediaEditorPencil.path(points, width: width))
            let style = tool == .highlighter ? StrokeStyle(lineWidth: width, lineCap: .square, lineJoin: .miter, miterLimit: 10)
                                             : StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .bevel, miterLimit: 10)
            c.stroke(p, with: .color(color.swiftUIColor), style: style)
        case .text(let text, let style, let hue, let fontSize):
            let colors = MediaEditorColor.text(style, hue: hue)
            c.withCGContext { cg in
                MediaEditorText.draw(text, fontSize: fontSize, fill: colors.fill, stroke: colors.stroke, background: colors.background, in: cg)
            }
        case .sticker(let img):
            let bitmap = MediaEditorBitmapCache.shared.bitmap(for: o.id, img)
            if let cg = bitmap.cgImage {
                c.draw(Image(decorative: cg, scale: 1).interpolation(.high),
                       in: CGRect(x: -CGFloat(img.width) / 2, y: -CGFloat(img.height) / 2, width: CGFloat(img.width), height: CGFloat(img.height)))
            }
        case .digitalTime(let date, let style):
            drawDigital(o, date: date, style: style, ctx: ctx)
        case .analogTime(let time, let style):
            drawAnalog(o, time: time, style: style, ctx: ctx)
        }
    }

    func drawDigital(_ o: MediaEditorObject, date: Date, style: DigitalClockStyle, ctx: GraphicsContext) {
        let l = DigitalClockLayout(date: date)
        let colors = style.colors
        if let bg = colors.background {
            // The group's axis-aligned bounding box in canvas space.
            let xs = o.corners.map(\.x), ys = o.corners.map(\.y)
            let r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            ctx.fill(Path(roundedRect: r, cornerRadius: 14), with: .color(bg.swiftUIColor))
        }
        var c = ctx
        c.concatenate(o.transform)
        c.withCGContext { cg in
            cg.saveGState()
            cg.translateBy(x: l.timeCenter.x, y: l.timeCenter.y)
            MediaEditorText.draw(l.time, fontSize: 72, fontName: DigitalClockLayout.timeFont, fill: colors.fill, stroke: nil, background: nil, in: cg)
            cg.restoreGState()
            cg.translateBy(x: l.dayCenter.x, y: l.dayCenter.y)
            MediaEditorText.draw(l.dayPeriod, fontSize: 11, fontName: DigitalClockLayout.dayFont, fill: colors.fill, stroke: nil, background: nil, in: cg)
        }
    }

    func drawAnalog(_ o: MediaEditorObject, time: AnalogTime, style: AnalogClockStyle, ctx: GraphicsContext) {
        var c = ctx
        c.concatenate(o.transform)
        SignalIconDrawing.draw("analog-time/\(style.rawValue)", in: CGRect(x: -300, y: -300, width: 600, height: 600), ctx: c)
        // Hands: in canvas space about the centre, by the time plus the object's angle.
        let radius = 300 * o.scale
        let h = AnalogClockHands.hands(style)
        var hc = ctx
        hc.translateBy(x: o.center.x, y: o.center.y)
        for (deg, spec, name) in [(time.hour, h.hour, "hour"), (time.minute, h.minute, "minute")] {
            var r = hc
            r.rotate(by: .degrees(deg + o.angle))
            let length = radius * spec.0, width = radius * spec.1, offset = radius * h.offset
            SignalIconDrawing.draw("analog-time/\(style.rawValue)-\(name)", in: CGRect(x: -width / 2, y: -length + offset, width: width, height: length), ctx: r)
        }
        if style == .dive {
            let s = radius * 0.08
            hc.fill(Path(ellipseIn: CGRect(x: -s, y: -s, width: 2 * s, height: 2 * s)), with: .color(Color(.sRGB, red: 0xd1 / 255, green: 1, blue: 0xc1 / 255)))
        }
    }

    // MARK: overlays (screen pixels)

    func drawCrop(_ r: CGRect, image: MediaEditorImageState, in ctx: GraphicsContext, zoom: CGFloat) {
        let s = CGRect(x: r.minX * zoom, y: r.minY * zoom, width: r.width * zoom, height: r.height * zoom)
        let w = image.width * zoom, h = image.height * zoom
        var outside = Path(CGRect(x: 0, y: 0, width: w, height: h))
        outside.addRect(s)
        ctx.fill(outside, with: .color(.black.opacity(0.4)), style: FillStyle(eoFill: true))
        ctx.stroke(Path(s), with: .color(.white), lineWidth: 1)
        // The corners: 3px white L-shapes (24px arms, or the width if smaller).
        let arm = min(s.width, 24)
        for (x, y, top, left) in [(s.minX, s.minY, true, true), (s.maxX, s.minY, true, false), (s.minX, s.maxY, false, true), (s.maxX, s.maxY, false, false)] {
            var p = Path()
            let xs = left ? x - 2 : x + 2, xe = left ? x + arm : x - arm
            let ys = top ? y + arm : y - arm, ye = top ? y - 2 : y + 2
            p.move(to: CGPoint(x: xs, y: ys))
            p.addLine(to: CGPoint(x: xs, y: ye))
            p.addLine(to: CGPoint(x: xe, y: ye))
            ctx.stroke(p, with: .color(.white), lineWidth: 3)
        }
    }

    func drawSelection(_ o: MediaEditorObject, in ctx: GraphicsContext, zoom: CGFloat) {
        let c = o.corners.map { CGPoint(x: $0.x * zoom, y: $0.y * zoom) }
        var border = Path()
        border.addLines(c)
        border.closeSubpath()
        ctx.stroke(border, with: .color(.white), lineWidth: 1)
        let k = MediaEditorControls(o, zoom: zoom)
        // Rotate: a line to the 5px dot 40px above.
        var line = Path()
        line.move(to: k.rotate)
        line.addLine(to: k.rotateAnchor)
        ctx.stroke(line, with: .color(.white), lineWidth: 1)
        ctx.fill(Path(ellipseIn: CGRect(x: k.rotate.x - 5, y: k.rotate.y - 5, width: 10, height: 10)), with: .color(.white))
        // Delete: a black 12px circle with a white ×.
        ctx.fill(Path(ellipseIn: CGRect(x: k.delete.x - 12, y: k.delete.y - 12, width: 24, height: 24)), with: .color(.black))
        var x = Path()
        x.move(to: CGPoint(x: k.delete.x - 4, y: k.delete.y - 4)); x.addLine(to: CGPoint(x: k.delete.x + 4, y: k.delete.y + 4))
        x.move(to: CGPoint(x: k.delete.x + 4, y: k.delete.y - 4)); x.addLine(to: CGPoint(x: k.delete.x - 4, y: k.delete.y + 4))
        ctx.stroke(x, with: .color(.white), lineWidth: 1)
        // Resize: a white 12px circle with NW and SE arrows (#3b3b3b).
        let r = k.resize
        ctx.fill(Path(ellipseIn: CGRect(x: r.x - 12, y: r.y - 12, width: 24, height: 24)), with: .color(.white))
        var arrows = Path()
        for s in [1.0, -1.0] {
            arrows.move(to: CGPoint(x: r.x + s * 0.5, y: r.y + s * 0.5)); arrows.addLine(to: CGPoint(x: r.x + s * 5, y: r.y + s * 5))
            arrows.move(to: CGPoint(x: r.x + s * 5, y: r.y + s * 1)); arrows.addLine(to: CGPoint(x: r.x + s * 5, y: r.y + s * 5))
            arrows.addLine(to: CGPoint(x: r.x + s * 1, y: r.y + s * 5))
        }
        ctx.stroke(arrows, with: .color(Color(.sRGB, red: 0x3b / 255, green: 0x3b / 255, blue: 0x3b / 255)), lineWidth: 1)
        if let m = k.moreStyles { drawMoreStyles(at: m, in: ctx) }
    }

    /// `moreStyles`: 11px Inter on a black 4px-rounded box (1.5 × the text wide, twice its ascent tall).
    func drawMoreStyles(at p: CGPoint, in ctx: GraphicsContext) {
        let f = MediaEditorText.font(11, name: AxoFonts.interName(weight: 400))
        let w = MediaEditorText.width(moreStylesLabel, font: f), ascent = CTFontGetAscent(f)
        let boxH = ascent * 2, boxW = w * 1.5
        ctx.fill(Path(roundedRect: CGRect(x: p.x - boxW / 2, y: p.y, width: boxW, height: boxH), cornerRadius: 4), with: .color(.black))
        ctx.withCGContext { cg in
            let attr = NSAttributedString(string: moreStylesLabel, attributes: [.font: f as NSFont, .foregroundColor: NSColor.white])
            cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            cg.textPosition = CGPoint(x: p.x - w / 2, y: p.y + boxH / 1.5)
            CTLineDraw(CTLineCreateWithAttributedString(attr), cg)
        }
    }
}

/// Sticker bitmaps by object (their CGImage made once).
final class MediaEditorBitmapCache: Sendable {
    static let shared = MediaEditorBitmapCache()
    let cache = Mutex<[Int: MediaEditorBitmap]>([:])
    func bitmap(for id: Int, _ img: RGBAImage) -> MediaEditorBitmap {
        if let b = cache.withLock({ $0[id] }), b.image == img { return b }
        let b = MediaEditorBitmap(img)
        cache.withLock { $0[id] = b }
        return b
    }
}

enum SignalIconDrawing {
    /// Draws a generated icon's paths (their own colours) into `rect` of a GraphicsContext.
    static func draw(_ name: String, in rect: CGRect, ctx: GraphicsContext) {
        guard let data = SignalIconsTable.icons[name] else { return }
        let paths = SignalIconCache.paths(name, data)
        let t = CGAffineTransform(translationX: -data.viewBox.minX, y: -data.viewBox.minY)
            .concatenating(CGAffineTransform(scaleX: rect.width / data.viewBox.width, y: rect.height / data.viewBox.height))
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        for (raw, spec) in zip(paths, data.paths) {
            let p = raw.applying(spec.transform).applying(t)
            if spec.filled { ctx.fill(p, with: .color((spec.color ?? RGBA(0, 0, 0)).swiftUIColor), style: FillStyle(eoFill: spec.evenOdd)) }
            if let stroke = spec.stroke {
                ctx.stroke(p, with: .color(stroke.swiftUIColor), style: StrokeStyle(lineWidth: spec.strokeWidth * rect.width / data.viewBox.width, miterLimit: spec.miterLimit))
            }
        }
    }
}
