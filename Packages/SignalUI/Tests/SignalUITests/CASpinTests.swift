// `caSpin` turns its content in place: the rotating layer stays anchored at its centre, at the
// centre of the view, through moves and resizes. (An earlier version rotated an NSHostingView's
// backing layer, whose anchor AppKit puts back at the corner, so the icon circled its corner.)

import AppKit
import SwiftUI
import Testing
@testable import SignalUI

@MainActor @Suite struct CASpinTests {
    func centre(of l: CALayer) -> CGPoint {
        // Where the layer's own centre ends up in its superlayer, with its transform applied.
        let mid = CGPoint(x: l.bounds.midX, y: l.bounds.midY)
        return l.convert(mid, to: l.superlayer)
    }

    @Test func turnsInPlaceThroughMovesAndResizes() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView = container
        let v = CASpinView(period: 1)
        v.content = AnyView(Rectangle().fill(Color.red))
        container.addSubview(v)
        for frame in [NSRect(x: 10, y: 20, width: 24, height: 24), NSRect(x: 80, y: 5, width: 56, height: 56), NSRect(x: 3, y: 90, width: 12, height: 18)] {
            v.frame = frame
            v.layoutSubtreeIfNeeded()
            v.layout()
            #expect(v.spin.anchorPoint == CGPoint(x: 0.5, y: 0.5))
            #expect(v.spin.bounds.size == frame.size)
            #expect(v.spin.position == CGPoint(x: frame.width / 2, y: frame.height / 2))
            #expect(v.spin.contents != nil, "nothing drawn")
            #expect(v.spin.animation(forKey: "spin") != nil, "not spinning")
            // Any angle of the turn keeps the centre where it is.
            for angle in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 3) {
                v.spin.setAffineTransform(CGAffineTransform(rotationAngle: angle))
                let c = centre(of: v.spin)
                #expect(abs(c.x - frame.width / 2) < 0.001 && abs(c.y - frame.height / 2) < 0.001, "centre moved at \(angle)")
            }
            v.spin.setAffineTransform(.identity)
        }
    }

    @Test func redrawsWhenTheContentChanges() {
        let v = CASpinView(period: 1)
        v.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        v.content = AnyView(Rectangle().fill(Color.red))
        v.layout()
        let first = v.spin.contents as AnyObject?
        v.content = AnyView(Circle().fill(Color.blue))
        v.layout()
        #expect(first != nil && (v.spin.contents as AnyObject?) !== first)
    }
}
