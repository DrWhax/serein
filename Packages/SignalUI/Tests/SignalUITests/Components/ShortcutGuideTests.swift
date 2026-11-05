// ShortcutGuide stories (ts/components/ShortcutGuide.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct ShortcutGuideTests {
    @Test(arguments: ["light", "dark"])
    func `default`(theme: String) throws {
        try Snapshot.assertMatches(ShortcutGuide(platform: "other", close: {}), story: "components-shortcutguide--default", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func mac(theme: String) throws {
        try Snapshot.assertMatches(ShortcutGuide(platform: "darwin", close: {}), story: "components-shortcutguide--mac", theme: theme)
    }
}
