// AxoContextMenu stories (ts/axo/AxoContextMenu.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

/// Story `Basic`: a `bg-primary p-12 text-accent` box, right-clicked at its centre by
/// Story.AutoTrigger (PointerEvent clientX/Y truncated to whole pixels).
struct AxoContextMenuBasicStory: View {
    /// The AutoTrigger's click: the box's centre in page coordinates, truncated to whole
    /// pixels, converted back to box coordinates (box centred in the 1168-wide container at x 16).
    static var autoClick: CGPoint {
        // Blink snaps box geometry to 1/64px (LayoutUnit), which puts the centre a hair
        // under the exact value; the event's clientX then truncates to a whole pixel.
        func lu(_ v: CGFloat) -> CGFloat { (v * 64).rounded(.down) / 64 }
        let w = lu(CSSTextLayout.make("Right-Click", CSSTextStyle(.bodyLarge), wrap: .nowrap, maxWidth: nil).width + 96)
        let x = lu(16 + (1168 - w) / 2)
        // (Chromium's centre is 599.99 for an exact-ish 600; our text width can differ by
        // ~0.01pt, so truncate just below the centre.)
        return CGPoint(x: (x + w / 2 - 0.02).rounded(.down) - x, y: 58)
    }
    @State var location: CGPoint? = AxoContextMenuBasicStory.autoClick
    @State var showBookmarks = true
    @State var showFullUrls = false
    @State var person: String? = "jamie"
    var body: some View {
        PopperStage {
            menuContainer(
                AxoContextMenu.Root(location: $location) {
                    CSSText("Right-Click", type: .bodyLarge, wrap: .nowrap, color: .labelAccent)
                        .padding(48)
                        .background(AxoColor.fillPrimary)
                } items: {
                    AxoContextMenu.Item("Back", symbol: "arrow-[start]", keyboardShortcut: "⌘[") {}
                    AxoContextMenu.Item("Forward", symbol: "arrow-[end]", keyboardShortcut: "⌘]", disabled: true) {}
                    AxoContextMenu.Item("Reload", keyboardShortcut: "⌘R") {}
                    AxoContextMenu.SubTrigger("More Tools")
                    AxoContextMenu.Separator()
                    AxoContextMenu.CheckboxItem("Show Bookmarks", keyboardShortcut: "⌘B", checked: $showBookmarks)
                    AxoContextMenu.CheckboxItem("Show Full URLs", symbol: "link", checked: $showFullUrls)
                    AxoContextMenu.Separator()
                    AxoContextMenu.Label("People")
                    AxoContextMenu.RadioGroup(value: $person) {
                        AxoContextMenu.RadioItem("Jamie", value: "jamie")
                        AxoContextMenu.RadioItem("Tyler", value: "tyler")
                    }
                })
        }
    }
}

@MainActor
@Suite struct AxoContextMenuTests {
    @Test(arguments: ["light", "dark"])
    func basic(theme: String) throws {
        try Snapshot.assertMatches(AxoContextMenuBasicStory(), story: "axo-axocontextmenu--basic", theme: theme)
    }
}
