// Mixed inline content laid out as one CSS paragraph: text runs, inline symbol glyphs and
// inline buttons (atomic, `dir="auto"` → a bidi isolate) share line boxes, wrap together,
// are aligned per line and clamped to N lines with an ellipsis (`line-clamp`). Drawn with
// CoreText like CSSText; inline buttons are hit-tested by string index.

import CoreText
import SwiftUI

/// One piece of inline content.
public enum AxoInlinePiece: Sendable {
    case text(String)
    /// Text in another weight and/or colour (an inline `<span class="font-semibold text-primary">`).
    case styled(String, weight: Int, color: RGBA?)
    /// A symbol glyph in the surrounding font size and weight.
    case glyph(Character)
    /// An inline button (`id` is reported to `onAction`).
    case action(String, id: Int)
}

struct AxoInlineFlowLayout {
    var lines: [CTLine]
    var widths: [CGFloat]
    var ranges: [CFRange]
    var lineHeight: CGFloat
    var baseline: CGFloat
    var actionRanges: [(id: Int, range: NSRange)]
    /// With line-clamp, the next line as wrapped: Chromium lays it out under the clamp, and
    /// overflow is clipped at the padding box, so a little of it shows in the padding.
    var overflow: (line: CTLine, width: CGFloat)?

    var width: CGFloat { widths.max() ?? 0 }
    var height: CGFloat { CGFloat(lines.count) * lineHeight }

    /// Font + CSS letter-spacing as CoreText tracking (keeps the font's kerning), like CSSText.
    static func attributes(_ font: CTFont, _ style: CSSTextStyle) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        if style.letterSpacing != 0 { a[NSAttributedString.Key(kCTTrackingAttributeName as String)] = style.letterSpacing }
        return a
    }

    static func attributed(_ pieces: [AxoInlinePiece], _ style: CSSTextStyle, rtl: Bool) -> (NSAttributedString, [(Int, NSRange)]) {
        let textFont = style.ctFont
        let glyphFont = CSSTextStyle(fontName: "SignalSymbols-Thin", size: style.size, lineHeight: style.size, letterSpacing: style.letterSpacing,
                                     variationWeight: 400).ctFont
        let out = NSMutableAttributedString()
        var actions: [(Int, NSRange)] = []
        func append(_ s: String, _ font: CTFont) {
            out.append(NSAttributedString(string: s, attributes: attributes(font, style)))
        }
        // The paragraph's base direction (UBA P2: its first strong character): RLM / LRM.
        append(rtl ? "\u{200F}" : "\u{200E}", textFont)
        for p in pieces {
            switch p {
            case .text(let s):
                // Emoji as FunInlineEmoji boxes (Emojify), as in CSSText.
                var plain = ""
                for ch in s {
                    if CSSTextLayout.isEmoji(ch) {
                        if !plain.isEmpty { append(plain, textFont); plain = "" }
                        out.append(CSSTextLayout.emojiPiece(String(ch), style, attributes(textFont, style)))
                    } else {
                        plain.append(ch)
                    }
                }
                if !plain.isEmpty { append(plain, textFont) }
            case .styled(let s, let weight, let color):
                var st = style
                st.fontName = AxoFonts.interName(weight: weight)
                var a = attributes(st.ctFont, style)
                if let color {
                    a[NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)] = nil
                    a[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a)
                }
                out.append(NSAttributedString(string: s, attributes: a))
            case .glyph(let g): append(String(g), glyphFont)
            case .action(let s, let id):
                // An atomic inline (no breaks inside), its own bidi isolate (dir="auto": FSI … PDI).
                let start = out.length
                append("\u{2068}" + s.replacingOccurrences(of: " ", with: "\u{00A0}") + "\u{2069}", textFont)
                actions.append((id, NSRange(location: start, length: out.length - start)))
            }
        }
        return (out, actions)
    }

    static func make(_ pieces: [AxoInlinePiece], _ style: CSSTextStyle, maxWidth: CGFloat?, maxLines: Int?, rtl: Bool) -> AxoInlineFlowLayout {
        let (text, actions) = attributed(pieces, style, rtl: rtl)
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        let length = text.length
        var lines: [CTLine] = [], ranges: [CFRange] = []
        var alignWidths: [Int: CGFloat] = [:]
        var start = 0
        var overflow: (line: CTLine, width: CGFloat)?
        while start < length {
            let count = maxWidth.map { CTTypesetterSuggestLineBreak(typesetter, start, Double($0) + 0.6) } ?? (length - start)
            let n = max(1, count)
            if let maxLines, lines.count == maxLines - 1, start + n < length, let maxWidth {
                // line-clamp: the last allowed line as wrapped, with an ellipsis after it
                // (cutting the line further only if the ellipsis does not fit).
                let range = NSRange(location: start, length: n)
                let clamped = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
                let token = NSAttributedString(string: "\u{2026}", attributes: attributes(style.ctFont, style))
                // Trailing spaces collapse before the ellipsis.
                while clamped.length > 0, clamped.string.last == " " { clamped.deleteCharacters(in: NSRange(location: clamped.length - 1, length: 1)) }
                let plain = CTLineCreateWithAttributedString(clamped)
                // Chromium aligns the line as wrapped; the ellipsis hangs after it, replacing
                // trailing graphemes until it fits.
                alignWidths[lines.count] = CGFloat(CTLineGetTypographicBounds(plain, nil, nil, nil))
                var withEllipsis: CTLine
                while true {
                    let candidate = NSMutableAttributedString(attributedString: clamped)
                    candidate.append(token)
                    withEllipsis = CTLineCreateWithAttributedString(candidate)
                    if CGFloat(CTLineGetTypographicBounds(withEllipsis, nil, nil, nil)) <= maxWidth + 0.6 || clamped.length == 0 { break }
                    let last = (clamped.string as NSString).rangeOfComposedCharacterSequence(at: clamped.length - 1)
                    clamped.deleteCharacters(in: last)
                }
                lines.append(withEllipsis)
                ranges.append(CFRange(location: start, length: length - start))
                let next = start + n
                let nextCount = max(1, CTTypesetterSuggestLineBreak(typesetter, next, Double(maxWidth) + 0.6))
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: next, length: nextCount))
                overflow = (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line)))
                break
            }
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: n)))
            ranges.append(CFRange(location: start, length: n))
            start += n
        }
        let widths = lines.enumerated().map { i, l in
            alignWidths[i] ?? (CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(l)))
        }
        return AxoInlineFlowLayout(lines: lines, widths: widths, ranges: ranges, lineHeight: style.lineHeight,
                                   baseline: AxoInlineText.baseline(style), actionRanges: actions, overflow: overflow)
    }

    func lineOrigin(_ i: Int, width: CGFloat, alignment: CSSTextAlign, rtl: Bool) -> CGFloat {
        Self.origin(lineWidth: widths[i], width: width, alignment: alignment, rtl: rtl)
    }

    static func origin(lineWidth: CGFloat, width: CGFloat, alignment: CSSTextAlign, rtl: Bool) -> CGFloat {
        switch alignment {
        case .center: (width - lineWidth) / 2
        case .start: rtl ? width - lineWidth : 0
        case .end: rtl ? 0 : width - lineWidth
        }
    }

    func draw(in context: CGContext, width: CGFloat, alignment: CSSTextAlign, rtl: Bool, color: CGColor) {
        context.setFillColor(color)
        context.textMatrix = .identity
        var placed = lines.enumerated().map { i, line in (line, lineOrigin(i, width: width, alignment: alignment, rtl: rtl)) }
        if let overflow { placed.append((overflow.line, Self.origin(lineWidth: overflow.width, width: width, alignment: alignment, rtl: rtl))) }
        for (i, (line, x)) in placed.enumerated() {
            context.saveGState()
            context.translateBy(x: x, y: CGFloat(i) * lineHeight + baseline)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CSSTextLayout.drawLine(line, context: context, color: color)
            context.restoreGState()
        }
    }

    /// The inline action under a point, if any.
    func action(at point: CGPoint, width: CGFloat, alignment: CSSTextAlign, rtl: Bool) -> Int? {
        let i = Int((point.y / lineHeight).rounded(.down))
        guard i >= 0, i < lines.count else { return nil }
        let x = point.x - lineOrigin(i, width: width, alignment: alignment, rtl: rtl)
        guard x >= 0, x <= widths[i] else { return nil }
        let index = CTLineGetStringIndexForPosition(lines[i], CGPoint(x: x, y: 0))
        return actionRanges.first { NSLocationInRange(index, $0.range) || index == NSMaxRange($0.range) - 1 }?.id
    }
}

/// Sizes itself like a block of text: as wide as its widest line (at most the proposal).
struct AxoInlineFlowFrame: Layout {
    let pieces: [AxoInlinePiece]
    let style: CSSTextStyle
    let maxLines: Int?
    let rtl: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = AxoInlineFlowLayout.make(pieces, style, maxWidth: nil, maxLines: nil, rtl: rtl)
        let maxWidth = proposal.width.map { min($0, natural.width) }
        let layout = AxoInlineFlowLayout.make(pieces, style, maxWidth: maxWidth, maxLines: maxLines, rtl: rtl)
        return CGSize(width: min(proposal.width ?? natural.width, max(layout.width, maxWidth ?? natural.width)), height: layout.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews { s.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}

/// Inline content as a paragraph (colour: the inherited `cssTextColor`).
struct AxoInlineFlowText: View {
    let pieces: [AxoInlinePiece]
    let style: CSSTextStyle
    let alignment: CSSTextAlign
    let maxLines: Int?
    /// Padding inside the clamp's overflow clip (`py-1 -my-1`): the next line shows that far.
    var clampOverflow: CGFloat = 0
    let onAction: (Int) -> Void
    @Environment(\.colorScheme) var scheme
    @Environment(\.cssTextColor) var color
    @Environment(\.layoutDirection) var direction
    @State private var drawnWidth: CGFloat = 0

    var plainText: String {
        pieces.map {
            switch $0 {
            case .text(let s), .action(let s, _), .styled(let s, _, _): s
            case .glyph: ""
            }
        }.joined()
    }

    var body: some View {
        let rtl = direction == .rightToLeft
        let rgba = color.value(for: scheme)
        AxoInlineFlowFrame(pieces: pieces, style: style, maxLines: maxLines, rtl: rtl) {
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                // +1pt: the frame may be a fraction under the widest line (pixel rounding).
                let layout = AxoInlineFlowLayout.make(pieces, style, maxWidth: size.width + 1, maxLines: maxLines, rtl: rtl)
                context.withCGContext { cg in
                    cg.translateBy(x: 0, y: clampOverflow)
                    layout.draw(in: cg, width: size.width, alignment: alignment, rtl: rtl,
                                color: CGColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a))
                }
            }
            .padding(.vertical, -clampOverflow)
            .clipped()
            .environment(\.layoutDirection, .leftToRight)   // CoreText already ordered the runs
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { drawnWidth = $0 }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { tap in
            let layout = AxoInlineFlowLayout.make(pieces, style, maxWidth: drawnWidth + 1, maxLines: maxLines, rtl: rtl)
            if let id = layout.action(at: tap.location, width: drawnWidth, alignment: alignment, rtl: rtl) { onAction(id) }
        })
        .accessibilityElement()
        .accessibilityLabel(plainText)
        .accessibilityActions {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, p in
                if case .action(let label, let id) = p {
                    Button(label) { onAction(id) }
                }
            }
        }
    }
}
