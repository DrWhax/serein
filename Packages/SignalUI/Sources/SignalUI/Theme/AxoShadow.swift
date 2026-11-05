// CSS box-shadow lists from the Axo theme (shadow-elevation-*, base-shadow-outline),
// per theme. Each layer becomes: a spread-only ring → a stroke just outside (or, inset,
// just inside) the shape; a blurred layer → a SwiftUI drop shadow (CSS blur radius B
// corresponds to a Gaussian σ = B/2, which is SwiftUI's `radius`).

import SwiftUI

public struct AxoShadowLayer: Sendable, Hashable {
    public var inset: Bool
    public var x: CGFloat, y: CGFloat, blur: CGFloat, spread: CGFloat
    public var color: RGBA
    public init(inset: Bool, x: CGFloat, y: CGFloat, blur: CGFloat, spread: CGFloat, color: RGBA) {
        self.inset = inset
        self.x = x
        self.y = y
        self.blur = blur
        self.spread = spread
        self.color = color
    }
}

public struct AxoShadow: Sendable, Hashable {
    public var light: [AxoShadowLayer]
    public var dark: [AxoShadowLayer]
    public init(light: [AxoShadowLayer], dark: [AxoShadowLayer]) {
        self.light = light
        self.dark = dark
    }
    public func layers(_ scheme: ColorScheme) -> [AxoShadowLayer] { scheme == .dark ? dark : light }
}

/// Paints a CSS box-shadow list the way browsers do: layer i is drawn below layer i-1;
/// an outer layer is the shape grown by `spread`, offset and blurred (Gaussian σ = blur/2),
/// visible only outside the border box; an inset layer is everything outside the shape
/// shrunk by `spread`, offset and blurred, visible only inside it.
struct CSSBoxShadowModifier<S: InsettableShape>: ViewModifier {
    let layers: [AxoShadowLayer]
    let shape: S

    var outerExtent: CGFloat {
        layers.filter { !$0.inset }.map { $0.blur * 1.5 + $0.spread + max(abs($0.x), abs($0.y)) + 1 }.max() ?? 0
    }

    func body(content: Content) -> some View {
        let outer = layers.filter { !$0.inset && $0.color.a > 0 }
        let inner = layers.filter { $0.inset && $0.color.a > 0 }
        let e = outerExtent
        content
            .background {
                if !outer.isEmpty {
                    GeometryReader { geo in
                        let snapped = CSSPixelSnap.box(geo.frame(in: .global), size: geo.size)
                        Canvas { ctx, size in
                            let box = snapped.offsetBy(dx: e, dy: e)
                            var clip = Path(CGRect(origin: .zero, size: size))
                            clip.addPath(shape.path(in: box))
                            ctx.clip(to: clip, style: FillStyle(eoFill: true))
                            for l in outer.reversed() {
                                var layer = ctx
                                if l.blur > 0 { layer.addFilter(.blur(radius: l.blur / 2)) }
                                let grown = shape.inset(by: -l.spread).path(in: box).offsetBy(dx: l.x, dy: l.y)
                                layer.fill(grown, with: .color(l.color.color))
                            }
                        }
                        .padding(-e)
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                if !inner.isEmpty {
                    GeometryReader { geo in
                        let box = CSSPixelSnap.box(geo.frame(in: .global), size: geo.size)
                        Canvas { ctx, size in
                            ctx.clip(to: shape.path(in: box))
                            for l in inner.reversed() {
                                var layer = ctx
                                if l.blur > 0 { layer.addFilter(.blur(radius: l.blur / 2)) }
                                var outside = Path(box.insetBy(dx: -(l.blur * 3 + abs(l.x) + abs(l.y) + 10), dy: -(l.blur * 3 + abs(l.x) + abs(l.y) + 10)))
                                outside.addPath(shape.inset(by: l.spread).path(in: box).offsetBy(dx: l.x, dy: l.y))
                                layer.fill(outside, with: .color(l.color.color), style: FillStyle(eoFill: true))
                            }
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}

/// Blink (layout in CSS pixels here) paints a box's background, borders and shadows in its
/// border box pixel-snapped: each edge, in page coordinates, rounded half up to a whole CSS
/// pixel. A view at a fractional position paints its box a little off its frame.
enum CSSPixelSnap {
    /// The snapped box in the view's own coordinates, given its frame in page coordinates
    /// and its own size. A rotated or scaled view (its page frame is a bounding box) paints
    /// unsnapped, as Blink does under a transform.
    static func box(_ frame: CGRect, size: CGSize) -> CGRect {
        guard abs(frame.width - size.width) < 0.01, abs(frame.height - size.height) < 0.01 else { return CGRect(origin: .zero, size: size) }
        func r(_ v: CGFloat) -> CGFloat { (v + 0.5).rounded(.down) }
        let x0 = r(frame.minX), y0 = r(frame.minY), x1 = r(frame.maxX), y1 = r(frame.maxY)
        return CGRect(x: x0 - frame.minX, y: y0 - frame.minY, width: x1 - x0, height: y1 - y0)
    }
}

/// A shape filled in the view's pixel-snapped border box (a CSS background).
struct SnappedShapeFill<S: Shape>: View {
    let shape: S
    let color: AxoColor
    var body: some View {
        GeometryReader { geo in
            let box = CSSPixelSnap.box(geo.frame(in: .global), size: geo.size)
            shape.fill(color).frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
        }
    }
}

struct AxoShadowModifier<S: InsettableShape>: ViewModifier {
    let shadow: AxoShadow
    let shape: S
    @Environment(\.colorScheme) var scheme

    func body(content: Content) -> some View {
        content.modifier(CSSBoxShadowModifier(layers: shadow.layers(scheme), shape: shape))
    }
}

extension View {
    public func axoShadow(_ shadow: AxoShadow, in shape: some InsettableShape) -> some View {
        modifier(AxoShadowModifier(shadow: shadow, shape: shape))
    }

    /// A literal CSS box-shadow list (same in both themes).
    public func cssBoxShadow(_ layers: [AxoShadowLayer], in shape: some InsettableShape) -> some View {
        modifier(CSSBoxShadowModifier(layers: layers, shape: shape))
    }
}
