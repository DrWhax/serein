// Port of ts/axo/AxoStackedButton.dom.tsx: an icon pill with a caption below it
// (`Root`), and a centred, wrapping row of them (`Row`).

import CoreText
import SwiftUI

public enum AxoStackedButton {
    /// `<AxoStackedButton.Root>`
    public struct Root: View {
        let symbol: AxoSymbol.Name
        let label: String
        let disabled: Bool
        let pending: Bool
        let discouraged: Bool
        let onClick: () -> Void

        public init(symbol: AxoSymbol.Name, label: String, disabled: Bool = false, pending: Bool = false, discouraged: Bool = false,
                    onClick: @escaping () -> Void = {}) {
            self.symbol = symbol
            self.label = label
            self.disabled = disabled
            self.pending = pending
            self.discouraged = discouraged
            self.onClick = onClick
        }

        public var body: some View {
            Button {
                if !disabled && !pending { onClick() }
            } label: {
                // Label is `contain-inline-size`: it never widens the button, which is as wide
                // as the pill (48 + mx-1) and wraps the caption within it.
                StackLayout {
                    Pill(symbol: symbol, pending: pending, dim: disabled || discouraged)
                    LineClampText(label, style: CSSTextStyle(AxoType.caption.weight(500)), maxLines: 2)
                        .cssTextColor(disabled ? .labelDisabled : .labelPrimary)
                }
            }
            .buttonStyle(AxoStackedButtonStyle(interactive: !(disabled || pending)))
            .accessibilityLabel(label)
            .accessibilityHint(pending ? "Pending" : "")
        }
    }

    /// `relative mx-1 px-3.75 py-2.25 rounded-full bg-primary` around an 18px icon.
    struct Pill: View {
        let symbol: AxoSymbol.Name
        let pending: Bool
        let dim: Bool
        @Environment(\.axoStackedButtonPressed) var pressed

        var body: some View {
            AxoSymbol.Icon(symbol, size: 18, label: nil)
                .opacity(pending ? 0 : 1)
                .cssTextColor(dim ? .labelDisabled : .labelPrimary)
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background(Capsule().fill(pressed ? AxoColor.fillPrimaryPressed : AxoColor.fillPrimary))
                .overlay {
                    if pending { Spinner() }
                }
                .padding(.horizontal, 4)
        }
    }

    /// `AxoStackedButton.Spinner` (internal)
    struct Spinner: View {
        var body: some View {
            AxoBaseSpinner.Root(size: 18, weight: .regular, variant: .default, value: .indeterminate, track: false)
                .accessibilityHidden(true)
        }
    }

    /// `inline-flex flex-col items-center gap-1.5`: the width is the pill's; the caption takes it.
    struct StackLayout: Layout {
        static let gap: CGFloat = 6

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard subviews.count == 2 else { return .zero }
            let pill = subviews[0].sizeThatFits(.unspecified)
            let width = min(pill.width, proposal.width ?? pill.width)
            let text = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
            return CGSize(width: width, height: pill.height + Self.gap + text.height)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            guard subviews.count == 2 else { return }
            let pill = subviews[0].sizeThatFits(.unspecified)
            subviews[0].place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: ProposedViewSize(pill))
            let text = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + pill.height + Self.gap),
                              proposal: ProposedViewSize(width: bounds.width, height: text.height))
        }
    }

    public enum RowSpacing: Sendable { case md }

    /// `<AxoStackedButton.Row>`: `flex w-full flex-wrap items-start justify-center gap-x-1
    /// gap-y-3 px-[2.5px] pt-[2.5px]`; once the buttons no longer fit on one line
    /// (`FlexWrapDetector`), every one takes the full width.
    public struct Row<Content: View>: View {
        let spacing: RowSpacing
        let content: Content

        public init(spacing: RowSpacing, @ViewBuilder content: () -> Content) {
            self.spacing = spacing
            self.content = content()
        }

        public var body: some View {
            RowLayout(columnGap: 4, rowGap: 12) { content }
                .padding(.horizontal, 2.5)
                .padding(.top, 2.5)
        }
    }

    struct RowLayout: Layout {
        let columnGap: CGFloat
        let rowGap: CGFloat

        func natural(_ subviews: Subviews) -> [CGSize] { subviews.map { $0.sizeThatFits(.unspecified) } }

        func fitsOnOneLine(_ sizes: [CGSize], width: CGFloat?) -> Bool {
            guard let width else { return true }
            return sizes.map(\.width).reduce(0, +) + columnGap * CGFloat(max(0, sizes.count - 1)) <= width + 0.01
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let sizes = natural(subviews)
            let content = sizes.map(\.width).reduce(0, +) + columnGap * CGFloat(max(0, sizes.count - 1))
            if fitsOnOneLine(sizes, width: proposal.width) {
                return CGSize(width: proposal.width ?? content, height: sizes.map(\.height).max() ?? 0)
            }
            let width = proposal.width ?? content
            let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
            return CGSize(width: width, height: heights.reduce(0, +) + rowGap * CGFloat(max(0, heights.count - 1)))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let sizes = natural(subviews)
            if fitsOnOneLine(sizes, width: bounds.width) {
                let used = sizes.map(\.width).reduce(0, +) + columnGap * CGFloat(max(0, sizes.count - 1))
                var x = bounds.minX + (bounds.width - used) / 2
                for (s, size) in zip(subviews, sizes) {
                    s.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(size))
                    x += size.width + columnGap
                }
            } else {
                var y = bounds.minY
                for s in subviews {
                    let size = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                    s.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: size.height))
                    y += size.height + rowGap
                }
            }
        }
    }
}

struct AxoStackedButtonPressedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var axoStackedButtonPressed: Bool {
        get { self[AxoStackedButtonPressedKey.self] }
        set { self[AxoStackedButtonPressedKey.self] = newValue }
    }
}

/// `group-active:bg-primary-pressed` on the pill.
struct AxoStackedButtonStyle: ButtonStyle {
    let interactive: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.axoStackedButtonPressed, interactive && configuration.isPressed)
            .contentShape(Rectangle())
    }
}

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
