// Shows a VideoPlaybackEngine's frames: an NSView backed by a CAMetalLayer, drawn by the
// shared VideoRenderer (contained, rotated, letterboxed in `background`) whenever the
// engine presents a frame or the view changes size.

import AppKit
import Metal
import QuartzCore
import SwiftUI

extension VideoRenderer {
    /// One renderer (device, queue, compiled pipelines) for every video view.
    public static let shared: VideoRenderer? = VideoRenderer()
}

public class VideoLayerView: NSView {
    let metalLayer = CAMetalLayer()
    var frame_: VideoPlanes?
    /// Remote call video (shown instead of `frame_` when set).
    var rgba_: RGBAFrame?
    var mirrored = false
    var rotation = 0
    var fit = VideoRenderer.Fit.contain
    var background = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        if let r = VideoRenderer.shared { metalLayer.device = r.device }
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        // The frames are converted in sRGB-encoded values, as Chromium composites video.
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer = metalLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var wantsUpdateLayer: Bool { true }

    public override func layout() {
        super.layout()
        resizeDrawable()
        redraw()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resizeDrawable()
        redraw()
    }

    func resizeDrawable() {
        // (NSView.window is unowned(unsafe); the backing conversion gives the scale without it.)
        let scale = max(1, convertToBacking(NSSize(width: 1, height: 1)).width)
        metalLayer.contentsScale = scale
        let px = convertToBacking(bounds.size)
        let size = CGSize(width: max(1, px.width.rounded()), height: max(1, px.height.rounded()))
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }

    func show(_ f: VideoPlanes?) {
        frame_ = f
        redraw()
    }

    func show(rgba f: RGBAFrame?) {
        rgba_ = f
        redraw()
    }

    func redraw() {
        guard bounds.width > 0, bounds.height > 0, let r = VideoRenderer.shared else { return }
        if let f = rgba_ {
            guard let drawable = metalLayer.nextDrawable(),
                  let cb = r.draw(f, into: drawable.texture, fit: fit, mirrored: mirrored, background: background) else { return }
            cb.present(drawable)
            cb.commit()
        } else if let f = frame_ {
            r.present(f, rotation: rotation, in: metalLayer, fit: fit, mirrored: mirrored, background: background)
        }
    }
}

extension VideoRenderer {
    public func present(_ frame: VideoPlanes, rotation: Int, in layer: CAMetalLayer, fit: Fit = .contain, mirrored: Bool = false, background: MTLClearColor) {
        guard let drawable = layer.nextDrawable(),
              let cb = draw(frame, rotation: rotation, into: drawable.texture, fit: fit, mirrored: mirrored, background: background) else { return }
        cb.present(drawable)
        cb.commit()
    }
}

/// The engine's video, contained in (or covering) the view's bounds.
public struct VideoView: NSViewRepresentable {
    let engine: VideoPlaybackEngine
    let fit: VideoRenderer.Fit
    let background: Color

    public init(engine: VideoPlaybackEngine, fit: VideoRenderer.Fit = .contain, background: Color = .black) {
        self.engine = engine
        self.fit = fit
        self.background = background
    }

    public func makeNSView(context: Context) -> VideoLayerView {
        let v = VideoLayerView(frame: .zero)
        update(v)
        return v
    }

    public func updateNSView(_ v: VideoLayerView, context: Context) { update(v) }

    func update(_ v: VideoLayerView) {
        let c = NSColor(background).usingColorSpace(.sRGB) ?? .black
        v.background = MTLClearColor(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent), alpha: Double(c.alphaComponent))
        v.metalLayer.isOpaque = c.alphaComponent >= 1
        v.rotation = engine.rotation
        v.fit = fit
        engine.onFrame = { [weak v] f in v?.show(f) }
        v.show(engine.currentFrame)
    }

    public static func dismantleNSView(_ v: VideoLayerView, coordinator: ()) {
        v.frame_ = nil
    }
}
