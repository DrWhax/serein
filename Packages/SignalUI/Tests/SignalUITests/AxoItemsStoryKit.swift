// Twins of upstream's Storybook helpers used by the items stories
// (ts/axo/_storybook-helpers/Story.dom.tsx: Story.Callout, Story.Legend) plus the block
// flow (collapsing vertical margins) and mixed-style text their markup needs.
// Candidates for StoryKit.swift.

import CoreText
import SwiftUI
@testable import SignalUI

// MARK: - Block flow with collapsing margins

struct StoryMarginKey: LayoutValueKey { static let defaultValue: (top: CGFloat, bottom: CGFloat) = (0, 0) }

extension View {
    /// Vertical CSS margins of a block in a `StoryBlocks` flow.
    func storyMargin(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        layoutValue(key: StoryMarginKey.self, value: (top, bottom))
    }
}

/// Blocks stacked as in normal flow: adjacent vertical margins collapse (max of the two).
/// With `collapseEdges` (a parent without padding or border) the first block's top margin and
/// the last block's bottom margin collapse through the parent, out of its box.
struct StoryBlocks: Layout {
    var collapseEdges = true
    /// The snapshot scale (references are 2x).
    var deviceScale: CGFloat = 2

    func frames(_ subviews: Subviews, width: CGFloat?) -> (ys: [CGFloat], heights: [CGFloat], total: CGFloat) {
        var ys: [CGFloat] = [], heights: [CGFloat] = []
        var y: CGFloat = 0
        var pending: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            let m = s[StoryMarginKey.self]
            let h = s.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            let top = i == 0 ? (collapseEdges ? 0 : m.top) : max(pending, m.top)
            y += top
            ys.append(y)
            heights.append(h)
            y += h
            pending = m.bottom
        }
        if !collapseEdges { y += pending }
        return (ys, heights, y)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return CGSize(width: width, height: frames(subviews, width: width).total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let f = frames(subviews, width: bounds.width)
        for (i, s) in subviews.enumerated() {
            // Chromium paints a block at its layout offset snapped down to the device pixel
            // (SwiftUI rounds to the nearest), which shows once heights carry fractions.
            let y = ((bounds.minY + f.ys[i]) * deviceScale).rounded(.down) / deviceScale
            s.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: f.heights[i]))
        }
    }
}

/// `mx-auto max-w-150` centred in the story root.
struct StoryMaxWidth<Content: View>: View {
    var width: CGFloat = 600
    @ViewBuilder var content: Content
    var body: some View {
        StoryBlocks { content }
            .frame(maxWidth: width)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Mixed-style text (<strong>, <em>)

struct StoryRun: Sendable, Hashable {
    var text: String
    var bold = false
    var italic = false
    static func plain(_ s: String) -> StoryRun { StoryRun(text: s) }
    static func strong(_ s: String) -> StoryRun { StoryRun(text: s, bold: true) }
    static func em(_ s: String) -> StoryRun { StoryRun(text: s, italic: true) }
}

/// Wrapped text whose runs may be synthetically emboldened or obliqued, as Chromium does
/// for faces the font family lacks (Skia: fake bold strokes the outline by size × ~1/24.5,
/// fake italic skews by 1/4).
struct StoryRichText: View {
    let runs: [StoryRun]
    let style: CSSTextStyle
    let color: AxoColor
    @Environment(\.colorScheme) var scheme

    static let italicKey = NSAttributedString.Key("StoryItalic")

    func attributed(_ cg: CGColor) -> NSAttributedString {
        let font = style.ctFont
        let out = NSMutableAttributedString()
        // Skia's fake-bold outset (kStdFakeBoldInterpKeys 9…36 → 1/24…1/32 of the size).
        let t = min(1, max(0, (style.size - 9) / 27))
        let extra = style.size * (1.0 / 24 + t * (1.0 / 32 - 1.0 / 24))
        for r in runs {
            var attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTTrackingAttributeName as String): style.letterSpacing,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): cg,
            ]
            if r.bold {
                attrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -100 * extra / style.size
                attrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = cg
            }
            if r.italic { attrs[Self.italicKey] = true }
            out.append(NSAttributedString(string: r.text, attributes: attrs))
        }
        return out
    }

    func lines(_ s: NSAttributedString, maxWidth: CGFloat?) -> [CTLine] {
        let typesetter = CTTypesetterCreateWithAttributedString(s)
        var lines: [CTLine] = []
        var start = 0
        while start < s.length {
            let count = maxWidth.map { CTTypesetterSuggestLineBreak(typesetter, start, Double($0) + 0.01) } ?? (s.length - start)
            let n = max(1, count)
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: n)))
            start += n
        }
        return lines
    }

    var body: some View {
        let rgba = color.value(for: scheme)
        let cg = CGColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
        let text = attributed(cg)
        StoryRichFrame(measure: { w in
            let ls = lines(text, maxWidth: w)
            let width = ls.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth($0)) }.max() ?? 0
            return CGSize(width: width, height: CGFloat(ls.count) * style.lineHeight)
        }) {
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                let font = style.ctFont
                let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
                // Blink's line-box placement, as CSSText: rounded ascent/descent, floored half-leading.
                let a = ascent.rounded(), d = descent.rounded()
                let halfLeading = ((style.lineHeight - (a + d)) / 2).rounded(.down)
                context.withCGContext { ctx in
                    for (i, line) in lines(text, maxWidth: size.width + 1).enumerated() {
                        let baseline = CGFloat(i) * style.lineHeight + halfLeading + a
                        ctx.saveGState()
                        ctx.translateBy(x: 0, y: baseline)
                        ctx.scaleBy(x: 1, y: -1)
                        ctx.textPosition = .zero
                        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
                            let attrs = CTRunGetAttributes(run) as NSDictionary
                            let italic = attrs[Self.italicKey] != nil
                            ctx.textMatrix = italic ? CGAffineTransform(a: 1, b: 0, c: 0.25, d: 1, tx: 0, ty: 0) : .identity
                            CTRunDraw(run, ctx, CFRange(location: 0, length: 0))
                        }
                        ctx.restoreGState()
                    }
                }
            }
        }
    }
}

struct StoryRichFrame: Layout {
    let measure: (CGFloat?) -> CGSize
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = measure(nil)
        guard let w = proposal.width, w < natural.width else { return natural }
        return measure(w)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews { s.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}

// MARK: - Dashed borders

/// A 1px `border-dashed` box in `color` (StoryKit's DashedFieldsetBorder dashes, all sides).
struct StoryDashedBorder: View {
    let color: AxoColor
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var path = Path()
            for d in DashedFieldsetBorder.dashes(length: w, width: 1) {
                path.addRect(CGRect(x: d.lowerBound, y: 0, width: 3, height: 1))
                path.addRect(CGRect(x: d.lowerBound, y: h - 1, width: 3, height: 1))
            }
            for d in DashedFieldsetBorder.dashes(length: h, width: 1) {
                path.addRect(CGRect(x: 0, y: d.lowerBound, width: 1, height: 3))
                path.addRect(CGRect(x: w - 1, y: d.lowerBound, width: 1, height: 3))
            }
            ctx.fill(path, with: .color(color.resolve(in: ctx.environment)))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - <Story.Callout>, <Story.Legend>

/// `<Story.Callout>`: my-2 first:mt-0 last:mb-0 flex gap-2 p-2 bg-warning-tint text-warning
/// border border-dashed type-caption font-medium font-mono, with an error-circle-fill glyph.
struct StoryCallout: View {
    let runs: [StoryRun]
    init(_ runs: [StoryRun]) { self.runs = runs }
    init(_ text: String) { runs = [.plain(text)] }

    static let style = CSSTextStyle.mono(size: 11, lineHeight: 14, letterSpacing: 0.055)

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AxoSymbol.InlineGlyph("error-circle-fill", size: 11, weight: 500)
                .cssTextColor(.labelWarning)
                .padding(.vertical, 1.5)
            StoryRichText(runs: runs, style: Self.style, color: .labelWarning)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .background(AxoColor.fillWarningTint)
        .overlay { StoryDashedBorder(color: .labelWarning) }
        .storyMargin(top: 8, bottom: 8)
    }
}

/// StoryKit's `<Story.Legend>` whose children flow as blocks (their my-2 margins collapse
/// inside the fieldset's padding), itself a my-2 block.
struct ItemLegend<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        StoryLegend(label: label) { StoryBlocks(collapseEdges: false) { content } }
            .storyMargin(top: 8, bottom: 8)
    }
}

// MARK: - Snapshot with an optional dump (ITEMS_DUMP=1) of passing renders for inspection

import CodecCore
import Testing
import EncodePNG
import Foundation

@MainActor
func itemsSnapshot(_ view: some View, story id: String, theme: String) throws {
    try Snapshot.assertMatches(view, story: id, theme: theme)
    guard ProcessInfo.processInfo.environment["ITEMS_DUMP"] != nil else { return }
    let (info, expected) = try Snapshot.reference(id, theme)
    let actual = try Snapshot.render(view, info: info)
    let dir = Snapshot.failuresDir.deletingLastPathComponent().appendingPathComponent("snapshot-debug")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let base = dir.appendingPathComponent("\(id).\(theme)")
    try Data(PNGEncoder.encode(actual)).write(to: base.appendingPathExtension("actual.png"))
    try Data(PNGEncoder.encode(expected)).write(to: base.appendingPathExtension("expected.png"))
}

// MARK: - FunInlineEmoji (ts/components/fun/FunEmoji.dom.tsx)

/// `<FunInlineEmoji>` in a 12px line: a 17×17 inline-block whose emoji image fills the box
/// (upstream draws Apple's emoji bitmaps from the "Signal Emoji" font; Apple Color Emoji
/// has the same images).
struct StoryInlineEmoji: View {
    let emoji: String
    static let size: CGFloat = 17

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 64, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: emoji, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ]))
            context.withCGContext { cg in
                let bounds = CTLineGetImageBounds(line, cg)
                guard bounds.width > 0, bounds.height > 0 else { return }
                cg.saveGState()
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: size.width / bounds.width, y: -size.height / bounds.height)
                cg.textPosition = CGPoint(x: -bounds.minX, y: -bounds.minY)
                CTLineDraw(line, cg)
                cg.restoreGState()
            }
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityLabel(emoji)
    }
}
