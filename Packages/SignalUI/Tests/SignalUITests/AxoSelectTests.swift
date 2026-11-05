// AxoSelect stories (ts/axo/AxoSelect.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

/// `TemplateItem`
struct AxoSelectTemplateItem: View {
    let value: String
    var disabled = false
    let text: String
    var body: some View {
        AxoSelect.Item(value: value, disabled: disabled) { AxoSelect.ItemText(text) }
    }
}

/// `Template`: a food picker with three groups.
struct AxoSelectTemplate: View {
    var disabled = false
    var triggerWidth: AxoSelect.TriggerWidth? = nil
    let triggerVariant: AxoSelect.TriggerVariant
    var triggerChevron: AxoSelect.TriggerChevron? = nil
    @State var value: String? = nil

    var label: String {
        ["Food", triggerVariant.rawValue, triggerWidth?.rawValue, triggerChevron?.rawValue, disabled ? "disabled" : nil]
            .compactMap { $0 }.joined(separator: " ")
    }

    var body: some View {
        AxoSelect.Root(label: label, value: $value, disabled: disabled) {
            AxoSelect.Trigger(variant: triggerVariant, width: triggerWidth ?? .fit, chevron: triggerChevron ?? .always,
                              placeholder: "Select an item...")
            AxoSelect.Content {
                AxoSelect.Group {
                    AxoSelect.Label("Fruits")
                    AxoSelectTemplateItem(value: "apple", text: "Apple")
                    AxoSelectTemplateItem(value: "banana", text: "Banana")
                    AxoSelectTemplateItem(value: "blueberry", text: "Blueberry")
                    AxoSelectTemplateItem(value: "grapes", text: "Grapes")
                    AxoSelectTemplateItem(value: "pineapple", text: "Pineapple")
                }
                AxoSelect.Separator()
                AxoSelect.Group {
                    AxoSelect.Label("Vegetables")
                    AxoSelectTemplateItem(value: "aubergine", text: "Aubergine")
                    AxoSelectTemplateItem(value: "broccoli", text: "Broccoli")
                    AxoSelectTemplateItem(value: "carrot", disabled: true, text: "Carrot")
                    AxoSelectTemplateItem(value: "leek", text: "Leek")
                }
                AxoSelect.Separator()
                AxoSelect.Group {
                    AxoSelect.Label("Meat")
                    AxoSelectTemplateItem(value: "beef", text: "Beef")
                    AxoSelectTemplateItem(value: "chicken", text: "Chicken")
                    AxoSelectTemplateItem(value: "lamb", text: "Lamb")
                    AxoSelectTemplateItem(value: "pork", text: "Pork")
                }
            }
        }
    }
}

/// Story `Basic`: `flex min-h-96 w-full flex-col items-center justify-center gap-2` of
/// `flex w-full gap-2` rows (enabled, disabled) for every chevron × width × variant.
struct AxoSelectBasicStory: View {
    var body: some View {
        VStack(spacing: 8) {
            ForEach([AxoSelect.TriggerChevron?.none, .onHover], id: \.self) { chevron in
                ForEach([AxoSelect.TriggerWidth?.none, .full], id: \.self) { width in
                    ForEach(AxoSelect.TriggerVariant.allCases, id: \.self) { variant in
                        HStack(spacing: 8) {
                            AxoSelectTemplate(triggerWidth: width, triggerVariant: variant, triggerChevron: chevron)
                            AxoSelectTemplate(disabled: true, triggerWidth: width, triggerVariant: variant, triggerChevron: chevron)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 384)
    }
}

@MainActor
@Suite struct AxoSelectTests {
    @Test(arguments: ["light", "dark"])
    func basic(theme: String) throws {
        try Snapshot.assertMatches(AxoSelectBasicStory(), story: "axo-axoselect--basic", theme: theme)
    }

    /// Story `Open`: opened from the keyboard (Story.AutoTrigger), the content item-aligned over
    /// the centred trigger with Banana highlighted and focused.
    @Test(arguments: ["light", "dark"])
    func open(theme: String) throws {
        let view = AxoSelect.Root(label: "Food", value: .constant("banana"), isOpen: .constant(true), openedWithKeyboard: true) {
            AxoSelect.Trigger(placeholder: "Choose a food")
            AxoSelect.Content {
                AxoSelect.Group {
                    AxoSelect.Label("Fruits")
                    AxoSelectTemplateItem(value: "apple", text: "Apple")
                    AxoSelectTemplateItem(value: "banana", text: "Banana")
                    AxoSelectTemplateItem(value: "cherry", disabled: true, text: "Cherry")
                }
                AxoSelect.Separator()
                AxoSelect.Group {
                    AxoSelect.Label("Vegetables")
                    AxoSelectTemplateItem(value: "carrot", text: "Carrot")
                    AxoSelectTemplateItem(value: "leek", text: "Leek")
                }
            }
        }
        .frame(width: 1168, height: 384)
        .axoLayerHost()
        try Snapshot.assertMatches(view, story: "axo-axoselect--open", theme: theme)
    }
}
