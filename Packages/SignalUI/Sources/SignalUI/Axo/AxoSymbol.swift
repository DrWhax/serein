// Port of ts/axo/AxoSymbol.dom.tsx: glyphs of the Signal Symbols icon font.
//   InlineGlyph — text-sized glyph (CSS: font-size and weight inherited, line-height 1)
//   Icon        — square icon of a fixed size (font-regular), centred in a size×size box

import CoreText
import SwiftUI

public enum AxoSymbol {
    public typealias Name = String
    public typealias IconSize = CGFloat   // upstream: 12 | 14 | 16 | 18 | 20 | 24 | 32 | 36 | 48 | 60

    /// `_getAxoSymbolInlineGlyph`
    public static func inlineGlyph(_ name: Name, rtl: Bool = false) -> Character {
        guard let g = (rtl ? AxoSymbolDefs.rtl[name] : nil) ?? AxoSymbolDefs.base[name] else {
            preconditionFailure("Invalid symbol name for inline glyph: \(name)")
        }
        return g
    }

    /// `_getAxoSymbolIcon`
    public static func icon(_ name: Name, rtl: Bool = false) -> Character {
        let g = rtl ? (AxoSymbolDefs.wideRTL[name] ?? AxoSymbolDefs.rtl[name] ?? AxoSymbolDefs.wide[name] ?? AxoSymbolDefs.base[name])
            : (AxoSymbolDefs.wide[name] ?? AxoSymbolDefs.base[name])
        guard let g else { preconditionFailure("Invalid symbol name for icon: \(name)") }
        return g
    }

    /// The variable symbol font at a size and CSS weight (wght axis 200…600).
    public static func font(size: CGFloat, weight: Int) -> Font {
        AxoFonts.register()
        let wght: Int = 0x7767_6874   // 'wght'
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontNameAttribute: "SignalSymbols-Thin",
            kCTFontVariationAttribute: [wght: Double(min(600, max(200, weight)))],
        ] as CFDictionary)
        return Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
    }

    static func style(size: CGFloat, weight: Int) -> CSSTextStyle {
        CSSTextStyle(fontName: "SignalSymbols-Thin", size: size, lineHeight: size, variationWeight: Double(min(600, max(200, weight))))
    }

    /// `<AxoSymbol.InlineGlyph>`: sized by the surrounding type.
    public struct InlineGlyph: View {
        let symbol: Name
        let size: CGFloat
        let weight: Int
        @Environment(\.layoutDirection) var direction

        public init(_ symbol: Name, size: CGFloat, weight: Int) {
            self.symbol = symbol
            self.size = size
            self.weight = weight
        }

        public var body: some View {
            // line-height: 1 → the glyph's line box is exactly `size` tall.
            CSSText(String(AxoSymbol.inlineGlyph(symbol, rtl: direction == .rightToLeft)),
                    style: AxoSymbol.style(size: size, weight: weight), wrap: .nowrap)
                .accessibilityHidden(true)
        }
    }

    /// `<AxoSymbol.Icon>`
    public struct Icon: View {
        let symbol: Name
        let size: IconSize
        let label: String?
        @Environment(\.layoutDirection) var direction

        public init(_ symbol: Name, size: IconSize, label: String?) {
            self.symbol = symbol
            self.size = size
            self.label = label
        }

        public var body: some View {
            CSSText(String(AxoSymbol.icon(symbol, rtl: direction == .rightToLeft)), style: AxoSymbol.style(size: size, weight: 400), wrap: .nowrap)
                .frame(width: size, height: size)
                .accessibilityLabel(label ?? "")
                .accessibilityHidden(label == nil)
        }
    }
}
