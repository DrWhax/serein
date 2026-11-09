// A message's attachment as the UI sees it (`AttachmentForUIType`, the parts ported so far),
// and the generic-file row (Message.dom.tsx `#renderAttachment`'s simple attachment, with
// AttachmentStatusIcon and FileThumbnail).

import SignalI18n
import SwiftUI

public struct MessageAttachment: Sendable, Hashable {
    public var contentType: String
    public var fileName: String?
    public var size: Int
    public var width: Int?
    public var height: Int?
    /// `getUrl(attachment)` is set: the plaintext is local and can be shown.
    public var isDownloaded = true
    public var pending = false
    public var totalDownloaded: Int?
    public var isPermanentlyUndownloadable = false
    public var wasTooBig = false
    /// The decoded `url` image (nil: no url, or it failed to load).
    public var image: RGBAImage?
    /// `screenshot.url` (a video's poster frame).
    public var screenshot: RGBAImage?
    /// `thumbnail` is set; `thumbnailImage` is its decoded url, if any.
    public var hasThumbnail = false
    public var thumbnailImage: RGBAImage?
    /// The attachment's blurhash, decoded by the media service.
    public var blurHash: RGBAImage?
    /// `isIncremental`: incrementalMac and chunkSize are set (a streamable video).
    public var incremental = false
    public var caption: String?
    /// `flags & AttachmentPointer.Flags.GIF` (a looping, muted video shown as a GIF).
    public var isGifFlag = false
    /// `url` is set (`useAttachmentStatus` keys on it; a GIF's video is local; `image` stays
    /// nil for videos).
    public var hasUrl = true
    /// An audio attachment's waveform and duration (`computeWaveform`, by the media service).
    public var audioWaveform: AudioWaveform?
    /// The video's first frame, decoded by the media service (nil: it failed to play).
    public var videoFrame: RGBAImage?

    public init(contentType: String, fileName: String? = nil, size: Int = 10304, width: Int? = 800, height: Int? = 600) {
        self.contentType = contentType
        self.fileName = fileName
        self.size = size
        self.width = width
        self.height = height
    }

    /// `getUrl`: a video shows its screenshot (never its url).
    var url: RGBAImage? { screenshot ?? (isVideo ? nil : image) }
    /// `areDimensionsDisplayable` (8192 × 8192 at most).
    var areDimensionsDisplayable: Bool { (height ?? 0) <= 8192 && (width ?? 0) <= 8192 }
    var displayUrl: RGBAImage? { areDimensionsDisplayable ? url : nil }
    /// `getDisplayThumbnailUrl`
    var displayThumbnailUrl: RGBAImage? { hasThumbnail ? thumbnailImage : displayUrl }

    /// `isGIF`
    var isGIF: Bool { isGifFlag && isVideo }

    var isImage: Bool { QuoteMIME.isImage(contentType) }
    var isVideo: Bool { QuoteMIME.isVideo(contentType) }
    var isAudio: Bool { QuoteMIME.isAudio(contentType) }

    /// `useAttachmentStatus` (without the transition delay).
    enum Status: Equatable { case needsDownload, downloading(size: Int, downloaded: Int), readyToShow }
    var status: Status {
        if isPermanentlyUndownloadable && !wasTooBig { return .readyToShow }
        if !hasUrl && !pending { return .needsDownload }
        if !hasUrl && pending { return .downloading(size: size, downloaded: totalDownloaded ?? 0) }
        return .readyToShow
    }

    /// `getExtensionForDisplay`
    var extensionForDisplay: String? {
        if let name = fileName, let dot = name.lastIndex(of: ".") {
            let ext = name[name.index(after: dot)...]
            if !ext.isEmpty { return String(ext) }
        }
        if let slash = contentType.firstIndex(of: "/") { return String(contentType[contentType.index(after: slash)...]) }
        return nil
    }

    static let dangerousTypes: Set<String> = [
        "ADE", "ADP", "APK", "BAT", "CAB", "CHM", "CMD", "COM", "CPL", "DIAGCAB", "DLL", "DMG", "EXE", "HTA", "INF", "INS", "ISP", "JAR", "JS",
        "JSE", "LIB", "LNK", "MDE", "MHT", "MSC", "MSI", "MSP", "MST", "NSH", "PIF", "PS1", "PSC1", "PSM1", "PSRC", "REG", "SCR", "SCT",
        "SETTINGCONTENT-MS", "SHB", "SYS", "VB", "VBE", "VBS", "VXD", "WSC", "WSF", "WSH",
    ]

    /// `isFileDangerous`: `/\.(EXE|…)(\.|\s)*?$/i`, a dangerous extension before any trailing dots
    /// and whitespace.
    static func isFileDangerous(_ fileName: String) -> Bool {
        var name = Substring(fileName)
        while let last = name.last, last == "." || last.isWhitespace { name = name.dropLast() }
        guard let dot = name.lastIndex(of: ".") else { return false }
        return dangerousTypes.contains(name[name.index(after: dot)...].uppercased())
    }
}

/// `FileThumbnail`: the generic-file page with the extension, plus the warning badge for
/// dangerous file types.
struct FileThumbnail: View {
    let contentType: String
    let fileName: String?

    var body: some View {
        let ext = MessageAttachment(contentType: contentType, fileName: fileName).extensionForDisplay ?? ""
        ZStack {
            if let img = BundledImage.named("generic-file") { PixelImage(img, fit: .contain) }
            CSSText(ext, style: CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: ext.count > 3 ? 9 : 11, lineHeight: 14,
                                             letterSpacing: ext.count > 3 ? 0 : 0.06),
                    wrap: .truncate, color: AxoColor(RGBA(0, 0, 0, 0.85)))
                // mx-1 leaves 22px; Chromium ellipsizes past exactly that ("mov" → "m…"), so
                // offset CSSText's 0.6px allowance for rounded SwiftUI proposals.
                .frame(maxWidth: 22 - CSSTextLayout.widthTolerance + CSSTextLayout.exactWidthTolerance)
        }
        .frame(width: 30, height: 40)
        .overlay(alignment: .topTrailing) {
            if MessageAttachment.isFileDangerous(fileName ?? ""), let img = BundledImage.named("generic-file-dangerous") {
                PixelImage(img, fit: .contain).frame(width: 20, height: 20).offset(x: 6, y: -4)
            }
        }
        .padding(.horizontal, 3)
    }
}

/// `AttachmentStatusIcon`: a download arrow / progress circle until the file is local, then the
/// thumbnail.
struct AttachmentStatusIcon<Thumbnail: View>: View {
    let attachment: MessageAttachment
    let isIncoming: Bool
    @ViewBuilder let thumbnail: () -> Thumbnail

    var circleBackground: AxoColor {
        isIncoming ? AxoColor(light: LegacyColor.whiteAlpha80, dark: LegacyColor.whiteAlpha20) : AxoColor(LegacyColor.whiteAlpha20)
    }

    var body: some View {
        Group {
            switch attachment.status {
            case .readyToShow:
                thumbnail()
            case .needsDownload:
                circle { icon("v3/arrow/arrow-down-bold") }
            case .downloading(let size, let downloaded):
                circle {
                    SpinnerV2(value: Double(downloaded), min: 0, max: Double(max(size, 1)), variant: isIncoming ? .noBackgroundIncoming : .noBackground,
                              marginRatio: 1, size: 36, strokeWidth: 2)
                    icon("v3/x/x-bold")
                }
            }
        }
        .frame(width: 36, height: 40, alignment: .topLeading)
        .padding(.vertical, 2)
        .padding(.trailing, 12)
    }

    func icon(_ name: String) -> some View {
        SignalIcon(name, size: 20, color: isIncoming ? .labelPrimary : .labelPrimaryOncolor)
    }

    func circle(@ViewBuilder _ content: () -> some View) -> some View {
        ZStack { content() }
            .frame(width: 36, height: 36)
            .background(circleBackground, in: Circle())
            .padding(.vertical, 2)
    }
}

/// `.module-message__simple-attachment`: the status icon / file thumbnail, the file name and size,
/// and (with no text) the metadata at the end of the size row.
struct MessageGenericAttachment: View {
    let attachment: MessageAttachment
    let direction: MessageDirection
    /// The bubble's text colour (the not-available icon's currentColor).
    let textColor: AxoColor
    let withContentAbove: Bool
    let withContentBelow: Bool
    let metadata: MessageMetadata?
    /// `#openGenericAttachment` (the whole row is the button).
    var onClick: (() -> Void)? = nil
    @Environment(\.i18n) var i18n

    var body: some View {
        if let onClick {
            SwiftUI.Button(action: onClick) { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(i18n(attachment.pending ? "icu:cancelDownload" : "icu:startDownload"))
        } else {
            content
        }
    }

    @ViewBuilder var content: some View {
        let incoming = direction == .incoming
        let unavailable = attachment.isPermanentlyUndownloadable && !attachment.wasTooBig
        HStack(alignment: .center, spacing: 0) {
            AttachmentStatusIcon(attachment: attachment, isIncoming: incoming) {
                FileThumbnail(contentType: attachment.contentType, fileName: attachment.fileName)
            }
            VStack(alignment: .leading, spacing: 0) {
                CSSText(attachment.fileName ?? "", style: LegacyType.body1(weight: 500), wrap: .truncate,
                        color: incoming ? AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05)
                                        : AxoColor(light: LegacyColor.white, dark: LegacyColor.whiteAlpha90))
                    .padding(.top, 2)
                HStack(alignment: .bottom, spacing: 0) {
                    if unavailable {
                        // .module-message__undownloadable-attachment-file: the error circle (16px,
                        // 1px down, 3px before the text) and "File not available" in body-2.
                        HStack(alignment: .top, spacing: 0) {
                            SignalIcon("v3/error/error-circle", size: 16, color: textColor).padding(.top, 1).padding(.trailing, 3)
                            CSSText(i18n("icu:attachmentNotAvailable__file"), style: LegacyType.body2(), wrap: .nowrap,
                                    color: incoming ? AxoColor(light: LegacyColor.gray80, dark: LegacyColor.gray25) : textColor)
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    } else {
                        CSSText(formatFileSize(attachment.size), style: LegacyType.bodySmall(), wrap: .nowrap,
                                color: incoming ? AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25)
                                                : AxoColor(light: LegacyColor.whiteAlpha80, dark: LegacyColor.whiteAlpha60))
                            .padding(.top, 2)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    if let metadata {
                        // .module-message__simple-attachment__metadata-container: flex-grow, 8px start,
                        // 6px top (+ the metadata's own 3px), aligned to the row's end.
                        metadata.padding(.top, 9).padding(.leading, 8).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, withContentAbove ? 4 : 0)
        .padding(.bottom, withContentBelow ? 8 : 0)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(attachment.status == .readyToShow ? "" : i18n("icu:startDownload"))
    }
}

/// The view-once state a message renders (`isTapToView` with its expired / error / viewed flags).
public struct TapToViewState: Sendable, Hashable {
    public var isExpired = false
    public var isError = false
    public var isViewed = false
    public init(isExpired: Bool = false, isError: Bool = false, isViewed: Bool = false) {
        self.isExpired = isExpired
        self.isError = isError
        self.isViewed = isViewed
    }
}

/// `#renderTapToView`: the view-once icon with "View Once Photo / Video", "Viewed" or (outgoing)
/// "View Once Media", in the simple-attachment row; metadata at its end.
struct MessageTapToView: View {
    let state: TapToViewState
    let attachment: MessageAttachment?
    let direction: MessageDirection
    let withContentAbove: Bool
    let metadata: MessageMetadata?
    @Environment(\.i18n) var i18n

    var incoming: Bool { direction == .incoming }

    /// `#renderTapToViewText`
    var text: (title: String, detail: String?) {
        if !incoming { return (i18n("icu:Message--tap-to-view--media"), nil) }
        if state.isViewed { return (i18n("icu:Message--tap-to-view--viewed"), nil) }
        var detail = i18n("icu:Message--tap-to-view--helper-text")
        if let a = attachment, !a.isDownloaded { detail = formatFileSize(a.size) }
        let isVideoLike = attachment.map { $0.isVideo || $0.contentType == QuoteMIME.gif } ?? false
        return (isVideoLike ? i18n("icu:Message--tap-to-view--video") : i18n("icu:Message--tap-to-view--photo"), detail)
    }

    var titleColor: AxoColor {
        incoming ? AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05) : AxoColor(light: LegacyColor.white, dark: LegacyColor.whiteAlpha90)
    }

    /// `#renderTapToViewIcon`
    var icon: some View {
        let disabled = !incoming || state.isViewed
        let background: AxoColor = incoming
            ? (disabled ? AxoColor(light: LegacyColor.whiteAlpha60, dark: LegacyColor.whiteAlpha10) : AxoColor(light: LegacyColor.whiteAlpha80, dark: LegacyColor.whiteAlpha20))
            : (disabled ? AxoColor(LegacyColor.whiteAlpha10) : AxoColor(LegacyColor.whiteAlpha20))
        let name = !incoming ? "v3/view_once/view_once-dash-bold" : state.isViewed ? "v3/view_once/view_once-viewed-bold" : "v3/view_once/view_once-bold"
        // --incoming paints the icon label-primary over the state's colour.
        return SignalIcon(name, size: 20, color: incoming ? .labelPrimary : AxoColor(LegacyColor.whiteAlpha80))
            .frame(width: 36, height: 36)
            .background(background, in: Circle())
            .padding(.vertical, 2)
            .frame(width: 36, height: 40, alignment: .top)
            .padding(.vertical, 2)
            .padding(.trailing, 12)
    }

    var body: some View {
        let t = text
        HStack(alignment: .center, spacing: 0) {
            if let a = attachment, !state.isExpired, a.status != .readyToShow {
                AttachmentStatusIcon(attachment: a, isIncoming: incoming) { EmptyView() }
            } else {
                icon
            }
            if let detail = t.detail {
                VStack(alignment: .leading, spacing: 0) {
                    CSSText(t.title, style: LegacyType.body1(weight: 500), wrap: .truncate, color: titleColor).padding(.top, 2)
                    HStack(alignment: .bottom, spacing: 0) {
                        CSSText(detail, style: LegacyType.bodySmall(), wrap: .nowrap,
                                color: incoming ? AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25)
                                                : AxoColor(light: LegacyColor.whiteAlpha80, dark: LegacyColor.whiteAlpha60))
                            .padding(.top, 2)
                            .frame(maxHeight: .infinity, alignment: .top)
                        if let metadata { metadata.padding(.top, 9).padding(.leading, 8).frame(maxWidth: .infinity, alignment: .trailing) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                CSSText(t.title, style: LegacyType.body1(weight: 500), wrap: .truncate, color: titleColor).padding(.top, 2)
                if let metadata {
                    metadata.padding(.top, 9).padding(.leading, 8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, withContentAbove ? 4 : 0)
    }
}

/// `#renderSimpleAttachmentNotAvailable` (the view-once cases): the slashed icon, why the media
/// is gone and "Learn more", across the whole bubble.
struct MessageAttachmentNotAvailable: View {
    let info: String
    let icon: String
    let learnMore: (() -> Void)?
    let withContentAbove: Bool
    var withContentBelow = false
    /// --with-content-below's 0.5px bottom border.
    var rule: AxoColor = AxoColor(light: LegacyColor.blackAlpha10, dark: LegacyColor.whiteAlpha10)
    @Environment(\.i18n) var i18n

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            SignalIcon(icon, size: 20).padding(.trailing, 8)
            VStack(alignment: .leading, spacing: 0) {
                CSSText(info, style: LegacyType.body1())
                if let learnMore {
                    SwiftUI.Button(action: learnMore) {
                        CSSText(i18n("icu:attachmentNoLongerAvailable__learnMore"), style: LegacyType.body1(weight: 500))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 8 + (withContentBelow ? 0.5 : 0), trailing: 12))
        .frame(minWidth: 200, alignment: .leading)
        .overlay(alignment: .bottom) { if withContentBelow { Rectangle().fill(rule).frame(height: 0.5) } }
        // margin-inline −12 / margin-block −8 (7 above content below): it spans the bubble's padding.
        .padding(.horizontal, -12)
        .padding(.top, withContentAbove ? 4 : -8)
        .padding(.bottom, withContentBelow ? 7 : -8)
    }
}
