// ContactName and TypingAnimation stories (ts/components/conversation/*.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct ContactNameTests {
    static let body = CSSTextStyle(AxoType.bodyLarge)

    /// ContactNameColors (ts/types/ContactNameColor.std.ts), in upstream's order.
    static let colors = ["200", "120", "300", "010", "210", "330", "230", "180", "030", "340", "270", "090", "000", "150", "240", "040", "160",
                         "280", "080", "320", "020", "140", "260", "060", "350", "100", "290", "130", "220", "050", "170", "250", "070", "190",
                         "310", "110"]

    static func name(_ title: String, firstName: String? = nil, preferFirstName: Bool = false, color: String? = nil,
                     label: ContactLabel? = nil) -> ContactName {
        ContactName(title: title, firstName: firstName, preferFirstName: preferFirstName, contactNameColor: color, contactLabel: label,
                    style: body, wrap: .wrap)
    }

    static func list(_ label: ContactLabel?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(colors, id: \.self) { c in name("Hello \(c)", color: c, label: label).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    static func narrow(_ label: ContactLabel) -> some View {
        name("Troublemaker", color: "140", label: label).frame(maxWidth: 400, alignment: .leading).clipped()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let id = "components-conversation-contactname--"
        try Snapshot.assertMatches(Self.name("Someone 🔥 Somewhere", firstName: "Ignored"), story: id + "first-name-and-title-title-preferred", theme: theme)
        try Snapshot.assertMatches(Self.name("Ignored", firstName: "Someone 🔥 Somewhere", preferFirstName: true),
                                   story: id + "first-name-and-title-first-name-preferred", theme: theme)
        try Snapshot.assertMatches(Self.narrow(ContactLabel(labelString: "this is a long label. really long. why don't we see what happens?", labelEmoji: "✅")),
                                   story: id + "with-long-label", theme: theme)
        try Snapshot.assertMatches(Self.narrow(ContactLabel(labelString: String(repeating: "𒐫", count: 24), labelEmoji: "✅")),
                                   story: id + "with-label-with-big-unicode", theme: theme)
        try Snapshot.assertMatches(Self.list(nil), story: id + "colors", theme: theme)
        try Snapshot.assertMatches(Self.list(ContactLabel(labelString: "Task Wrangler", labelEmoji: "✅")), story: id + "colors-with-labels", theme: theme)
        try Snapshot.assertMatches(Self.list(ContactLabel(labelString: "Task Wrangler")), story: id + "colors-with-no-label-emoji", theme: theme)
        try Snapshot.assertMatches(Self.list(ContactLabel(labelString: "Task Wrangler", labelEmoji: "&")), story: id + "colors-with-invalid-label-emoji",
                                   theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func typingAnimation(theme: String) throws {
        // Captures are static (frozen clock): every dot at its resting 40% opacity.
        let line = TypingAnimation().padding(.top, 8).frame(maxWidth: .infinity, maxHeight: 20, alignment: .topLeading)
        try Snapshot.assertMatches(line, story: "components-conversation-typinganimation--default", theme: theme)
        try Snapshot.assertMatches(TypingAnimation(color: .light).padding(.top, 8).frame(maxWidth: .infinity, maxHeight: 20, alignment: .topLeading)
            .padding(28).background(Color(.sRGB, red: 128 / 255, green: 128 / 255, blue: 128 / 255)),
                                   story: "components-conversation-typinganimation--light", theme: theme)
    }
}
