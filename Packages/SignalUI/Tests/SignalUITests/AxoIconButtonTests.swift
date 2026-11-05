// AxoIconButton stories (ts/axo/AxoIconButton.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

/// `p-2 text-center` grid cell holding one inline-block button.
@MainActor func iconCell(_ content: some View) -> some View {
    content.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
}

struct AxoIconButtonGridStory: View {
    let rows: [String]
    let button: (Int, AxoIconButton.Variant) -> AxoIconButton.Root
    var body: some View {
        CSSGrid {
            ForEach(Array(rows.enumerated()), id: \.offset) { r, label in
                StoryGridLabel(label).gridCell(row: r, column: 0)
                ForEach(Array(AxoIconButton.Variant.all.enumerated()), id: \.offset) { c, v in
                    iconCell(button(r, v)).gridCell(row: r, column: c + 1)
                }
            }
        }
    }
}

/// Story `Variants`: one row per (theme, background), every variant on that background.
struct AxoIconButtonVariantsStory: View {
    static let backgrounds: [(String, AxoColor)] = [
        ("background-primary", .surfacePrimary), ("background-secondary", .surfaceSecondary), ("background-overlay", .fillOverlay),
        ("elevated-background-primary", .materialPrimary), ("elevated-background-secondary", .materialSecondary),
        ("elevated-background-tertiary", .materialTertiary), ("elevated-background-quaternary", .materialQuaternary),
    ]
    var body: some View {
        let rows = ["light", "dark"].flatMap { t in Self.backgrounds.map { (t, $0.0, $0.1) } }
        CSSGrid {
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                StoryGridLabel("\(row.1) (\(row.0))").gridCell(row: r, column: 0)
                ForEach(Array(AxoIconButton.Variant.all.enumerated()), id: \.offset) { c, v in
                    iconCell(AxoIconButton.Root(label: v.rawValue, variant: v, size: .lg, symbol: "lock-fill"))
                        .background(Rectangle().fill(row.2))
                        .background(Rectangle().fill(AxoColor.surfacePrimary))
                        .environment(\.colorScheme, row.0 == "dark" ? .dark : .light)   // scheme-only-*
                        .gridCell(row: r, column: c + 1)
                }
            }
        }
    }
}

@MainActor
@Suite struct AxoIconButtonTests {
    @Test(arguments: ["light", "dark"])
    func basic(theme: String) throws {
        try Snapshot.assertMatches(AxoIconButton.Root(label: "More actions", variant: .strongSecondary, size: .lg, symbol: "more"),
                                   story: "axo-axoiconbutton--basic", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func variants(theme: String) throws {
        try Snapshot.assertMatches(AxoIconButtonVariantsStory(), story: "axo-axoiconbutton--variants", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func sizes(theme: String) throws {
        let sizes = AxoIconButton.Size.allCases
        try Snapshot.assertMatches(AxoIconButtonGridStory(rows: sizes.map(\.rawValue)) { r, v in
            AxoIconButton.Root(label: "More actions", variant: v, size: sizes[r], symbol: "more")
        }, story: "axo-axoiconbutton--sizes", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func states(theme: String) throws {
        try Snapshot.assertMatches(AxoIconButtonGridStory(rows: ["disabled=true", "pressed=false", "pressed=true"]) { r, v in
            AxoIconButton.Root(label: "More actions", variant: v, size: .lg, symbol: "more", pressed: r == 0 ? nil : r == 2, disabled: r == 0)
        }, story: "axo-axoiconbutton--states", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func spinners(theme: String) throws {
        let sizes = AxoIconButton.Size.allCases
        try Snapshot.assertMatches(AxoIconButtonGridStory(rows: sizes.map(\.rawValue)) { r, v in
            AxoIconButton.Root(label: "More actions", variant: v, size: sizes[r], symbol: "more", pending: true)
        }, story: "axo-axoiconbutton--spinners", theme: theme)
    }
}
