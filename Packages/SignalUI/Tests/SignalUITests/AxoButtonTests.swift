// AxoButton stories (ts/axo/AxoButton.dom.stories.tsx) and their SwiftUI twins.

import SwiftUI
import Testing
@testable import SignalUI

/// Story `Basic`: every size × variant, plain / disabled / icon / arrow.
struct AxoButtonBasicStory: View {
    func rowBackground(_ v: AxoButton.Variant) -> AxoColor? {
        switch v {
        case .messageIncomingPrimary: .surfaceMessageIncoming
        case .messageOutgoingPrimary: .surfaceMessageOutgoing
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {                 // grid gap-1
            ForEach(AxoButton.Size.allCases, id: \.self) { size in
                VStack(alignment: .leading, spacing: 0) {
                    CSSText("Size: \(size.rawValue)", type: .titleMedium).padding(4)   // h2 p-1
                    ForEach(AxoButton.Variant.all, id: \.self) { v in
                        HStack(spacing: 4) {                          // flex gap-1 p-1
                            AxoButton.Root(v.rawValue, variant: v, size: size)
                            AxoButton.Root("Disabled", variant: v, size: size, disabled: true)
                            AxoButton.Root("Icon", variant: v, size: size, symbol: "info")
                            AxoButton.Root("Disabled", variant: v, size: size, symbol: "info", disabled: true)
                            AxoButton.Root("Arrow", variant: v, size: size, arrow: .next)
                            AxoButton.Root("Disabled", variant: v, size: size, arrow: .next, disabled: true)
                        }
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background { if let bg = rowBackground(v) { Rectangle().fill(bg) } }
                    }
                }
            }
        }
        .padding(16)                                                  // p-4
    }
}

/// Story `Arrows`: flex gap-2
struct AxoButtonArrowsStory: View {
    var body: some View {
        HStack(spacing: 8) {
            AxoButton.Root("Collapse", variant: .subtlePrimary, size: .md, arrow: .collapse)
            AxoButton.Root("Expand", variant: .subtlePrimary, size: .md, arrow: .expand)
            AxoButton.Root("Next", variant: .subtlePrimary, size: .md, arrow: .next)
            AxoButton.Root("External Link", variant: .subtlePrimary, size: .md, arrow: .externalLink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Story `Group`
struct AxoButtonGroupStory: View {
    var body: some View {
        StoryStack {
            AxoButton.Group {
                AxoButton.Root("One", variant: .subtleSecondary, size: .md)
                AxoButton.Root("Two", variant: .subtleSecondary, size: .md)
                AxoButton.Root("Three", variant: .subtlePrimary, size: .md)
            }
            AxoButton.Group {
                AxoButton.Root("One", variant: .subtleSecondary, size: .md, width: .grow)
                AxoButton.Root("Two", variant: .subtleSecondary, size: .md, width: .grow)
                AxoButton.Root("Three", variant: .subtlePrimary, size: .md, width: .grow)
            }
        }
    }
}

/// Story `Spinner`: a switch row (mb-4 flex gap-2), then one `flex gap-2` row per size of
/// pending "Save" buttons, which overflow and shrink per the flex algorithm.
struct AxoButtonSpinnerStory: View {
    @State var pending = true
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CSSFlex(.row, gap: 8) {
                AxoSwitch.Root(checked: $pending).flexItem(alignSelf: .start)
                StoryText("Loading", wrap: .nowrap)
            }
            CSSFlex(.column, gap: 8) {
                ForEach(AxoButton.Size.allCases, id: \.self) { size in
                    CSSFlex(.row, gap: 8) {
                        ForEach(AxoButton.Variant.all, id: \.self) { v in
                            AxoButton.Root("Save", variant: v, size: size, pending: pending, disabled: pending)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
@Suite struct AxoButtonTests {
    @Test(arguments: ["light", "dark"])
    func spinner(theme: String) throws {
        try Snapshot.assertMatches(AxoButtonSpinnerStory(), story: "axo-axobutton--spinner", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func arrows(theme: String) throws {
        try Snapshot.assertMatches(AxoButtonArrowsStory(), story: "axo-axobutton--arrows", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func group(theme: String) throws {
        try Snapshot.assertMatches(AxoButtonGroupStory(), story: "axo-axobutton--group", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func basic(theme: String) throws {
        try Snapshot.assertMatches(AxoButtonBasicStory(), story: "axo-axobutton--basic", theme: theme)
    }
}
