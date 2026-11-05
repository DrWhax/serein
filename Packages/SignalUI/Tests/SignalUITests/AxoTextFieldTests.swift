// AxoTextField stories (ts/axo/fields/AxoTextField.dom.stories.tsx).

import CoreText
import SwiftUI
import Testing
@testable import SignalUI

/// A story's `useState(initial)` text value.
private struct Field<Content: View>: View {
    @State var value: String
    @ViewBuilder var content: (Binding<String>) -> Content
    init(_ initial: String, @ViewBuilder content: @escaping (Binding<String>) -> Content) {
        _value = State(initialValue: initial)
        self.content = content
    }
    var body: some View { content($value) }
}

struct AxoTextFieldBasicStory: View {
    var body: some View {
        Field("") { v in
            AxoTextField.Root(value: v, maxGraphemes: 200, maxBytes: 800) { AxoTextField.Input(placeholder: "Placeholder") }
        }
    }
}

struct AxoTextFieldIconStory: View {
    var body: some View {
        Field("Typed text") { v in
            AxoTextField.Root(value: v, maxGraphemes: 200, maxBytes: 800) {
                AxoTextField.Icon(symbol: "label")
                AxoTextField.Input(placeholder: "Placeholder")
            }
        }
    }
}

struct AxoTextFieldClearStory: View {
    var body: some View {
        Field("Typed text") { v in
            AxoTextField.Root(value: v, maxGraphemes: 200, maxBytes: 800) {
                AxoTextField.Icon(symbol: "label")
                AxoTextField.TextArea(placeholder: "Placeholder")
                AxoTextField.Clear()
            }
        }
    }
}

struct AxoTextFieldCountStory: View {
    var body: some View {
        Field("Typed text") { v in
            AxoTextField.Root(value: v, maxGraphemes: 16, maxBytes: 64) {
                AxoTextField.Icon(symbol: "label")
                AxoTextField.Input(placeholder: "Placeholder")
                AxoTextField.Count()
            }
        }
    }
}

struct AxoTextFieldTextAreaStory: View {
    var body: some View {
        Field("Typed text\ncan be\nmultiline") { v in
            StoryStack {
                AxoTextField.Root(value: v, maxGraphemes: 200, maxBytes: 800) { AxoTextField.TextArea(placeholder: "Placeholder") }
                AxoTextField.Root(value: v, maxGraphemes: 32, maxBytes: 128) {
                    AxoTextField.Icon(symbol: "label")
                    AxoTextField.TextArea(placeholder: "Placeholder")
                    AxoTextField.Count()
                    AxoTextField.Clear()
                    AxoTextField.ValidationError("This field has an error.")
                }
            }
        }
    }
}

struct AxoTextFieldActionStory: View {
    var body: some View {
        Field("Typed text") { v in
            AxoTextField.Root(value: v, maxGraphemes: 200, maxBytes: 800) {
                AxoTextField.Icon(symbol: "label")
                AxoTextField.Input(placeholder: "Placeholder")
                AxoTextField.Action(label: "More actions", symbol: "more")
            }
        }
    }
}

struct AxoTextFieldLeadingActionStory: View {
    var body: some View {
        Field("Typed text") { v in
            AxoTextField.Root(value: v, maxGraphemes: 200, maxBytes: 800) {
                AxoTextField.Input(placeholder: "Placeholder")
                AxoTextField.Action(slot: .leading, label: "More actions", symbol: "more")
            }
        }
    }
}

struct AxoTextFieldLeadingAndTrailingActionsStory: View {
    var body: some View {
        Field("Typed text") { v in
            AxoTextField.Root(value: v, maxGraphemes: 200, maxBytes: 800) {
                AxoTextField.Input(placeholder: "Placeholder")
                AxoTextField.Action(slot: .leading, label: "Pick emoji", symbol: "face-smiling")
                AxoTextField.Action(slot: .trailing, label: "More actions", symbol: "more")
            }
        }
    }
}

struct AxoTextFieldDisabledStory: View {
    var disabled = true
    var readOnly = false
    var body: some View {
        Field("Typed text") { v in
            StoryStack {
                AxoTextField.Root(value: v, maxGraphemes: 200, maxBytes: 800, disabled: disabled, readOnly: readOnly) {
                    AxoTextField.Input(placeholder: "Placeholder")
                }
                AxoTextField.Root(value: v, maxGraphemes: 200, maxBytes: 800, disabled: disabled, readOnly: readOnly) {
                    AxoTextField.Icon(symbol: "label")
                    AxoTextField.Input(placeholder: "Placeholder")
                    AxoTextField.Clear()
                    AxoTextField.Count()
                    AxoTextField.Action(label: "More actions", symbol: "more")
                }
            }
        }
    }
}

struct AxoTextFieldLoadingIndicatorStory: View {
    var body: some View {
        Field("Typed text") { v in
            AxoTextField.Root(value: v, maxGraphemes: 200, maxBytes: 800) {
                AxoTextField.Input(placeholder: "Placeholder")
                AxoTextField.LoadingIndicator(pending: true)
            }
        }
    }
}

struct AxoTextFieldLeadingSlotsStory: View {
    var body: some View {
        Field("") { v in
            LegendStack {
                StoryLegend(label: "Icon") {
                    AxoTextField.Root(value: v, maxGraphemes: 200, maxBytes: 800) {
                        AxoTextField.Icon(symbol: "label")
                        AxoTextField.Input(placeholder: "Placeholder")
                    }
                }
                StoryLegend(label: "Leading Action") {
                    AxoTextField.Root(value: v, maxGraphemes: 200, maxBytes: 800) {
                        AxoTextField.Input(placeholder: "Placeholder")
                        AxoTextField.Action(slot: .leading, label: "More actions", symbol: "more")
                    }
                }
                StoryLegend(label: "Icon + Leading Action") {
                    AxoTextField.Root(value: v, maxGraphemes: 200, maxBytes: 800) {
                        AxoTextField.Icon(symbol: "label")
                        AxoTextField.Input(placeholder: "Placeholder")
                        AxoTextField.Action(slot: .leading, label: "More actions", symbol: "more")
                    }
                    StoryHint("Rendering a leading action will hide the icon")
                }
            }
        }
    }
}

struct AxoTextFieldTrailingSlotsStory: View {
    var body: some View {
        Field("") { v in
            LegendStack {
                StoryLegend(label: "Clear") {
                    AxoTextField.Root(value: v, maxGraphemes: 200, maxBytes: 800) {
                        AxoTextField.Input(placeholder: "Placeholder")
                        AxoTextField.Clear(forceShow: true)
                    }
                }
                StoryLegend(label: "Trailing Action") {
                    AxoTextField.Root(value: v, maxGraphemes: 200, maxBytes: 800) {
                        AxoTextField.Input(placeholder: "Placeholder")
                        AxoTextField.Action(slot: .trailing, label: "More actions", symbol: "more")
                    }
                }
                StoryLegend(label: "Loading Indicator (Pending)") {
                    AxoTextField.Root(value: v, maxGraphemes: 200, maxBytes: 800) {
                        AxoTextField.Input(placeholder: "Placeholder")
                        AxoTextField.LoadingIndicator(pending: true)
                    }
                }
                StoryLegend(label: "Clear + Trailing Action") {
                    AxoTextField.Root(value: v, maxGraphemes: 200, maxBytes: 800) {
                        AxoTextField.Input(placeholder: "Placeholder")
                        AxoTextField.Clear(forceShow: true)
                        AxoTextField.Action(slot: .trailing, label: "More actions", symbol: "more")
                    }
                    StoryHint("Rendering a trailing action will hide the clear button")
                }
                StoryLegend(label: "Clear + Trailing Action + Loading Indicator (Pending)") {
                    AxoTextField.Root(value: v, maxGraphemes: 200, maxBytes: 800) {
                        AxoTextField.Input(placeholder: "Placeholder")
                        AxoTextField.Clear(forceShow: true)
                        AxoTextField.Action(slot: .trailing, label: "More actions", symbol: "more")
                        AxoTextField.LoadingIndicator(pending: true)
                    }
                    StoryHint("Rendering a pending loading indicator will hide the trailing action and the clear button")
                }
                StoryLegend(label: "Clear + Trailing Action + Loading Indicator (Not Pending)") {
                    AxoTextField.Root(value: v, maxGraphemes: 200, maxBytes: 800) {
                        AxoTextField.Input(placeholder: "Placeholder")
                        AxoTextField.Clear(forceShow: true)
                        AxoTextField.Action(slot: .trailing, label: "More actions", symbol: "more")
                        AxoTextField.LoadingIndicator(pending: false)
                    }
                    StoryHint("If the loading indicator is not visible, it will not hide other trailing items.")
                }
            }
        }
    }
}

struct AxoTextFieldErrorStory: View {
    var body: some View {
        Field("") { v in
            AxoTextField.Root(value: v, maxGraphemes: 200, maxBytes: 800) {
                AxoTextField.Input(placeholder: "Placeholder", required: true)
                AxoTextField.ValidationError("This is an error message.")
            }
        }
    }
}

@MainActor
@Suite struct AxoTextFieldTests {
    static let stories: [(String, AnyView)] = [
        ("basic", AnyView(AxoTextFieldBasicStory())),
        ("icon", AnyView(AxoTextFieldIconStory())),
        ("clear", AnyView(AxoTextFieldClearStory())),
        ("count", AnyView(AxoTextFieldCountStory())),
        ("text-area", AnyView(AxoTextFieldTextAreaStory())),
        ("action", AnyView(AxoTextFieldActionStory())),
        ("leading-action", AnyView(AxoTextFieldLeadingActionStory())),
        ("leading-and-trailing-actions", AnyView(AxoTextFieldLeadingAndTrailingActionsStory())),
        ("disabled", AnyView(AxoTextFieldDisabledStory())),
        ("read-only", AnyView(AxoTextFieldDisabledStory(disabled: false, readOnly: true))),
        ("loading-indicator", AnyView(AxoTextFieldLoadingIndicatorStory())),
        ("leading-slots", AnyView(AxoTextFieldLeadingSlotsStory())),
        ("trailing-slots", AnyView(AxoTextFieldTrailingSlotsStory())),
        ("error", AnyView(AxoTextFieldErrorStory())),
    ]

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        for (name, view) in Self.stories {
            try Snapshot.assertMatches(view, story: "axo-fields-axotextfield--\(name)", theme: theme)
        }
    }

    @Test func limits() {
        #expect(AxoBaseField.truncate("héllo", maxBytes: 3, maxGraphemes: 10) == "h\u{e9}")
        #expect(AxoBaseField.truncate("hello", maxBytes: 10, maxGraphemes: 2) == "he")
        #expect(AxoBaseField.limit(old: "abcd", new: "abXYZcd", maxBytes: 5, maxGraphemes: 5) == "abXcd")
        #expect(AxoBaseField.limit(old: "ab", new: "abc", maxBytes: 5, maxGraphemes: 5) == "abc")
        #expect(AxoBaseField.remaining("Typed text", maxBytes: 64, maxGraphemes: 16) == (6, 16))
        #expect(AxoBaseField.remaining("", maxBytes: 64, maxGraphemes: 16) == (16, 16))
    }
}
