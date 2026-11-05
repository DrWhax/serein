// Block-level text (a `<p>`, `<h1>`, `<div>` of text): CSS gives a block the full width of
// its container and breaks lines when a line would exceed exactly that width. CSSText sizes
// itself to its widest line and allows 0.6pt of overflow (for SwiftUI handing it back its own
// width rounded down), and re-wraps at its frame + 1 when drawing; for a paragraph whose line
// overflows the container by a fraction of a point (Chromium breaks it) that keeps the word on
// the line. CSSBlockText takes the proposed width as its frame and wraps at exactly that width
// both when measuring and when drawing. (Proposed for Theme/ next to CSSText.)

import SwiftUI

public struct CSSBlockText: View {
    let string: String
    let style: CSSTextStyle
    let alignment: CSSTextAlign
    let color: AxoColor?
    @Environment(\.colorScheme) var scheme
    @Environment(\.cssTextColor) var inherited

    public init(_ string: String, style: CSSTextStyle, alignment: CSSTextAlign = .start, color: AxoColor? = nil) {
        self.string = string
        self.style = style
        self.alignment = alignment
        self.color = color
    }

    /// CSSTextLayout's wrap allows 0.6pt over `maxWidth`; take it back off.
    nonisolated static func layout(_ string: String, _ style: CSSTextStyle, width: CGFloat) -> CSSTextLayout {
        CSSTextLayout.make(string, style, wrap: .wrap, maxWidth: width - 0.6)
    }

    public var body: some View {
        let rgba = (color ?? inherited).value(for: scheme)
        BlockTextFrame(string: string, style: style) {
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                let layout = Self.layout(string, style, width: size.width)
                context.withCGContext { cg in
                    layout.draw(in: cg, width: size.width, alignment: alignment,
                                color: CGColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(string)
    }
}

struct BlockTextFrame: Layout {
    let string: String
    let style: CSSTextStyle

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let width = proposal.width, width.isFinite else {
            let natural = CSSTextLayout.make(string, style, wrap: .nowrap, maxWidth: nil)
            return CGSize(width: natural.width, height: natural.height)
        }
        return CGSize(width: width, height: CSSBlockText.layout(string, style, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews { s.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}
