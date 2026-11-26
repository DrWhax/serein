#if canImport(CoreText)
import CoreText
import SwiftUI

/// Centred caption text clamped to `maxLines` (`line-clamp-N text-center wrap-break-word`):
/// words wrap, an over-long word breaks anywhere, and the last visible line ends in "…" when
/// text remains.
struct LineClampText: View {
    let string: String
    let style: CSSTextStyle
    let maxLines: Int
    @Environment(\.colorScheme) var scheme
    @Environment(\.cssTextColor) var color

    init(_ string: String, style: CSSTextStyle, maxLines: Int) {
        self.string = string
        self.style = style
        self.maxLines = maxLines
    }

    var body: some View {
        let rgba = color.value(for: scheme)
        LineClampFrame(string: string, style: style, maxLines: maxLines) {
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                let layout = LineClampLayout.make(string, style, maxLines: maxLines, width: size.width)
                context.withCGContext { cg in
                    layout.draw(in: cg, width: size.width, color: CGColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(string)
    }
}

struct LineClampLayout {
    var lines: [CTLine]
    /// Widths used to centre each line: a "…" appended to a line that has room for it
    /// hangs past the centred content, as in Chromium.
    var widths: [CGFloat]
    var ascent: CGFloat
    var descent: CGFloat
    var lineHeight: CGFloat
    var height: CGFloat { CGFloat(lines.count) * lineHeight }

    static func attributes(_ font: CTFont, _ style: CSSTextStyle) -> [NSAttributedString.Key: Any] {
        [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): style.letterSpacing,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
    }

    static func width(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
    }

    static func make(_ string: String, _ style: CSSTextStyle, maxLines: Int, width: CGFloat?) -> LineClampLayout {
        let font = style.ctFont
        let attrs = attributes(font, style)
        let attributed = NSAttributedString(string: string, attributes: attrs)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = attributed.length
        var lines: [CTLine] = []
        var widths: [CGFloat] = []
        var start = 0
        while start < length && lines.count < maxLines {
            let count = width.map { CTTypesetterSuggestLineBreak(typesetter, start, Double($0) + 0.01) } ?? (length - start)
            let n = max(1, count)
            let isLast = lines.count == maxLines - 1 && start + n < length
            if isLast, let width {
                let text = (attributed.string as NSString).substring(with: NSRange(location: start, length: n))
                    .trimmingCharacters(in: .whitespaces)
                let withEllipsis = CTLineCreateWithAttributedString(NSAttributedString(string: text + "\u{2026}", attributes: attrs))
                let plain = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
                if Self.width(withEllipsis) <= width + 0.01 {
                    lines.append(withEllipsis)
                    widths.append(Self.width(plain))
                } else {
                    // No room for "…" after the line: cut the rest of the text where "…" fits.
                    let rest = CTLineCreateWithAttributedString(attributed.attributedSubstring(from: NSRange(location: start, length: length - start)))
                    let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: attrs))
                    let truncated = CTLineCreateTruncatedLine(rest, Double(width), .end, ellipsis) ?? plain
                    lines.append(truncated)
                    widths.append(Self.width(truncated))
                }
            } else {
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: n))
                lines.append(line)
                widths.append(Self.width(line))
            }
            start += n
        }
        return LineClampLayout(lines: lines, widths: widths, ascent: CTFontGetAscent(font), descent: CTFontGetDescent(font),
                               lineHeight: style.lineHeight)
    }

    func draw(in context: CGContext, width: CGFloat, color: CGColor) {
        context.setFillColor(color)
        context.textMatrix = .identity
        let halfLeading = (lineHeight - (ascent + descent)) / 2
        for (i, line) in lines.enumerated() {
            let baseline = CGFloat(i) * lineHeight + halfLeading + ascent
            context.saveGState()
            context.translateBy(x: (width - widths[i]) / 2, y: baseline)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }
}

struct LineClampFrame: Layout {
    let string: String
    let style: CSSTextStyle
    let maxLines: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let layout = LineClampLayout.make(string, style, maxLines: maxLines, width: proposal.width)
        return CGSize(width: proposal.width ?? (layout.widths.max() ?? 0), height: layout.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews { s.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}
#endif
