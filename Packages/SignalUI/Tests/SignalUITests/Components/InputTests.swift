// Input stories (ts/components/Input.dom.stories.tsx) and their SwiftUI twins.

import SwiftUI
import Testing
@testable import SignalUI

/// The stories' `Controller`: an Input bound to local state (initially empty).
struct InputStory: View {
    var disabled = false
    var disableSpellcheck = false
    var expandable = false
    var hasClearButton = false
    var maxLengthCount = 0
    var shouldShowClearButton = false
    var whenToShowRemainingCount = Int.max
    @State var value = ""
    var body: some View {
        // English `icu:cancel`.
        Input(value: $value, placeholder: "Enter some text here", clearLabel: "Cancel", disabled: disabled, disableSpellcheck: disableSpellcheck,
              expandable: expandable, hasClearButton: hasClearButton, shouldShowClearButton: shouldShowClearButton, maxLengthCount: maxLengthCount,
              whenToShowRemainingCount: whenToShowRemainingCount)
    }
}

@MainActor
@Suite struct InputTests {
    static let stories: [String: InputStory] = [
        "simple": InputStory(),
        "has-clear-button": InputStory(hasClearButton: true),
        "clear-button-forced-with-no-data": InputStory(hasClearButton: true, shouldShowClearButton: true),
        "character-count": InputStory(maxLengthCount: 10),
        "character-count-customizable-show": InputStory(maxLengthCount: 64, whenToShowRemainingCount: 32),
        "expandable": InputStory(expandable: true),
        "expandable-w-count": InputStory(expandable: true, hasClearButton: true, maxLengthCount: 140, whenToShowRemainingCount: 0),
        "disabled": InputStory(disabled: true),
        "spellcheck-disabled": InputStory(disableSpellcheck: true),
    ]

    @Test(arguments: ["simple", "has-clear-button", "clear-button-forced-with-no-data", "character-count", "character-count-customizable-show",
                      "expandable", "expandable-w-count", "disabled", "spellcheck-disabled"], ["light", "dark"])
    func story(name: String, theme: String) throws {
        try Snapshot.assertMatches(Self.stories[name]!, story: "components-input--\(name)", theme: theme)
    }
}
