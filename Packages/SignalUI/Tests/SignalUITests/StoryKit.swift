// Twins of upstream's Storybook scaffolding (ts/axo/_storybook-helpers, story markup).

import SwiftUI
@testable import SignalUI

/// Storybook's body text: 14px/20px Inter, type-body-large (ts/axo/_tailwind-theme/global.css).
@MainActor func StoryText(_ s: String, type: AxoType = .bodyLarge, wrap: CSSTextWrap = .wrap) -> CSSText {
    CSSText(s, type: type, wrap: wrap)
}

/// `<Story.Stack>`: flex flex-col gap-4
struct StoryStack<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading, spacing: 16) { content }.frame(maxWidth: .infinity, alignment: .leading) }
}

/// `<code>` in story markup: font-mono at the inherited 14px/20px.
@MainActor func StoryCode(_ s: String) -> CSSText {
    CSSText(s, style: .mono(size: 14, lineHeight: 20, letterSpacing: -0.084), wrap: .nowrap)
}

/// Story grid label cell: `flex items-center p-2 text-end` with a `<code>` label.
@MainActor func StoryGridLabel(_ s: String) -> some View {
    StoryCode(s).padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
}

// MARK: - Story.Legend / Story.Hint (from the fields port; dashed border checked against Chromium)

/// `<Story.Legend>`: fieldset.my-2.border.border-dashed.border-selected.p-2 with a
/// legend.px-2.font-mono.type-caption.text-accent; the top border runs through the legend's middle.
struct StoryLegend<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    static var legendStyle: CSSTextStyle { .mono(size: 11, lineHeight: 14, letterSpacing: 0.055) }

    var body: some View {
        let legendWidth = CSSTextLayout.make(label, Self.legendStyle, wrap: .nowrap, maxWidth: nil).width + 16
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.top, 22)
            .padding(.bottom, 9)
            .background { DashedFieldsetBorder(top: 7, gapStart: 9, gapEnd: 9 + legendWidth) }
            .overlay(alignment: .topLeading) {
                CSSText(label, style: Self.legendStyle, wrap: .nowrap, color: .labelAccent).padding(.leading, 17)
            }
    }
}

/// A 1px `border-dashed` box painted like Chromium: per side, dashes of 3px with gaps
/// near 2px, adjusted so that each side starts and ends with a whole dash.
struct DashedFieldsetBorder: View {
    let top: CGFloat
    let gapStart: CGFloat
    let gapEnd: CGFloat

    static func dashes(length: CGFloat, width: CGFloat) -> [ClosedRange<CGFloat>] {
        let dash = 3 * width, gap = 2 * width
        let minDashes = ((length + gap) / (dash + gap)).rounded(.down)
        let maxDashes = minDashes + 1
        let minGap = minDashes > 1 ? (length - minDashes * dash) / (minDashes - 1) : 0
        let maxGap = (length - maxDashes * dash) / (maxDashes - 1)
        let useMin = maxGap <= 0 || abs(minGap - gap) < abs(maxGap - gap)
        let n = Int(useMin ? minDashes : maxDashes), g = useMin ? minGap : maxGap
        return (0..<max(n, 1)).map { i in
            let s = CGFloat(i) * (dash + g)
            return s...(s + dash)
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let color = GraphicsContext.Shading.color(AxoColor.borderSelected.resolve(in: ctx.environment))
            let w = size.width, h = size.height - top
            var path = Path()
            for d in Self.dashes(length: w, width: 1) {
                for (x0, x1) in [(d.lowerBound, min(d.upperBound, gapStart)), (max(d.lowerBound, gapEnd), d.upperBound)] where x1 > x0 {
                    path.addRect(CGRect(x: x0, y: top, width: x1 - x0, height: 1))
                }
                path.addRect(CGRect(x: d.lowerBound, y: size.height - 1, width: 3, height: 1))
            }
            for d in Self.dashes(length: h, width: 1) {
                path.addRect(CGRect(x: 0, y: top + d.lowerBound, width: 1, height: 3))
                path.addRect(CGRect(x: w - 1, y: top + d.lowerBound, width: 1, height: 3))
            }
            ctx.fill(path, with: color)
        }
    }
}

/// `<Story.Hint>`: p.my-2.first:mt-0.last:mb-0.type-caption.text-secondary (after the field).
@MainActor func StoryHint(_ s: String) -> some View {
    CSSText(s, type: .caption, color: .labelSecondary).padding(.top, 8)
}

/// Fieldsets in a fragment: block siblings whose my-2 margins collapse to 8.
struct LegendStack<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading, spacing: 8) { content }.frame(maxWidth: .infinity, alignment: .leading) }
}
