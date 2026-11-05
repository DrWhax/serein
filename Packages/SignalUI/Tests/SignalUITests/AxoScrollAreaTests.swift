// AxoScrollArea stories (ts/axo/AxoScrollArea.dom.stories.tsx).
//
// The captures hide scrollbars (headless Chromium) but keep the 11px `stable both-edges`
// gutters; hints and masks rest in their base style (scroll-driven animations do not run
// in the capture), so the *-with-hints / *-with-mask stories look like the plain ones.

import SwiftUI
import Testing
@testable import SignalUI

/// Story `Box`: flex items-center justify-center rounded-2xl bg-accent p-10
/// type-title-large font-semibold text-primary-oncolor
struct ScrollStoryBox: View {
    let label: String
    /// Stretched across a column (vertical stories); in a row the width is the content's.
    var fillWidth = true
    var body: some View {
        CSSText(label, type: .titleLarge, wrap: .nowrap, color: .labelPrimaryOncolor)
            .padding(40)
            .frame(maxWidth: fillWidth ? .infinity : nil, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16).fill(AxoColor.fillAccent))
    }
}

/// `MaybeMask`
struct ScrollStoryMaybeMask<Content: View>: View {
    let mask: Bool
    @ViewBuilder var content: Content
    var body: some View {
        if mask { AxoScrollArea.Mask { content } } else { content }
    }
}

/// `flex h-full flex-row items-stretch gap-2 [justify-center-safe]` of boxes that cannot
/// shrink or grow: an HStack, which (unlike CSSFlex) fills the proposed height, so the
/// boxes stretch; `justify-center-safe` centres it when it fits, else starts it.
struct StretchedRow<Content: View>: View {
    let gap: CGFloat
    let centerSafe: Bool
    @ViewBuilder var content: Content
    var body: some View {
        if centerSafe {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: gap) { content }.fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity)
                HStack(spacing: gap) { content }.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(spacing: gap) { content }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ScrollStoryVerticalTemplate: View {
    let items: Int
    var centered = false
    var fit = false
    var hints = false
    var mask = false

    var root: some View {
        AxoScrollArea.Root(maxHeight: fit ? 400 : nil, scrollbarWidth: .thin) {
            if hints {
                AxoScrollArea.Hint(edge: .top)
                AxoScrollArea.Hint(edge: .bottom)
            }
            ScrollStoryMaybeMask(mask: mask) {
                AxoScrollArea.Viewport {
                    AxoScrollArea.Content {
                        CSSFlex(.column, gap: 8, justify: centered ? .center : .start) {
                            ForEach(0..<items, id: \.self) { ScrollStoryBox(label: "\($0 + 1)") }
                        }
                    }
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CSSText("Header", type: .titleLarge).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            if fit {
                root.fixedSize(horizontal: false, vertical: true)
            } else {
                root.frame(height: 400)
            }
            CSSText("Footer", type: .titleLarge).padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
        }
        .frame(width: 256, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16).fill(AxoColor.surfaceSecondary))
    }
}

/// `flex w-fit flex-row gap-2` (cards stretch to the tallest).
struct ScrollStoryVerticalVariants: View {
    var hints = false
    var mask = false
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach([10, 2, 0], id: \.self) { n in
                ScrollStoryVerticalTemplate(items: n, hints: hints, mask: mask)
                ScrollStoryVerticalTemplate(items: n, centered: true, hints: hints, mask: mask)
                ScrollStoryVerticalTemplate(items: n, fit: true, hints: hints, mask: mask)
            }
        }
        .fixedSize()
    }
}

struct ScrollStoryHorizontalTemplate: View {
    let items: Int
    var centered = false
    var fit = false
    var hints = false
    var mask = false

    @ViewBuilder var boxes: some View {
        ForEach(0..<items, id: \.self) { ScrollStoryBox(label: "\($0 + 1)", fillWidth: false) }
    }

    var root: some View {
        AxoScrollArea.Root(orientation: .horizontal, maxWidth: fit ? 400 : nil, scrollbarWidth: .thin) {
            if hints {
                AxoScrollArea.Hint(edge: .inlineStart)
                AxoScrollArea.Hint(edge: .inlineEnd)
            }
            ScrollStoryMaybeMask(mask: mask) {
                AxoScrollArea.Viewport {
                    AxoScrollArea.Content {
                        StretchedRow(gap: 8, centerSafe: centered) { boxes }
                    }
                }
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            AxoSymbol.Icon("arrow-[start]", size: 24, label: nil).padding(16).frame(maxHeight: .infinity)
            if fit {
                root.fixedSize(horizontal: true, vertical: false)
            } else {
                root.frame(width: 400)
            }
            AxoSymbol.Icon("arrow-[end]", size: 24, label: nil).padding(16).frame(maxHeight: .infinity)
        }
        .frame(height: 128)
        .fixedSize(horizontal: true, vertical: false)
        .background(RoundedRectangle(cornerRadius: 16).fill(AxoColor.surfaceSecondary))
    }
}

/// `flex flex-col gap-2`
struct ScrollStoryHorizontalVariants: View {
    var hints = false
    var mask = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollStoryHorizontalTemplate(items: 10, hints: hints, mask: mask)
            ScrollStoryHorizontalTemplate(items: 10, centered: true, hints: hints, mask: mask)
            ScrollStoryHorizontalTemplate(items: 10, fit: true, hints: hints, mask: mask)
            ScrollStoryHorizontalTemplate(items: 2, hints: hints, mask: mask)
            ScrollStoryHorizontalTemplate(items: 2, centered: true, hints: hints, mask: mask)
            ScrollStoryHorizontalTemplate(items: 2, fit: true, hints: hints, mask: mask)
            ScrollStoryHorizontalTemplate(items: 0, hints: hints, mask: mask)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ScrollStoryBothTemplate: View {
    let cols: Int
    let rows: Int
    var centered = false
    var fit = false
    var hints = false
    var mask = false

    var root: some View {
        AxoScrollArea.Root(orientation: .both, maxWidth: fit ? 400 : nil, maxHeight: fit ? 400 : nil, scrollbarWidth: .thin,
                           scrollbarGutter: .stableBothEdges) {
            if hints {
                AxoScrollArea.Hint(edge: .top)
                AxoScrollArea.Hint(edge: .bottom)
                AxoScrollArea.Hint(edge: .inlineStart)
                AxoScrollArea.Hint(edge: .inlineEnd)
            }
            ScrollStoryMaybeMask(mask: mask) {
                AxoScrollArea.Viewport {
                    AxoScrollArea.Content {
                        // flex flex-col gap-2 [min-h-full justify-center]: a block-level column
                        // as wide as the content box (rows overflow it), so a VStack; CSSFlex
                        // columns grow to their widest row.
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(0..<rows, id: \.self) { _ in
                                CSSFlex(.row, gap: 8, justify: centered ? .center : .start) {
                                    ForEach(0..<cols, id: \.self) { ScrollStoryBox(label: "\($0 + 1)", fillWidth: false) }
                                }
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: centered ? .center : .top)
                    }
                }
            }
        }
    }

    var body: some View {
        Group {
            if fit {
                root.fixedSize()
            } else {
                root.frame(width: 400, height: 400)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(AxoColor.surfaceSecondary))
    }
}

/// `flex flex-col items-start justify-start gap-2`
struct ScrollStoryBothVariants: View {
    var hints = false
    var mask = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([10, 2, 0], id: \.self) { n in
                ScrollStoryBothTemplate(cols: n, rows: n, hints: hints, mask: mask)
                ScrollStoryBothTemplate(cols: n, rows: n, centered: true, hints: hints, mask: mask)
                ScrollStoryBothTemplate(cols: n, rows: n, fit: true, hints: hints, mask: mask)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
@Suite struct AxoScrollAreaTests {
    nonisolated static let ids = [
        "vertical", "vertical-with-hints", "vertical-with-mask", "horizontal", "horizontal-with-hints", "horizontal-with-mask",
        "both", "both-with-hints", "both-with-mask",
    ]

    static func story(_ name: String) -> AnyView {
        let hints = name.hasSuffix("-with-hints"), mask = name.hasSuffix("-with-mask")
        if name.hasPrefix("vertical") { return AnyView(ScrollStoryVerticalVariants(hints: hints, mask: mask)) }
        if name.hasPrefix("horizontal") { return AnyView(ScrollStoryHorizontalVariants(hints: hints, mask: mask)) }
        return AnyView(ScrollStoryBothVariants(hints: hints, mask: mask))
    }

    @Test(arguments: ids, ["light", "dark"])
    func story(name: String, theme: String) throws {
        try Snapshot.assertMatches(Self.story(name), story: "axo-axoscrollarea--\(name)", theme: theme)
    }
}
