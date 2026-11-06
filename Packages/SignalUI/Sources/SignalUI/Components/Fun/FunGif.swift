// Port of ts/components/fun/FunGif.dom.tsx (+ stylesheets/components/fun/FunGif.scss): GIFs
// (Giphy MP4 renditions) in the Fun picker and the GIF send preview.
// - FunGif: the looping video, rounded 8px, paused under reduced motion unless hovered or
//   focused (the intent), or always playing with `ignoreReducedMotion`.
// - FunGifPreview: sized to the GIF's aspect ratio within the available width and
//   `maxHeight`, over a fill-primary backdrop that shows a spinner while loading (from the
//   next tick) and an error triangle when it failed.
//
// With a `player` the video plays (VideoView; frames decoded by the media service); without
// one, or until its first frame, `frame` (the poster) shows.

import SwiftUI

public struct FunGif: View {
    let frame: RGBAImage?
    let width: CGFloat
    let height: CGFloat
    let accessibilityLabel: String?
    let player: VideoPlaybackEngine?
    let ignoreReducedMotion: Bool
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var hovered = false
    @FocusState private var focused: Bool

    public init(frame: RGBAImage?, width: CGFloat, height: CGFloat, accessibilityLabel: String? = nil, player: VideoPlaybackEngine? = nil,
                ignoreReducedMotion: Bool = false) {
        self.frame = frame
        self.width = width
        self.height = height
        self.accessibilityLabel = accessibilityLabel
        self.player = player
        self.ignoreReducedMotion = ignoreReducedMotion
    }

    /// `!reducedMotion || intent` (hover or focus), or always with `ignoreReducedMotion`.
    var shouldPlay: Bool { ignoreReducedMotion || !reduceMotion || hovered || focused }

    public var body: some View {
        Group {
            if let player {
                FunGifVideo(player: player, poster: frame, shouldPlay: shouldPlay)
            } else if let frame { PixelImage(frame, fit: .fill) } else { Color.clear }
        }
        .onHover { hovered = $0 }
        .focused($focused)
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
    let player: VideoPlaybackEngine?
    @State private var spinner = false
    @Environment(\.axoStaticRendering) var staticRendering

    public init(frame: RGBAImage?, state: FunLoadingState, width: CGFloat, height: CGFloat, maxHeight: CGFloat, playbackError: Bool = false,
                player: VideoPlaybackEngine? = nil) {
        self.player = player
        self.frame = frame
        self.state = state
        self.width = width
        self.height = height
        self.maxHeight = maxHeight
        self.playbackError = playbackError
    }

    var hasError: Bool { state == .loadFailed || playbackError || player?.lastError != nil }

    public var body: some View {
        // __Sizer: an svg of the GIF's size, max-width 100%, max-height `maxHeight`.
        FunGifSizer(width: width, height: height, maxHeight: maxHeight) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(AxoColor.fillPrimary)
                if (spinner || staticRendering) && !hasError && frame == nil && player?.currentFrame == nil {
                    SpinnerV2(size: 36, strokeWidth: 2)
                }
                if hasError {
                    SignalIcon("v3/error/error-triangle", size: 36, color: .labelSecondary, mask: true)
                }
                if let player {
                    FunGifVideo(player: player, poster: frame, shouldPlay: true).clipShape(RoundedRectangle(cornerRadius: 8))
                } else if let frame {
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

/// `<video loop muted autoPlay>`: the player's frames stretched to the box (its aspect ratio is
/// the GIF's), over the poster (seen until the first frame).
struct FunGifVideo: View {
    let player: VideoPlaybackEngine
    let poster: RGBAImage?
    let shouldPlay: Bool
    var body: some View {
        ZStack {
            if let poster { PixelImage(poster, fit: .fill) }
            VideoView(engine: player, fit: .cover, background: .clear)
        }
        .task(id: ObjectIdentifier(player)) { player.isLooping = true }
        .onChange(of: shouldPlay, initial: true) { _, play in Task { await player.match(play) } }
        .onDisappear { player.pause() }
    }
}
