// AxoDropdownMenu stories (ts/axo/AxoDropdownMenu.dom.stories.tsx): menus open in the
// layer host above the story root (full-viewport capture).

import SwiftUI
import Testing
@testable import SignalUI

/// The Storybook viewport with the story root at 16,16 and the popper layer host.
struct PopperStage<Root: View>: View {
    @ViewBuilder var root: Root
    var body: some View {
        root.padding(16)
            .frame(width: 1200, height: 900, alignment: .topLeading)
            .axoLayerHost()
    }
}

/// Story `Container`: flex h-96 w-full items-center justify-center.
@MainActor func menuContainer(_ content: some View) -> some View {
    content.frame(maxWidth: .infinity).frame(height: 384)
}

struct AxoDropdownMenuBasicStory: View {
    @State var open = true
    @State var showBookmarks = true
    @State var showFullUrls = false
    @State var person: String? = "jamie"
    var body: some View {
        PopperStage {
            menuContainer(
                AxoDropdownMenu.Root(isOpen: $open) {
                    AxoButton.Root("Open Dropdown Menu", variant: .strongPrimary, size: .md)   // Story.AutoTrigger
                } items: {
                    AxoDropdownMenu.Item("Back", symbol: "arrow-[start]", keyboardShortcut: "⌘[") {}
                    AxoDropdownMenu.Item("Forward", symbol: "arrow-[end]", keyboardShortcut: "⌘]", disabled: true) {}
                    AxoDropdownMenu.Item("Reload", keyboardShortcut: "⌘R") {}
                    AxoDropdownMenu.SubTrigger("More Tools")
                    AxoDropdownMenu.Separator()
                    AxoDropdownMenu.CheckboxItem("Show Bookmarks", keyboardShortcut: "⌘B", checked: $showBookmarks)
                    AxoDropdownMenu.CheckboxItem("Show Full URLs", symbol: "link", checked: $showFullUrls)
                    AxoDropdownMenu.Separator()
                    AxoDropdownMenu.Label("People")
                    AxoDropdownMenu.RadioGroup(value: $person) {
                        AxoDropdownMenu.RadioItem("Jamie", value: "jamie")
                        AxoDropdownMenu.RadioItem("Tyler", value: "tyler")
                    }
                })
        }
    }
}

let dropdownLongText = "Lorem ipsum dolor sit amet consectetur adipisicing elit. Cum nostrum, inventore quia tenetur sunt non ab fuga explicabo ullam tempore."

struct AxoDropdownMenuStory<Items: View>: View {
    @State var open = true
    @ViewBuilder var items: Items
    var body: some View {
        PopperStage {
            menuContainer(
                AxoDropdownMenu.Root(isOpen: $open) {
                    AxoButton.Root("Open Dropdown Menu", variant: .strongPrimary, size: .md)
                } items: { items })
        }
    }
}

@MainActor
@Suite struct AxoDropdownMenuTests {
    @Test(arguments: ["light", "dark"])
    func withHeader(theme: String) throws {
        let view = AxoDropdownMenuStory {
            AxoDropdownMenu.Header(label: "Notification profile", description: "On")
            AxoDropdownMenu.Item("Sleep") {}
            AxoDropdownMenu.Item("Work") {}
            AxoDropdownMenu.SubTrigger("Sub-menu")
        }
        try Snapshot.assertMatches(view, story: "axo-axodropdownmenu--with-header", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func withItemDescriptions(theme: String) throws {
        let view = AxoDropdownMenuStory {
            AxoDropdownMenu.Item("Custom story", symbol: "stories", description: "Visible only to specific people") {}
            AxoDropdownMenu.Item("Group story", symbol: "group", description: "Share to an existing group") {}
            AxoDropdownMenu.Item("Long description", symbol: "info", description: dropdownLongText) {}
        }
        try Snapshot.assertMatches(view, story: "axo-axodropdownmenu--with-item-descriptions", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func basic(theme: String) throws {
        try Snapshot.assertMatches(AxoDropdownMenuBasicStory(), story: "axo-axodropdownmenu--basic", theme: theme)
    }

    /// `StressTestLongText`: every kind of row with a `<strong>` prefix and the long text.
    @Test(arguments: ["light", "dark"])
    func stressTestLongText(theme: String) throws {
        func runs(_ prefix: String) -> [CSSTextRun] {
            var b = CSSTextRun(prefix + ":"); b.fontName = AxoFonts.interName(weight: 700)
            return [b, CSSTextRun(" " + dropdownLongText)]
        }
        @ViewBuilder func items() -> some View {
            AxoDropdownMenu.Item(dropdownLongText) {}.runs(runs("Item"))
            AxoDropdownMenu.Item(dropdownLongText, symbol: "megaphone", keyboardShortcut: "⌘[") {}.runs(runs("Item"))
        }
        @ViewBuilder func checkboxItems() -> some View {
            AxoDropdownMenu.CheckboxItem(dropdownLongText, checked: .constant(false)).runs(runs("CheckboxItem"))
            AxoDropdownMenu.CheckboxItem(dropdownLongText, symbol: "megaphone", keyboardShortcut: "⌘[", checked: .constant(false))
                .runs(runs("CheckboxItem"))
        }
        @ViewBuilder func content() -> some View {
            AxoDropdownMenu.Header(label: dropdownLongText, description: dropdownLongText)
            items()
            checkboxItems()
            AxoDropdownMenu.RadioGroup(value: .constant("value")) {
                AxoDropdownMenu.RadioItem(dropdownLongText, value: "value").runs(runs("RadioItem"))
                AxoDropdownMenu.RadioItem(dropdownLongText, value: "value", symbol: "megaphone", keyboardShortcut: "⌘[").runs(runs("RadioItem"))
            }
            AxoDropdownMenu.Separator()
            AxoDropdownMenu.Label(dropdownLongText).runs(runs("Label"))
            items()
            checkboxItems()
        }
        let view = AxoDropdownMenuStory {
            content()
            AxoDropdownMenu.Sub(AxoDropdownMenu.SubTrigger(dropdownLongText)) { content() }
        }
        try Snapshot.assertMatches(view, story: "axo-axodropdownmenu--stress-test-long-text", theme: theme)
    }
}
