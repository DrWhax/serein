// Port of ts/components/conversation/GIF.dom.tsx: a GIF-flagged video at its timeline size
// (300 wide), muted and looping while the window has focus (`player`, VideoView); with
// reduced motion (or `_forceTapToPlay`) it starts paused, plays for MAX_GIF_TIME / MAX_GIF_REPEAT
// after a tap and shows the "GIF" tap-to-play button while paused (GIFPlayback). Without a
// player it shows the first frame. Until the video is local it shows its
// blurhash (react-blurhash: 32×32, stretched), the download button or progress, and the size
// pill with "· GIF".

import Blurhash
import SignalI18n
import SwiftUI

public struct MessageGIF: View {
    let attachment: MessageAttachment
    let size: CGFloat
    let forceTapToPlay: Bool
    let blurHashDark: Bool?
    let showVisualAttachment: (() -> Void)?
    let startDownload: (() -> Void)?
    let cancelDownload: (() -> Void)?
    let showMediaNoLongerAvailableToast: (() -> Void)?
    let player: VideoPlaybackEngine?
    @State private var playback = GIFPlayback()
    @Environment(\.controlActiveState) var activeState
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.colorScheme) var scheme
    @Environment(\.i18n) var i18n

    public init(attachment: MessageAttachment, size: CGFloat = 300, forceTapToPlay: Bool = false, blurHashDark: Bool? = nil,
                showVisualAttachment: (() -> Void)? = nil, startDownload: (() -> Void)? = nil, cancelDownload: (() -> Void)? = nil,
                showMediaNoLongerAvailableToast: (() -> Void)? = nil, player: VideoPlaybackEngine? = nil) {
        self.player = player
        self.attachment = attachment
        self.size = size
        self.forceTapToPlay = forceTapToPlay
        self.blurHashDark = blurHashDark
        self.showVisualAttachment = showVisualAttachment
        self.startDownload = startDownload
        self.cancelDownload = cancelDownload
        self.showMediaNoLongerAvailableToast = showMediaNoLongerAvailableToast
    }

    var tapToPlay: Bool { reduceMotion || forceTapToPlay }

    var shouldPlay: Bool {
        guard let player else { return !tapToPlay }
        return playback.shouldPlay(tapToPlay: tapToPlay, focused: activeState != .inactive, loopCount: player.loopCount,
                                   currentTime: player.currentTime, duration: player.duration)
    }

    public var body: some View {
        let dims = imageDimensionsForTimeline(width: attachment.width, height: attachment.height, forcedWidth: size)
        let pending = attachment.pending
        let notResolved = !attachment.hasUrl && !pending
        let downloadable = !attachment.isPermanentlyUndownloadable
        let errored = attachment.hasUrl && (player.map { $0.lastError != nil || !$0.isLoaded } ?? (attachment.videoFrame == nil))
        let isPlaying = shouldPlay
        ZStack {
            if notResolved || pending || !downloadable || errored {
                // The attachment's blurhash, decoded by the media service at react-blurhash's 32×32.
                let blur = attachment.blurHash ?? BlurHashImage.trustedSquare(BlurHashImage.defaultHash(dark: blurHashDark ?? (scheme == .dark)))
                if let blur { PixelImage(blur, fit: .fill) }
            } else if let player {
                // object-fit: cover — the timeline box has the attachment's aspect ratio.
                VideoView(engine: player, fit: .cover)
                    .contentShape(Rectangle())
                    .onTapGesture { showVisualAttachment?() }
                    .task(id: ObjectIdentifier(player)) { player.isLooping = true }
                    .onChange(of: shouldPlay, initial: true) { _, play in Task { await player.match(play) } }
                    .onDisappear { player.pause() }
            } else if let frame = attachment.videoFrame {
                PixelImage(frame, fit: .cover).onTapGesture { showVisualAttachment?() }
            }
            if pending, cancelDownload != nil {
                SwiftUI.Button { cancelDownload?() } label: {
                    ConversationImage.circle().overlay {
                        ConversationImage.icon("v3/stop/stop-fill")
                        SpinnerV2(value: attachment.size > 0 && (attachment.totalDownloaded ?? 0) > 0 ? Double(attachment.totalDownloaded ?? 0) : nil,
                                  min: 0, max: Double(attachment.size), marginRatio: 1, size: 44, strokeWidth: 2)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(i18n("icu:cancelDownload"))
            }
            if (tapToPlay && !isPlaying) || (notResolved && downloadable) {
                // .module-image--not-downloaded / --tap-to-play: a 50px black-alpha-70 circle.
                SwiftUI.Button {
                    if notResolved { startDownload?() } else if tapToPlay { playback.tappedAtLoop = player?.loopCount ?? 0 }
                } label: {
                    Circle().fill(LegacyColor.blackAlpha70.color).frame(width: 50, height: 50)
                        .overlay {
                            if notResolved {
                                SignalIcon("v3/arrow/arrow-down", size: 24, color: AxoColor(LegacyColor.white))
                            } else {
                                CSSText("GIF", style: LegacyType.body1(), wrap: .nowrap, color: AxoColor(LegacyColor.white))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(i18n("icu:GIF--download"))
            } else if attachment.isPermanentlyUndownloadable {
                SwiftUI.Button { showMediaNoLongerAvailableToast?() } label: {
                    ConversationImage.circle(LegacyColor.blackAlpha40).overlay { ConversationImage.icon("v3/photo/photo-slash-compact") }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(i18n("icu:mediaNotAvailable"))
            }
            if downloadable {
                AttachmentDetailPill(attachments: [attachment], isGif: true, startDownload: startDownload, cancelDownload: cancelDownload)
                    .padding([.top, .leading], 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: dims.width, height: dims.height)
        .clipped()
    }
}

extension BlurHashImage {
    /// react-blurhash's canvas: 32×32 pixels (resolutionX / resolutionY), stretched to the box.
    static func trustedSquare(_ hash: String) -> RGBAImage? {
        guard let buffer = try? Blurhash.decode(hash, width: 32, height: 32) else { return nil }
        return RGBAImage(buffer)
    }
}
