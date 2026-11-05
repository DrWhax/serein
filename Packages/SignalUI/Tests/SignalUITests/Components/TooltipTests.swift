// Tooltip stories (ts/components/Tooltip.dom.stories.tsx) and their SwiftUI twins.

import SwiftUI
import Testing
@testable import SignalUI

/// The stories' `Trigger`: an inline-block span, background #eee, padding 20, radius 4.
struct TooltipStoryTrigger: View {
    var body: some View {
        StoryText("Trigger", wrap: .nowrap)
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 4).fill(AxoColor(RGBA(hex: 0xEEEEEE))))
    }
}

/// The decorator: `display: flex; justify-content: center; align-items: center; height: 100vh`
/// The capture grows the viewport to 932 (900 + 2 × 16 margins), so 100vh = 932, while the
/// screenshot is clipped to the viewport: the reference PNG is the top 916px (its JSON height
/// is corrected to match; see the Tools/capture-storybook.mjs proposal).
struct TooltipStory: View {
    var direction: TooltipPlacement = .top
    var sticky = false
    var forceDark = false
    var body: some View {
        Tooltip("Hello World", direction: direction, sticky: sticky, forceDark: forceDark) { TooltipStoryTrigger() }
            .frame(maxWidth: .infinity)
            .frame(height: 932)
    }
}

@MainActor
@Suite struct TooltipTests {
    static let stories: [String: TooltipStory] = [
        "top": TooltipStory(direction: .top),
        "right": TooltipStory(direction: .right),
        "bottom": TooltipStory(direction: .bottom),
        "left": TooltipStory(direction: .left),
        "sticky": TooltipStory(sticky: true),
        // popperModifiers offset [80, 80]: only moves a shown tooltip, and this one is hidden.
        "with-applied-popper-modifiers": TooltipStory(direction: .bottom),
        "dark-theme": TooltipStory(sticky: true, forceDark: true),
    ]

    @Test(arguments: ["top", "right", "bottom", "left", "sticky", "with-applied-popper-modifiers", "dark-theme"], ["light", "dark"])
    func story(name: String, theme: String) throws {
        try Snapshot.assertMatches(Self.stories[name]!, story: "components-tooltip--\(name)", theme: theme)
    }
}
