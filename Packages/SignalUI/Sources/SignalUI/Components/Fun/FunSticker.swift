// Port of ts/components/fun/FunSticker.dom.tsx + base/FunImage.dom.tsx (+ FunSticker.scss):
// a sticker image at its natural size (CSS width/height auto, at most the container's), 4px
// corners. Animated stickers play unless reduced motion is on; then the first frame shows
// until hover or focus (the intent), or always play with `ignoreReducedMotion`.

import SwiftUI

public struct FunSticker: View {
    /// The first frame (shown under reduced motion) and, for animated stickers, the frames to
    /// play with their durations.
    let still: RGBAImage
    let frames: [(image: RGBAImage, duration: TimeInterval)]
    let ignoreReducedMotion: Bool
    let accessibilityLabel: String?
    @State private var intent = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.axoStaticRendering) var staticRendering

    public init(still: RGBAImage, frames: [(image: RGBAImage, duration: TimeInterval)] = [], ignoreReducedMotion: Bool = false,
                accessibilityLabel: String? = nil) {
        self.still = still
        self.frames = frames
        self.ignoreReducedMotion = ignoreReducedMotion
        self.accessibilityLabel = accessibilityLabel
    }

    var plays: Bool { !frames.isEmpty && (ignoreReducedMotion || !reduceMotion || intent) && !staticRendering }

    public var body: some View {
        Group {
            if plays {
                TimelineView(.animation) { ctx in PixelImage(frame(at: ctx.date), fit: .fill) }
            } else {
                PixelImage(still, fit: .fill)
            }
        }
        .frame(width: CGFloat(still.width) / still.scale, height: CGFloat(still.height) / still.scale)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onHover { intent = $0 }
        .accessibilityLabel(accessibilityLabel ?? "")
        .accessibilityAddTraits(.isImage)
    }

    func frame(at date: Date) -> RGBAImage {
        let total = frames.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return frames[0].image }
        var t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: total)
        for f in frames {
            if t < f.duration { return f.image }
            t -= f.duration
        }
        return frames[frames.count - 1].image
    }
}
