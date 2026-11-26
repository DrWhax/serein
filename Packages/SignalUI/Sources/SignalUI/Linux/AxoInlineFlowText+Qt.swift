#if os(Linux)
import SwiftUI

struct AxoInlineFlowText: View {
    let pieces: [AxoInlinePiece]
    let style: CSSTextStyle
    let alignment: CSSTextAlign
    let maxLines: Int?
    var clampOverflow: CGFloat = 0
    let onAction: (Int) -> Void
    @Environment(\.layoutDirection) var direction

    private var runs: [CSSTextRun] {
        var result = [CSSTextRun(direction == .rightToLeft ? "\u{200F}" : "\u{200E}")]
        for piece in pieces {
            switch piece {
            case .text(let text):
                var run = CSSTextRun(text)
                run.emojify = true
                result.append(run)
            case .styled(let text, let weight, let color):
                result.append(CSSTextRun(text, fontName: AxoFonts.interName(weight: weight), color: color.map { AxoColor($0) }))
            case .glyph(let glyph):
                result.append(CSSTextRun(String(glyph), fontName: "SignalSymbols-Thin"))
            case .action(let text, let id):
                let unbroken = text.replacingOccurrences(of: " ", with: "\u{00A0}")
                result.append(CSSTextRun("\u{2068}\(unbroken)\u{2069}", action: String(id)))
            }
        }
        return result
    }

    var body: some View {
        CSSText(runs: runs, style: style, wrap: maxLines.map(CSSTextWrap.clamp) ?? .wrap, alignment: alignment) { value in
            if let id = Int(value) { onAction(id) }
        }
        .modifier(AxoInlineAccessibility(pieces: pieces, onAction: onAction))
    }
}
#endif
