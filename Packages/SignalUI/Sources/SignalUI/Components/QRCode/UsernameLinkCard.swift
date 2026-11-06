// The username link card saved from the QR code page (UsernameLinkEditor `_generateImageBlob`):
// a 424×576 card in the colour's tint, the rounded pill with the branded QR code on white,
// the username (600 20/26px, wrapped by grapheme at 222px) and the hint (14/17px, wrapped by
// word at 296px) below; drawn at 3x and saved as a 300 dpi PNG.

import CodecCore
import EncodePNG
import SignalI18n
import SwiftUI

public enum UsernameLinkCard {
    static let width: CGFloat = 424, height: CGFloat = 576
    static let pixelRatio: CGFloat = 3
    static let qrSize: CGFloat = 184
    static let dpi = 300
    static let pillWidth: CGFloat = 296, pillHeight: CGFloat = 324
    static let usernameTop: CGFloat = 352, usernameMaxWidth: CGFloat = 222, usernameLineHeight: CGFloat = 26
    static let hintTop: CGFloat = 447, hintMaxWidth: CGFloat = 296, hintLineHeight: CGFloat = 17

    static var usernameStyle: CSSTextStyle {
        CSSTextStyle(fontName: AxoFonts.interName(weight: 600), size: 20, lineHeight: usernameLineHeight, letterSpacing: -0.34)
    }
    static var hintStyle: CSSTextStyle { CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 14, lineHeight: hintLineHeight) }

    static func width(_ text: String, _ style: CSSTextStyle) -> CGFloat {
        CSSTextLayout.make(runs: [CSSTextRun(text)], style, wrap: .nowrap, maxWidth: nil, colors: nil).width
    }

    /// `splitText`: lines no wider than `maxWidth`, broken between graphemes or before words.
    static func split(_ text: String, words: Bool, maxWidth: CGFloat, style: CSSTextStyle) -> [String] {
        var segments: [(String, wordLike: Bool)] = []
        if words {
            var current = "", isSpace: Bool?
            for ch in text {
                let space = ch.isWhitespace || ch.isPunctuation
                if let s = isSpace, s != space { segments.append((current, !s)); current = "" }
                current.append(ch)
                isSpace = space
            }
            if !current.isEmpty { segments.append((current, !(isSpace ?? false))) }
        } else {
            segments = text.map { (String($0), true) }
        }
        var result: [String] = [], acc = "", best = ""
        for (segment, wordLike) in segments {
            acc += segment
            if !wordLike { best = acc; continue }
            let probe = words ? acc.trimmingCharacters(in: .whitespaces) : acc
            if width(probe, style) > maxWidth {
                result.append(best)
                acc = String(acc.dropFirst(best.count))
                best = acc
            } else {
                best = acc
            }
        }
        if !best.isEmpty { result.append(best) }
        return words ? result.map { $0.trimmingCharacters(in: .whitespaces) } : result
    }

    struct Card: View {
        let link: String
        let usernameLines: [String]
        let hintLines: [String]
        let color: UsernameLinkColor
        let hintDirection: SwiftUI.LayoutDirection

        var body: some View {
            let c = color.colors
            let white = color == .white
            let extra = CGFloat(usernameLines.count - 1) * UsernameLinkCard.usernameLineHeight
            ZStack(alignment: .topLeading) {
                Color(rgba: c.tint)
                RoundedRectangle(cornerRadius: 32).fill(Color(rgba: c.bg))
                    .frame(width: pillWidth, height: pillHeight + extra)
                    .offset(x: 64, y: 80)
                RoundedRectangle(cornerRadius: 12).fill(Color.white)
                    .overlay { if white { RoundedRectangle(cornerRadius: 12).strokeBorder(Color(rgba: RGBA(hex: 0xE9E9E9)), lineWidth: 2) } }
                    .frame(width: 216, height: 216)
                    .offset(x: 104, y: 112)
                BrandedQRCode(size: qrSize, link: link, color: Color(rgba: c.fg))
                    .frame(width: qrSize, height: qrSize)
                    .offset(x: 120, y: 128)
                // fillText at textBaseline 'top' (the em box's top): the line box starts half
                // its leading above it.
                lines(usernameLines, style: usernameStyle, top: usernameTop, color: white ? RGBA(0, 0, 0) : RGBA(1, 1, 1))
                lines(hintLines, style: hintStyle, top: hintTop + extra, color: RGBA(60 / 255, 60 / 255, 69 / 255, 0.7))
                    .environment(\.layoutDirection, hintDirection)
            }
            .frame(width: UsernameLinkCard.width, height: UsernameLinkCard.height, alignment: .topLeading)
            .environment(\.colorScheme, .light)
        }

        func lines(_ lines: [String], style: CSSTextStyle, top: CGFloat, color: RGBA) -> some View {
            let halfLeading = (style.lineHeight - style.size) / 2
            return VStack(spacing: 0) {
                ForEach(lines.indices, id: \.self) { i in
                    CSSText(lines[i], style: style, wrap: .nowrap, alignment: .center, color: AxoColor(color))
                        .frame(width: UsernameLinkCard.width, height: style.lineHeight)
                }
            }
            .offset(y: top - halfLeading)
        }
    }

    /// The card as PNG bytes (nil if it can't be drawn).
    @MainActor
    public static func png(link: String, username: String, color: UsernameLinkColor, i18n: Localizer) -> [UInt8]? {
        let usernameLines = split(username, words: false, maxWidth: usernameMaxWidth, style: usernameStyle)
        let hintLines = split(i18n("icu:UsernameLinkModalBody__hint"), words: true, maxWidth: hintMaxWidth, style: hintStyle)
        let card = Card(link: link, usernameLines: usernameLines, hintLines: hintLines, color: color,
                        hintDirection: i18n.direction == .rightToLeft ? .rightToLeft : .leftToRight)
        let renderer = ImageRenderer(content: card)
        renderer.scale = pixelRatio
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        guard let cg = renderer.cgImage, let pixels = MediaEditorExport.pixels(cg) else { return nil }
        return PNGEncoder.encode(pixels, dotsPerInch: dpi)
    }

    /// `saveAttachmentToDisk` name.
    public static let fileName = "signal-username-qr-code.png"
}
