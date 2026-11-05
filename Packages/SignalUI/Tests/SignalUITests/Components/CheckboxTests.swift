// CircleCheckbox and Checkbox stories (ts/components/CircleCheckbox.dom.stories.tsx,
// Checkbox.dom.stories.tsx) and their SwiftUI twins.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct CircleCheckboxTests {
    static let stories: [String: CircleCheckbox] = [
        "normal": CircleCheckbox(),
        "checked": CircleCheckbox(checked: true),
        "disabled": CircleCheckbox(disabled: true),
        "small-normal": CircleCheckbox(variant: .small),
        "small-checked": CircleCheckbox(variant: .small, checked: true),
        "small-disabled": CircleCheckbox(variant: .small, disabled: true),
        "radio-normal": CircleCheckbox(isRadio: true),
        "radio-checked": CircleCheckbox(checked: true, isRadio: true),
        "radio-disabled": CircleCheckbox(disabled: true, isRadio: true),
        "small-radio-normal": CircleCheckbox(variant: .small, isRadio: true),
        "small-radio-checked": CircleCheckbox(variant: .small, checked: true, isRadio: true),
        "small-radio-disabled": CircleCheckbox(variant: .small, disabled: true, isRadio: true),
    ]

    @Test(arguments: ["normal", "checked", "disabled", "small-normal", "small-checked", "small-disabled", "radio-normal", "radio-checked",
                      "radio-disabled", "small-radio-normal", "small-radio-checked", "small-radio-disabled"], ["light", "dark"])
    func story(name: String, theme: String) throws {
        // The story root is a block: the checkbox at the start of a full-width line.
        try Snapshot.assertMatches(Self.stories[name]!.frame(maxWidth: .infinity, alignment: .leading),
                                   story: "components-circlecheckbox--\(name)", theme: theme)
    }
}

@MainActor
@Suite struct CheckboxTests {
    static func story(_ name: String) -> Checkbox {
        switch name {
        case "checked": Checkbox(label: "Check Me!", name: "check-me", checked: true) { _ in }
        case "description": Checkbox(label: "Check Me!", description: "This is a checkbox", name: "check-me") { _ in }
        case "disabled": Checkbox(label: "Check Me!", name: "check-me", disabled: true) { _ in }
        default: Checkbox(label: "Check Me!", name: "check-me") { _ in }
        }
    }

    @Test(arguments: ["normal", "checked", "description", "disabled"], ["light", "dark"])
    func story(name: String, theme: String) throws {
        try Snapshot.assertMatches(Self.story(name), story: "components-checkbox--\(name)", theme: theme)
    }
}
