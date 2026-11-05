// AxoCheckbox stories (ts/axo/AxoCheckbox.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

/// Story `Basic`: h1, then per variant four `label.my-2.flex.items-center.gap-2` rows
/// (sections add no box, so all margins collapse to 8).
struct AxoCheckboxBasicStory: View {
    struct Row: View {
        let variant: AxoCheckbox.Variant
        let label: String
        @State var checked: Bool
        var disabled = false
        var body: some View {
            HStack(spacing: 8) {
                AxoCheckbox.Root(variant: variant, checked: $checked, disabled: disabled)
                StoryText(label)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StoryText("AxoCheckbox", type: .titleLarge)
            ForEach(AxoCheckbox.Variant.allCases, id: \.self) { v in
                Row(variant: v, label: "Unchecked", checked: false)
                Row(variant: v, label: "Checked", checked: true)
                Row(variant: v, label: "Unchecked+Disabled", checked: false, disabled: true)
                Row(variant: v, label: "Checked+Disabled", checked: true, disabled: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
@Suite struct AxoCheckboxTests {
    @Test(arguments: ["light", "dark"])
    func basic(theme: String) throws {
        try Snapshot.assertMatches(AxoCheckboxBasicStory(), story: "axo-axocheckbox--basic", theme: theme)
    }
}
