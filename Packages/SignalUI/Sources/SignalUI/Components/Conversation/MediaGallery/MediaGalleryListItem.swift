// Ports of ts/components/conversation/media-gallery/ListItem.dom.tsx and DocumentListItem.dom.tsx:
// a gallery row: the thumbnail, the title (truncated) over the subtitle, the date ("MMM D", it
// shows the message), and while the attachment is not downloaded a 28px download / cancel
// button (with the progress ring while downloading).

import SignalI18n
import SwiftUI

/// A gallery entry's message metadata.
public struct MediaItemMessage: Sendable {
    public var id: String
    public var receivedAt: Date
    public init(id: String, receivedAt: Date) {
        self.id = id
        self.receivedAt = receivedAt
    }
}

public struct MediaGalleryListItem<Thumbnail: View, Subtitle: View>: View {
    let attachment: MessageAttachment?
    let isLink: Bool
    let message: MediaItemMessage
    let title: String
    let readyLabel: String
    let thumbnail: Thumbnail
    let subtitle: Subtitle
    let onClick: () -> Void
    let showMessage: () -> Void
    @State private var hovered = false
    @Environment(\.i18n) var i18n
    @Environment(\.timeZone) var timeZone

    public init(attachment: MessageAttachment?, isLink: Bool = false, message: MediaItemMessage, title: String, readyLabel: String,
                onClick: @escaping () -> Void = {}, showMessage: @escaping () -> Void = {},
                @ViewBuilder thumbnail: () -> Thumbnail, @ViewBuilder subtitle: () -> Subtitle) {
        self.attachment = attachment
        self.isLink = isLink
        self.message = message
        self.title = title
        self.readyLabel = readyLabel
        self.thumbnail = thumbnail()
        self.subtitle = subtitle()
        self.onClick = onClick
        self.showMessage = showMessage
    }

    /// moment `MMM D`
    var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: i18n.locale)
        f.timeZone = timeZone
        f.dateFormat = DateFormatter.dateFormat(fromTemplate: "MMMd", options: 0, locale: f.locale)
        return f.string(from: message.receivedAt)
    }

    var label: String {
        switch attachment?.status {
        case .needsDownload: i18n("icu:downloadAttachment")
        case .downloading: i18n("icu:cancelDownload")
        default: readyLabel
        }
    }

    @ViewBuilder var downloadButton: some View {
        if let a = attachment, a.status != .readyToShow, !isLink {
            let downloading = if case .downloading = a.status { true } else { false }
            ZStack {
                Circle().fill(AxoColor.fillPrimary)
                if downloading {
                    SpinnerV2(value: a.totalDownloaded.map(Double.init), max: Double(a.size), variant: .noBackgroundIncoming, marginRatio: 1,
                              size: 28, strokeWidth: 1)
                }
                AxoSymbol.Icon(downloading ? "x" : "arrow-down", size: 16, label: nil).cssTextColor(.labelPrimary)
            }
            .frame(width: 28, height: 28)
            .padding(.leading, -4)
        }
    }

    public var body: some View {
        HStack(alignment: isLink ? .top : .center, spacing: 12) {
            thumbnail.fixedSize()
            VStack(alignment: .leading, spacing: 0) {
                CSSText(runs: [Emojify.run(title)], style: LegacyType.body1(), wrap: .truncate, color: .labelPrimary)
                subtitle
                    .environment(\.cssTextColor, .labelSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SwiftUI.Button(action: showMessage) {
                CSSText(dateText, type: .bodySmall, wrap: .nowrap, color: .labelSecondary)
                    .frame(maxHeight: isLink ? nil : .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(i18n("icu:ListItem__show-message"))
            .fixedSize(horizontal: true, vertical: false)
            downloadButton
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovered ? AxoColor.fillPrimary : AxoColor(RGBA(0, 0, 0, 0))))
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .padding(.horizontal, 10)
    }
}

/// `DocumentListItem`: the file thumbnail, "name · author", and the size (with a download
/// arrow while not downloaded).
public struct DocumentListItem: View {
    let attachment: MessageAttachment
    let message: MediaItemMessage
    let authorTitle: String
    let onClick: () -> Void
    let showMessage: () -> Void
    @Environment(\.i18n) var i18n

    public init(attachment: MessageAttachment, message: MediaItemMessage, authorTitle: String, onClick: @escaping () -> Void = {},
                showMessage: @escaping () -> Void = {}) {
        self.attachment = attachment
        self.message = message
        self.authorTitle = authorTitle
        self.onClick = onClick
        self.showMessage = showMessage
    }

    public var body: some View {
        let title = ([attachment.fileName].compactMap { $0 } + [authorTitle]).joined(separator: " · ")
        MediaGalleryListItem(attachment: attachment, message: message, title: title, readyLabel: i18n("icu:startDownload"),
                             onClick: onClick, showMessage: showMessage) {
            FileThumbnail(contentType: attachment.contentType, fileName: attachment.fileName)
                .frame(width: 30, height: 40)
                .padding(.horizontal, 3)
        } subtitle: {
            // type-body-small leading-4
            let style = CSSTextStyle(AxoType.bodySmall)
            HStack(spacing: 0) {
                if attachment.status != .readyToShow {
                    AxoSymbol.InlineGlyph("arrow-down", size: 12, weight: 400)
                    CSSText("\u{00A0}", style: style, wrap: .nowrap)
                }
                CSSText(formatFileSize(attachment.size), style: style, wrap: .nowrap)
            }
            .cssTextColor(.labelSecondary)
        }
    }
}

/// `AudioListItem`: a 36px card of 7 waveform bars (2px wide, 2–22px tall, none until the
/// peaks are computed), "name · author", "size · Audio / Voice Message · duration" and the
/// unplayed dot.
public struct AudioListItem: View {
    static let barCount = 7
    static let maxPeakHeight: CGFloat = 22
    static let minPeakHeight: CGFloat = 2

    let attachment: MessageAttachment
    let message: MediaItemMessage
    let authorTitle: String
    let isVoiceMessage: Bool
    let duration: Double
    /// 0…1 peaks (`useComputePeaks`); nil while processing or not downloaded.
    let peaks: [Double]?
    let isPlayed: Bool
    let onClick: () -> Void
    let showMessage: () -> Void
    @Environment(\.i18n) var i18n

    public init(attachment: MessageAttachment, message: MediaItemMessage, authorTitle: String, isVoiceMessage: Bool = false, duration: Double,
                peaks: [Double]?, isPlayed: Bool, onClick: @escaping () -> Void = {}, showMessage: @escaping () -> Void = {}) {
        self.attachment = attachment
        self.message = message
        self.authorTitle = authorTitle
        self.isVoiceMessage = isVoiceMessage
        self.duration = duration
        self.peaks = peaks
        self.isPlayed = isPlayed
        self.onClick = onClick
        self.showMessage = showMessage
    }

    var thumbnail: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                let v = peaks.map { i < $0.count ? $0[i] : 0 }
                // p-px: a bar is never under 2px.
                let h = v.map { max(Self.minPeakHeight, $0 * Self.maxPeakHeight) } ?? 0
                RoundedRectangle(cornerRadius: 4).fill(AxoColor.labelPlaceholder).frame(width: 2, height: max(2, h))
            }
        }
        .frame(width: 36, height: 36)
        .background(AxoColor.materialTertiary, in: RoundedRectangle(cornerRadius: 4))
    }

    public var body: some View {
        let parts = [formatFileSize(attachment.size),
                     i18n(isVoiceMessage ? "icu:AudioListItem__subtitle--voice-message" : "icu:AudioListItem__subtitle--audio"),
                     durationToPlaybackText(duration)]
        let title = attachment.fileName.map { "\($0) · \(authorTitle)" } ?? authorTitle
        MediaGalleryListItem(attachment: attachment, message: message, title: title, readyLabel: i18n("icu:startDownload"),
                             onClick: onClick, showMessage: showMessage) {
            thumbnail
        } subtitle: {
            HStack(alignment: .center, spacing: 4) {
                CSSText(parts.joined(separator: " · "), type: .bodySmall, wrap: .truncate, color: .labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                RoundedRectangle(cornerRadius: 4).fill(AxoColor.labelSecondary).frame(width: 6, height: 6)
                    .scaleEffect(isPlayed ? 0 : 1)
                    .animation(.spring(duration: 0.3), value: isPlayed)
            }
        }
    }
}

/// `LinkPreviewItem`: the preview image (36px, cover) or a link glyph card, the title, the url
/// (body-medium, underlined) and "author · domain".
public struct LinkPreviewItem: View {
    let preview: LinkPreview
    let message: MediaItemMessage
    let authorTitle: String
    let onClick: () -> Void
    let showMessage: () -> Void
    @Environment(\.i18n) var i18n

    public init(preview: LinkPreview, message: MediaItemMessage, authorTitle: String, onClick: @escaping () -> Void = {},
                showMessage: @escaping () -> Void = {}) {
        self.preview = preview
        self.message = message
        self.authorTitle = authorTitle
        self.onClick = onClick
        self.showMessage = showMessage
    }

    @ViewBuilder var thumbnail: some View {
        if let image = preview.image, image.hasUrl {
            ImageOrBlurhash(image: image.image, blurHash: image.blurHash)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            AxoSymbol.Icon("link", size: 20, label: nil)
                .cssTextColor(.labelSecondary)
                .frame(width: 36, height: 36)
                .background(AxoColor.materialTertiary, in: RoundedRectangle(cornerRadius: 4))
        }
    }

    public var body: some View {
        MediaGalleryListItem(attachment: preview.image, isLink: true, message: message, title: preview.title ?? "",
                             readyLabel: i18n("icu:LinkPreviewItem__alt"), onClick: onClick, showMessage: showMessage) {
            thumbnail
        } subtitle: {
            VStack(alignment: .leading, spacing: 0) {
                var run = CSSTextRun(preview.url)
                let _ = (run.underline = true)
                // The url (body-medium) sets the first line box to 18px.
                CSSText(runs: [run], style: CSSTextStyle(AxoType.bodyMedium), wrap: .truncate, color: .labelSecondary)
                CSSText(runs: [Emojify.run("\(authorTitle) · \(preview.domain ?? "")")], style: CSSTextStyle(AxoType.bodySmall), wrap: .wrap,
                        color: .labelSecondary)
            }
        }
    }
}

/// The media gallery's `ContactListItem`: a shared contact's 36px avatar (AvatarColors[0]),
/// "name · author" and "Contact".
public struct GalleryContactListItem: View {
    let name: String
    let avatar: MessageAttachment?
    let message: MediaItemMessage
    let authorTitle: String
    let onClick: () -> Void
    let showMessage: () -> Void
    @Environment(\.i18n) var i18n

    public init(name: String, avatar: MessageAttachment?, message: MediaItemMessage, authorTitle: String, onClick: @escaping () -> Void = {},
                showMessage: @escaping () -> Void = {}) {
        self.name = name
        self.avatar = avatar
        self.message = message
        self.authorTitle = authorTitle
        self.onClick = onClick
        self.showMessage = showMessage
    }

    public var body: some View {
        MediaGalleryListItem(attachment: avatar, message: message, title: "\(name) · \(authorTitle)", readyLabel: i18n("icu:startDownload"),
                             onClick: onClick, showMessage: showMessage) {
            ListAvatar(data: ConversationAvatarData(title: name, color: AxoTokens.Avatar.allColorNames[0],
                                                    image: avatar?.hasUrl == true ? avatar?.image : nil), size: 36)
        } subtitle: {
            CSSText(i18n("icu:ContactListItem__subtitle"), type: .bodySmall, color: .labelSecondary)
        }
    }
}
