// Upstream's bundled SVG icons (images/icons/**, generated into SignalIcons.generated.swift
// by Tools/gen-icons.mjs), drawn as SwiftUI paths. Black paths are templates filled with
// the given colour (the SCSS `color-svg` mask); coloured paths keep their own fill.

import SwiftUI
import Synchronization

public struct SignalIconPath: Sendable {
    public var d: String
    public var evenOdd: Bool
    /// nil: template (caller's colour)
    public var color: RGBA?
    /// `fill="none"`: stroke only.
    public var filled = true
    /// An SVG stroke (the avatar icons), in viewBox units.
    public var stroke: RGBA? = nil
    public var strokeWidth: CGFloat = 1
    public var miterLimit: CGFloat = 4
    /// An element `transform` (illustrations' rotated rects), in viewBox units.
    public var transform: CGAffineTransform = .identity
}

public struct SignalIconData: Sendable {
    public var width: CGFloat
    public var height: CGFloat
    public var viewBox: CGRect
    public var paths: [SignalIconPath]
}

enum SignalIconCache {
    static let parsed = Mutex<[String: [Path]]>([:])
    static func paths(_ name: String, _ data: SignalIconData) -> [Path] {
        if let p = parsed.withLock({ $0[name] }) { return p }
        let p = data.paths.map { SVGPathData.parse($0.d) ?? Path() }
        parsed.withLock { $0[name] = p }
        return p
    }
}

/// `images/icons/<name>.svg` (e.g. "v3/chat/chat"), sized `size` (default: its own size).
public struct SignalIcon: View {
    let name: String
    let size: CGSize?
    let color: AxoColor?
    /// Drawn as a CSS mask (`mask-image`): every path takes the tint, whatever its own fill.
    let mask: Bool
    @Environment(\.cssTextColor) var inherited

    public init(_ name: String, size: CGFloat? = nil, color: AxoColor? = nil, mask: Bool = false) {
        self.name = name
        self.size = size.map { CGSize(width: $0, height: $0) }
        self.color = color
        self.mask = mask
    }

    public static func exists(_ name: String) -> Bool { SignalIconsTable.icons[name] != nil }

    public var body: some View {
        if let data = SignalIconsTable.icons[name] {
            let paths = SignalIconCache.paths(name, data)
            let target = size ?? CGSize(width: data.width, height: data.height)
            let tint = color ?? inherited
            Canvas { ctx, sz in
                let sx = sz.width / data.viewBox.width, sy = sz.height / data.viewBox.height
                let t = CGAffineTransform(translationX: -data.viewBox.minX, y: -data.viewBox.minY).concatenating(CGAffineTransform(scaleX: sx, y: sy))
                for (raw, spec) in zip(paths, data.paths) {
                    let p = raw.applying(spec.transform)
                    let fill: AxoColor = mask ? tint : spec.color.map { AxoColor($0) } ?? tint
                    if spec.filled { ctx.fill(p.applying(t), with: .style(fill), style: FillStyle(eoFill: spec.evenOdd)) }
                    if let stroke = spec.stroke {
                        ctx.stroke(p.applying(t), with: .style(mask ? tint : AxoColor(stroke)),
                                   style: StrokeStyle(lineWidth: spec.strokeWidth * sx, miterLimit: spec.miterLimit))
                    }
                }
            }
            .frame(width: target.width, height: target.height)
            .accessibilityHidden(true)
        } else {
            Color.clear.frame(width: size?.width ?? 0, height: size?.height ?? 0)
        }
    }
}
