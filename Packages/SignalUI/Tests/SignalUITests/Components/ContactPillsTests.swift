// ContactPills stories (ts/components/ContactPills.dom.stories.tsx). getDefaultConversation
// picks each contact's first name (shown, preferFirstName) and avatar at random, per capture:
// both are read from that theme's DOM.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct ContactPillsTests {
    struct Pill { let name: String; let fixture: String? }

    static func pills(_ story: String, theme: String) -> [Pill] {
        StoryDOM(story, theme: theme).groups(startingWith: "module-ContactPill").map { nodes in
            Pill(name: nodes.first { $0.text != nil }?.text ?? "",
                 fixture: nodes.first { $0.cls.contains("module-Avatar__image") }?.fixture)
        }
    }

    static func image(_ fixture: String?) -> RGBAImage? {
        guard let fixture else { return nil }
        return fixture.hasSuffix(".gif") ? SimpleModalsTests.gifFrame(fixture, 0) : fixtureImage(fixture)
    }

    @Test(arguments: ["one-contact", "three-contacts", "four-contacts-one-with-a-long-name", "fifty-contacts"], ["light", "dark"])
    func story(name: String, theme: String) throws {
        let id = "components-contact-pills--\(name)"
        let pills = Self.pills(id, theme: theme)
        let view = ContactPills(count: pills.count) {
            ForEach(pills.indices, id: \.self) { i in
                let image = Self.image(pills[i].fixture)
                ContactPill(id: "contact-\(i)", title: pills[i].name, firstName: pills[i].name, image: image.map { AnyView(PixelImage($0, fit: .cover)) },
                            hasAvatar: image != nil, avatarStrings: avatarStrings, removeLabel: "Remove contact") { _ in }
            }
        }
        try Snapshot.assertMatches(SmallComponentStoriesTests.top(view), story: id, theme: theme)
    }
}
