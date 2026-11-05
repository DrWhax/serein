// AxoButton.dom.stories.tsx `WidthsTest`: the fit / grow / fill widths of md buttons
// (strong-primary "Fit", strong-affirmative "Grow", strong-destructive "Fill", optionally with
// LONG_TEXT, truncated) in six layout contexts. `.axo-button` is `inline-flex max-w-full` with
// a 56px min-width; grow adds `flex-grow: 1`, fill `width: 100%`. Per context, the CSS outcome
// is expressed with CSSFlex: block = inline boxes on lines (no growing), flex row (fill's 100%
// basis shrinks around the others' minimums), wrapped row, column and grid (stretch: the
// button fills, i.e. `.full`), and the dialog footer (a right-aligned wrapping row as wide as
// its buttons' max-content, at most the container).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
struct AxoButtonWidthsStory {
    enum Kind { case fit, grow, full }
    struct Item { let kind: Kind; let long: Bool }

    static let long = "Lorem ipsum dolor sit amet consectetur adipisicing elit. Id dicta dolorum magnam quibusdam nam commodi vel esse voluptatibus ut sint error consectetur nihil, ad, optio maiores, ipsa explicabo officiis animi."
    static let width: CGFloat = 1168

    static let rows: [(String, [Item])] = {
        func r(_ k: Kind, _ l: [Bool]) -> [Item] { l.map { Item(kind: k, long: $0) } }
        return [
            ("Mixed", [Item(kind: .fit, long: false), Item(kind: .grow, long: false), Item(kind: .full, long: false)]),
            ("Fit", r(.fit, [false, false, false])), ("Fit: With long text", r(.fit, [true, true, true])),
            ("Fit: With mixed length texts", r(.fit, [false, false, true])),
            ("Fit", r(.grow, [false, false, false])), ("Grow: With long text", r(.grow, [true, true, true])),
            ("Grow: With mixed length texts", r(.grow, [false, false, true])),
            ("Fill", r(.full, [false, false, false])), ("Full: With long text", r(.full, [true, true, true])),
            ("Full: With mixed length texts", r(.full, [false, false, true])),
        ]
    }()

    static func label(_ i: Item) -> String {
        let base = i.kind == .fit ? "Fit" : i.kind == .grow ? "Grow" : "Fill"
        return i.long ? base + " " + long : base
    }

    static func variant(_ k: Kind) -> AxoButton.Variant { k == .fit ? .strongPrimary : k == .grow ? .strongAffirmative : .strongDestructive }

    static func button(_ i: Item, width: AxoButton.Width) -> some View {
        AxoButton.Root(label(i), variant: variant(i.kind), size: .md, width: width)
    }

    /// max-content width: the label (medium 13/18) and 12px padding each side, at least 56.
    static func natural(_ i: Item) -> CGFloat {
        max(56, CSSTextLayout.make(label(i), CSSTextStyle(AxoType.bodyMedium.weight(500)), wrap: .nowrap, maxWidth: nil).width + 24)
    }

    enum Context { case block, flex, wrapped, column, footer, grid }

    @ViewBuilder static func container(_ c: Context, _ items: [Item]) -> some View {
        let w = width
        switch c {
        case .block:
            CSSFlex(.row, wrap: true, align: .start) {
                ForEach(items.indices, id: \.self) { n in
                    let i = items[n]
                    button(i, width: i.kind == .full ? .full : .fit).flexItem(shrink: 0, basis: i.kind == .full ? w : nil, maxMain: w)
                }
            }
        case .flex, .wrapped:
            CSSFlex(.row, wrap: c == .wrapped, align: .start) {
                ForEach(items.indices, id: \.self) { n in
                    let i = items[n]
                    button(i, width: i.kind == .fit ? .fit : .full)
                        .flexItem(grow: i.kind == .grow ? 1 : 0, basis: i.kind == .full ? w : nil, maxMain: w)
                }
            }
        case .column:
            VStack(spacing: 0) { ForEach(items.indices, id: \.self) { button(items[$0], width: .full) } }
        case .footer:
            let inner = min(w, items.map(natural).reduce(0, +))
            CSSFlex(.row, wrap: true, align: .start) {
                ForEach(items.indices, id: \.self) { n in
                    let i = items[n]
                    button(i, width: i.kind == .fit ? .fit : .full)
                        .flexItem(grow: i.kind == .grow ? 1 : 0, basis: i.kind == .full ? inner : nil, maxMain: inner)
                }
            }
            .frame(width: inner)
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .grid:
            HStack(spacing: 0) { ForEach(items.indices, id: \.self) { button(items[$0], width: .full).frame(width: w / 3) } }
        }
    }

    static func section(_ title: String, _ c: Context) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CSSText(title, type: .titleLarge, color: .labelPrimary)
            ForEach(rows.indices, id: \.self) { r in
                CSSText(rows[r].0, type: .bodyLarge, color: .labelPrimary)
                container(c, rows[r].1).frame(width: width, alignment: .leading)
            }
        }
    }

    static var view: some View {
        VStack(alignment: .leading, spacing: 64) {
            section("Block", .block)
            section("Flex", .flex)
            section("Flex: Wrapped", .wrapped)
            section("Flex: Column", .column)
            section("Flex: Dialog footer layout", .footer)
            section("Grid", .grid)
        }
        .padding(.bottom, 16)
        .frame(width: width, alignment: .topLeading)
    }
}

@MainActor
@Suite struct AxoButtonWidthsTests {
    @Test(arguments: ["light", "dark"])
    func widthsTest(theme: String) throws {
        try Snapshot.assertMatches(SmallComponentStoriesTests.top(AxoButtonWidthsStory.view), story: "axo-axobutton--widths-test", theme: theme)
    }
}
