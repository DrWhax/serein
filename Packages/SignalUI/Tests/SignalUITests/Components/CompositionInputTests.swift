// ts/components/CompositionInput.dom.stories.tsx. The input focuses itself on open (shown as
// keyboard focus). In Mentions the draft's mention has no matching group member, so Quill
// shows its replacement text as plain text.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct CompositionInputTests {
    static let multiline = """
        here's some starting text
        and more on another line
        and yet another line
        and yet another line
        and yet another line
        and yet another line
        and yet another line
        and yet another line
        and we're done
        """
    static let emojis = "\u{2063}😐😐😐😐😐😐😐\n😐😐😐😐😐😐😐\n😐😐😐😂\u{2063}😐😐😐\n😐😐😐😐😐😐😐\n😐😐😐😐😐😐😐"

    static func input(_ text: String = "", large: Bool = false, disabled: Bool = false, viewOnce: Bool = false, viewOnceActive: Bool = false) -> CompositionInput {
        CompositionInput(text: .constant(text), large: large, disabled: disabled, showViewOnceButton: viewOnce, isViewOnceActive: viewOnceActive)
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let cases: [(String, AnyView)] = [
            ("default", AnyView(Self.input())),
            ("large", AnyView(Self.input(large: true))),
            ("disabled", AnyView(Self.input(disabled: true))),
            ("starting-text", AnyView(Self.input("here's some starting text"))),
            ("multiline-text", AnyView(Self.input(Self.multiline))),
            ("emojis", AnyView(Self.input(Self.emojis))),
            ("mentions", AnyView(Self.input("send @Kate Beaton a message"))),
            ("no-formatting-menu", AnyView(Self.input())),
            ("view-once-button", AnyView(Self.input(viewOnce: true))),
            ("view-once-button-active", AnyView(Self.input(viewOnce: true, viewOnceActive: true))),
            ("recovery-key-warning", AnyView(VStack(alignment: .leading, spacing: 0) {
                CSSText(runs: [CSSTextRun("Paste "), CSSTextRun("AEP", fontName: "Menlo-Regular"), CSSTextRun(" into the input.")], style: LegacyType.body1())
                Self.input()
            })),
        ]
        for (name, view) in cases {
            try Snapshot.assertMatches(view.frame(width: 1168, alignment: .topLeading), story: "components-compositioninput--\(name)", theme: theme)
        }
    }
}
