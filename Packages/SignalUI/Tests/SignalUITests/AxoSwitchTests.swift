// AxoSwitch stories (ts/axo/AxoSwitch.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

/// Story `Basic`: h1 + four `label.my-2.flex.items-center.gap-2` rows (margins collapse to 8).
struct AxoSwitchBasicStory: View {
    struct Row: View {
        let label: String
        @State var checked: Bool
        var disabled = false
        var body: some View {
            HStack(spacing: 8) {
                AxoSwitch.Root(checked: $checked, disabled: disabled)
                StoryText(label)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StoryText("AxoSwitch", type: .titleLarge)
            Row(label: "Unchecked", checked: false)
            Row(label: "Checked", checked: true)
            Row(label: "UncheckedDisabled", checked: false, disabled: true)
            Row(label: "CheckedDisabled", checked: true, disabled: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
@Suite struct AxoSwitchTests {
    @Test(arguments: ["light", "dark"])
    func basic(theme: String) throws {
        try Snapshot.assertMatches(AxoSwitchBasicStory(), story: "axo-axoswitch--basic", theme: theme)
    }
}
