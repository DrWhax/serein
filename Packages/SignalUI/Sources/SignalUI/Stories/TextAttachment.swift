// Ports of ts/components/TextAttachment.dom.tsx and StoryLinkPreview.dom.tsx (+ their .scss,
// util/getStoryBackground, util/getFontNameByTextScript): a text story — 720×1280 scaled to
// the frame's height — with its background (colour or gradient), the text in one of the six
// story styles (59 / 42 / 32px by length, centred unless small), an optional text background
// pill, and the link preview card below it.

import CoreText
import SignalI18n
import SwiftUI

/// `TextAttachmentStyleType`
public enum TextAttachmentStyle: Int, Sendable, Hashable {
    case `default` = 0, regular, bold, serif, script, condensed
}

/// `TextAttachmentType`'s gradient: two colours, or `colors` at `positions`.
public struct StoryGradient: Sendable, Hashable {
    public var angle: Double
    public var startColor: UInt32?
    public var endColor: UInt32?
    public var colors: [UInt32]?
    public var positions: [Double]?
    public init(angle: Double, startColor: UInt32? = nil, endColor: UInt32? = nil, colors: [UInt32]? = nil, positions: [Double]? = nil) {
        self.angle = angle
        self.startColor = startColor
        self.endColor = endColor
        self.colors = colors
        self.positions = positions
    }
}

/// `LinkPreviewForUIType` (the parts a story shows).
public struct StoryLinkPreviewData: Sendable, Hashable {
    public var url: String
    public var title: String?
    public var description: String?
    public var image: RGBAImage?
    /// The image attachment's declared dimensions (its aspect ratio sizes the tall card).
    public var imageSize: CGSize?
    public var domain: String?
    public init(url: String, title: String? = nil, description: String? = nil, image: RGBAImage? = nil, imageSize: CGSize? = nil, domain: String? = nil) {
        self.url = url
        self.imageSize = imageSize
        self.title = title
        self.description = description
        self.image = image
        self.domain = domain
    }
}

/// `TextAttachmentType`
public struct TextAttachmentData: Sendable, Hashable {
    public var text: String?
    public var textStyle: TextAttachmentStyle?
    public var textForegroundColor: UInt32?
    public var textBackgroundColor: UInt32?
    public var color: UInt32?
    public var gradient: StoryGradient?
    public var preview: StoryLinkPreviewData?
    public init(text: String? = nil, textStyle: TextAttachmentStyle? = nil, textForegroundColor: UInt32? = nil, textBackgroundColor: UInt32? = nil,
                color: UInt32? = nil, gradient: StoryGradient? = nil, preview: StoryLinkPreviewData? = nil) {
        self.text = text
        self.textStyle = textStyle
        self.textForegroundColor = textForegroundColor
        self.textBackgroundColor = textBackgroundColor
        self.color = color
        self.gradient = gradient
        self.preview = preview
    }
}

enum StoryColors {
    static let white: UInt32 = 4_294_704_123     // COLOR_WHITE_INT
    static let black: UInt32 = 4_278_190_080     // COLOR_BLACK_INT

    /// `getHexFromNumber`: the ARGB integer's RGB (the alpha byte is dropped).
    static func rgba(_ argb: UInt32) -> RGBA {
        RGBA(Double((argb >> 16) & 0xFF) / 255, Double((argb >> 8) & 0xFF) / 255, Double(argb & 0xFF) / 255, 1)
    }

    /// `getBackgroundColor`: the gradient (CSS `linear-gradient(<angle>deg, …)`) or colour.
    @ViewBuilder static func background(_ t: TextAttachmentData) -> some View {
        if let g = t.gradient {
            StoryGradientFill(angle: g.angle, stops: stops(g))
        } else {
            Color(rgba: rgba(t.color ?? white))
        }
    }

    static func stops(_ g: StoryGradient) -> [(RGBA, Double)] {
        if let colors = g.colors, !colors.isEmpty, colors.count == g.positions?.count {
            return zip(colors, g.positions ?? []).map { (rgba($0.0 == 0 ? white : $0.0), $0.1) }
        }
        return [(rgba(g.startColor.flatMap { $0 == 0 ? nil : $0 } ?? white), 0), (rgba(g.endColor.flatMap { $0 == 0 ? nil : $0 } ?? white), 1)]
    }
}

/// CSS `linear-gradient(<angle>deg, …)` with any stops (CSSLinearGradientFill's geometry).
struct StoryGradientFill: View {
    let angle: Double
    let stops: [(RGBA, Double)]
    var body: some View {
        GeometryReader { geo in
            let (s, e) = CSSLinearGradient(deg: angle, start: stops.first?.0 ?? RGBA(1, 1, 1), end: stops.last?.0 ?? RGBA(1, 1, 1)).points(in: geo.size)
            Rectangle().fill(.linearGradient(Gradient(stops: stops.map { Gradient.Stop(color: $0.0.color, location: $0.1) }).colorSpace(.device),
                                             startPoint: s, endPoint: e))
        }
    }
}

public struct TextAttachment: View {
    let textAttachment: TextAttachmentData
    let isThumbnail: Bool
    let onClick: (() -> Void)?
    let onRemoveLinkPreview: (() -> Void)?
    /// `onChange`: the text is an editable textarea (the story creator), enabled while
    /// `isEditingText`, showing "Add text" (the UA placeholder: the text colour at 50%) when empty.
    var editText: Binding<String>?
    var isEditingText = false
    @Environment(\.i18n) var i18n
    @Environment(\.axoStaticRendering) var staticRendering
    @FocusState private var editorFocused: Bool

    public init(textAttachment: TextAttachmentData, isThumbnail: Bool = false, onClick: (() -> Void)? = nil, onRemoveLinkPreview: (() -> Void)? = nil) {
        self.textAttachment = textAttachment
        self.isThumbnail = isThumbnail
        self.onClick = onClick
        self.onRemoveLinkPreview = onRemoveLinkPreview
    }

    /// The creator's editable text (`onChange`, `isEditingText`).
    public func editable(_ text: Binding<String>, isEditingText: Bool) -> TextAttachment {
        var copy = self
        copy.editText = text
        copy.isEditingText = isEditingText
        return copy
    }

    enum TextSize { case small, medium, large }

    static func textSize(_ text: String) -> TextSize {
        let n = text.count
        return n < 50 ? .large : n < 200 ? .medium : .small
    }

    /// The story font (`getFont`): size by length; the style's face (Latin); bold for BOLD.
    /// The `font` shorthand resets line-height to `normal`.
    static func textStyle(_ text: String, _ style: TextAttachmentStyle?) -> CSSTextStyle {
        let size: CGFloat = switch textSize(text) { case .large: 59; case .medium: 42; case .small: 32 }
        let name: String = switch style ?? .default {
        case .default, .regular: AxoFonts.interName(weight: 400)
        case .bold: AxoFonts.interName(weight: 700)
        case .serif: "EBGaramond-Regular"
        case .script: "Parisienne-Regular"
        case .condensed: "BarlowCondensed-Medium"
        }
        let s = CSSTextStyle(fontName: name, size: size, lineHeight: CSSTextStyle.normalLineHeight(fontName: name, size: size),
                             cascade: ["SignalEmojiSmall", "SignalEmojiLarge"])
        return s
    }

    var story: some View {
        let text = textAttachment.text ?? ""
        let fg = StoryColors.rgba(textAttachment.textForegroundColor.flatMap { $0 == 0 ? nil : $0 } ?? StoryColors.white)
        let bg = textAttachment.textBackgroundColor.flatMap { $0 == 0 ? nil : $0 }
        let size = Self.textSize(text)
        return VStack(spacing: 0) {
            if editText != nil && text.isEmpty {
                // field-sizing: content: the empty textarea is as wide as its placeholder.
                let style = Self.textStyle(text, textAttachment.textStyle)
                editor(style: style, fg: fg, width: nil)
                    .padding(28)
                    .background { if let bg { RoundedRectangle(cornerRadius: 36).fill(Color(rgba: StoryColors.rgba(bg))) } }
                    .padding(.horizontal, bg != nil ? 36 : 56)
                    .fixedSize()
                    .frame(width: 720)
            } else if !text.isEmpty {
                let style = Self.textStyle(text, textAttachment.textStyle)
                // The text box is fit-content in the centred column: as wide as its text up to
                // the column, but never narrower than its longest word (which then overflows).
                let available: CGFloat = 720 - 2 * (bg != nil ? 36 : 56) - 56
                let maxContent = CSSTextLayout.make(runs: [CSSTextRun(text)], style, wrap: .wrap, maxWidth: nil, colors: nil).widths.max() ?? 0
                let width = min(maxContent, max(CSSTextLayout.minContentWidth(text, style), available))
                Group {
                    if editText != nil {
                        editor(style: style, fg: fg, width: width)
                    } else {
                        CSSText(runs: [CSSTextRun(text)], style: style, wrap: .wrap, alignment: size == .small ? .start : .center,
                                color: AxoColor(light: fg, dark: fg))
                    }
                }
                    .frame(width: width)
                    .clipped()
                    .padding(28)
                    .background { if let bg { RoundedRectangle(cornerRadius: 36).fill(Color(rgba: StoryColors.rgba(bg))) } }
                    .padding(.horizontal, bg != nil ? 36 : 56)
                    .fixedSize()
                    .frame(width: 720)
            }
            if let preview = textAttachment.preview, !preview.url.isEmpty {
                StoryLinkPreview(preview: preview, forceCompactMode: size != .large)
                    .overlay(alignment: .topTrailing) {
                        if let onRemoveLinkPreview {
                            Button(action: onRemoveLinkPreview) {
                                SignalIcon("v3/x/x", size: 24, color: AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray15), mask: true)
                                    .frame(width: 24, height: 24)
                                    .frame(width: 48, height: 48)
                                    .background(Circle().fill(Color(rgba: LegacyColor.blackAlpha40)))
                            }
                            .buttonStyle(UndimmedButtonStyle())
                            .accessibilityLabel(i18n("icu:Keyboard--remove-draft-link-preview"))
                            .offset(x: 16, y: -16)
                        }
                    }
                    .padding(.horizontal, 56)
                    .padding(.top, 36)
            }
        }
        .frame(width: 720, height: 1280)
        .background { if !isThumbnail { StoryColors.background(textAttachment) } }
        .clipped()
    }

    /// `.TextAttachment__text__textarea`: centred, no border; drawn as text when not editing
    /// (and offscreen), an editor while editing.
    @ViewBuilder func editor(style: CSSTextStyle, fg: RGBA, width: CGFloat?) -> some View {
        let text = editText?.wrappedValue ?? ""
        let placeholder = i18n("icu:TextAttachment__placeholder")
        if isEditingText && !staticRendering, let editText {
            TextField("", text: editText, prompt: Text(placeholder).foregroundStyle(Color(rgba: RGBA(fg.r, fg.g, fg.b, 0.5))), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.custom(style.fontName, size: style.size))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(rgba: fg))
                .focused($editorFocused)
                .onAppear { editorFocused = true }
                .frame(width: width ?? CSSTextLayout.make(runs: [CSSTextRun(placeholder)], style, wrap: .nowrap, maxWidth: nil, colors: nil).width)
        } else if text.isEmpty {
            CSSText(placeholder, style: style, wrap: .nowrap, alignment: .center, color: AxoColor(RGBA(fg.r, fg.g, fg.b, 0.5)))
        } else {
            CSSText(runs: [CSSTextRun(text)], style: style, wrap: .wrap, alignment: Self.textSize(text) == .small ? .start : .center,
                    color: AxoColor(light: fg, dark: fg))
        }
    }

    public var body: some View {
        GeometryReader { g in
            // scale(height / 1280), centred in the frame.
            let scale = g.size.height / 1280
            story
                .scaleEffect(scale, anchor: .center)
                .frame(width: g.size.width, height: g.size.height)
        }
        // A thumbnail paints the background on the whole frame, not just the story.
        .background { if isThumbnail { StoryColors.background(textAttachment) } }
        .contentShape(Rectangle())
        .onTapGesture { onClick?() }
    }
}

public struct StoryLinkPreview: View {
    let preview: StoryLinkPreviewData
    let forceCompactMode: Bool
    @Environment(\.i18n) var i18n

    public init(preview: StoryLinkPreviewData, forceCompactMode: Bool = false) {
        self.preview = preview
        self.forceCompactMode = forceCompactMode
    }

    /// `getSafeDomain`
    static func domain(_ url: String) -> String { URL(string: url)?.host() ?? "" }

    public var body: some View {
        let location = preview.domain ?? Self.domain(preview.url)
        let title = preview.title ?? "", description = preview.description ?? ""
        let isCompact = forceCompactMode || preview.image == nil
        let isTiny = title.isEmpty && description.isEmpty && preview.image == nil
        let gray90 = AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray90)
        let content = VStack(alignment: .leading, spacing: 0) {
            if title.isEmpty && description.isEmpty {
                CSSText(location, style: Self.titleStyle, wrap: .clamp(1), color: gray90)
            } else {
                CSSText(title, style: Self.titleStyle, wrap: .clamp(1), color: gray90)
                if !description.isEmpty {
                    CSSText(Self.unescape(description), style: Self.descriptionStyle,
                            wrap: .clamp(2), color: gray90)
                }
                CSSText(location, style: Self.locationStyle,
                        wrap: .wrap, color: AxoColor(light: LegacyColor.gray45, dark: LegacyColor.gray45))
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 24)
        // inline-flex: the 176px image box and the text shrink in proportion to their widths
        // when together they exceed the card.
        let lines: [(String, CSSTextStyle)] = title.isEmpty && description.isEmpty ? [(location, Self.titleStyle)]
            : [(title, Self.titleStyle), (Self.unescape(description), Self.descriptionStyle), (location, Self.locationStyle)]
        let textWidth: CGFloat = lines.map {
            CSSTextLayout.make(runs: [CSSTextRun($0.0)], $0.1, wrap: .nowrap, maxWidth: nil, colors: nil).widths.max() ?? 0
        }.max() ?? 0
        let overflow = 176 + textWidth + 48 - 560
        let iconBox: CGFloat = overflow > 0 ? 176 - overflow * 176 / (176 + textWidth) : 176
        let image: AnyView? = preview.image.map { img in
            let w: CGFloat = isCompact ? 176 : 560
            let size = preview.imageSize ?? CGSize(width: img.width, height: img.height)
            let h: CGFloat = isCompact ? 176 : w / (Double(size.width) / Double(max(size.height, 1)))
            let picture = PixelImage(img, fit: .cover).frame(width: w, height: h).clipShape(RoundedRectangle(cornerRadius: 4))
            return isCompact ? AnyView(picture.frame(width: iconBox, alignment: .leading).clipped()) : AnyView(picture)
        }
        let noImage = SignalIcon("v3/link/link", size: 48, color: gray90, mask: true)
            .frame(width: 48, height: 48)
            .frame(height: isTiny ? 100 : 176)
            .padding(.leading, isTiny ? 24 : 52).padding(.trailing, isTiny ? 0 : 52)
        Group {
            if !isCompact {
                VStack(alignment: .leading, spacing: 0) {
                    image
                    content.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 0) {
                    if let image { image } else { noImage }
                    content.frame(maxWidth: isTiny ? nil : .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: isTiny ? nil : 560, maxWidth: 560, alignment: .leading)
        .fixedSize(horizontal: isTiny, vertical: true)
        .frame(maxHeight: 560 / (2.0 / 3.0), alignment: .top)     // no taller than 2:3
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 36).fill(Color(rgba: LegacyColor.white)))
        .clipShape(RoundedRectangle(cornerRadius: 36))
    }

    static var descriptionStyle: CSSTextStyle { CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 26, lineHeight: 36, letterSpacing: -0.06) }
    static var locationStyle: CSSTextStyle { CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 22, lineHeight: 28, letterSpacing: 0.12) }
    static var titleStyle: CSSTextStyle { CSSTextStyle(fontName: AxoFonts.interName(weight: 600), size: 28, lineHeight: 40, letterSpacing: -0.16) }

    /// lodash `unescape`: the five HTML entities.
    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }
}

extension CSSTextStyle {
    /// CSS `line-height: normal` as Chromium computes it: the font's ascent, descent and line
    /// gap, each rounded.
    public static func normalLineHeight(fontName: String, size: CGFloat) -> CGFloat {
        AxoFonts.register()
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        return CTFontGetAscent(font).rounded() + CTFontGetDescent(font).rounded() + CTFontGetLeading(font).rounded()
    }
}
