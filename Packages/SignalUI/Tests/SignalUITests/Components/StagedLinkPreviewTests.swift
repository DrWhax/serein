// ts/components/conversation/StagedLinkPreview.dom.stories.tsx

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct StagedLinkPreviewTests {
    static let longTitle = "This is a super-sweet site. And it's got some really amazing content in store for you if you just click that link. Can you click that link for me?"
    static let longDescription = "You're gonna love this description. Not only does it have a lot of characters, but it will also be truncated in the UI. How cool is that??"
    static let now = TimelineMessageTests.now

    static func preview(domain: String = "signal.org", title: String = "This is a super-sweet site", description: String = "This is a description") -> LinkPreview {
        LinkPreview(url: "https://www.signal.org", domain: domain, title: title, description: description, date: now.timeIntervalSince1970 * 1000)
    }

    static var kitten: MessageAttachment {
        var a = MessageAttachment(contentType: "image/jpeg")
        a.isDownloaded = true
        a.image = fixtureImage("kitten-4-112-112.jpg")
        return a
    }

    static var stories: [(String, StagedLinkPreview)] {
        [
            ("loading", StagedLinkPreview(preview: preview(domain: ""), onClose: {})),
            ("no-image", StagedLinkPreview(preview: preview(), onClose: {})),
            ("image", StagedLinkPreview(preview: preview(), image: kitten, onClose: {})),
            ("image-no-title-or-description", StagedLinkPreview(preview: preview(domain: "instagram.com", title: "", description: ""), image: kitten, onClose: {})),
            ("no-image-long-title-with-description", StagedLinkPreview(preview: preview(title: longTitle), onClose: {})),
            ("no-image-long-title-without-description", StagedLinkPreview(preview: preview(title: longTitle, description: ""), onClose: {})),
            ("image-long-title-without-description", StagedLinkPreview(preview: preview(title: longTitle), image: kitten, onClose: {})),
            ("image-long-title-and-description", StagedLinkPreview(preview: preview(title: longTitle, description: longDescription), image: kitten, onClose: {})),
            ("everything-image-title-description-and-date", StagedLinkPreview(preview: preview(title: longTitle, description: longDescription), image: kitten,
                                                                               onClose: {})),
            ("composition-input", StagedLinkPreview(preview: preview(title: longTitle, description: longDescription), image: kitten, placement: .compositionInput,
                                                    onClose: {})),
            ("composition-input-sticker-pack", StagedLinkPreview(preview: preview(title: "Cat stickers", description: "Sticker pack by Ann Chovy"), image: kitten,
                                                                 isStickerPack: true, placement: .compositionInput, onClose: {})),
        ]
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        for (name, view) in Self.stories {
            // The composition-input card's 6px margin collapses out of the story root.
            let collapsed = name.hasPrefix("composition-input")
            try Snapshot.assertMatches(TimelineMessageTests.stage(view.padding(.vertical, collapsed ? -6 : 0)),
                                       story: "components-conversation-stagedlinkpreview--\(name)", theme: theme)
        }
    }
}
