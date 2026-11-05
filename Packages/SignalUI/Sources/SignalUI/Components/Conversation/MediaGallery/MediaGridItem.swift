// Port of ts/components/conversation/media-gallery/MediaGridItem.dom.tsx: a square, rounded
// media tile (the image, a video's screenshot, or the blurhash, cover) with the metadata
// overlay (GIF, a video's size, or the size when asked; on a bottom gradient) and, until
// downloaded, the 50px download / cancel badge. Alone it is as wide as its image; in the
// gallery grid it fills its cell.

import SignalI18n
import SwiftUI

public struct MediaGridItem: View {
    let attachment: MessageAttachment
    let showSize: Bool
    let onClick: () -> Void
    @Environment(\.i18n) var i18n

    public init(attachment: MessageAttachment, showSize: Bool = false, onClick: @escaping () -> Void = {}) {
        self.attachment = attachment
        self.showSize = showSize
        self.onClick = onClick
    }

    var shownImage: RGBAImage? { attachment.hasUrl ? (attachment.isVideo ? attachment.screenshot : attachment.image) : nil }

    /// The tile's intrinsic side (`aspect-square` on the image's width; a blurhash is 32px).
    var naturalSide: CGFloat { CGFloat(shownImage?.width ?? attachment.blurHash?.width ?? 32) }

    var metadataText: String? {
        let a = attachment
        let ready = a.status == .readyToShow
        if ready && !a.isGIF && !a.isVideo && !showSize { return nil }
        if !showSize && a.isGIF && ready { return i18n("icu:message--getNotificationText--gif") }
        return formatFileSize(a.size)
    }

    var label: String {
        switch attachment.status {
        case .readyToShow: i18n("icu:imageOpenAlt")
        case .downloading: i18n("icu:cancelDownload")
        case .needsDownload: i18n("icu:startDownload")
        }
    }

    @ViewBuilder var spinnerOverlay: some View {
        if attachment.status != .readyToShow {
            let downloading = if case .downloading = attachment.status { true } else { false }
            ZStack {
                Circle().fill(AxoColor.deprecatedFillOnMedia)
                if downloading {
                    SpinnerV2(value: attachment.totalDownloaded.map(Double.init), max: Double(attachment.size), variant: .noBackground,
                              marginRatio: 1, size: 44, strokeWidth: 2)
                }
                AxoSymbol.Icon(downloading ? "x" : "arrow-down", size: 24, label: nil).cssTextColor(.labelPrimaryOncolor)
            }
            .frame(width: 50, height: 50)
        }
    }

    public var body: some View {
        SwiftUI.Button(action: onClick) {
            GeometryReader { geo in
                ZStack {
                    ImageOrBlurhash(image: shownImage, blurHash: attachment.blurHash)
                        .frame(width: geo.size.width, height: geo.size.height)
                    if let text = metadataText {
                        // absolute end-0 bottom-0 h-11.5 w-full, a transparent → black/60% gradient
                        LinearGradient(colors: [.clear, Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.6)], startPoint: .top, endPoint: .bottom)
                            .frame(width: geo.size.width, height: 46)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                        CSSText(text, style: CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 12, lineHeight: 14, letterSpacing: 0.06),
                                wrap: .wrap, color: .labelPrimaryOncolor)
                            .frame(maxWidth: max(0, geo.size.width - 8), alignment: .trailing)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.trailing, 8).padding(.bottom, 6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                    spinnerOverlay
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .frame(idealWidth: naturalSide)
        .accessibilityLabel(label)
    }
}
