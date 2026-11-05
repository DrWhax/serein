// AxoSegmentedControl (Experimental) stories (ts/axo/AxoSegmentedControl.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

/// `Template`: an `<h2 font-mono type-title-medium>` naming the props, then the control.
struct AxoSegmentedControlTemplate: View {
    typealias SC = ExperimentalAxoSegmentedControl
    let variant: SC.Variant
    let width: SC.RootWidth
    let itemWidth: SC.ItemWidth
    var longNames = false
    var includeBadges = false
    @State var value: String? = "inbox"

    var body: some View {
        // `<h2>` is one line here; `.nowrap` avoids CSSText `.wrap` re-breaking at a rounded-down frame width.
        CSSText("variant=\(variant.rawValue), width=\(width.rawValue), itemWidth=\(itemWidth.rawValue)",
                style: .mono(size: 18, lineHeight: 24, letterSpacing: -0.252), wrap: .nowrap)
            .frame(maxWidth: .infinity, alignment: .leading)
        SC.Root(label: "Folders", width: width, itemWidth: itemWidth, variant: variant,
                value: Binding(get: { value }, set: { if let v = $0 { value = v } })) {
            SC.Item(value: "inbox") {
                SC.ItemText((longNames ? "Really Really Long Name For " : "") + "Inbox")
                if includeBadges { SC.ItemBadge(variant: .primary, value: .count(42), max: 99, label: "42 unread messages") }
            }
            SC.Item(value: "drafts") {
                SC.ItemText((longNames ? "Really Really Long Name For " : "") + "Drafts")
                if includeBadges { SC.ItemBadge(variant: .primary, value: .mention, max: 99, label: "You were mentioned") }
            }
            SC.Item(value: "sent") {
                SC.ItemText("Sent")
                if includeBadges { SC.ItemBadge(variant: .primary, value: .unread, max: 99, label: "Marked unread") }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `TemplateVariants`: `grid gap-4` of every variant × width × itemWidth.
struct AxoSegmentedControlVariantsStory: View {
    var longNames = false
    var includeBadges = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(ExperimentalAxoSegmentedControl.RootWidth.allCases.reversed(), id: \.self) { w in
                ForEach(ExperimentalAxoSegmentedControl.ItemWidth.allCases, id: \.self) { iw in
                    ForEach(ExperimentalAxoSegmentedControl.Variant.allCases, id: \.self) { v in
                        AxoSegmentedControlTemplate(variant: v, width: w, itemWidth: iw, longNames: longNames, includeBadges: includeBadges)
                    }
                }
            }
        }
    }
}

@MainActor
@Suite struct AxoSegmentedControlTests {
    @Test(arguments: ["light", "dark"])
    func basic(theme: String) throws {
        try Snapshot.assertMatches(AxoSegmentedControlVariantsStory(), story: "axo-axosegmentedcontrol-experimental--basic", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func longNames(theme: String) throws {
        try Snapshot.assertMatches(AxoSegmentedControlVariantsStory(longNames: true),
                                   story: "axo-axosegmentedcontrol-experimental--long-names", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func withBadges(theme: String) throws {
        try Snapshot.assertMatches(AxoSegmentedControlVariantsStory(includeBadges: true),
                                   story: "axo-axosegmentedcontrol-experimental--with-badges", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func longNamesWithBadges(theme: String) throws {
        try Snapshot.assertMatches(AxoSegmentedControlVariantsStory(longNames: true, includeBadges: true),
                                   story: "axo-axosegmentedcontrol-experimental--long-names-with-badges", theme: theme)
    }
}
