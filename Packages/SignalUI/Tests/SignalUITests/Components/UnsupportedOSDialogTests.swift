// UnsupportedOSDialog and LeftPaneBanner stories.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct UnsupportedOSDialogTests {
    @Test(arguments: ["light", "dark"])
    func iterations(theme: String) throws {
        // The story's expirationTimestamp is Date.now() + 5 days: Nov 9, 2026 at capture time.
        let expiration = Date(timeIntervalSince1970: 1_793_802_854 + 5 * 86_400)
        let permutations: [(String, WidthBreakpoint, LeftPaneDialogType)] = [
            ("Warning (wide container)", .wide, .warning), ("Warning (narrow container)", .narrow, .warning),
            ("Error (wide container)", .wide, .error), ("Error (narrow container)", .narrow, .error),
        ]
        let view = VStack(alignment: .leading, spacing: 0) {
            ForEach(permutations, id: \.0) { title, width, type in
                StoryText(title)
                FakeLeftPaneContainer(width) {
                    UnsupportedOSDialog(containerWidthBreakpoint: width, expirationTimestamp: expiration, type: type, os: "macOS")
                }
            }
        }
        .environment(\.timeZone, TimeZone(identifier: "GMT")!)
        try Snapshot.assertMatches(view, story: "components-unsupportedosdialog--iterations", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func leftPaneBanner(theme: String) throws {
        // margin-block 4px 8px: the top margin collapses out of the story root.
        let view = LeftPaneBanner(actionText: "Fix now", onClick: {}, text: "Recoverable issue detected").padding(.vertical, -4).padding(.bottom, 4)
        try Snapshot.assertMatches(view, story: "components-leftpanebanner--defaults", theme: theme)
    }
}
