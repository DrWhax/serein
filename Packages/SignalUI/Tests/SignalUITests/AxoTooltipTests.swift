// AxoTooltip stories (ts/axo/AxoTooltip.dom.stories.tsx). The stories force tooltips open.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct AxoTooltipTests {
    /// Story `LongText`: no room above the trigger, so the tooltip flips below it.
    @Test(arguments: ["light", "dark"])
    func longText(theme: String) throws {
        let view = PopperStage {
            AxoTooltip.Root(label: "This person is in your contacts.", forceOpen: true) {
                AxoButton.Root("Hover Me", variant: .strongPrimary, size: .md)
            }
        }
        try Snapshot.assertMatches(view, story: "axo-axotooltip--long-text", theme: theme)
    }

    /// Story `Disabled`: a disabled tooltip never opens; only the trigger shows.
    @Test(arguments: ["light", "dark"])
    func disabled(theme: String) throws {
        let view = AxoTooltip.Root(label: "Hello World", disabled: true, forceOpen: true) {
            AxoButton.Root("Hover Me", variant: .strongPrimary, size: .md)
        }
        try Snapshot.assertMatches(SmallComponentStoriesTests.top(view), story: "axo-axotooltip--disabled", theme: theme)
    }

    static let longText = "Lorem ipsum dolor sit amet, consectetur adipisicing elit. Dolore nesciunt eligendi velit doloribus ipsum deleniti eaque voluptatibus, sequi quae pariatur nulla ad maiores eos, necessitatibus esse mollitia odio consequatur aliquid?"

    /// The stories' `Example`: a 400px bordered scroller (its 1000px content snapped to the
    /// centre) with a forced-open tooltip on the centred "Hover Me" button.
    static func example(_ trigger: String, label: String = "Hello World", side: AxoTooltip.Side = .top, align: AxoTooltip.Align = .center,
                        keyboardShortcut: String? = nil, timestamp: String? = nil) -> some View {
        AxoTooltip.Root(label: label, side: side, align: align, keyboardShortcut: keyboardShortcut, timestamp: timestamp, forceOpen: true) {
            AxoButton.Root(trigger, variant: .strongPrimary, size: .md)
        }
        .frame(width: 400, height: 400)
        .overlay(Rectangle().strokeBorder(AxoColor.labelPrimary, lineWidth: 1))
    }

    /// `Stack` of `Row`s: flex-wrap gap 8 in the 1168px root (two boxes a row), rows 8 apart.
    static func grid(_ rows: [[AnyView]]) -> some View {
        PopperStage {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows.indices, id: \.self) { r in
                    let pairs = stride(from: 0, to: rows[r].count, by: 2).map { Array(rows[r][$0..<min($0 + 2, rows[r].count)]) }
                    ForEach(pairs.indices, id: \.self) { p in
                        HStack(spacing: 8) { ForEach(pairs[p].indices, id: \.self) { pairs[p][$0] } }
                    }
                }
            }
        }
    }

    static var gridStories: [String: AnyView] {
        let l = longText
        return [
            "sides": AnyView(grid([
                [AnyView(example("Top", side: .top)), AnyView(example("Bottom", side: .bottom)),
                 AnyView(example("Inline Start", side: .inlineStart)), AnyView(example("Inline End", side: .inlineEnd))],
                [AnyView(example("Top", label: l, side: .top)), AnyView(example("Bottom", label: l, side: .bottom)),
                 AnyView(example("Inline Start", label: l, side: .inlineStart)), AnyView(example("Inline End", label: l, side: .inlineEnd))],
            ])),
            "align": AnyView(grid([
                [AnyView(example("Center", align: .center)), AnyView(example("Center", align: .forceStart)), AnyView(example("Center", align: .forceEnd))],
                [AnyView(example("Center", label: l, align: .center)), AnyView(example("Center", label: l, align: .forceStart)),
                 AnyView(example("Center", label: l, align: .forceEnd))],
            ])),
            // Date.now() under the capture's fixed clock.
            "accessories": AnyView(grid([
                [AnyView(example("None")), AnyView(example("Keyboard Shortcut", keyboardShortcut: "⌘⇧Y")), AnyView(example("Timestamp", timestamp: "1:26 PM"))],
                [AnyView(example("None", label: l)), AnyView(example("Keyboard Shortcut", label: l, keyboardShortcut: "⌘⇧Y")),
                 AnyView(example("Timestamp", label: l, timestamp: "1:26 PM"))],
            ])),
        ]
    }

    @Test(arguments: ["sides", "align", "accessories"], ["light", "dark"])
    func gridStory(name: String, theme: String) throws {
        try Snapshot.assertMatches(Self.gridStories[name]!, story: "axo-axotooltip--\(name)", theme: theme)
    }

    static func simpleExample() -> some View {
        AxoTooltip.Root(label: "Hello World", forceOpen: true) { AxoButton.Root("Hover Me", variant: .strongPrimary, size: .md) }
    }

    /// Story `InScrollArea`: a 400px scroll area (both axes) over a 3×3 grid, gap and padding
    /// 200: only the first trigger is in view, so only its tooltip shows.
    @Test(arguments: ["light", "dark"])
    func inScrollArea(theme: String) throws {
        let view = PopperStage {
            AxoScrollArea.Root(orientation: .both, scrollbarWidth: .thin) {
                AxoScrollArea.Hint(edge: .top)
                AxoScrollArea.Hint(edge: .bottom)
                AxoScrollArea.Hint(edge: .inlineStart)
                AxoScrollArea.Hint(edge: .inlineEnd)
                AxoScrollArea.Viewport {
                    AxoScrollArea.Content {
                        Grid(horizontalSpacing: 200, verticalSpacing: 200) {
                            ForEach(0..<3, id: \.self) { _ in GridRow { ForEach(0..<3, id: \.self) { _ in Self.simpleExample() } } }
                        }
                        .padding(200).fixedSize()
                    }
                }
            }
            .frame(width: 400, height: 400)
        }
        try Snapshot.assertMatches(view, story: "axo-axotooltip--in-scroll-area", theme: theme)
    }

    /// Story `InDialog`: six triggers 200 apart in the dialog body (py 200); the second is
    /// scrolled almost out of view, within the 8px collision padding, so its tooltip hides.
    @Test(arguments: ["light", "dark"])
    func inDialog(theme: String) throws {
        let view = ZStack {
            AxoBaseDialog.Host {
                AxoDialog.Content(size: .md) {
                    AxoDialog.Header { AxoDialog.Title("Title"); AxoDialog.Close() }
                    AxoDialog.Body {
                        VStack(spacing: 200) { ForEach(0..<6, id: \.self) { _ in Self.simpleExample() } }
                            .padding(.vertical, 200).frame(maxWidth: .infinity)
                    }
                    AxoDialog.Footer {
                        AxoDialog.Actions { AxoDialog.IconAction(label: "Send message", variant: .strongPrimary, symbol: "send-fill") {} }
                    }
                }
            }
        }
        .frame(width: 1200, height: 900)
        .axoLayerHost()
        try Snapshot.assertMatches(view, story: "axo-axotooltip--in-dialog", theme: theme)
    }
}
