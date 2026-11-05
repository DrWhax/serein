// ts/components/DebugLogWindow.dom.stories.tsx: fetchLogs resolves 'Sample logs' (loaded).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct DebugLogWindowTests {
    @Test(arguments: ["light", "dark"])
    func basic(theme: String) throws {
        try Snapshot.assertMatches(DebugLogWindow(initialLogs: "Sample logs").frame(width: 1168, height: 210), story: "components-debuglogwindow--basic",
                                   theme: theme)
    }
}
