// AxoTheme story (ts/axo/AxoTheme.dom.stories.tsx): sections of closed triggers (tooltip,
// dropdown menu, context menu and dialog triggers are their AxoButton children; the select
// shows its trigger), without / with overrides.

import SwiftUI
import Testing
@testable import SignalUI

struct AxoThemeStory: View {
    struct SelectTest: View {
        @State var value: String?
        var body: some View {
            AxoSelect.Root(label: "AxoSelect", value: $value) {
                AxoSelect.Trigger(placeholder: "AxoSelect")
                AxoSelect.Content {
                    AxoSelect.Item(value: "1") { AxoSelect.ItemText("Item 1") }
                    AxoSelect.Item(value: "2") { AxoSelect.ItemText("Item 2") }
                }
            }
        }
    }

    /// `flex gap-2`
    struct TestCases: View {
        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                AxoButton.Root("AxoTooltip", variant: .strongSecondary, size: .md)
                AxoButton.Root("AxoDropdownMenu", variant: .strongSecondary, size: .md)
                AxoButton.Root("AxoContextMenu", variant: .strongSecondary, size: .md)
                SelectTest()
                AxoButton.Root("AxoDialog", variant: .strongPrimary, size: .md)
                AxoButton.Root("AxoAlertDialog", variant: .strongPrimary, size: .md)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// `section.flex.flex-col.gap-2.bg-surface-primary.p-4` with an `h2.type-title-small.text-primary`
    struct Section<Content: View>: View {
        let label: String
        @ViewBuilder var content: Content
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                CSSText(label, type: .titleSmall, color: .labelPrimary)
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AxoColor.surfacePrimary)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Section(label: "Without override") { TestCases() }
            AxoThemeOverride(theme: .auto) { Section(label: "Auto") { TestCases() } }
            AxoThemeOverride(theme: .forceLight) { Section(label: "Force Light") { TestCases() } }
            AxoThemeOverride(theme: .forceDark) {
                Section(label: "Force Dark") {
                    TestCases()
                    AxoThemeOverride(theme: .auto) { Section(label: "Auto (Escape from an override)") { TestCases() } }
                }
            }
        }
    }
}

@MainActor
@Suite struct AxoThemeTests {
    @Test(arguments: ["light", "dark"])
    func basic(theme: String) throws {
        try Snapshot.assertMatches(AxoThemeStory(), story: "axo-axotheme--basic", theme: theme)
    }
}
