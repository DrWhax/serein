// AxoTabs stories (ts/axo/AxoTabs.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

/// The content texts are single lines; `.nowrap` because CSSText's `.wrap` re-breaks a
/// line whose frame SwiftUI rounds just under its measured width (see the report).
struct AxoTabsBasicStory: View {
    @State var value = "1"
    var body: some View {
        AxoTabs.Root(value: $value) {
            AxoTabs.List {
                AxoTabs.Trigger(value: "1", "One")
                AxoTabs.Trigger(value: "2", "Two")
                AxoTabs.Trigger(value: "3", "Three")
            }
            AxoTabs.Content(value: "1") { StoryText("One Content", wrap: .nowrap) }
            AxoTabs.Content(value: "2") { StoryText("Two Content", wrap: .nowrap) }
            AxoTabs.Content(value: "3") { StoryText("Three Content", wrap: .nowrap) }
        }
    }
}

@MainActor
@Suite struct AxoTabsTests {
    @Test(arguments: ["light", "dark"])
    func basic(theme: String) throws {
        try Snapshot.assertMatches(AxoTabsBasicStory(), story: "axo-axotabs--basic", theme: theme)
    }
}
