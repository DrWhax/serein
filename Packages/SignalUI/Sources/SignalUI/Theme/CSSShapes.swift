// CSS shapes: rounded rectangles whose corners follow `corner-shape: superellipse(K)`
// (CSS Borders 4: the corner curve |x|^n + |y|^n = 1 with n = 2^K; K = 1 is the ordinary
// quarter-circle) — upstream's `curved-*` utility is radius × 1.15 with superellipse(1.25).

import SwiftUI

public struct SuperellipseRect: InsettableShape, Sendable {
    public var radius: CGFloat
    public var k: CGFloat
    var insetAmount: CGFloat = 0

    public init(radius: CGFloat, k: CGFloat = 1.25) {
        self.radius = radius
        self.k = k
    }

    /// Upstream `curved-<n>`: border-radius n × 1.15, corner-shape superellipse(1.25).
    public static func curved(_ n: CGFloat) -> SuperellipseRect { SuperellipseRect(radius: n * 1.15) }

    public func path(in rect: CGRect) -> Path {
        let r0 = rect.insetBy(dx: insetAmount, dy: insetAmount)
        // CSS clamps radii so adjacent corners never overlap.
        let r = max(0, min(radius - insetAmount, r0.width / 2, r0.height / 2))
        let n = pow(2, k)
        let steps = 24
        var p = Path()
        // Corner centres and the quadrant each corner sweeps, clockwise from top-left.
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: r0.minX + r, y: r0.minY + r), -1, -1),
            (CGPoint(x: r0.maxX - r, y: r0.minY + r), 1, -1),
            (CGPoint(x: r0.maxX - r, y: r0.maxY - r), 1, 1),
            (CGPoint(x: r0.minX + r, y: r0.maxY - r), -1, 1),
        ]
        for (i, (c, sx, sy)) in corners.enumerated() {
            for j in 0...steps {
                // Each corner runs from its first edge to the next one (clockwise):
                // even corners start on the vertical edge, odd ones on the horizontal edge.
                let t = CGFloat(j) / CGFloat(steps) * .pi / 2
                let a = pow(cos(t), 2 / n), b = pow(sin(t), 2 / n)
                let (dx, dy) = i % 2 == 0 ? (a, b) : (b, a)
                let point = CGPoint(x: c.x + sx * r * dx, y: c.y + sy * r * dy)
                if i == 0 && j == 0 { p.move(to: point) } else { p.addLine(to: point) }
            }
        }
        p.closeSubpath()
        return p
    }

    public func inset(by amount: CGFloat) -> SuperellipseRect {
        var s = self
        s.insetAmount += amount
        return s
    }
}
