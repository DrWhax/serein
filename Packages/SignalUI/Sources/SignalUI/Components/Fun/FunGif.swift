// Port of ts/components/fun/FunGif.dom.tsx (+ stylesheets/components/fun/FunGif.scss): GIFs
// (Giphy MP4 renditions) in the Fun picker and the GIF send preview.
// - FunGif: the looping video, rounded 8px, paused under reduced motion unless hovered or
//   focused (the intent), or always playing with `ignoreReducedMotion`.
// - FunGifPreview: sized to the GIF's aspect ratio within the available width and
//   `maxHeight`, over a fill-primary backdrop that shows a spinner while loading (from the
//   next tick) and an error triangle when it failed.
//
// Frames come decoded from the media service (H.264 in Swift, Phase 5); until then `frame`
// is the poster.

import SwiftUI

public struct FunGif: View {
    let frame: RGBAImage?
    let width: CGFloat
    let height: CGFloat
    let accessibilityLabel: String?
    public init(frame: RGBAImage?, width: CGFloat, height: CGFloat, accessibilityLabel: String? = nil) {
        self.frame = frame
        self.width = width
        self.height = height
        self.accessibilityLabel = accessibilityLabel
    }
    public var body: some View {
        Group {
            if let frame { PixelImage(frame, fit: .fill) } else { Color.clear }
        }
        .aspectRatio(width / max(height, 1), contentMode: .fit)
        .frame(maxWidth: width)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(accessibilityLabel ?? "")
    }
}

/// `LoadingState`
public enum FunLoadingState: Sendable { case loading, loaded, loadFailed }

public struct FunGifPreview: View {
    let frame: RGBAImage?
    let state: FunLoadingState
    let width: CGFloat
    let height: CGFloat
    let maxHeight: CGFloat
    let playbackError: Bool
    @State private var spinner = false
    @Environment(\.axoStaticRendering) var staticRendering

    public init(frame: RGBAImage?, state: FunLoadingState, width: CGFloat, height: CGFloat, maxHeight: CGFloat, playbackError: Bool = false) {
        self.frame = frame
        self.state = state
        self.width = width
        self.height = height
        self.maxHeight = maxHeight
        self.playbackError = playbackError
    }

    var hasError: Bool { state == .loadFailed || playbackError }

    public var body: some View {
        // __Sizer: an svg of the GIF's size, max-width 100%, max-height `maxHeight`.
        FunGifSizer(width: width, height: height, maxHeight: maxHeight) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(AxoColor.fillPrimary)
                if (spinner || staticRendering) && !hasError && frame == nil {
                    SpinnerV2(size: 36, strokeWidth: 2)
                }
                if hasError {
                    SignalIcon("v3/error/error-triangle", size: 36, color: .labelSecondary, mask: true)
                }
                if let frame {
                    PixelImage(frame, fit: .fill).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .task { spinner = true }     // setTimeout(…, 0)
    }
}

/// `.FunGifPreview__Sizer`: the GIF's box scaled down to the offered width and `maxHeight`
/// (keeping its ratio), placed at the leading edge of the offered width.
struct FunGifSizer: Layout {
    let width: CGFloat
    let height: CGFloat
    let maxHeight: CGFloat
    func box(_ available: CGFloat?) -> CGSize {
        let ratio = width / max(height, 1)
        let w = min(width, available ?? width, maxHeight * ratio)
        return CGSize(width: w, height: w / ratio)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let b = box(proposal.width)
        return CGSize(width: proposal.width ?? b.width, height: b.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let b = box(bounds.width)
        for s in subviews { s.place(at: bounds.origin, proposal: ProposedViewSize(b)) }
    }
}
