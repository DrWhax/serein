// NavTabs stories (ts/components/NavTabs.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct NavTabsTests {
    @Test(arguments: ["light", "dark"])
    func hasPendingUpdate(theme: String) throws {
        let view = NavTabs(selected: .chats, hasPendingUpdate: true) { _ in
            StoryText("Chats Tab goes here")
        }
        .fixedSize(horizontal: false, vertical: true)
        try Snapshot.assertMatches(view, story: "components-navtabs--has-pending-update", theme: theme)
    }
}
