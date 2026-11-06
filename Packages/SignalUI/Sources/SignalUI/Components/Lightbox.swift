// Port of ts/components/Lightbox.dom.tsx (stylesheets/components/Lightbox.scss): the
// full-window black media viewer, always dark: header (sender, controls), the selected item
// (image, an "unsupported" placeholder, or custom children), prev/next zones, the caption and
// the thumbnail strip.
//
// A video item plays through its `player` (VideoView, Metal) when it has one: it starts on
// show, GIFs and view-once videos loop without controls (view-once shows the time in the
// footer), others get the controls (play/pause, time, seek). Without a player it shows
// `image` (a still frame; black until then). Not ported yet: zoom and pan, the spring
// animations, and the incremental-download toast.

import SignalI18n
import SwiftUI

/// What the lightbox needs of a `MediaItemType`.
public struct LightboxMediaItem: Sendable {
    /// A video's length (seconds), for its controls' "0:00 / 0:39".
    public var duration: Double?
    /// How much of a video has loaded (its controls' timeline shows it brighter).
    public var bufferedFraction: Double = 0
    public enum Kind: Sendable, Hashable {
        /// A supported image; `image` nil when it has no URL (the "missing" placeholder).
        case image
        case video
        case unsupportedImage
        case unsupportedVideo
        case file
    }
    public var kind: Kind
    public var image: RGBAImage?
    /// A video's playback (loaded by the caller).
    public var player: VideoPlaybackEngine?
    /// The attachment has the GIF flag: it loops, muted, without controls.
    public var isGIF = false
    public var thumbnail: RGBAImage?
    public var caption: String?
    public init(kind: Kind, image: RGBAImage? = nil, thumbnail: RGBAImage? = nil, caption: String? = nil, player: VideoPlaybackEngine? = nil, isGIF: Bool = false) {
        self.kind = kind
        self.image = image
        self.player = player
        self.isGIF = isGIF
        self.thumbnail = thumbnail
        self.caption = caption
    }
}

/// `LightboxHeader`: the conversation's avatar, title and the item's time.
public struct LightboxHeaderInfo: Sendable {
    public var title: String
    public var conversationType: AvatarConversationType
    public var color: String
    public var avatar: RGBAImage?
    /// `formatDateTimeForAttachment(sentAt)`
    public var timestamp: String
    public init(title: String, conversationType: AvatarConversationType = .direct, color: String = "A200", avatar: RGBAImage? = nil, timestamp: String) {
        self.title = title
        self.conversationType = conversationType
        self.color = color
        self.avatar = avatar
        self.timestamp = timestamp
    }
}

public struct Lightbox<Children: View>: View {
    let media: [LightboxMediaItem]
    let selectedIndex: Int
    let isViewOnce: Bool
    let header: LightboxHeaderInfo?
    let hasPrevMessage: Bool
    let hasNextMessage: Bool
    let closeLightbox: () -> Void
    let onForward: () -> Void
    let onSave: () -> Void
    let onPrevAttachment: () -> Void
    let onNextAttachment: () -> Void
    let onSelectAttachment: (Int) -> Void
    let children: Children
    @Environment(\.i18n) var i18n
    @Environment(\.titleBarDragAreaHeight) var dragAreaHeight
    @FocusState private var closeFocused: Bool

    public init(media: [LightboxMediaItem], selectedIndex: Int = 0, isViewOnce: Bool = false, header: LightboxHeaderInfo? = nil,
                hasPrevMessage: Bool = false, hasNextMessage: Bool = false, closeLightbox: @escaping () -> Void = {},
                onForward: @escaping () -> Void = {}, onSave: @escaping () -> Void = {}, onPrevAttachment: @escaping () -> Void = {},
                onNextAttachment: @escaping () -> Void = {}, onSelectAttachment: @escaping (Int) -> Void = { _ in },
                @ViewBuilder children: () -> Children = { EmptyView() }) {
        self.media = media
        self.selectedIndex = selectedIndex
        self.isViewOnce = isViewOnce
        self.header = header
        self.hasPrevMessage = hasPrevMessage
        self.hasNextMessage = hasNextMessage
        self.closeLightbox = closeLightbox
        self.onForward = onForward
        self.onSave = onSave
        self.onPrevAttachment = onPrevAttachment
        self.onNextAttachment = onNextAttachment
        self.onSelectAttachment = onSelectAttachment
        self.children = children()
    }

    var current: LightboxMediaItem? { media.indices.contains(selectedIndex) ? media[selectedIndex] : nil }
    static var gray15: AxoColor { AxoColor(LegacyColor.gray15) }
    static var gray25: AxoColor { AxoColor(LegacyColor.gray25) }

    public var body: some View {
        AxoThemeOverride(theme: .forceDark) {
            VStack(spacing: 0) {
                headerBar.padding(.top, dragAreaHeight).padding(.bottom, 16)
                objectContainer.frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .contentShape(Rectangle())
            .onTapGesture(perform: closeLightbox)
            .onKeyPress(.escape) {
                closeLightbox()
                return .handled
            }
            .onKeyPress(.leftArrow) {
                if selectedIndex > 0 || hasPrevMessage { onPrevAttachment() }
                return .handled
            }
            .onKeyPress(.rightArrow) {
                if selectedIndex < media.count - 1 || hasNextMessage { onNextAttachment() }
                return .handled
            }
            .onAppear { closeFocused = true }
        }
    }

    // MARK: Header

    var headerBar: some View {
        HStack(spacing: 0) {
            if let header {
                HStack(alignment: .top, spacing: 10) {
                    Avatar(strings: AvatarStrings(i18n: i18n), title: header.title, size: 32, conversationType: header.conversationType, color: header.color,
                           image: header.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: header.avatar != nil)
                    VStack(alignment: .leading, spacing: 0) {
                        CSSText(header.title, style: LegacyType.body2(weight: 600), color: AxoColor(LegacyColor.white))
                        CSSText(header.timestamp, style: LegacyType.caption(), color: Self.gray25)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 32) {
                if !isViewOnce {
                    button("v3/forward/forward", label: i18n("icu:forwardMessage"), action: onForward)
                    button("v3/save/save", label: i18n("icu:save"), action: onSave)
                }
                button("v3/x/x", label: i18n("icu:close"), action: closeLightbox)
                    .focused($closeFocused)
                    .axoFocusRing(closeFocused, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    /// `Lightbox__button`: a 24px gray-15 icon.
    func button(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { SignalIcon(icon, size: 24, color: Self.gray15, mask: true) }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel(label)
    }

    // MARK: Object

    var hasPrevious: Bool { selectedIndex > 0 || hasPrevMessage }
    var hasNext: Bool { selectedIndex < media.count - 1 || hasNextMessage }

    @ViewBuilder var objectContainer: some View {
        ZStack {
            content
            // Prev / next: 96px zones, 224 tall, whose chevrons show only on hover.
            HStack(spacing: 0) {
                if hasPrevious { NavZone(next: false, label: i18n("icu:previous"), action: onPrevAttachment) }
                Spacer(minLength: 0)
                if hasNext { NavZone(next: true, label: i18n("icu:next"), action: onNextAttachment) }
            }
        }
        .clipped()
    }

    @ViewBuilder var content: some View {
        if let current {
            switch current.kind {
            case .image:
                if let image = current.image {
                    // __zoomable-container: margin-inline 40px, the image contained; Chromium
                    // paints it into its rect rounded outward to device pixels.
                    PixelImage(image, fit: .contain, snapsOutward: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 40)
                        .accessibilityLabel(i18n("icu:lightboxImageAlt"))
                } else {
                    unsupported("alert-outline", label: i18n("icu:lightboxImageAlt"))
                }
            case .video:
                // video.Lightbox__object--video: the full object area, the frame contained.
                if let player = current.player {
                    let shouldLoop = current.isGIF || isViewOnce
                    VideoView(engine: player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        // A click on the video toggles playback, as on a `<video controls>`.
                        .onTapGesture { if !shouldLoop { Task { await player.togglePlayback() } } }
                        .overlay(alignment: .bottom) {
                            if !shouldLoop { LightboxVideoControls(duration: current.duration ?? player.duration, buffered: current.bufferedFraction, player: player) }
                        }
                        .task(id: ObjectIdentifier(player)) {
                            player.isLooping = shouldLoop
                            await player.play()
                        }
                        .onDisappear { player.pause() }
                        .accessibilityLabel(i18n("icu:lightboxImageAlt"))
                } else if let frame = current.image {
                    // Chromium's paused `<video controls>` panel sits at the bottom of the video
                    // element (the object area), over the frame or its letterbox (looping
                    // view-once videos have no controls).
                    PixelImage(frame, fit: .contain, snapsContentRect: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottom) {
                            if !isViewOnce { LightboxVideoControls(duration: current.duration ?? 0, buffered: current.bufferedFraction) }
                        }
                } else {
                    Color.black
                }
            case .unsupportedImage: unsupported("image", label: i18n("icu:unsupportedAttachment"))
            case .unsupportedVideo: unsupported("movie", label: i18n("icu:unsupportedAttachment"))
            case .file: unsupported("file", label: i18n("icu:unsupportedAttachment"))
            }
        } else {
            children
        }
    }

    /// `Lightbox__unsupported`: 200px wide, the icon stretched to the width (gray-25), centred.
    func unsupported(_ icon: String, label: String) -> some View {
        Button(action: closeLightbox) {
            SignalIcon(icon, size: 200, color: Self.gray25, mask: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .frame(width: 200)
        .accessibilityLabel(label)
    }

    struct NavZone: View {
        let next: Bool
        let label: String
        let action: () -> Void
        @State private var hovered = false
        var body: some View {
            Button(action: action) {
                SignalIcon(next ? "v3/chevron/chevron-right-white" : "v3/chevron/chevron-left-white", size: 32)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .padding(next ? .trailing : .leading, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: next ? .trailing : .leading)
                    .contentShape(Rectangle())
                    .opacity(hovered ? 1 : 0)
            }
            .buttonStyle(.plain)
            .frame(width: 96, height: 224)
            .onHover { hovered = $0 }
            .accessibilityLabel(label)
        }
    }

    // MARK: Footer

    var footer: some View {
        VStack(spacing: 0) {
            if isViewOnce, current?.kind == .video, let player = current?.player, player.currentTime > 0 {
                ViewOnceTime(player: player)
            }
            if let caption = current?.caption, !caption.isEmpty {
                CSSText(caption, style: LegacyType.body2(), alignment: .center, color: AxoColor(LegacyColor.white))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            thumbnails.frame(height: 44)
        }
        .padding(.top, 16).padding(.bottom, 24).padding(.horizontal, 16)
    }

    /// `Lightbox__thumbnails`: starts at the centre and slides so the selected one is centred.
    var thumbnails: some View {
        GeometryReader { geo in
            if media.count > 1 {
                HStack(spacing: 8) {
                    ForEach(Array(media.enumerated()), id: \.offset) { index, item in
                        Button { onSelectAttachment(index) } label: { thumbnail(item, selected: index == selectedIndex) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(i18n("icu:lightboxImageAlt"))
                    }
                }
                .offset(x: geo.size.width / 2 - CGFloat(selectedIndex) * 52 - 22)
            }
        }
    }

    func thumbnail(_ item: LightboxMediaItem, selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        return Group {
            if let thumb = item.thumbnail {
                PixelImage(thumb, fit: .contain).opacity(0.8)
            } else {
                SignalIcon("image", size: 44, color: Self.gray25, mask: true)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(shape)
        .overlay { if selected { shape.strokeBorder(Color.white, lineWidth: 2) } }
    }
}

/// Chromium's native media controls as a paused `<video controls>` shows them, at the bottom
/// of the video element: a black gradient over the bottom 106px (stops measured from the
/// captures), the button row centred 48px up (play and "current / duration" on the left,
/// mute, fullscreen and the overflow menu on the right), and the 4px timeline track 20px up
/// (white at 30%, the buffered part brighter).
struct LightboxVideoControls: View {
    let duration: Double
    let buffered: Double
    /// Live playback (interactive controls); nil draws the paused panel.
    var player: VideoPlaybackEngine?
    var time: Double { player?.currentTime ?? 0 }
    var playing: Bool { player?.isPlaying ?? false }
    /// (offset from the top of the 106px band, black opacity)
    static let stops: [(Double, Double)] = [(0, 0), (0.104, 0.046), (0.226, 0.15), (0.34, 0.3), (0.453, 0.475), (0.528, 0.597), (0.604, 0.711),
                                            (0.679, 0.812), (0.755, 0.899), (0.83, 0.957), (1, 1)]

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(stops: Self.stops.map { .init(color: Color.black.opacity($0.1), location: $0.0) }, startPoint: .top, endPoint: .bottom)
                .frame(height: 106)
            HStack(spacing: 0) {
                Group {
                    if playing {
                        HStack(spacing: 3) { Rectangle().fill(Color.white).frame(width: 2.5); Rectangle().fill(Color.white).frame(width: 2.5) }
                    } else {
                        Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 8, y: 5.25)); p.addLine(to: CGPoint(x: 0, y: 10.5)); p.closeSubpath() }
                            .fill(Color.white)
                    }
                }
                .frame(width: 8, height: 10.5)
                .contentShape(Rectangle().inset(by: -10))
                .padding(.leading, 21)
                .onTapGesture { if let player { Task { await player.togglePlayback() } } }
                Text(durationToPlaybackText(time) + " / " + durationToPlaybackText(duration))
                    .font(.system(size: 13.5)).foregroundStyle(Color.white).fixedSize()
                    .padding(.leading, 19)
                Spacer(minLength: 0)
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 13)).foregroundStyle(Color.white)
                    .frame(width: 15, height: 14)
                Corners().stroke(Color.white, lineWidth: 1.5).frame(width: 10.5, height: 11.5).padding(.leading, 35)
                VStack(spacing: 2.5) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white).frame(width: 2.5, height: 2.5) } }
                    .padding(.leading, 41.5).padding(.trailing, 23)
            }
            .frame(height: 14)
            .padding(.bottom, 41)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.3))
                    if buffered > 0 { Capsule().fill(Color.white.opacity(0.7)).frame(width: w * min(1, buffered)) }
                    if player != nil, duration > 0 { Capsule().fill(Color.white).frame(width: w * min(1, max(0, time / duration))) }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle().inset(by: -8))
                .gesture(SpatialTapGesture().onEnded { e in
                    guard let player, w > 0 else { return }
                    let t = min(max(0, e.location.x / w), 1) * duration
                    Task { await player.seek(to: t) }
                })
            }
            .frame(height: 4)
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .allowsHitTesting(player != nil)
        .accessibilityHidden(player == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(durationToPlaybackText(time) + " / " + durationToPlaybackText(duration))
        .accessibilityAddTraits(player != nil ? .startsMediaSession : [])
    }
    /// The fullscreen glyph: four corner brackets.
    struct Corners: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            let l: CGFloat = 3.5
            for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
                p.move(to: CGPoint(x: x + dx * l, y: y)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: y + dy * l))
            }
            return p
        }
    }
}

/// `Lightbox__timestamp`: a view-once video's time, a black body-1 pill (#eeefef text).
struct ViewOnceTime: View {
    let player: VideoPlaybackEngine
    var body: some View {
        CSSText(durationToPlaybackText(player.currentTime), style: LegacyType.body1(), alignment: .center, color: AxoColor(RGBA(0xee / 255.0, 0xef / 255.0, 0xef / 255.0)))
            .padding(.vertical, 6).padding(.horizontal, 18)
            .background(Capsule().fill(Color.black))
    }
}
