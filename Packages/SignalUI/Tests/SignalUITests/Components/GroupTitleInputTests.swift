// ts/components/GroupTitleInput.dom.stories.tsx and GroupDescriptionInput.dom.stories.tsx.
// Disabled stacks two inputs around a <br>: the inputs' 16px margins either side of its 20px
// line (the outer margins collapse out of the story root).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct GroupTitleInputTests {
    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let title: (String, Bool) -> AnyView = { v, d in AnyView(GroupTitleInput(value: .constant(v), disabled: d)) }
        let description: (String, Bool) -> AnyView = { v, d in AnyView(GroupDescriptionInput(value: .constant(v), disabled: d)) }
        for (name, make) in [("grouptitleinput", title), ("groupdescriptioninput", description)] {
            try Snapshot.assertMatches(make("", false).frame(width: 1168), story: "components-\(name)--default", theme: theme)
            let disabled = VStack(spacing: 0) {
                make("", true)
                Color.clear.frame(height: 16 + 20 + 16)
                make("Has a value", true)
            }
            try Snapshot.assertMatches(disabled.frame(width: 1168), story: "components-\(name)--disabled", theme: theme)
        }
    }
}
