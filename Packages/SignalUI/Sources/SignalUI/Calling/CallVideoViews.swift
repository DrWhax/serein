// Call video on screen: remote participants' frames pulled from ringrtc on every display
// refresh (CanvasVideoRenderer's requestAnimationFrame loop), as RGBA into Metal; and the
// mirrored local camera preview from the frames CameraCapture produces.

import AppKit
import Metal
import QuartzCore
import SwiftUI
import Foundation

/// Something ringrtc frames can be pulled from: a 1:1 call, or one group-call participant.
@MainActor
public protocol CallVideoFrameSource: AnyObject {
    /// The newest frame (RGBA, rotated) if there is one since the last call.
    func receiveVideoFrame(into buffer: inout [UInt8], maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int)?
}

/// A remote participant's video.
public final class RemoteVideoLayerView: VideoLayerView {
    weak var source: (any CallVideoFrameSource)?
    var maxSize = CallVideoConstants.maxFrame
    var buffer: [UInt8] = []
    var link: CADisplayLink?
    /// The size of the last frame (`setSizer`), for the tile's aspect ratio.
    var onSize: ((Int, Int) -> Void)?
    var lastSize: (Int, Int)?

    func attach(_ s: (any CallVideoFrameSource)?, maxWidth: Int, maxHeight: Int) {
        source = s
        maxSize = (maxWidth, maxHeight)
        let needed = maxWidth * maxHeight * 4
        if buffer.count != needed { buffer = [UInt8](repeating: 0, count: needed) }
        if s != nil, link == nil {
            let l = displayLink(target: self, selector: #selector(tick))
            l.add(to: .main, forMode: .common)
            link = l
        } else if s == nil {
            stop()
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
        rgba_ = nil
        lastSize = nil
    }

    @objc func tick() {
        guard let source, let size = source.receiveVideoFrame(into: &buffer, maxWidth: maxSize.width, maxHeight: maxSize.height) else { return }
        let n = size.width * size.height * 4
        guard n > 0, n <= buffer.count else { return }
        show(rgba: RGBAFrame(width: size.width, height: size.height, pixels: Array(buffer[0..<n])))
        if lastSize.map({ $0 != (size.width, size.height) }) ?? true {
            lastSize = (size.width, size.height)
            onSize?(size.width, size.height)
        }
    }
}

/// Remote video in static rendering (snapshots, previews): one frame pulled from the source
/// and drawn as an image, since a Metal layer is not captured by ImageRenderer.
struct StaticRemoteVideo: View {
    let source: any CallVideoFrameSource
    let fit: VideoRenderer.Fit
    let maxWidth: Int, maxHeight: Int

    var body: some View {
        var buffer = [UInt8](repeating: 0, count: maxWidth * maxHeight * 4)
        if let s = source.receiveVideoFrame(into: &buffer, maxWidth: maxWidth, maxHeight: maxHeight), s.width > 0, s.height > 0 {
            let n = s.width * s.height * 4
            PixelImage(RGBAImage(width: s.width, height: s.height, pixels: Data(buffer[0..<n])), fit: fit == .cover ? .cover : .contain)
        }
    }
}

public struct RemoteVideoStack: View {
    let source: (any CallVideoFrameSource)?
    let fit: VideoRenderer.Fit
    let onSize: ((Int, Int) -> Void)?
    @Environment(\.axoStaticRendering) var staticRendering

    public init(source: (any CallVideoFrameSource)?, fit: VideoRenderer.Fit = .cover, onSize: ((Int, Int) -> Void)? = nil) {
        self.source = source
        self.fit = fit
        self.onSize = onSize
    }

    public var body: some View {
        if staticRendering {
            if let source { StaticRemoteVideo(source: source, fit: fit, maxWidth: 640, maxHeight: 480) }
        } else {
            RemoteVideoView(source: source, fit: fit, onSize: onSize)
        }
    }
}

public struct RemoteVideoView: NSViewRepresentable {
    let source: (any CallVideoFrameSource)?
    let fit: VideoRenderer.Fit
    let maxWidth: Int, maxHeight: Int
    let onSize: ((Int, Int) -> Void)?

    public init(source: (any CallVideoFrameSource)?, fit: VideoRenderer.Fit = .cover, maxWidth: Int = CallVideoConstants.maxFrame.width,
                maxHeight: Int = CallVideoConstants.maxFrame.height, onSize: ((Int, Int) -> Void)? = nil) {
        self.source = source
        self.fit = fit
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.onSize = onSize
    }

    public func makeNSView(context: Context) -> RemoteVideoLayerView {
        let v = RemoteVideoLayerView(frame: .zero)
        v.background = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        v.metalLayer.isOpaque = false
        updateNSView(v, context: context)
        return v
    }

    public func updateNSView(_ v: RemoteVideoLayerView, context: Context) {
        v.fit = fit
        v.onSize = onSize
        if v.source !== source || v.maxSize != (maxWidth, maxHeight) { v.attach(source, maxWidth: maxWidth, maxHeight: maxHeight) }
    }

    public static func dismantleNSView(_ v: RemoteVideoLayerView, coordinator: ()) { v.stop() }
}

/// The local camera's frames for the preview (fed from CameraCapture's callback).
@MainActor
public final class LocalVideoModel {
    public private(set) var current: VideoPlanes?
    var onFrame: ((VideoPlanes?) -> Void)?
    public init() {}

    public func present(_ frame: CapturedFrame) {
        let p = frame.planes
        current = p
        onFrame?(p)
    }

    public func clear() {
        current = nil
        onFrame?(nil)
    }
}

/// The local preview: mirrored, as the user sees themselves in upstream.
public struct LocalVideoView: NSViewRepresentable {
    let model: LocalVideoModel
    let fit: VideoRenderer.Fit

    public init(model: LocalVideoModel, fit: VideoRenderer.Fit = .cover) {
        self.model = model
        self.fit = fit
    }

    public func makeNSView(context: Context) -> VideoLayerView {
        let v = VideoLayerView(frame: .zero)
        v.mirrored = true
        updateNSView(v, context: context)
        return v
    }

    public func updateNSView(_ v: VideoLayerView, context: Context) {
        v.fit = fit
        model.onFrame = { [weak v] f in v?.show(f) }
        v.show(model.current)
    }

    public static func dismantleNSView(_ v: VideoLayerView, coordinator: ()) { v.frame_ = nil }
}
