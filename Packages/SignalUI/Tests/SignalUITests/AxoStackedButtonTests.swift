// AxoStackedButton stories (ts/axo/AxoStackedButton.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

/// Story decorator: `flex flex-col items-center gap-4 py-8 text-center type-body-small text-secondary`
/// (with `layout: 'centered'`, the root shrinks to its content and is centred).
struct AxoStackedButtonDecorator<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .center, spacing: 16) { content }
            .cssTextColor(.labelSecondary)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
    }
}

@MainActor
@Suite struct AxoStackedButtonTests {
    @Test(arguments: ["light", "dark"])
    func basic(theme: String) throws {
        try Snapshot.assertMatches(AxoStackedButtonDecorator { AxoStackedButton.Root(symbol: "info", label: "Info") },
                                   story: "axo-axostackedbutton--basic", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func longText(theme: String) throws {
        try Snapshot.assertMatches(AxoStackedButtonDecorator {
            AxoStackedButton.Root(symbol: "info", label: "Lorem ipsum dolor sit amet consectetur adipisicing elit")
        }, story: "axo-axostackedbutton--long-text", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func disabled(theme: String) throws {
        try Snapshot.assertMatches(AxoStackedButtonDecorator { AxoStackedButton.Root(symbol: "camera", label: "Video", disabled: true) },
                                   story: "axo-axostackedbutton--disabled", theme: theme)
    }

    /// `Pending`: not pending until clicked, followed by a `<p>`.
    @Test(arguments: ["light", "dark"])
    func pending(theme: String) throws {
        try Snapshot.assertMatches(AxoStackedButtonDecorator {
            AxoStackedButton.Root(symbol: "minus-circle", label: "Remove", pending: false)
            // One line; `.nowrap` because CSSText's `.wrap` re-breaks a line whose frame
            // SwiftUI rounds just under its measured width.
            StoryText("Click to start spinner", type: .bodySmall, wrap: .nowrap)
        }, story: "axo-axostackedbutton--pending", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func row(theme: String) throws {
        try Snapshot.assertMatches(AxoStackedButtonDecorator {
            AxoStackedButton.Row(spacing: .md) {
                AxoStackedButton.Root(symbol: "camera", label: "Video")
                AxoStackedButton.Root(symbol: "phone", label: "Audio")
                AxoStackedButton.Root(symbol: "bell", label: "Hippopotomonstrosesquippedaliophobia")
                AxoStackedButton.Root(symbol: "search", label: "Search")
            }
        }, story: "axo-axostackedbutton--row", theme: theme)
    }

    /// `Tooltip`: a discouraged button under a forced-open tooltip (captured with
    /// CAPTURE_REMOUNT: on a cold page the label measured the fallback font and wrapped).
    @Test(arguments: ["light", "dark"])
    func tooltip(theme: String) throws {
        let view = AxoStackedButtonDecorator {
            AxoTooltip.Root(label: "Already in a call", forceOpen: true) {
                AxoStackedButton.Root(symbol: "phone", label: "Audio", discouraged: true)
            }
        }
        .padding(.top, 16)
        .frame(width: 1200, height: 900, alignment: .top)
        .axoLayerHost()
        try Snapshot.assertMatches(view, story: "axo-axostackedbutton--tooltip", theme: theme)
    }
}
