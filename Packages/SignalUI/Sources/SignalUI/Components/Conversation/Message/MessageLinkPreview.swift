// Message.dom.tsx `#renderPreview` (stylesheets/_modules.scss .module-message__link-preview):
// the first link preview across the bubble's width — a full-size image grid on top when the
// image is big and not square, else a 72px (sticker pack: 64px) thumbnail beside the text —
// with the title (2 lines), description (5 lines), and the domain • date footer.

import SignalI18n
import SwiftUI

/// `LinkPreviewType` (the parts the bubble renders).
public struct LinkPreview: Sendable, Hashable {
    public var url: String
    public var domain: String?
    public var title: String?
    public var description: String?
    /// Milliseconds since 1970 (`date`).
    public var date: Double?
    public var image: MessageAttachment?
    public var isStickerPack = false
    public var isCallLink = false
    public var callLinkRoomId: String?
    public init(url: String, domain: String? = nil, title: String? = nil, description: String? = nil, date: Double? = nil,
                image: MessageAttachment? = nil) {
        self.url = url
        self.domain = domain
        self.title = title
        self.description = description
        self.date = date
        self.image = image
    }

    /// `shouldUseFullSizeLinkPreviewImage`: an image at least 200×200 and not roughly square.
    var isFullSizeImage: Bool {
        guard !isStickerPack, let image, image.isImage, let w = image.width, let h = image.height, w >= 200, h >= 200 else { return false }
        return abs(1 - Double(w) / Double(h)) >= 0.05
    }
}

/// `getKeyFromCallLink`: the `key` hash parameter.
func callLinkKey(_ url: String) -> String {
    guard let hash = url.split(separator: "#", maxSplits: 1).dropFirst().first else { return "" }
    for pair in hash.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1)
        if kv.first == "key" { return kv.count > 1 ? String(kv[1]).removingPercentEncoding ?? String(kv[1]) : "" }
    }
    return ""
}

/// `getColorForCallLink`: the root key's first byte (base-16 consonants) picks the avatar colour.
func callLinkColor(_ rootKey: String) -> String {
    let alphabet = Array("bcdfghkmnpqrstxz")
    let chars = Array(rootKey.prefix(2))
    func index(_ i: Int) -> Int { i < chars.count ? (alphabet.firstIndex(of: chars[i]) ?? 0) : 0 }
    let byte = index(0) * 16 + index(1)
    return AxoTokensTables.avatarColors[byte % AxoTokensTables.avatarColors.count].name
}

/// `isLinkPreviewDateValid`: set, finite and before a day from now.
func isLinkPreviewDateValid(_ ms: Double?, now: Date) -> Bool {
    guard let ms, ms != 0, ms.isFinite else { return false }
    return ms < now.timeIntervalSince1970 * 1000 + 86_400_000
}

struct MessageLinkPreview: View {
    let preview: LinkPreview
    let direction: MessageDirection
    let withContentAbove: Bool
    let shouldCollapseAbove: Bool
    let blurHashDark: Bool?
    let open: (() -> Void)?
    let startDownload: (() -> Void)?
    let cancelDownload: (() -> Void)?
    let showMediaNoLongerAvailableToast: (() -> Void)?
    @Environment(\.i18n) var i18n
    @Environment(\.conversationListNow) var fixedNow
    @Environment(\.timeZone) var timeZone

    static var thumbnailOptions: ConversationImage.Options {
        var o = ConversationImage.Options()
        o.noBorder = true
        o.noBackground = true
        return o
    }

    static let primary = AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05)

    var title: String? { preview.title ?? (preview.isCallLink ? i18n("icu:calling__call-link-default-title") : nil) }
    var description: String? { preview.description ?? (preview.isCallLink ? i18n("icu:message--call-link-description") : nil) }

    /// `moment(date).format('ll')` ("Mar 10, 2020").
    func dateText(_ ms: Double) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Locale(identifier: i18n.locale), timeZone: timeZone)
        style.calendar = Calendar(identifier: .gregorian)
        return Date(timeIntervalSince1970: ms / 1000).formatted(style)
    }

    var body: some View {
        let hasImage = preview.image?.isImage ?? false
        let fullSize = preview.isFullSizeImage
        VStack(alignment: .leading, spacing: 0) {
            if let image = preview.image, hasImage, fullSize {
                ImageGrid(attachments: [image], direction: direction, shouldCollapseAbove: shouldCollapseAbove, withContentAbove: withContentAbove,
                          withContentBelow: true, blurHashDark: blurHashDark, showVisualAttachment: open.map { f in { _ in f() } },
                          showMediaNoLongerAvailableToast: showMediaNoLongerAvailableToast, cancelDownload: cancelDownload,
                          startDownload: startDownload)
                    .frame(maxWidth: .infinity)
            }
            HStack(alignment: .center, spacing: 0) {
                if let image = preview.image, preview.domain != nil, hasImage, !fullSize {
                    let side: CGFloat = preview.isStickerPack ? 64 : 72
                    ConversationImage(attachment: image, url: image.image, blurHash: image.blurHash, width: side, height: side,
                                      corners: .init(topLeft: .tiny, topRight: .tiny, bottomLeft: withContentAbove ? .tiny : .small, bottomRight: .tiny),
                                      options: Self.thumbnailOptions, blurHashDark: blurHashDark, startDownload: startDownload, cancelDownload: cancelDownload,
                                      showVisualAttachment: open, showMediaNoLongerAvailableToast: showMediaNoLongerAvailableToast)
                        // -m-0.5 (not for sticker packs), then me-2 (Tailwind puts the longhand
                        // after the shorthand): −2px on three sides, 8px at the end.
                        .padding(.top, preview.isStickerPack ? 0 : -2)
                        .padding(.bottom, preview.isStickerPack ? 0 : -2)
                        .padding(.leading, preview.isStickerPack ? 0 : -2)
                        .padding(.trailing, 8)
                }
                if preview.isCallLink {
                    // .module-message__link-preview__call-link-icon
                    Avatar(strings: AvatarStrings(i18n: i18n), title: title ?? i18n("icu:calling__call-link-default-title"), size: 64,
                           conversationType: .callLink, color: callLinkColor(callLinkKey(preview.url)))
                        .padding(.vertical, 4)
                        .padding(.trailing, 12)
                }
                if preview.isStickerPack {
                    VStack(alignment: .leading, spacing: 0) {
                        CSSText(title ?? "", style: CSSTextStyle(AxoType.bodyMedium.weight(600)), color: .labelPrimary)
                            .padding(.top, 4).padding(.bottom, 2)
                        if let description {
                            CSSText(Self.unescape(description), style: CSSTextStyle(AxoType.bodyMedium), color: .labelPrimary).padding(.bottom, 2)
                        }
                        CSSText(preview.domain ?? "", style: CSSTextStyle(AxoType.bodySmall), color: .labelSecondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        CSSText(title ?? "", style: LegacyType.body1(weight: 600).breakingWords(), wrap: .clamp(2), color: Self.primary)
                        if let description {
                            CSSText(Self.unescape(description), style: LegacyType.body2().breakingWords(), wrap: .clamp(5), color: Self.primary)
                                .padding(.top, 4)
                        }
                        footer.padding(.top, 2)
                    }
                    .padding(.top, hasImage && !fullSize ? 5 : 0)
                    .layoutPriority(1)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AxoColor(light: LegacyColor.gray02, dark: LegacyColor.gray80))
        }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { open?() }
        .accessibilityAddTraits(open != nil ? .isLink : [])
    }

    /// `.module-message__link-preview__footer`: the domain (lowercased), then `•` (at half the
    /// font size, 0.2rem either side) and the date.
    var footer: some View {
        let color = AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25)
        let style = LegacyType.body2()
        // flex row: the domain, then the date item (its ::before bullet a flex item at 6.5px
        // in the inherited 18px line height).
        let hasDate = isLinkPreviewDateValid(preview.date, now: fixedNow ?? .now)
        return HStack(alignment: .top, spacing: 0) {
            // An empty location (no domain, no date) has no line box.
            if !(preview.domain ?? "").isEmpty || hasDate {
                CSSText((preview.domain ?? "").lowercased(), style: style, wrap: .nowrap, color: color)
            }
            if isLinkPreviewDateValid(preview.date, now: fixedNow ?? .now), let ms = preview.date {
                HStack(alignment: .top, spacing: 0) {
                    CSSText("\u{2022}", style: CSSTextStyle(fontName: style.fontName, size: style.size / 2, lineHeight: style.lineHeight,
                                                             letterSpacing: style.letterSpacing), wrap: .nowrap, color: color)
                        .padding(.horizontal, 3.2)
                    CSSText(dateText(ms), style: style, wrap: .nowrap, color: color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// lodash `unescape`: the five HTML entities.
    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }
}
