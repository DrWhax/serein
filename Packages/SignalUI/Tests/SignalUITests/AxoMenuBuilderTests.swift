// AxoMenuBuilder stories (ts/axo/AxoMenuBuilder.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

/// Story `Template`: the browser-like menu, rendered by `renderer`.
struct AxoMenuBuilderTemplate<Trigger: View>: View {
    let renderer: AxoMenuBuilder.Renderer
    var isOpen = false
    @ViewBuilder var trigger: Trigger
    @State var showBookmarks = true
    @State var showFullUrls = false
    @State var person: String? = "jamie"

    var body: some View {
        AxoMenuBuilder.Root(renderer: renderer, isOpen: .constant(isOpen)) { trigger } items: {
            AxoMenuBuilder.Item("Back", symbol: "arrow-[start]", keyboardShortcut: "⌘[") {}
            AxoMenuBuilder.Item("Forward", symbol: "arrow-[end]", keyboardShortcut: "⌘]", disabled: true) {}
            AxoMenuBuilder.Item("Reload", keyboardShortcut: "⌘R") {}
            AxoMenuBuilder.Sub(AxoMenuBuilder.SubTrigger("More Tools")) {
                AxoMenuBuilder.Item("Save Page As...", keyboardShortcut: "⌘S") {}
                AxoMenuBuilder.Item("Create Shortcut...") {}
                AxoMenuBuilder.Item("Name Window...") {}
                AxoMenuBuilder.Separator()
                AxoMenuBuilder.Item("Developer Tools") {}
            }
            AxoMenuBuilder.Separator()
            AxoMenuBuilder.CheckboxItem("Show Bookmarks", keyboardShortcut: "⌘B", checked: $showBookmarks)
            AxoMenuBuilder.CheckboxItem("Show Full URLs", symbol: "link", checked: $showFullUrls)
            AxoMenuBuilder.Separator()
            AxoMenuBuilder.Label("People")
            AxoMenuBuilder.RadioGroup(value: $person) {
                AxoMenuBuilder.RadioItem("Jamie", value: "jamie")
                AxoMenuBuilder.RadioItem("Tyler", value: "tyler")
            }
        }
    }
}

@MainActor
@Suite struct AxoMenuBuilderTests {
    /// `Basic`: the dropdown renderer (auto-opened) beside the context-menu one, gap 32.
    @Test(arguments: ["light", "dark"])
    func basic(theme: String) throws {
        let view = PopperStage {
            menuContainer(
                HStack(spacing: 32) {
                    AxoMenuBuilderTemplate(renderer: .dropdownMenu, isOpen: true) {
                        AxoButton.Root("Open Dropdown Menu", variant: .strongPrimary, size: .md)
                    }
                    AxoMenuBuilderTemplate(renderer: .contextMenu) {
                        CSSText("Right-Click", type: .bodyLarge, wrap: .nowrap, color: .labelAccent).padding(48).background(AxoColor.fillPrimary)
                    }
                })
        }
        try Snapshot.assertMatches(view, story: "axo-axomenubuilder--basic", theme: theme)
    }
}
