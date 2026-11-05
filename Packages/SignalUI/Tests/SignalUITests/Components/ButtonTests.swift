// Button stories (ts/components/Button.dom.stories.tsx) and their SwiftUI twins.

import SwiftUI
import Testing
@testable import SignalUI

/// Story `KitchenSink`: per variant and size, a `<p>` each with a plain, disabled and
/// discouraged button (Storybook's `p` has no margins).
struct ButtonKitchenSinkStory: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(LegacyButton.Variant.allCases, id: \.self) { variant in
                ForEach(LegacyButton.Size.allCases, id: \.self) { size in
                    LegacyButton(variant.rawValue, size: size, variant: variant)
                    LegacyButton(variant.rawValue, size: size, variant: variant, disabled: true)
                    LegacyButton(variant.rawValue, size: size, variant: variant, discouraged: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Story `AriaLabel`: a button with no children, an empty inline-block on the 20px line's
/// baseline (its bottom edge 16.9px below the line top, line box 23px).
struct ButtonAriaLabelStory: View {
    var body: some View {
        LegacyButton(nil, ariaLabel: "hello").padding(.top, 7).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Story `CustomStyles`: `style={{ transform: 'rotate(5deg)' }}` (paint only; the layout box is unrotated).
struct ButtonCustomStylesStory: View {
    var body: some View {
        LegacyButton("Hello world").rotationEffect(.degrees(5)).frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
@Suite struct ButtonTests {
    @Test(arguments: ["light", "dark"])
    func kitchenSink(theme: String) throws {
        try Snapshot.assertMatches(ButtonKitchenSinkStory(), story: "components-button--kitchen-sink", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func ariaLabel(theme: String) throws {
        try Snapshot.assertMatches(ButtonAriaLabelStory(), story: "components-button--aria-label", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func customStyles(theme: String) throws {
        try Snapshot.assertMatches(ButtonCustomStylesStory(), story: "components-button--custom-styles", theme: theme)
    }
}
