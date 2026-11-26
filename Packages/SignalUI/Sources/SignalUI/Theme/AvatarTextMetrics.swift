#if os(Linux)
@_spi(Qt) import SwiftUI
#else
import CoreText
import SwiftUI
#endif

/// The text entry fits by typographic advance. Preset avatars fit by the visible glyph bounds.
enum AvatarTextMetrics {
    static func fittedSize(_ text: String, canvas: CGFloat, ink: Bool) -> CGFloat {
        let diameter = (canvas * 0.75).rounded(.up)
        let emoji = text.count == 1 && text.first.map(CSSTextLayout.isEmoji) == true
        var size = (canvas * (emoji ? 0.6 : 0.45)).rounded(.up)
        let minimum = (canvas * 0.05).rounded(.up)
        let family = AxoFonts.interName(weight: 400)
        AxoFonts.register()
        while size >= minimum {
            let bounds: CGSize
            #if os(Linux)
            if ink {
                bounds = QtFontDatabase.inkSize(of: text, family: family, size: size)
            } else {
                let advance = QtTextLayout.lines(in: AttributedString(text), font: .custom(family, fixedSize: size)).first?.advance ?? 0
                bounds = CGSize(width: advance, height: 20)
            }
            #else
            let font = CTFontCreateWithName(family as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            bounds = ink ? CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).size
                         : CGSize(width: CTLineGetTypographicBounds(line, nil, nil, nil), height: 20)
            #endif
            if bounds.width < diameter && bounds.height < diameter { break }
            size -= 1
        }
        return size
    }

    static func inputHeight(fontName: String, size: CGFloat) -> CGFloat {
        #if os(Linux)
        let metrics = QtFontDatabase.metrics(family: fontName, size: size)
        return max(20, metrics.ascent.rounded() + metrics.descent.rounded())
        #else
        AxoFonts.register()
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        return max(20, CTFontGetAscent(font).rounded() + CTFontGetDescent(font).rounded())
        #endif
    }
}
