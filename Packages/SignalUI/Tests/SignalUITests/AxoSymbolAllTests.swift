// AxoSymbol.dom.stories.tsx `All`: the sticky search box over a 4-column grid of every symbol
// (lg:grid-cols-4, gap 16), each a bordered card with its LTR (and RTL, when different)
// glyph at 20px, the code points and the name. The order is the story's localeCompare sort,
// read from the capture.

import SwiftUI
import Testing
@testable import SignalUI

struct AxoSymbolInfoCard: View {
    let name: String

    static func codePoints(_ s: String) -> String {
        s.unicodeScalars.map { "U+" + String($0.value, radix: 16, uppercase: true) }.joined(separator: " ")
    }

    func variant(_ title: String, rtl: Bool) -> some View {
        VStack(spacing: 8) {
            CSSText(title, type: .caption, wrap: .nowrap, color: .labelSecondary)
            AxoSymbol.InlineGlyph(name, size: 20, weight: 400).environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                .cssTextColor(.labelPrimary)
            CSSText(Self.codePoints(String(AxoSymbol.inlineGlyph(name, rtl: rtl))), style: .mono(size: 11, lineHeight: 14, letterSpacing: 0.055),
                    wrap: .nowrap, color: .labelSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        let same = AxoSymbol.inlineGlyph(name, rtl: false) == AxoSymbol.inlineGlyph(name, rtl: true)
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                if same { variant("LTR/RTL", rtl: false) } else { variant("LTR", rtl: false); variant("RTL", rtl: true) }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            // figcaption: border-t border-dotted, pt-4, the name in text-accent
            CSSText(name, style: .mono(size: 13, lineHeight: 18, letterSpacing: -0.039), wrap: .truncate, color: .labelAccent)
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
                .overlay(alignment: .top) {
                    Path { p in p.move(to: CGPoint(x: 0, y: 0.5)); p.addLine(to: CGPoint(x: 246, y: 0.5)) }
                        .stroke(AxoColor.borderPrimary, style: StrokeStyle(lineWidth: 1, dash: [1, 1]))
                        .frame(height: 1)
                }
                .padding(.top, 1)
        }
        .padding(16)
        .padding(1)
        .frame(width: 280)
        .frame(maxHeight: .infinity)
        .background(AxoColor.surfaceSecondary)
        .overlay(Rectangle().strokeBorder(AxoColor.borderPrimary, lineWidth: 1))
    }
}

@MainActor
@Suite struct AxoSymbolAllTests {
    @Test(arguments: ["light", "dark"])
    func all(theme: String) throws {
        let id = "axo-axosymbol--all"
        let names = StoryDOM(id, theme: theme).nodes.filter { $0.tag == "code" && $0.text != nil && !$0.text!.hasPrefix("U+") }.map { $0.text! }
        #expect(names.count == AxoSymbolDefs.allNames.count)
        let rows = stride(from: 0, to: names.count, by: 4).map { Array(names[$0..<min($0 + 4, names.count)]) }
        let view = VStack(alignment: .leading, spacing: 0) {
            // sticky top-4 mb-3 bg-material-primary p-4 shadow-elevation-2
            CSSText("Search...", type: .bodyMedium, wrap: .nowrap, color: .labelPrimary).opacity(0.5)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(AxoColor.materialSecondary, in: RoundedRectangle(cornerRadius: 4))
                .padding(16)
                .background(AxoColor.materialPrimary)
                .axoShadow(.shadowElevation2, in: Rectangle())
                .padding(.bottom, 12)
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
                ForEach(rows.indices, id: \.self) { r in
                    GridRow { ForEach(rows[r], id: \.self) { AxoSymbolInfoCard(name: $0) } }
                }
            }
        }
        .frame(width: 1168, alignment: .topLeading)
        try Snapshot.assertMatches(SmallComponentStoriesTests.top(view), story: id, theme: theme)
    }
}
