// Avatar stories (ts/components/Avatar.dom.stories.tsx) and their SwiftUI twins.

import SwiftUI
import Testing
@testable import SignalUI

/// English strings of `icu:contactAvatarAlt`, `icu:unknownContact`, `icu:deletedAccount`, `icu:Avatar__View`.
let avatarStrings = AvatarStrings(contactAvatarAlt: { "Avatar for contact \($0)" }, unknownContact: "Unknown contact",
                                  deletedAccount: "Deleted Account", view: "View")

/// `createProps` + `Template`: one avatar per AvatarSize, inline (vertical-align: middle) in a row.
struct AvatarTemplateStory: View {
    var title = ""
    var conversationType: AvatarConversationType = .direct
    var color = AxoTokens.Avatar.allColorNames[0]
    var hasAvatar = false
    var loading = false
    var noteToSelf = false
    var searchResult = false
    /// `avatarUrl`: the image (`.module-Avatar__image`, background-size cover).
    var image: RGBAImage? = nil
    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(AvatarSize.allCases, id: \.self) { size in
                Avatar(strings: avatarStrings, title: title, size: size.rawValue, conversationType: conversationType, color: color,
                       image: image.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: hasAvatar || image != nil, loading: loading,
                       noteToSelf: noteToSelf, searchResult: searchResult, onClick: {})
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Story `Colors`: an 80px avatar per AvatarColors entry.
struct AvatarColorsStory: View {
    var body: some View {
        HStack(spacing: 0) {
            ForEach(AxoTokens.Avatar.allColorNames, id: \.self) { color in
                Avatar(strings: avatarStrings, title: "", size: 80, conversationType: .direct, color: color, onClick: {})
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
@Suite struct AvatarTests {
    static func story(_ name: String) -> AnyView {
        switch name {
        case "one-word-name": AnyView(AvatarTemplateStory(title: "John"))
        case "two-word-name": AnyView(AvatarTemplateStory(title: "John Smith"))
        case "wide-initials": AnyView(AvatarTemplateStory(title: "Walter White"))
        case "three-word-name": AnyView(AvatarTemplateStory(title: "Walter H. White"))
        case "note-to-self": AnyView(AvatarTemplateStory(noteToSelf: true))
        case "contact-icon": AnyView(AvatarTemplateStory())
        case "group-icon": AnyView(AvatarTemplateStory(conversationType: .group))
        case "search-icon": AnyView(AvatarTemplateStory(searchResult: true))
        case "colors": AnyView(AvatarColorsStory())
        case "broken-color": AnyView(AvatarTemplateStory(color: "nope"))
        // avatarUrl 'badimage.png' fails to load: hasAvatar is set but the URL counts as a
        // local image, so the fallback is the icon (no initials: the title is empty).
        case "broken-avatar": AnyView(AvatarTemplateStory())
        case "broken-avatar-for-group": AnyView(AvatarTemplateStory(conversationType: .group))
        case "loading": AnyView(AvatarTemplateStory(loading: true))
        // Chromium animates GIFs on the compositor's clock, not the page's frozen one: the
        // capture shows frame 11 (of 40, 60ms each).
        case "default": AnyView(AvatarTemplateStory(image: SimpleModalsTests.gifFrame("giphy-GVNvOUpeYmI7e.gif", 11)))
        case "wide-image": AnyView(AvatarTemplateStory(image: fixtureImage("wide.jpg")))
        // TemplateSingle: one 80px avatar.
        case "blurred-based-on-props", "force-blurred": AnyView(single(blur: .blurPicture))
        case "blurred-with-click-to-view": AnyView(single(blur: .blurPictureWithClickToView))
        case "story-unread": AnyView(single(storyRing: .unread))
        case "story-read": AnyView(single(storyRing: .read))
        default: fatalError(name)
        }
    }

    static func single(blur: AvatarBlur = .noBlur, storyRing: HasStories? = nil) -> some View {
        Avatar(strings: avatarStrings, title: "", size: 80, conversationType: .direct, color: AxoTokens.Avatar.allColorNames[0],
               image: fixtureImage("kitten-3-64-64.jpg").map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: true, storyRing: storyRing,
               blur: blur, onClick: {})
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @Test(arguments: ["one-word-name", "two-word-name", "wide-initials", "three-word-name", "note-to-self", "contact-icon", "group-icon",
                      "search-icon", "colors", "broken-color", "broken-avatar", "broken-avatar-for-group", "loading",
                      "default", "wide-image", "blurred-based-on-props", "force-blurred", "blurred-with-click-to-view", "story-unread", "story-read"],
          ["light", "dark"])
    func story(name: String, theme: String) throws {
        try Snapshot.assertMatches(Self.story(name), story: "components-avatar--\(name)", theme: theme)
    }

    @Test func initials() {
        #expect(Avatar.initials("John Smith") == "JS")
        #expect(Avatar.initials("Walter H. White") == "WW")
        #expect(Avatar.initials("John") == "J")
        #expect(Avatar.initials("AB") == "AB")
        #expect(Avatar.initials("  ") == nil)
        #expect(Avatar.initials("+1 555") == nil)
    }
}
