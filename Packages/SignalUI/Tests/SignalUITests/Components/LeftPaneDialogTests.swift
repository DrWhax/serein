// LeftPaneDialog stories (ts/components/LeftPaneDialog.dom.stories.tsx): default args with the
// story's WidthDecorator (wide 400px, narrow 100px).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct LeftPaneDialogTests {
    typealias D = LeftPaneDialog<EmptyView>

    static let cases: [(String, D.DialogType?, D.Icon, WidthBreakpoint)] = [
        ("update", nil, .update, .wide), ("warning", .warning, .warning, .wide), ("info", .info, .error, .wide),
        ("error", .error, .warning, .wide), ("relink", nil, .relink, .wide), ("network", .warning, .network, .wide),
        ("narrow-update", nil, .update, .narrow), ("narrow-warning", .warning, .warning, .narrow),
        ("narrow-info", .info, .warning, .narrow), ("narrow-error", .error, .warning, .narrow),
    ]

    @Test(arguments: ["light", "dark"], 0..<10)
    func story(theme: String, index: Int) throws {
        let (name, type, icon, width) = Self.cases[index]
        let view = D(type: type, icon: icon, title: "Lorem ipsum dolor sit amet",
                     subtitle: "Consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
                     hoverText: "Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur.",
                     containerWidthBreakpoint: width, onClick: {}, clickLabel: "Click me", hasAction: true, onClose: {}, closeLabel: "Close")
            .frame(width: width == .narrow ? 100 : 400)
            // --info's block margins (2 / 6) collapse through the story root, outside the capture.
            .padding(.top, type == .info ? -2 : 0)
            .padding(.bottom, type == .info ? -6 : 0)
        try Snapshot.assertMatches(view, story: "components-leftpanedialog--\(name)", theme: theme)
    }
}
