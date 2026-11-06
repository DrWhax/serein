// StoryCreator stories (ts/components/StoryCreator.dom.stories.tsx): with no file the creator is
// TextStoryCreator, a full-window portal. The link preview only shows once applied, so
// "link-preview" and "first-time" look like "default"; "sending" swaps Next for a spinner.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct TextStoryCreatorTests {
    @Test(arguments: ["default", "link-preview", "first-time", "sending"], ["light", "dark"])
    func story(name: String, theme: String) throws {
        let preview = StoryLinkPreviewData(url: "https://www.catsandkittens.lolcats/kittens/page/1", title: "Cats & Kittens LOL",
                                           image: fixtureImage("kitten-4-112-112.jpg"), domain: "www.catsandkittens.lolcats")
        let view = TextStoryCreator(isSending: name == "sending", linkPreview: name == "link-preview" ? preview : nil)
        try Snapshot.assertMatches(view, story: "components-storycreator--\(name)", theme: theme)
    }
}
