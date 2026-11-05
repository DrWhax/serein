// An inline `.axo-symbol-glyph` in a line of text, as CSS lays it out: the glyph inherits
// the surrounding font size, weight and letter-spacing, its own box is line-height 1, and
// it sits on the baseline of the surrounding line box (line-height of the text around it).
// Used by AxoOutgoingStatus / AxoExpireTimer, whose glyphs flow with caption or body text.

import CoreText
import SwiftUI

enum AxoInlineText {
    /// Distance from the top of a line box to its baseline, placed like Blink (and CSSText):
    /// ascent and descent rounded to whole pixels, the top half-leading floored.
    static func baseline(_ style: CSSTextStyle) -> CGFloat {
        let font = style.ctFont
        let a = CTFontGetAscent(font).rounded(), d = CTFontGetDescent(font).rounded()
        return ((style.lineHeight - (a + d)) / 2).rounded(.down) + a
    }
}

struct AxoInlineGlyphLine: View {
    let glyph: Character
    /// The surrounding text (font size, weight, letter-spacing, line-height).
    let type: AxoType

    var glyphStyle: CSSTextStyle {
        CSSTextStyle(fontName: "SignalSymbols-Thin", size: type.size, lineHeight: type.size, letterSpacing: type.tracking * type.size,
                     variationWeight: Double(min(600, max(200, type.weight))))
    }

    var body: some View {
        let style = glyphStyle
        let offset = AxoInlineText.baseline(CSSTextStyle(type)) - AxoInlineText.baseline(style)
        CSSText(String(glyph), style: style, wrap: .nowrap)
            .padding(.top, offset)
            .frame(height: type.lineHeight, alignment: .top)
            .accessibilityHidden(true)
    }
}
