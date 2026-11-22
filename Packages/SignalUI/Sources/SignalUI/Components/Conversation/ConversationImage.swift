// Port of ts/components/conversation/Image.dom.tsx (stylesheets/_modules.scss .module-image),
// named ConversationImage so it does not shadow SwiftUI.Image: a visual attachment at a fixed
// size, cover-fitted, with its blurhash until it loads, the download / progress / play
// overlays, the caption mark, bottom and dark overlays, overlay text, the 1px inner border and
// per-corner curves.

import Blurhash
import SignalI18n
import SwiftUI

/// `CurveType`
public enum CurveType: CGFloat, Sendable {
    case none = 0, tiny = 4, small = 10, normal = 18
}

/// `computeBlurHashUrl`: a blurhash rendered at about 32×32 pixels in the attachment's aspect
/// ratio (width a multiple of 4, each side ≥ 4), as upstream draws it before scaling.
public enum BlurHashImage {
    static let pixelCount = 32.0 * 32.0
    static let minDimension = 4.0

    public static func size(intrinsicWidth: Int?, intrinsicHeight: Int?) -> (width: Int, height: Int) {
        let maxAspect = pixelCount / (minDimension * minDimension), minAspect = 1 / maxAspect
        let w0 = Double(intrinsicWidth ?? 1), h0 = Double(intrinsicHeight ?? 1)
        let invAspect = min(maxAspect, max(minAspect, (abs(h0) + 1e-23) / (abs(w0) + 1e-23)))
        var width = Int((pixelCount / (invAspect + 1e-23)).squareRoot().rounded())
        width = max(Int(minDimension), (width >> 2) << 2)
        let height = max(Int(minDimension), Int((Double(width) * invAspect).rounded()))
        return (width, height)
    }

    /// Decodes a trusted, constant blurhash (`defaultBlurHash`). Message blurhashes are decoded
    /// by the media service, which uses the same size.
    public static func trusted(_ hash: String, intrinsicWidth: Int?, intrinsicHeight: Int?) -> RGBAImage? {
        let (w, h) = size(intrinsicWidth: intrinsicWidth, intrinsicHeight: intrinsicHeight)
        guard let buffer = try? Blurhash.decode(hash, width: w, height: h) else { return nil }
        return RGBAImage(buffer)
    }

    /// `defaultBlurHash(theme)`
    public static func defaultHash(dark: Bool) -> String { dark ? "L05OQnoffQofoffQfQfQfQfQfQfQ" : "L1Q]+w-;fQ-;~qfQfQfQfQfQfQfQ" }
}

public struct ConversationImage: View {
    public struct Corners: Sendable, Hashable {
        public var topLeft: CurveType, topRight: CurveType, bottomLeft: CurveType, bottomRight: CurveType
        public init(topLeft: CurveType = .none, topRight: CurveType = .none, bottomLeft: CurveType = .none, bottomRight: CurveType = .none) {
            self.topLeft = topLeft
            self.topRight = topRight
            self.bottomLeft = bottomLeft
            self.bottomRight = bottomRight
        }
        public static func all(_ c: CurveType) -> Corners { Corners(topLeft: c, topRight: c, bottomLeft: c, bottomRight: c) }
        var radii: RectangleCornerRadii {
            RectangleCornerRadii(topLeading: topLeft.rawValue, bottomLeading: bottomLeft.rawValue, bottomTrailing: bottomRight.rawValue,
                                 topTrailing: topRight.rawValue)
        }
    }

    public struct Options: Sendable, Hashable {
        public var bottomOverlay = false
        public var closeButton = false
        public var darkOverlay = false
        public var noBackground = false
        public var noBorder = false
        public var overlayText: String?
        public var playIconOverlay = false
        public var caption: String?
        /// `isIncremental(attachment)` (incrementalMac + chunkSize: streamable video).
        public var incremental = false
        public init() {}
    }

    let attachment: MessageAttachment
    /// The loaded `url` image (nil: none, or it failed to load).
    let url: RGBAImage?
    /// The decoded blurhash (nil: the theme's default).
    let blurHash: RGBAImage?
    let width: CGFloat
    let height: CGFloat
    let cropWidth: CGFloat
    let cropHeight: CGFloat
    let corners: Corners
    let options: Options
    let startDownload: (() -> Void)?
    let cancelDownload: (() -> Void)?
    let showVisualAttachment: (() -> Void)?
    let onClickClose: (() -> Void)?
    let showMediaNoLongerAvailableToast: (() -> Void)?
    /// `theme`: the default blurhash's theme (stories pass light regardless of the page).
    let blurHashDark: Bool?
    @Environment(\.colorScheme) var scheme
    @Environment(\.i18n) var i18n

    public init(attachment: MessageAttachment, url: RGBAImage?, blurHash: RGBAImage? = nil, width: CGFloat, height: CGFloat,
                cropWidth: CGFloat = 0, cropHeight: CGFloat = 0, corners: Corners = Corners(), options: Options = Options(),
                blurHashDark: Bool? = nil, startDownload: (() -> Void)? = nil, cancelDownload: (() -> Void)? = nil,
                showVisualAttachment: (() -> Void)? = nil, onClickClose: (() -> Void)? = nil,
                showMediaNoLongerAvailableToast: (() -> Void)? = nil) {
        self.attachment = attachment
        self.url = url
        self.blurHash = blurHash
        self.width = width
        self.height = height
        self.cropWidth = cropWidth
        self.cropHeight = cropHeight
        self.corners = corners
        self.options = options
        self.blurHashDark = blurHashDark
        self.startDownload = startDownload
        self.cancelDownload = cancelDownload
        self.showVisualAttachment = showVisualAttachment
        self.onClickClose = onClickClose
        self.showMediaNoLongerAvailableToast = showMediaNoLongerAvailableToast
    }

    var resolvedBlurHash: RGBAImage? {
        blurHash ?? BlurHashImage.trusted(BlurHashImage.defaultHash(dark: blurHashDark ?? (scheme == .dark)),
                                          intrinsicWidth: attachment.width, intrinsicHeight: attachment.height)
    }

    static func circle(_ background: RGBA = LegacyColor.blackAlpha80) -> some View {
        Circle().fill(background.color).frame(width: 50, height: 50)
    }

    static func icon(_ name: String) -> some View { SignalIcon(name, size: 24, color: .labelPrimaryOncolor) }

    @Environment(\.inlineVideo) var inlineVideo

    public var body: some View {
        let shape = UnevenRoundedRectangle(cornerRadii: corners.radii)
        let o = options
        let path = attachment.isDownloaded
        let undownloadable = attachment.isPermanentlyUndownloadable
        ZStack {
            if !o.noBackground { shape.fill(AxoColor(light: LegacyColor.white, dark: LegacyColor.black)) }
            // ImageOrBlurhash: the image once loaded, else the blurhash (both object-fit: cover).
            // The img is not clipped to the curves (only a cropped image's overflow: hidden root
            // clips it); the background and border overlay are curved.
            if let shown = url ?? resolvedBlurHash {
                if cropWidth > 0 || cropHeight > 0 { PixelImage(shown, fit: .cover, snapsContentRect: true).clipShape(shape) } else { PixelImage(shown, fit: .cover, snapsContentRect: true) }
            }
            // A video playing in place (InlineVideo): its frames over the poster.
            if attachment.isVideo, let player = inlineVideo.player {
                VideoView(engine: player, fit: .cover).clipShape(shape)
            }
            if startDownload != nil {
                if undownloadable {
                    SwiftUI.Button { showMediaNoLongerAvailableToast?() } label: {
                        Self.circle(LegacyColor.blackAlpha40).overlay { Self.icon("v3/photo/photo-slash-compact") }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(i18n("icu:mediaNotAvailable"))
                } else if !path && !attachment.pending && !o.incremental {
                    SwiftUI.Button { startDownload?() } label: {
                        Rectangle().fill(Color.clear).contentShape(shape)
                            .overlay { Self.circle().overlay { Self.icon("v3/arrow/arrow-down") } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(i18n("icu:startDownload"))
                }
            }
            if !o.incremental, cancelDownload != nil, attachment.pending {
                // getSpinner
                SwiftUI.Button { cancelDownload?() } label: {
                    Self.circle().overlay {
                        Self.icon("v3/stop/stop-fill")
                        let value = attachment.size > 0 && (attachment.totalDownloaded ?? 0) > 0 ? Double(attachment.totalDownloaded ?? 0) : nil
                        SpinnerV2(value: value, min: 0, max: Double(attachment.size), marginRatio: 1, size: 44, strokeWidth: 2)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(i18n("icu:cancelDownload"))
            }
            if o.caption != nil, let img = BundledImage.named("caption-shadow") {
                PixelImage(img).frame(width: 24, height: 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding([.top, .leading], 6)
                    .accessibilityLabel(i18n("icu:imageCaptionIconAlt"))
            }
            if o.bottomOverlay {
                BottomOverlayGradient().frame(height: 48).frame(maxHeight: .infinity, alignment: .bottom)
            }
            if (path || o.incremental) && !undownloadable && o.playIconOverlay && inlineVideo.player?.isPlaying != true {
                if attachment.isVideo, path, let play = inlineVideo.play {
                    // Plays here (with sound); the rest of the image still opens the lightbox.
                    SwiftUI.Button(action: play) { Self.circle().overlay { Self.icon("v3/play/play-fill") } }
                        .buttonStyle(.plain)
                        .accessibilityLabel(i18n("icu:MessageAudio--play"))
                } else {
                    Self.circle().overlay { Self.icon("v3/play/play-fill") }
                }
            }
            if let text = o.overlayText, !text.isEmpty {
                CSSText(text, style: LegacyType.body1(), alignment: .center, color: AxoColor(LegacyColor.white))
                    .frame(maxWidth: .infinity)
            }
            if o.darkOverlay || !o.noBorder {
                ZStack {
                    if o.darkOverlay { shape.fill(LegacyColor.blackAlpha20.color) }
                    if !o.noBorder {
                        shape.strokeBorder(AxoColor(light: RGBA(0, 0, 0, 0.085), dark: LegacyColor.whiteAlpha20), lineWidth: 1)
                    }
                }
                .allowsHitTesting(false)
            }
            if o.closeButton {
                SwiftUI.Button { onClickClose?() } label: {
                    SignalIcon("v3/x/x-compact", size: 16, color: AxoColor(LegacyColor.white)).frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(i18n("icu:remove-attachment"))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding([.top, .trailing], 4)
            }
        }
        // The root is width − crop × height − crop; the img fills it (width/height 100%).
        .frame(width: width - cropWidth, height: height - cropHeight)
        .clipped()
        .contentShape(shape)
        .onTapGesture {
            // A video playing in place pauses on a click; otherwise the lightbox opens.
            if attachment.isVideo, let player = inlineVideo.player, player.isPlaying {
                player.pause()
            } else if attachment.isDownloaded {
                showVisualAttachment?()
            }
        }
        .accessibilityAddTraits(showVisualAttachment != nil ? .isButton : [])
        .accessibilityLabel(i18n("icu:imageOpenAlt"))
    }
}

/// `.module-image__bottom-overlay`: transparent to 40% black over 48px.
struct BottomOverlayGradient: View {
    static let stops: [(Double, Double)] = [
        (0, 0), (0.09, 0), (0.17, 0.02), (0.24, 0.05), (0.31, 0.08), (0.37, 0.12), (0.44, 0.16), (0.50, 0.2), (0.56, 0.24), (0.63, 0.28),
        (0.69, 0.32), (0.76, 0.35), (0.83, 0.38), (0.91, 0.4), (1, 0.4),
    ]
    var body: some View {
        LinearGradient(stops: Self.stops.map { Gradient.Stop(color: Color(.sRGB, red: 0, green: 0, blue: 0, opacity: $0.1), location: $0.0) },
                       startPoint: .top, endPoint: .bottom)
    }
}

/// Port of ts/components/ImageOrBlurhash.dom.tsx: the image, or (none, or it failed to load)
/// its blurhash rendered by `computeBlurHashUrl` at the intrinsic aspect, filling the frame.
public struct ImageOrBlurhash: View {
    let image: RGBAImage?
    let blurHash: RGBAImage?
    public init(image: RGBAImage?, blurHash: RGBAImage?) {
        self.image = image
        self.blurHash = blurHash
    }
    public var body: some View {
        if let shown = image ?? blurHash { PixelImage(shown, fit: .cover, snapsContentRect: true) } else { Color.clear }
    }
}

/// A message's video played in the bubble: its player once started, and the action that starts
/// (or resumes) it. Set by Message for a message whose one attachment is a video.
public struct InlineVideo {
    public var player: VideoPlaybackEngine?
    public var play: (() -> Void)?
    public init(player: VideoPlaybackEngine? = nil, play: (() -> Void)? = nil) {
        self.player = player
        self.play = play
    }
}

extension EnvironmentValues {
    @Entry public var inlineVideo = InlineVideo()
}
