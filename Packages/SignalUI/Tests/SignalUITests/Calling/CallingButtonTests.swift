import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct CallingButtonTests {
    static let stories: [(String, CallingButtonType)] = [
        ("audio-on", .audioOn), ("audio-off", .audioOff), ("audio-disabled", .audioDisabled), ("video-on", .videoOn), ("video-off", .videoOff),
        ("video-disabled", .videoDisabled), ("presenting-on", .presentingOn), ("presenting-off", .presentingOff), ("tooltip-right", .ringOn),
    ]

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        for (name, type) in Self.stories {
            try Snapshot.assertMatches(CallingButton(type, onClick: {}), story: "components-callingbutton--\(name)", theme: theme)
        }
    }

    @Test(arguments: ["light", "dark"])
    func kitchenSink(theme: String) throws {
        let view = VStack(alignment: .leading, spacing: 0) {
            ForEach(CallingButtonType.allCases, id: \.self) { CallingButton($0, onClick: {}) }
        }
        try Snapshot.assertMatches(view, story: "components-callingbutton--kitchen-sink", theme: theme)
    }
}
