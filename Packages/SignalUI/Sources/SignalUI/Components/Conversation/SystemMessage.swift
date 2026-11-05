// SystemMessage (ts/components/conversation/SystemMessage.dom.tsx + stylesheets/components/
// SystemMessage.scss): the timeline's centred notification row: font-body-2 at 16px line
// height in label-secondary (danger: destructive), 10px above and below. The contents block
// (max 400px, text centred) starts with the 16px icon as an inline-block (`::before`,
// vertical-align text-top, 8px after it; error / danger: destructive) or an AxoSymbol, and
// may end with an ExpireTimer (inline-block, 6px before it, vertical-align middle). An
// optional button sits 12px below.
//
// The icon and timer are reserved in the text as zero-content inline-blocks and drawn where
// the laid-out first / last line puts them.

import SwiftUI

public struct SystemMessage<Button: View>: View {
    public enum Kind: Sendable { case normal, danger, error }
    public enum Leading: Sendable, Hashable {
        /// `icon` (deprecated upstream): an images/icons path, e.g. "v3/phone/phone-compact".
        case icon(String, width: CGFloat = 16)
        case symbol(AxoSymbol.Name)
    }

    let leading: Leading?
    let contents: [CSSTextRun]
    let kind: Kind
    let expireTimer: (length: TimeInterval, expiration: Date)?
    /// Further `<p>` blocks below the first line (the first `<p>` is inline-block, next to
    /// the icon): each centred, 4px apart.
    let paragraphs: [[CSSTextRun]]
    let button: Button
    /// The contents are a `<p>` (`p:first-child` is inline-block): too wide to fit after the
    /// icon, the paragraph drops to the line below it.
    var contentsIsParagraph = false

    public func contentsIsParagraph(_ value: Bool = true) -> Self {
        var copy = self
        copy.contentsIsParagraph = value
        return copy
    }

    public init(_ leading: Leading?, contents: [CSSTextRun], paragraphs: [[CSSTextRun]] = [], kind: Kind = .normal,
                expireTimer: (length: TimeInterval, expiration: Date)? = nil, @ViewBuilder button: () -> Button) {
        self.leading = leading
        self.contents = contents
        self.paragraphs = paragraphs
        self.kind = kind
        self.expireTimer = expireTimer
        self.button = button()
    }

    static var style: CSSTextStyle { var s = LegacyType.body2(); s.lineHeight = 16; return s }

    var textColor: AxoColor { kind == .danger ? .labelDestructive : .labelSecondary }
    var iconColor: AxoColor { kind == .normal ? .labelSecondary : .labelDestructive }

    var leadingWidth: CGFloat? {
        switch leading {
        case .icon(_, let w): w + 8
        case .symbol: 16 + 8          // me-2
        case nil: nil
        }
    }

    /// An inline-block paragraph wider than the room left after the icon wraps below it.
    var paragraphBelowIcon: Bool {
        guard contentsIsParagraph, let w = leadingWidth, expireTimer == nil else { return false }
        let maxContent = CSSTextLayout.make(runs: contents, Self.style, wrap: .nowrap, maxWidth: nil, colors: nil).width
        return w + min(maxContent, SystemMessageContents.maxWidth) > SystemMessageContents.maxWidth + CSSTextLayout.exactWidthTolerance
    }

    var runs: [CSSTextRun] {
        var out: [CSSTextRun] = []
        if let w = leadingWidth { out.append(.inlineBlock("", CSSInlineBlock(paddingInline: w / 2))) }
        out += contents
        if expireTimer != nil { out.append(.inlineBlock("", CSSInlineBlock(paddingInline: 9))) }    // 6 + 12
        return out
    }

    public var body: some View {
        VStack(spacing: 0) {
            if paragraphBelowIcon {
                // The icon alone on a line (its 8px margin counts in the centring), the paragraph below.
                leadingView.padding(.trailing, 8).frame(height: Self.style.lineHeight, alignment: .top).cssTextColor(textColor)
                CSSText(runs: contents, style: Self.style, alignment: .center, color: textColor)
                    .frame(maxWidth: SystemMessageContents.maxWidth)
            } else {
                SystemMessageContents(runs: runs, style: Self.style, hasLeading: leading != nil, hasTrailing: expireTimer != nil) {
                    CSSText(runs: runs, style: Self.style, alignment: .center)
                    leadingView
                    if let expireTimer {
                        ExpireTimer(expirationLength: expireTimer.length, expirationTimestamp: expireTimer.expiration, color: textColor)
                    }
                }
                .cssTextColor(textColor)
            }
            ForEach(paragraphs.indices, id: \.self) { i in
                // An empty <p> still takes the previous one's 4px margin.
                if paragraphs[i].isEmpty {
                    Color.clear.frame(width: 0, height: 0).padding(.top, 4)
                } else {
                    CSSText(runs: paragraphs[i], style: Self.style, alignment: .center, color: textColor)
                        .frame(maxWidth: SystemMessageContents.maxWidth)
                        .padding(.top, 4)
                }
            }
            if Button.self != EmptyView.self {
                button.padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    @ViewBuilder var leadingView: some View {
        switch leading {
        case .icon(let name, let w): SignalIcon(name, color: iconColor).frame(width: w, height: 16)
        case .symbol(let s): AxoSymbol.Icon(s, size: 16, label: nil)
        case nil: EmptyView()
        }
    }
}

extension SystemMessage where Button == EmptyView {
    public init(_ leading: Leading?, contents: [CSSTextRun], paragraphs: [[CSSTextRun]] = [], kind: Kind = .normal,
                expireTimer: (length: TimeInterval, expiration: Date)? = nil) {
        self.init(leading, contents: contents, paragraphs: paragraphs, kind: kind, expireTimer: expireTimer) { EmptyView() }
    }

    public init(_ leading: Leading?, text: String, kind: Kind = .normal) {
        self.init(leading, contents: [CSSTextRun(text)], kind: kind)
    }
}

/// The contents block: subview 0 the text (shrink-to-fit, ≤ 400), 1 the leading icon at the
/// first line's start (text-top), 2 the timer at the last line's end (vertical-align middle).
struct SystemMessageContents: Layout {
    let runs: [CSSTextRun]
    let style: CSSTextStyle
    let hasLeading: Bool
    let hasTrailing: Bool
    static let maxWidth: CGFloat = 400

    func layout(_ proposal: ProposedViewSize) -> CSSTextLayout {
        // max-width: 400px, compared as Blink does (to 1/64px).
        CSSTextLayout.make(runs: runs, style, wrap: .wrap, maxWidth: min(proposal.width ?? Self.maxWidth, Self.maxWidth), colors: nil,
                           tolerance: CSSTextLayout.exactWidthTolerance)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let l = layout(proposal)
        return CGSize(width: l.width, height: l.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let l = layout(ProposedViewSize(width: bounds.width, height: nil))
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        let font = style.ctFont
        let a = CTFontGetAscent(font).rounded(), d = CTFontGetDescent(font).rounded()
        let halfLeading = ((style.lineHeight - (a + d)) / 2).rounded(.down)
        let x0 = (bounds.width - (l.widths.first ?? 0)) / 2
        if hasLeading, subviews.count > 1 {
            subviews[1].place(at: CGPoint(x: bounds.minX + x0, y: bounds.minY + halfLeading), proposal: .unspecified)
        }
        if hasTrailing, subviews.count > 2 {
            let last = max(0, l.lines.count - 1)
            let w = l.widths.last ?? 0
            let xEnd = (bounds.width - w) / 2 + w
            // middle: the box's centre at the baseline − half the x-height.
            let baseline = CGFloat(last) * style.lineHeight + halfLeading + a
            let mid = baseline - CTFontGetXHeight(font) / 2
            subviews[2].place(at: CGPoint(x: bounds.minX + xEnd - 12, y: bounds.minY + mid - 6), proposal: .unspecified)
        }
    }
}
