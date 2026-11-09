// A continuous rotation run by Core Animation (in the render server, as Chromium runs a CSS
// `animation: spin`), not by per-frame SwiftUI updates: a TimelineView(.animation) re-ran the
// whole window's view graph 60–120 times a second for as long as one "sending" icon was on
// screen (≈100% CPU with a stuck message).

import AppKit
import QuartzCore
import SwiftUI

extension View {
    /// Spins clockwise, one turn per `period` seconds.
    public func caSpin(period: Double) -> some View {
        CASpinHost(period: period, content: self)
    }
}

struct CASpinHost<Content: View>: NSViewRepresentable {
    let period: Double
    let content: Content

    func makeNSView(context: Context) -> CASpinView {
        CASpinView(rootView: AnyView(content), period: period)
    }

    func updateNSView(_ v: CASpinView, context: Context) {
        v.host.rootView = AnyView(content)
        v.period = period
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CASpinView, context: Context) -> CGSize? {
        let fitting = nsView.host.fittingSize
        return CGSize(width: proposal.width ?? fitting.width, height: proposal.height ?? fitting.height)
    }
}

final class CASpinView: NSView {
    let host: NSHostingView<AnyView>
    var period: Double {
        didSet { if period != oldValue { restart() } }
    }

    init(rootView: AnyView, period: Double) {
        host = NSHostingView(rootView: rootView)
        self.period = period
        super.init(frame: .zero)
        wantsLayer = true
        host.wantsLayer = true
        addSubview(host)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        host.frame = bounds
        guard let layer = host.layer else { return }
        // Rotate about the centre (AppKit layers default to the corner).
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        if layer.animation(forKey: "spin") == nil { restart() }
    }

    func restart() {
        guard let layer = host.layer else { return }
        layer.removeAnimation(forKey: "spin")
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = -2 * Double.pi      // clockwise on screen
        a.duration = max(0.05, period)
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        layer.add(a, forKey: "spin")
    }
}
