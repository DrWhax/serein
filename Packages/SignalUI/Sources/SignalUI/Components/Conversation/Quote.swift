// Port of ts/components/conversation/Quote.dom.tsx (stylesheets/components/Quote.scss,
// StoryReplyQuote.scss): the quoted message in a bubble or above the composer. The author,
// the quoted text (2 lines) or a type label, an optional thumbnail/icon on the trailing side,
// a close button (compose) and the "original message not found" warning.

import SignalI18n
import SwiftUI

/// `QuotedAttachmentType` (the parts the quote renders).
public struct QuotedAttachment: Sendable, Hashable {
    public var contentType: String
    public var fileName: String?
    public var isVoiceMessage = false
    /// The decoded thumbnail, nil when it has not been downloaded (or failed to decode).
    public var thumbnail: RGBAImage?
    public init(contentType: String, fileName: String? = nil, isVoiceMessage: Bool = false, thumbnail: RGBAImage? = nil) {
        self.contentType = contentType
        self.fileName = fileName
        self.isVoiceMessage = isVoiceMessage
        self.thumbnail = thumbnail
    }
}

/// The props of `<Quote>`.
public struct QuoteModel: Sendable, Hashable {
    public enum Direction: Sendable, Hashable { case incoming, outgoing, compose }

    public var authorTitle: String
    public var authorLabel: ContactLabel?
    public var isFromMe = false
    public var direction: Direction = .outgoing
    public var text: String?
    public var bodyRanges: [BodyRange] = []
    public var rawAttachment: QuotedAttachment?
    public var isViewOnce = false
    public var isStoryReply = false
    public var referencedMessageNotFound = false
    public var reactionEmoji: String?
    public var bubbleColor: BubbleColor?
    /// `.module-message--collapsed-above .module-quote`: this top corner is 4px.
    public var squaredTopCorner: HorizontalEdge?

    public init(authorTitle: String, text: String?) {
        self.authorTitle = authorTitle
        self.text = text
    }

    /// `getAttachment`: long-message text attachments are not shown.
    var attachment: QuotedAttachment? {
        guard let a = rawAttachment, a.contentType != QuoteMIME.longMessage else { return nil }
        return a
    }

    /// `validateQuote`
    var isValid: Bool {
        if isStoryReply && (referencedMessageNotFound || reactionEmoji != nil) { return true }
        // Gift badges (donations) are not ported: a quoted gift has no text or attachment.
        return !(text ?? "").isEmpty || rawAttachment != nil
    }
}

/// The MIME helpers Quote uses (`ts/types/MIME.std.ts`, `ts/util/GoogleChrome.std.ts`).
enum QuoteMIME {
    static let longMessage = "text/x-signal-plain"
    static let gif = "image/gif"
    static let supportedImages: Set<String> = ["image/avif", "image/bmp", "image/gif", "image/jpeg", "image/webp", "image/x-xbitmap",
                                               "image/vnd.microsoft.icon", "image/ico", "image/icon", "image/x-icon", "image/apng", "image/png"]
    static let supportedVideos: Set<String> = ["video/mp4", "video/ogg", "video/webm"]
    static func isImage(_ t: String) -> Bool { supportedImages.contains(t) }
    static func isVideo(_ t: String) -> Bool { supportedVideos.contains(t) }
    static func isAudio(_ t: String) -> Bool { t.hasPrefix("audio/") }
}

extension RGBA {
    /// `hsl(from c h s calc(…))`: this colour with its HSL lightness (0…100) mapped by `f`.
    func mapLightness(_ f: (Double) -> Double) -> RGBA {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        let d = mx - mn
        var h = 0.0, s = 0.0
        if d > 0 {
            s = l == 0 || l == 1 ? 0 : (mx - l) / min(l, 1 - l)
            if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
            h *= 60
        }
        return .hsl(h, s, max(0, min(100, f(l * 100))) / 100, alpha: a)
    }

    /// CSS `hsl()`: hue in degrees, saturation and lightness 0…1.
    public static func hsl(_ h: Double, _ s: Double, _ l: Double, alpha: Double = 1) -> RGBA {
        func channel(_ n: Double) -> Double {
            let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
            let a = s * min(l, 1 - l)
            return l - a * max(-1, min(k - 3, 9 - k, 1))
        }
        return RGBA(channel(0), channel(8), channel(4), alpha)
    }

    /// Quote.scss `css-lighten($color, $amount)`
    func cssLighten(_ amount: Double) -> RGBA { mapLightness { $0 + (100 - $0) * amount } }
    /// Quote.scss `css-darken($color, $amount)`
    func cssDarken(_ amount: Double) -> RGBA { mapLightness { $0 * (1 - amount) } }
}

public struct Quote: View {
    let model: QuoteModel
    let onClick: (() -> Void)?
    let onClose: (() -> Void)?
    /// The inherited line-height the author's inline-flex box sits in: the page's 20px body-1
    /// standalone, 0 in a message (`.module-message__container` sets line-height 0).
    let strut: CGFloat
    @Environment(\.i18n) var i18n

    public init(_ model: QuoteModel, onClick: (() -> Void)? = nil, onClose: (() -> Void)? = nil, strut: CGFloat = 20) {
        self.strut = strut
        self.model = model
        self.onClick = onClick
        self.onClose = onClose
    }

    static let gray = AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05)
    var radii: RectangleCornerRadii {
        RectangleCornerRadii(topLeading: model.squaredTopCorner == .leading ? 4 : 8, bottomLeading: 4, bottomTrailing: 4,
                             topTrailing: model.squaredTopCorner == .trailing ? 4 : 8)
    }

    var borderColor: AxoColor {
        if model.direction == .outgoing { return AxoColor(LegacyColor.white) }
        guard let data = model.bubbleColor?.data else { return AxoColor(RGBA(0, 0, 0, 0)) }
        return AxoColor((data.solid ?? data.gradient?.start) ?? RGBA(0, 0, 0, 0))
    }

    public var body: some View {
        if model.isValid {
            VStack(alignment: .leading, spacing: 0) {
                button
                if model.referencedMessageNotFound && !model.isStoryReply { referenceWarning }
            }
            .background { QuoteBackground(color: model.bubbleColor) }
            .clipShape(UnevenRoundedRectangle(cornerRadii: radii))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(onClick != nil ? .isButton : [])
            .onTapGesture { onClick?() }
        }
    }

    var button: some View {
        HStack(alignment: .top, spacing: 0) {
            primary
            if let icon = iconContainer {
                icon.frame(width: model.isStoryReply ? 40 : 54)
                    .frame(minHeight: model.isStoryReply ? 64 : nil, maxHeight: .infinity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .bottomTrailing) {
            if let emoji = model.reactionEmoji {
                if model.rawAttachment != nil {
                    Emojify(emoji, style: LegacyType.body1(), wrap: .nowrap).padding(.trailing, 25).padding(.bottom, 5)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let onClose {
                SwiftUI.Button(action: onClose) {
                    Circle().fill(LegacyColor.blackAlpha40.color).frame(width: 16, height: 16)
                        .overlay { SignalIcon("v3/x/x", size: 14, color: AxoColor(LegacyColor.white)) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(i18n("icu:close"))
                .padding(4)
            }
        }
    }

    // MARK: primary

    var primary: some View {
        VStack(alignment: .leading, spacing: 0) {
            authorLine
            genericFile
            textOrLabel
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 7, leading: 8, bottom: 7, trailing: 8))
        .frame(minHeight: model.isStoryReply ? 52 : 54, alignment: .top)
        .padding(.leading, 4)
        .overlay(alignment: .leading) { Rectangle().fill(borderColor).frame(width: 4) }
    }

    /// The author (inline-flex) on a body-1 line box. Payments are not ported (out of scope),
    /// so upstream's inline payment text after it is omitted.
    var authorLine: some View {
        author.frame(height: max(strut, 18), alignment: .leading)
    }

    var author: some View {
        let style = LegacyType.body2(weight: 600)
        let title: String = model.isFromMe ? i18n("icu:you") : model.authorTitle
        return HStack(alignment: .center, spacing: 4) {
            if model.isStoryReply {
                // `{title} &middot; {story}` in the inline-flex author: a contact name is its own
                // flex item (4px gap; the text's leading space collapses), "You" merges into one text.
                if model.isFromMe {
                    CSSText(title + " · " + i18n("icu:Quote__story"), style: style, wrap: .truncate, color: Self.gray)
                } else {
                    CSSText(title, style: style, wrap: .truncate, color: Self.gray)
                    CSSText("· " + i18n("icu:Quote__story"), style: style, wrap: .nowrap, color: Self.gray)
                }
            } else {
                CSSText(title, style: style, wrap: .truncate, color: Self.gray)
                if let label = model.authorLabel {
                    GroupMemberLabel(contactLabel: label, contactNameColor: nil, context: .quote).padding(.top, 1)
                }
            }
        }
        // Baseline-aligned in a 20px body-1 line box, the 18px box sits 1px down.
        .padding(.top, strut > 18 ? 1 : 0)
        .frame(height: max(strut, 18), alignment: .top)
    }

    @ViewBuilder var genericFile: some View {
        if let a = model.attachment, !QuoteMIME.isVideo(a.contentType), !QuoteMIME.isImage(a.contentType), !QuoteMIME.isAudio(a.contentType) {
            HStack(spacing: 6) {
                if let img = BundledImage.named("generic-file") { PixelImage(img, fit: .contain).frame(width: 30, height: 40) }
                CSSText(a.fileName ?? "", style: LegacyType.body2(), wrap: .truncate, color: Self.gray)
            }
            .frame(height: 40)
        }
    }

    @ViewBuilder var textOrLabel: some View {
        if let text = model.text, !text.isEmpty {
            MessageBody(text: text, bodyRanges: model.bodyRanges, disableJumbomoji: true, disableLinks: true, renderLocation: .quote,
                        style: LegacyType.body1().breakingWords(), wrap: .clamp(2), linkColor: Self.gray,
                        alignment: MessageBody.firstStrongDirection(text) == .rightToLeft ? .end : .start)
                .environment(\.cssTextColor, Self.gray)
        } else if let label = typeLabel {
            CSSText(label, style: CSSTextStyle(fontName: AxoFonts.interName(weight: 400, italic: true), size: 13, lineHeight: 18, letterSpacing: -0.03),
                    color: Self.gray)
        }
    }

    /// `getTypeLabel`
    var typeLabel: String? {
        guard let a = model.attachment else { return nil }
        let t = a.contentType
        if QuoteMIME.isVideo(t) { return model.isViewOnce ? i18n("icu:message--getDescription--disappearing-video") : i18n("icu:video") }
        if QuoteMIME.isImage(t) {
            if model.isViewOnce { return i18n("icu:message--getDescription--disappearing-photo") }
            return t == QuoteMIME.gif ? i18n("icu:message--getDescription--gif") : i18n("icu:photo")
        }
        if model.isViewOnce { return i18n("icu:message--getDescription--disappearing-media") }
        if QuoteMIME.isAudio(t) && a.isVoiceMessage { return i18n("icu:voiceMessage") }
        return QuoteMIME.isAudio(t) ? i18n("icu:audio") : nil
    }

    // MARK: icon container

    /// `renderIconContainer`
    var iconContainer: AnyView? {
        guard let a = model.attachment else { return nil }
        if model.isViewOnce { return AnyView(QuoteIcon(name: "v3/view_once/view_once")) }
        if QuoteMIME.isVideo(a.contentType) {
            if let thumb = a.thumbnail { return AnyView(QuoteThumbnail(image: thumb, play: true)) }
            return AnyView(QuoteIcon(name: "movie"))
        }
        if QuoteMIME.isImage(a.contentType) {
            if let thumb = a.thumbnail { return AnyView(QuoteThumbnail(image: thumb, play: false)) }
            return AnyView(QuoteIcon(name: "v3/photo/photo-square"))
        }
        if QuoteMIME.isAudio(a.contentType) { return AnyView(QuoteIcon(name: "v3/mic/mic")) }
        return nil
    }

    // MARK: reference warning

    var referenceWarning: some View {
        HStack(spacing: 6) {
            SignalIcon("v3/link/link-slash", size: 16, color: Self.gray)
            CSSText(i18n("icu:originalMessageNotFound"), style: LegacyType.caption(), wrap: .nowrap, color: Self.gray)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }
}

/// `.module-quote__icon-container__circle-background` with its 20px ultramarine icon.
struct QuoteCircleIcon: View {
    let name: String
    var body: some View {
        Circle().fill(LegacyColor.white.color).frame(width: 32, height: 32)
            .overlay { SignalIcon(name, size: 20, color: AxoColor(LegacyColor.ultramarine)) }
    }
}

/// `renderIcon`: the circle icon centred in the container.
struct QuoteIcon: View {
    let name: String
    var body: some View {
        QuoteCircleIcon(name: name).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `ThumbnailImage`: the thumbnail as a `background-size: cover` image, with the play icon for videos.
struct QuoteThumbnail: View {
    let image: RGBAImage?
    let play: Bool
    var body: some View {
        ZStack {
            if let image {
                PixelImage(image, fit: .cover)
            }
            if play { QuoteCircleIcon(name: "v3/play/play-fill") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `.module-quote--color-solid`: the bubble colour lightened 60% (light) or darkened 40% (dark).
/// `.module-quote--color-gradient` draws nothing: its `background-image: light-dark(<gradient>,
/// <gradient>)` is invalid (Chromium's light-dark() takes colours only), so the quote stays
/// transparent, as upstream renders it.
struct QuoteBackground: View {
    let color: BubbleColor?
    @Environment(\.colorScheme) var scheme
    var body: some View {
        if let solid = color?.data.solid {
            Rectangle().fill((scheme == .dark ? solid.cssDarken(0.4) : solid.cssLighten(0.6)).color)
        }
    }
}
