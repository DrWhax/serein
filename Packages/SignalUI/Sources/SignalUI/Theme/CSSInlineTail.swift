// A text run followed by one inline-block (e.g. `text <button>`): the box follows the text's
// last line when it fits, otherwise it wraps onto its own line, as in CSS inline flow. The
// box shares the line's top (its height should not exceed the line height).

import CoreText
import SwiftUI

public struct CSSInlineTail<Tail: View>: View {
    let text: String
    let style: CSSTextStyle
    let tail: Tail

    public init(_ text: String, style: CSSTextStyle, @ViewBuilder tail: () -> Tail) {
        self.text = text
        self.style = style
        self.tail = tail()
    }

    public var body: some View {
        InlineTailLayout(text: text, style: style) {
            CSSText(text, style: style)
            tail
        }
    }
}

struct InlineTailLayout: Layout {
    let text: String
    let style: CSSTextStyle

    /// Where the tail goes for a given width: its origin and the total height.
    func arrange(width: CGFloat?, tail: CGSize) -> (CGPoint, CGFloat, CGFloat) {
        let layout = CSSTextLayout.make(text, style, wrap: .wrap, maxWidth: width)
        let lastLine = layout.lines.last
        var last: CGFloat = 0
        if let lastLine { last = CGFloat(CTLineGetTypographicBounds(lastLine, nil, nil, nil)) }    // includes the trailing space
        let lines = CGFloat(max(layout.lines.count, 1))
        let textWidth = layout.width
        if layout.isEmpty { return (.zero, tail.height, tail.width) }
        if width == nil || last + tail.width <= width! + 0.6 {
            let y = (lines - 1) * style.lineHeight
            return (CGPoint(x: last, y: y), max(lines * style.lineHeight, y + tail.height), max(textWidth, last + tail.width))
        }
        return (CGPoint(x: 0, y: lines * style.lineHeight), lines * style.lineHeight + tail.height, max(textWidth, tail.width))
    }

    /// The tail at its max-content size when it follows the text; on its own line it wraps
    /// within the full width (an inline-block shrinks to fit the line).
    func tailSize(_ subviews: Subviews, width: CGFloat?) -> (CGPoint, CGSize, CGFloat, CGFloat) {
        let natural = subviews[1].sizeThatFits(.unspecified)
        let (origin, height, w) = arrange(width: width, tail: natural)
        guard let width, origin.x == 0, natural.width > width else { return (origin, natural, height, w) }
        let wrapped = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return (origin, wrapped, origin.y + wrapped.height, width)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (_, _, height, width) = tailSize(subviews, width: proposal.width)
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (origin, tail, _, _) = tailSize(subviews, width: bounds.width)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
        subviews[1].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: ProposedViewSize(tail))
    }
}
