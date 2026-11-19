// The Lightbox image's zoom (ts/components/Lightbox.dom.tsx `zoomed`, `maxZoom`, the pan that
// follows the pointer): a click on the image zooms in to its full resolution (at least 2×)
// and a second click zooms back out; zoomed, the image pans with the pointer so its edges
// come into view at the window's edges. A trackpad pinch zooms in steps between, and ⌘+ /
// ⌘- / ⌘0 zoom in, out and back to fit. A click beside the image closes the lightbox, as
// before.

import SwiftUI

struct LightboxZoomableImage: View {
    let image: RGBAImage
    let label: String
    let close: () -> Void
    /// 1: fitted to the object area (the Lightbox's, for its ⌘+ / ⌘- / ⌘0).
    @Binding var zoom: CGFloat
    /// The zoom when a pinch began.
    @State private var pinchBase: CGFloat?
    /// The pointer over the object area (pans the zoomed image).
    @State private var pointer: CGPoint?
    @Environment(\.displayScale) var displayScale
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    init(image: RGBAImage, label: String, close: @escaping () -> Void, zoom: Binding<CGFloat>) {
        self.image = image
        self.label = label
        self.close = close
        self._zoom = zoom
    }

    static let horizontalMargin: CGFloat = 40
    static let maxZoomLimit: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let area = geo.size
            let fitted = Self.fittedRect(image, in: area)
            let max = maxZoom(fitted)
            PixelImage(image, fit: .contain, snapsOutward: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, Self.horizontalMargin)
                .scaleEffect(zoom)
                .offset(Self.pan(zoom: zoom, fitted: fitted, area: area, pointer: pointer))
                .frame(width: area.width, height: area.height)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { e in
                    if zoom > 1 {
                        setZoom(1)
                    } else if fitted.contains(e.location) {
                        pointer = e.location
                        setZoom(max)
                    } else {
                        close()
                    }
                })
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { v in
                        let base = pinchBase ?? zoom
                        pinchBase = base
                        zoom = Swift.min(Swift.max(base * v.magnification, 1), max)
                    }
                    .onEnded { _ in pinchBase = nil })
                .onContinuousHover { phase in
                    if case .active(let p) = phase { pointer = p }
                }
                .pointerStyle(zoom > 1 ? .zoomOut : (pointer.map(fitted.contains) == true ? .zoomIn : nil))
                .clipped()
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isImage)
    }

    func setZoom(_ z: CGFloat) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { zoom = z }
    }

    /// ⌘+ / ⌘- / ⌘0: twice, half, or back to fitted.
    static func keyZoom(_ zoom: CGFloat, _ key: String) -> CGFloat {
        switch key {
        case "0": 1
        case "-": Swift.max(1, zoom / 2)
        default: Swift.min(maxZoomLimit, zoom * 2)
        }
    }

    /// Full resolution (one image pixel per device pixel), at least 2×, at most 8×.
    func maxZoom(_ fitted: CGRect) -> CGFloat {
        guard fitted.width > 0 else { return 1 }
        let native = CGFloat(image.width) / displayScale / fitted.width
        return Swift.min(Swift.max(native, 2), Self.maxZoomLimit)
    }

    /// Where `.contain` draws the image: inside the 40px side margins, centred.
    static func fittedRect(_ image: RGBAImage, in area: CGSize) -> CGRect {
        let box = CGSize(width: Swift.max(0, area.width - 2 * horizontalMargin), height: area.height)
        guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let k = Swift.min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * k, height: CGFloat(image.height) * k)
        return CGRect(x: (area.width - size.width) / 2, y: (area.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// The offset of the zoomed image: the pointer's place in the area maps to the same place
    /// in the image (left edge shows the left edge), along each axis where it overflows.
    static func pan(zoom: CGFloat, fitted: CGRect, area: CGSize, pointer: CGPoint?) -> CGSize {
        guard zoom > 1, let p = pointer, area.width > 0, area.height > 0 else { return .zero }
        let overflowX = Swift.max(0, (fitted.width * zoom - area.width) / 2)
        let overflowY = Swift.max(0, (fitted.height * zoom - area.height) / 2)
        let fx = Swift.min(Swift.max(p.x / area.width, 0), 1) * 2 - 1
        let fy = Swift.min(Swift.max(p.y / area.height, 0), 1) * 2 - 1
        return CGSize(width: -fx * overflowX, height: -fy * overflowY)
    }
}
