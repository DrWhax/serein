#if os(Linux)
@_spi(Qt) import SwiftUI

extension CSSTextStyle {
    func font(face: String? = nil, size override: CGFloat? = nil) -> Font {
        let family = face ?? fontName
        if family == fontName, let variationWeight {
            return QtFontDatabase.font(family: family, size: override ?? size, weight: Int(variationWeight))
        }
        return .custom(family, fixedSize: override ?? size)
    }
}

private extension CSSTextRun {
    /// The same character runs are used for measuring, painting, native selection and link hit testing.
    func attributed(style: CSSTextStyle, scheme: ColorScheme?, index: Int) -> AttributedString {
        var span = AttributedString(text)
        span.font = style.font(face: fontName)
        if let scheme {
            if let color { span.foregroundColor = color.value(for: scheme).color }
            if let background = inlineBlock?.background ?? background { span.backgroundColor = background.value(for: scheme).color }
            if underline { span.underlineStyle = .single }
            if strikethrough { span.strikethroughStyle = .single }
            if action != nil { span.link = URL(string: "serein-text-action://run/\(index)") }
        }
        if emojify {
            var start = span.startIndex
            for character in text {
                let end = span.characters.index(after: start)
                if CSSTextLayout.isEmoji(character) {
                    span[start..<end].font = style.font(face: "SignalEmojiLarge", size: emojiSize ?? (style.size * 1.4).rounded())
                }
                start = end
            }
        }
        return span
    }
}

struct CSSTextLayout {
    typealias Line = QtTextLayout.Line
    static let widthTolerance: CGFloat = 0.6
    static let exactWidthTolerance: CGFloat = 1.0 / 64
    var lines: [Line]
    var height: CGFloat
    var widths: [CGFloat] { lines.map(\.width) }
    var width: CGFloat { widths.max() ?? 0 }
    var isEmpty: Bool { lines.isEmpty }

    static func isEmoji(_ ch: Character) -> Bool {
        guard ch.unicodeScalars.contains(where: { $0.value > 0x7F }) || ch.unicodeScalars.count > 1 else { return false }
        return EmojiData.shared.isEmoji(String(ch))
    }

    static func minContentWidth(_ string: String, _ style: CSSTextStyle) -> CGFloat {
        make(string, style, wrap: .wrap, maxWidth: 0).width
    }
    static func ch(_ style: CSSTextStyle) -> CGFloat { make("0", style, wrap: .nowrap, maxWidth: nil).width - style.letterSpacing }
    static func make(_ string: String, _ style: CSSTextStyle, wrap: CSSTextWrap, maxWidth: CGFloat?) -> Self {
        make(runs: [CSSTextRun(string)], style, wrap: wrap, maxWidth: maxWidth, colors: nil)
    }

    static func make(runs: [CSSTextRun], _ style: CSSTextStyle, wrap: CSSTextWrap, maxWidth: CGFloat?,
                     colors: ((AxoColor) -> Color)?, tolerance: CGFloat = widthTolerance) -> Self {
        AxoFonts.register()
        let text = runs.enumerated().reduce(into: AttributedString()) {
            $0 += $1.element.attributed(style: style, scheme: nil, index: $1.offset)
        }
        func measure(_ width: CGFloat?) -> [Line] {
            QtTextLayout.lines(in: text, font: style.font(), tracking: style.letterSpacing, width: width,
                               breaksLongWords: style.breakWord || runs.contains(where: \.breakAll))
        }
        var lines = measure(wrap == .nowrap ? nil : maxWidth.map { max(0, $0 + tolerance) })
        switch wrap {
        case .truncate: lines = Array(lines.prefix(1))
        case .clamp(let count): lines = Array(lines.prefix(max(1, count)))
        case .balance:
            if let maxWidth, lines.count > 1 {
                var lower: CGFloat = 0, upper = maxWidth
                let count = lines.count
                while upper - lower >= 0.5 {
                    let trial = (lower + upper) / 2
                    let candidate = measure(trial)
                    if candidate.count <= count { lines = candidate; upper = trial } else { lower = trial }
                }
            }
        default: break
        }
        var boxes: [(range: NSRange, height: CGFloat, border: CGFloat)] = []
        var offset = 0
        for run in runs {
            let length = run.text.utf16.count
            if let box = run.inlineBlock {
                boxes.append((NSRange(location: offset, length: length), 0, box.border))
            }
            if run.emojify {
                var start = offset
                for character in run.text {
                    let count = character.utf16.count
                    if isEmoji(character) {
                        boxes.append((NSRange(location: start, length: count), (run.emojiSize ?? (style.size * 1.4).rounded()) + (run.emojiTopMargin ?? 0), 0))
                    }
                    start += count
                }
            }
            offset += length
        }
        let height = lines.reduce(CGFloat(0)) { total, line in
            var tallest: CGFloat = 0, border: CGFloat = 0
            for box in boxes where NSIntersectionRange(box.range, line.range).length > 0 {
                tallest = max(tallest, box.height)
                border = max(border, box.border)
            }
            return total + max(style.lineHeight + border, tallest) + border
        }
        return Self(lines: lines, height: height)
    }
}

extension CSSText {
    public var body: some View {
        let attributed = runs.enumerated().reduce(into: AttributedString()) {
            var span = $1.element.attributed(style: style, scheme: scheme, index: $1.offset)
            if span.foregroundColor == nil { span.foregroundColor = (color ?? inherited).value(for: scheme).color }
            $0 += span
        }
        let align: TextAlignment = switch alignment { case .start: .leading; case .center: .center; case .end: .trailing }
        let limit: Int? = switch wrap { case .nowrap, .truncate: 1; case .clamp(let n): n; default: nil }
        let metrics = style.fontMetrics
        let leading = max(0, style.lineHeight - metrics.ascent - metrics.descent)
        return CSSTextFrame(runs: runs, style: style, wrap: wrap, exactWrapWidth: envWrapWidth) {
            let label = Text(attributed)
                .font(style.font())
                .tracking(style.letterSpacing)
                .lineSpacing(leading)
                .lineLimit(limit)
                .multilineTextAlignment(align)
                .padding(.vertical, leading / 2)
                .frame(maxWidth: .infinity, alignment: align == .center ? .center : align == .trailing ? .trailing : .leading)
            if selectable { label.textSelection(.enabled) } else { label }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "serein-text-action", url.host == "run",
                  let index = Int(url.lastPathComponent), runs.indices.contains(index),
                  let action = runs[index].action, let onTap else { return .discarded }
            onTap(action)
            return .handled
        })
    }
}
#endif
