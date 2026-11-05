// AxoItem stories (ts/axo/items/AxoItem.dom.stories.tsx) and their SwiftUI twins.

import SwiftUI
import Testing
@testable import SignalUI

enum ItemStoryText {
    static let long = "Lorem ipsum dolor sit amet consectetur adipisicing elit. Ipsa magni rerum consequatur vero enim, laborum ullam voluptate expedita tempora amet natus nisi praesentium alias earum accusantium ex doloribus et quidem."
    static let label = "Very long label: " + long
    static let value = "Very long value: " + long
    static let description = "Very long description: " + long
}

/// `<AxoItem.Root>` with optional leading icon / value / description / arrow and a trigger.
@MainActor func storyItem(_ label: String, symbol: AxoSymbol.Name? = nil, avatar: AxoItem.IconAvatarSize? = nil, value: String? = nil,
                          description: String? = nil, trigger: Bool = true, arrow: AxoItem.ArrowKind? = nil,
                          variant: AxoItem.Variant = .secondary, disabled: Bool = false) -> some View {
    AxoItem.Root(variant: variant, disabled: disabled) {
        if let symbol {
            AxoItem.Leading {
                if let avatar { AxoItem.IconAvatar(size: avatar, symbol: symbol) } else { AxoItem.Icon(symbol: symbol) }
            }
        }
        AxoItem.Content {
            AxoItem.Label(label)
            if let value { AxoItem.Value(value) }
            if let description { AxoItem.Description(description) }
            if trigger { AxoItem.HiddenTrigger(label: "Trigger") {} }
            if let arrow { AxoItem.Trailing { AxoItem.Arrow(kind: arrow) } }
        }
    }
}

struct ItemLabelStory: View {
    var body: some View {
        StoryMaxWidth {
            AxoItem.Group {
                storyItem("Label of item")
                storyItem("Another label")
                storyItem(ItemStoryText.label)
            }
        }
    }
}

struct ItemDescriptionStory: View {
    var body: some View {
        StoryMaxWidth {
            AxoItem.Group {
                storyItem("Label of item", description: "Description of the item")
                storyItem("Another label", description: "Description with more detail about the item")
                storyItem("Yet another label", description: ItemStoryText.description)
            }
        }
    }
}

struct ItemIconStory: View {
    var body: some View {
        StoryMaxWidth {
            AxoItem.Group {
                storyItem("Label of item", symbol: "settings")
                storyItem("Another label", symbol: "appearance", description: ItemStoryText.description)
                storyItem("Item without icon", description: "Notice it stays aligned with the other items")
            }
        }
    }
}

struct ItemIconAvatarStory: View {
    var body: some View {
        StoryMaxWidth {
            ForEach([32, 36, 38, 48] as [CGFloat], id: \.self) { size in
                ItemLegend(label: "size=\(Int(size))") {
                    AxoItem.Group {
                        storyItem("Label of item", symbol: "settings", avatar: size)
                        storyItem("Another label", symbol: "appearance", avatar: size, description: ItemStoryText.description)
                        storyItem("Item without icon avatar", description: "Notice it stays aligned with the other items")
                    }
                }
            }
        }
    }
}

struct ItemValueStory: View {
    var body: some View {
        StoryMaxWidth {
            AxoItem.Group {
                storyItem("Label of item", value: "+1 555 555-5555")
                storyItem("Another label", value: "Jamie-MacBook-Pro.local", description: ItemStoryText.description)
                storyItem("Yet another label", value: "System Language", description: "Description that explains what this means")
            }
            StoryCallout([.strong("Note:"), .plain(" If you have a value, you cannot have any other type of accessory.")])
        }
    }
}

struct ItemArrowStory: View {
    var body: some View {
        StoryMaxWidth {
            AxoItem.Group {
                storyItem("Label of item", arrow: .next)
                storyItem("Another label", value: "Item value", description: ItemStoryText.description, arrow: .next)
                storyItem("Item without arrow", description: ItemStoryText.description)
                storyItem("External link ", arrow: .externalLink)
            }
            StoryCallout([.strong("Note:"), .plain(" Arrows should only be used when the item is clickable and needs an extra hint.")])
            StoryCallout([.strong("Note:"), .plain(" Arrows should not be used with any accessories except for values.")])
        }
    }
}

struct ItemActionStory: View {
    var body: some View {
        StoryMaxWidth {
            AxoItem.Group {
                AxoItem.Root {
                    AxoItem.Content {
                        AxoItem.Label("Label of item")
                        AxoItem.Accessory { AxoItem.Action("Action", variant: .subtleSecondary) }
                    }
                }
                AxoItem.Root {
                    AxoItem.Content {
                        AxoItem.Label("Label of item")
                        AxoItem.Description("Description of the item")
                        AxoItem.Accessory { AxoItem.Action("Action", variant: .subtleSecondary) }
                    }
                }
                AxoItem.Root {
                    AxoItem.Content {
                        AxoItem.Label("Another label")
                        AxoItem.Description(ItemStoryText.description)
                        AxoItem.Accessory { AxoItem.Action("Join", variant: .strongAffirmative, symbol: "phone-fill") }
                    }
                }
            }
            StoryCallout([.strong("Note:"), .plain(" There should only be one text action at a time, if you need more than one action you can use an icon action or menu.")])
            StoryCallout([.strong("Note:"), .plain(" Items with actions should not be clickable")])
        }
    }
}

struct ItemIconActionsStory: View {
    var download: some View { AxoItem.IconAction(label: "Download", variant: .impliedSecondary, symbol: "arrow-down") }
    var more: some View { AxoItem.IconAction(label: "More", variant: .impliedSecondary, symbol: "more", tooltip: false) }
    var body: some View {
        StoryMaxWidth {
            AxoItem.Group {
                AxoItem.Root {
                    AxoItem.Content {
                        AxoItem.Label("Label of item")
                        AxoItem.Trailing { download }
                    }
                }
                AxoItem.Root {
                    AxoItem.Content {
                        AxoItem.Label("Another label")
                        AxoItem.Description(ItemStoryText.description)
                        AxoItem.Trailing { more }
                    }
                }
                AxoItem.Root {
                    AxoItem.Content {
                        AxoItem.Label("Yet another label")
                        AxoItem.Description(ItemStoryText.description)
                        AxoItem.Trailing { download; more }
                    }
                }
            }
        }
    }
}

/// The stories' `<AxoSelect.Root>`: a placeholder trigger and its options.
struct StorySelect: View {
    @State var value: String?
    var disabled = false
    var options: [(String, String)] = [("option1", "Option 1"), ("option2", "Option 2"), ("option3", "Really really long item")]
    var body: some View {
        AxoSelect.Root(label: nil, value: $value, disabled: disabled) {
            AxoSelect.Trigger(placeholder: "Select an option")
            AxoSelect.Content {
                ForEach(options, id: \.0) { option in
                    AxoSelect.Item(value: option.0) { AxoSelect.ItemText(option.1) }
                }
            }
        }
    }
}

struct ItemOtherAccessoriesStory: View {
    @State var on = false
    var body: some View {
        StoryMaxWidth {
            AxoItem.Group {
                AxoItem.Root {
                    AxoItem.Content {
                        AxoItem.Label("Label of item")
                        AxoItem.Trailing { AxoSwitch.Root(checked: $on) }
                    }
                }
                AxoItem.Root {
                    AxoItem.Content {
                        AxoItem.Label("Another label")
                        AxoItem.Accessory { StorySelect() }
                    }
                }
                AxoItem.Root {
                    AxoItem.Content {
                        AxoItem.Label("Label of item")
                        AxoItem.Description("Description of the item")
                        AxoItem.Trailing { AxoSwitch.Root(checked: $on) }
                    }
                }
                AxoItem.Root {
                    AxoItem.Content {
                        AxoItem.Label("Another label")
                        AxoItem.Description(ItemStoryText.description)
                        AxoItem.Accessory { StorySelect() }
                    }
                }
            }
        }
    }
}

/// `StressTest`: a one-item group with a settings icon, a trigger and an arrow.
@MainActor func stressTest(_ label: String, value: String? = nil, description: String? = nil) -> some View {
    AxoItem.Group {
        storyItem(label, symbol: "settings", value: value, description: description, arrow: .next)
    }
}

struct ItemStressTestsStory: View {
    var body: some View {
        let L = ItemStoryText.label, V = ItemStoryText.value, D = ItemStoryText.description
        StoryMaxWidth {
            StoryCallout("These should all fit in their normal place.")
            ItemLegend(label: "Baseline") {
                stressTest("Label")
                stressTest("Label", value: "Value")
                stressTest("Label", description: "Description")
                stressTest("Label", value: "Value", description: "Description")
            }
            ItemLegend(label: "Long label") {
                StoryCallout([.plain("Long labels should "), .em("not"), .plain(" break into a stacked layout.")])
                stressTest(L)
                stressTest(L, value: "Value")
                stressTest(L, description: "Description")
                stressTest(L, value: "Value", description: "Description")
            }
            ItemLegend(label: "Long value") {
                StoryCallout("These should all break into a stacked layout.")
                stressTest("Label", value: V)
                stressTest("Label", value: V, description: "Description")
            }
            ItemLegend(label: "Long description") {
                StoryCallout([.plain("Long descriptions should "), .em("not"), .plain(" break into a stacked layout.")])
                stressTest("Label", description: D)
                stressTest("Label", value: "Value", description: D)
            }
            ItemLegend(label: "Long label + value") {
                StoryCallout("These should all break into a stacked layout.")
                stressTest(L, value: V)
                stressTest(L, value: V, description: "Description")
            }
            ItemLegend(label: "Long everything") {
                StoryCallout("These should all break into a stacked layout.")
                stressTest(L, value: V, description: D)
            }
        }
    }
}

struct ItemDisabledStory: View {
    var body: some View {
        StoryMaxWidth {
            AxoItem.Group {
                storyItem("Title of item", symbol: "settings", value: "Value of the item", description: "Description of the item",
                          arrow: .next, disabled: true)
                AxoItem.Root(disabled: true) {
                    AxoItem.Content {
                        AxoItem.Label("Another title")
                        AxoItem.Accessory { AxoSwitch.Root(checked: .constant(true), disabled: true) }
                    }
                }
                AxoItem.Root(disabled: true) {
                    AxoItem.Content {
                        AxoItem.Label("Yet another title")
                        AxoItem.Description("Description that explains what this means")
                        AxoItem.Accessory { StorySelect(value: "option1", disabled: true, options: [("option1", "Option 1")]) }
                    }
                }
            }
        }
    }
}

struct ItemDestructiveStory: View {
    var body: some View {
        StoryMaxWidth {
            AxoItem.Group {
                storyItem("Title of item", variant: .destructive)
                storyItem("Item with lots of stuff", symbol: "settings", value: "Value of the item", description: "Description of the item",
                          arrow: .next, variant: .destructive)
                AxoItem.Root(variant: .destructive, disabled: true) {
                    AxoItem.Content {
                        AxoItem.Label("Disabled item")
                        AxoItem.Accessory { AxoSwitch.Root(checked: .constant(true), disabled: true) }
                    }
                }
                AxoItem.Root(variant: .destructive) {
                    AxoItem.Content {
                        AxoItem.Label("Yet another item")
                        AxoItem.Description("Description that explains what this means")
                        AxoItem.Accessory { StorySelect(value: "option1", options: [("option1", "Option 1")]) }
                    }
                }
            }
        }
    }
}

@MainActor
@Suite struct AxoItemTests {
    @Test(arguments: ["light", "dark"]) func label(theme: String) throws {
        try itemsSnapshot(ItemLabelStory(), story: "axo-items-axoitem--label", theme: theme)
    }
    @Test(arguments: ["light", "dark"]) func description(theme: String) throws {
        try itemsSnapshot(ItemDescriptionStory(), story: "axo-items-axoitem--description", theme: theme)
    }
    @Test(arguments: ["light", "dark"]) func icon(theme: String) throws {
        try itemsSnapshot(ItemIconStory(), story: "axo-items-axoitem--icon", theme: theme)
    }
    @Test(arguments: ["light", "dark"]) func iconAvatar(theme: String) throws {
        try itemsSnapshot(ItemIconAvatarStory(), story: "axo-items-axoitem--icon-avatar", theme: theme)
    }
    @Test(arguments: ["light", "dark"]) func value(theme: String) throws {
        try itemsSnapshot(ItemValueStory(), story: "axo-items-axoitem--value", theme: theme)
    }
    @Test(arguments: ["light", "dark"]) func arrow(theme: String) throws {
        try itemsSnapshot(ItemArrowStory(), story: "axo-items-axoitem--arrow", theme: theme)
    }
    @Test(arguments: ["light", "dark"]) func action(theme: String) throws {
        try itemsSnapshot(ItemActionStory(), story: "axo-items-axoitem--action", theme: theme)
    }
    @Test(arguments: ["light", "dark"]) func iconActions(theme: String) throws {
        try itemsSnapshot(ItemIconActionsStory(), story: "axo-items-axoitem--icon-actions", theme: theme)
    }
    @Test(arguments: ["light", "dark"]) func otherAccessories(theme: String) throws {
        try itemsSnapshot(ItemOtherAccessoriesStory(), story: "axo-items-axoitem--other-accessories", theme: theme)
    }
    @Test(arguments: ["light", "dark"]) func stressTests(theme: String) throws {
        try itemsSnapshot(ItemStressTestsStory(), story: "axo-items-axoitem--stress-tests", theme: theme)
    }
    @Test(arguments: ["light", "dark"]) func disabled(theme: String) throws {
        try itemsSnapshot(ItemDisabledStory(), story: "axo-items-axoitem--disabled", theme: theme)
    }
    @Test(arguments: ["light", "dark"]) func destructive(theme: String) throws {
        try itemsSnapshot(ItemDestructiveStory(), story: "axo-items-axoitem--destructive", theme: theme)
    }
}
