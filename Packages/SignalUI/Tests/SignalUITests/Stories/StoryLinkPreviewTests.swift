// StoryLinkPreview stories (ts/components/StoryLinkPreview.dom.stories.tsx): the card at the
// top-left of the story root. fakeAttachment has no dimensions, so the tall image is 1:1.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct StoryLinkPreviewTests {
    static let longTitle = "This is a super-sweet site. And it's got some really amazing content in store for you if you just click that link. Can you click that link for me?"
    static let longDescription = "You're gonna love this description. Not only does it have a lot of characters, but it will also be truncated in the UI. How cool is that??"
    static let description = "Introducing Mac Studio. Stunningly compact. Endless connectivity. And astonishing performance with M1 Max or the new M1 Ultra chip."

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let kitten = fixtureImage("kitten-4-112-112.jpg")
        func p(title: String = "Mac Studio", description: String? = Self.description, image: RGBAImage? = kitten) -> StoryLinkPreviewData {
            StoryLinkPreviewData(url: "https://www.apple.com/mac-studio/", title: title, description: description, image: image, imageSize: CGSize(width: 800, height: 600))
        }
        let cases: [(String, StoryLinkPreviewData, Bool)] = [
            ("default", p(), false), ("compact-mode", p(), true), ("no-image", p(image: nil), false),
            ("image-no-description", p(description: ""), false), ("image-no-title-or-description", p(title: "", description: ""), false),
            ("no-image-no-title-or-description", p(title: "", description: "", image: nil), false),
            ("no-image-long-title-with-description", p(title: Self.longTitle, image: nil), false),
            ("no-image-long-title-without-description", p(title: Self.longTitle, description: "", image: nil), false),
            ("image-long-title-without-description", p(title: Self.longTitle, description: ""), false),
            ("image-long-title-and-description", p(title: Self.longTitle, description: Self.longDescription), false),
        ]
        for (name, preview, compact) in cases {
            try Snapshot.assertMatches(StoryLinkPreview(preview: preview, forceCompactMode: compact), story: "components-storylinkpreview--\(name)", theme: theme)
        }
    }
}
