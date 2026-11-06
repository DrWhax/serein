// StoryImage stories (ts/components/StoryImage.dom.stories.tsx). fakeAttachment is 800×600;
// "Video" plays an MP4 in Storybook and is not compared.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct StoryImageTests {
    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let photo = fixtureImage("nathan-anderson-316188-unsplash.jpg")
        let good = StoryAttachmentData(image: photo, thumbnail: photo)
        let notDownloaded = StoryAttachmentData(isNotResolved: true)
        let pending = StoryAttachmentData(pending: true)
        let broken = StoryAttachmentData()                  // the URL does not load
        let error = StoryAttachmentData(error: true)
        let cases: [(String, StoryAttachmentData, Bool, Bool)] = [
            ("good-story", good, false, false), ("good-story-thumbnail", good, true, false),
            ("not-downloaded", notDownloaded, false, false), ("not-downloaded-thumbnail", notDownloaded, true, false),
            ("pending-download", pending, false, false), ("pending-download-thumbnail", pending, true, false),
            ("broken-image", broken, false, false), ("broken-image-thumbnail", broken, true, false),
            ("error-image", error, false, false), ("error-image-thumbnail", error, true, false), ("error-image-you", error, false, true),
        ]
        for (name, attachment, thumb, isMe) in cases {
            try Snapshot.assertMatches(StoryImage(attachment: attachment, firstName: "Charlie", isMe: isMe, isThumbnail: thumb),
                                       story: "components-storyimage--\(name)", theme: theme)
        }
    }
}
