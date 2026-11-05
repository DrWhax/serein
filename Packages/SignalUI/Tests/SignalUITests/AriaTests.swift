// AriaLabelled (ts/axo/aria/AriaLabelled.dom.stories.tsx) and AriaClickable
// (ts/axo/AriaClickable.dom.stories.tsx) stories.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct AriaTests {
    @Test(arguments: ["light", "dark"])
    func ariaLabelled(theme: String) throws {
        let basic = AriaLabelled.Root {
            AriaLabelled.Target {
                VStack(spacing: 0) {
                    AriaLabelled.Label("Label")
                    AriaLabelled.Description("Description")
                }
            }
        }
        try Snapshot.assertMatches(SmallComponentStoriesTests.top(basic.cssTextColor(.labelPrimary)), story: "axo-aria-arialabelled--basic", theme: theme)
        let asChild = AriaLabelled.Root {
            AriaLabelled.Target {
                VStack(alignment: .leading, spacing: 0) {
                    AriaLabelled.Label("Label") { CSSText("Label", type: AxoType.bodyMedium.weight(600), color: .labelPrimary) }
                    AriaLabelled.Description("Description") { CSSText("Description", type: .caption, color: .labelSecondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        try Snapshot.assertMatches(SmallComponentStoriesTests.top(asChild), story: "axo-aria-arialabelled--as-child", theme: theme)
    }

    static func seeMore(hovered: Bool) -> CSSTextRun {
        var r = CSSTextRun("See more", color: .labelAccent)
        r.underline = hovered          // group-data-hovered:underline
        return r
    }

    /// `Basic`: the card (1px border-secondary, rounded 6, p-4, gap 16): title and text with
    /// the "See more" trigger label, then the Edit / Delete buttons in a dead area.
    @Test(arguments: ["light", "dark"])
    func ariaClickable(theme: String) throws {
        let shape = RoundedRectangle(cornerRadius: 6)
        let card = AriaClickable.Root { state in
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    CSSText("Card Title", type: .titleMedium, color: .labelPrimary)
                    CSSText(runs: [CSSTextRun("Lorem ipsum dolor, sit amet consectetur adipisicing elit... "), Self.seeMore(hovered: state.hovered)],
                            style: CSSTextStyle(AxoType.bodyLarge), color: .labelPrimary)
                        .background(AriaClickable.HiddenTrigger(label: "See more") {})
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                AriaClickable.DeadArea {
                    HStack(spacing: 16) {
                        AriaClickable.SubWidget { AxoButton.Root("Edit", variant: .impliedPrimary, size: .md) }
                        AriaClickable.SubWidget { AxoButton.Root("Delete", variant: .strongDestructive, size: .md) }
                    }
                }
            }
            .padding(17)
            .background { if state.pressed { shape.fill(AxoColor.fillPrimaryPressed) } else if state.hovered { shape.fill(AxoColor.surfaceSecondary) } }
            .overlay(shape.strokeBorder(AxoColor.borderSecondary, lineWidth: 1))
        }
        try Snapshot.assertMatches(SmallComponentStoriesTests.top(card), story: "axo-ariaclickable--basic", theme: theme)
    }
}
