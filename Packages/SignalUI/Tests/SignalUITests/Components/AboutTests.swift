// ts/components/About.dom.stories.tsx (fullscreen layout).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct AboutTests {
    @Test(arguments: ["light", "dark"])
    func basic(theme: String) throws {
        try Snapshot.assertMatches(About(appEnv: "production", version: "1.2.3").frame(width: 1200, height: 900), story: "components-about--basic", theme: theme)
    }
}
