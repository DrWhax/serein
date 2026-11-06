import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct CallingHeaderTests {
    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        try Snapshot.assertMatches(CallingHeader(participantCount: 0, togglePip: {}, toggleSettings: { _ in }), story: "components-callingheader--default",
                                   theme: theme)
        try Snapshot.assertMatches(CallingHeader(participantCount: 0, onCancel: {}, toggleSettings: { _ in }), story: "components-callingheader--lobby-style",
                                   theme: theme)
    }
}
