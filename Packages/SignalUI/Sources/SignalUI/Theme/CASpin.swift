// A continuous rotation run by Core Animation (in the render server, as Chromium runs a CSS
// `animation: spin`), not by per-frame SwiftUI updates: a TimelineView(.animation) re-ran the
// whole window's view graph 60–120 times a second for as long as one "sending" icon was on
// screen (≈100% CPU with a stuck message).
//
// The content is drawn into a layer this view owns and rotated about that layer's centre. An
// earlier version rotated the backing layer of an NSHostingView instead; AppKit owns the
// geometry of a view's backing layer and puts its anchor back at the corner whenever it updates
// the frame, so the icon swung in circles around its corner instead of turning in place.

import AppKit
import QuartzCore
import SwiftUI

extension View {
    /// Spins clockwise in place, one turn per `period` seconds.
    public func caSpin(period: Double) -> some View {
        CASpinHost(period: period, content: self)
    }
}

struct CASpinHost<Content: View>: NSViewRepresentable {
    let period: Double
    let content: Content

    func makeNSView(context: Context) -> CASpinView { CASpinView(period: period) }

    func updateNSView(_ v: CASpinView, context: Context) {
        v.period = period
        // The drawing happens outside this hierarchy: hand it what the content reads.
        v.content = AnyView(content
            .environment(\.colorScheme, context.environment.colorScheme)
            .environment(\.layoutDirection, context.environment.layoutDirection))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CASpinView, context: Context) -> CGSize? {
        let ideal = nsView.idealSize
        return CGSize(width: proposal.width ?? ideal.width, height: proposal.height ?? ideal.height)
    }
}

final class CASpinView: NSView {
    /// The rotating layer: a sublayer of the layer this view hosts, so AppKit never touches it.
    let spin = CALayer()
    var period: Double {
        didSet { if period != oldValue { restart() } }
    }
    var content = AnyView(EmptyView()) {
        didSet {
            measure.rootView = content
            needsRender = true
            needsLayout = true
        }
    }
    /// Only measures the content (never on screen).
    let measure = NSHostingView(rootView: AnyView(EmptyView()))
    private var needsRender = true
    private var renderedSize = CGSize.zero
    private var renderedScale: CGFloat = 0

    init(period: Double) {
        self.period = period
        super.init(frame: .zero)
        layer = CALayer()       // layer-hosting: the layer tree below is ours
        wantsLayer = true
        spin.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        spin.contentsGravity = .resize
        layer?.addSublayer(spin)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var idealSize: CGSize { measure.fittingSize }

    /// Device pixels per point where the view is (2 before it is on a screen).
    var scale: CGFloat {
        let s = convertToBacking(NSSize(width: 1, height: 1)).width
        return s > 0 ? s : 2
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.frame = bounds
        spin.bounds = CGRect(origin: .zero, size: bounds.size)
        spin.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        if needsRender || renderedSize != bounds.size || renderedScale != scale { render() }
        if spin.animation(forKey: "spin") == nil { restart() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Layers can drop their animations when the view leaves a window; the scale may differ.
        needsLayout = true
    }

    /// Decorative: clicks go to whatever is underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func render() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let renderer = ImageRenderer(content: content.frame(width: bounds.width, height: bounds.height))
        renderer.scale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spin.contents = renderer.cgImage
        spin.contentsScale = scale
        CATransaction.commit()
        renderedSize = bounds.size
        renderedScale = scale
        needsRender = false
    }

    func restart() {
        spin.removeAnimation(forKey: "spin")
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = -2 * Double.pi      // clockwise on screen (the hosted layer is not flipped)
        a.duration = max(0.05, period)
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        spin.add(a, forKey: "spin")
    }
}
