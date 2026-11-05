// ts/components/conversation/AttachmentList.dom.stories.tsx, StagedGenericAttachment.dom.stories.tsx
// and StagedPlaceholderAttachment.dom.stories.tsx. (AttachmentList EmptyList renders nothing.)

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct AttachmentListTests {
    /// `fakeDraftAttachment`: a path, no dimensions.
    static func draft(_ contentType: String, _ fileName: String, url: String?, screenshot: String? = nil) -> MessageAttachment {
        var a = MessageAttachment(contentType: contentType, fileName: fileName, size: 10304, width: nil, height: nil)
        a.isDownloaded = true
        a.hasUrl = url != nil
        a.image = fixtureByURL(url)
        a.screenshot = fixtureByURL(screenshot)
        return a
    }

    static let tina = draft("image/jpeg", "tina-rolf-269345-unsplash.jpg", url: "/fixtures/tina-rolf-269345-unsplash.jpg")
    static let video = draft("video/mp4", "pixabay-Soap-Bubble-7141.mp4", url: "/fixtures/kitten-4-112-112.jpg", screenshot: "/fixtures/kitten-4-112-112.jpg")
    /// The captures caught the animated GIF on its 9th frame.
    static var gif: MessageAttachment {
        var a = draft("image/gif", "giphy-GVNv0UpeYm17e", url: "/fixtures/giphy-GVNvOUpeYmI7e.gif")
        a.image = fixtureGIFFrame("giphy-GVNvOUpeYmI7e.gif", 8)
        return a
    }

    /// With no header, the rail's 12px top margin collapses out of the story's root div (the
    /// capture starts at the rail).
    static func list(_ a: [MessageAttachment]) -> some View {
        AttachmentList(attachments: a, onAddAttachment: {}, onClickAttachment: { _ in }, onCloseAttachment: { _ in }, onClose: {})
            .padding(.top, a.count > 1 ? 0 : -12)
    }

    @Test(arguments: ["light", "dark"])
    func attachmentList(theme: String) throws {
        let c = "components-conversation-attachmentlist--"
        try Snapshot.assertMatches(Self.list([Self.tina]), story: c + "one-file", theme: theme)
        try Snapshot.assertMatches(Self.list([Self.tina]), story: c + "staged-image-missing-dimensions", theme: theme)
        // The image fails to load: the tile stays with no picture.
        try Snapshot.assertMatches(Self.list([Self.draft("image/jpeg", "tina-rolf-269345-unsplash.jpg", url: "/fixtures/this-image-does-not-exist.jpg")]),
                                   story: c + "staged-image-that-fails-to-load", theme: theme)
        try Snapshot.assertMatches(Self.list([Self.tina, Self.video, Self.gif]), story: c + "multiple-visual-attachments", theme: theme)
        try Snapshot.assertMatches(Self.list([Self.tina, Self.draft("text/plain", "lorem-ipsum.txt", url: "/fixtures/lorem-ipsum.txt"),
                                              Self.draft("audio/mp3", "incompetech-com-Agnus-Dei-X.mp3", url: "/fixtures/incompetech-com-Agnus-Dei-X.mp3"),
                                              Self.video, Self.gif]),
                                   story: c + "multiple-with-non-visual-types", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func staged(theme: String) throws {
        func generic(_ name: String) -> some View {
            StagedGenericAttachment(attachment: MessageAttachment(contentType: "text/plain", fileName: name, size: 14243, width: nil, height: nil))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        let c = "components-conversation-stagedgenericattachment--"
        try Snapshot.assertMatches(generic("manifesto.txt"), story: c + "text-file", theme: theme)
        try Snapshot.assertMatches(generic("this-is-my-very-important-manifesto-you-must-read-it.txt"), story: c + "long-name", theme: theme)
        try Snapshot.assertMatches(generic("manifesto.reallylongtxt"), story: c + "long-extension", theme: theme)
        try Snapshot.assertMatches(StagedPlaceholderAttachment {}.frame(maxWidth: .infinity, alignment: .leading),
                                   story: "components-conversation-stagedplaceholderattachment--default", theme: theme)
    }
}
