// AxoRadioGroup stories (ts/axo/controls/AxoRadioGroup.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

struct AxoRadioGroupDefaultStory: View {
    @State var value: String? = "foo"
    var body: some View {
        AxoRadioGroup.Root(value: $value) {
            AxoRadioGroup.Item(value: "foo") { AxoRadioGroup.Label("Foo") }
            AxoRadioGroup.Item(value: "bar") { AxoRadioGroup.Label("Bar") }
            AxoRadioGroup.Item(value: "baz") {
                AxoRadioGroup.Label("Lorem ipsum dolor, sit amet consectetur adipisicing elit. Veniam accusantium a aperiam quas "
                    + "perferendis error velit ipsam animi natus deserunt iste voluptatem asperiores voluptates rem odio "
                    + "necessitatibus delectus, optio officia?")
            }
        }
    }
}

@MainActor
@Suite struct AxoRadioGroupTests {
    @Test(arguments: ["light", "dark"])
    func defaultStory(theme: String) throws {
        try Snapshot.assertMatches(AxoRadioGroupDefaultStory(), story: "axo-controls-axoradiogroup--default", theme: theme)
    }
}
