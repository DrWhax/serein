// getStoryDuration (ts/util/getStoryDuration.dom.ts), in seconds.

import Foundation
import Testing
@testable import SignalSafe

@MainActor
@Suite struct StoryTimingTests {
    typealias Media = StoriesScreen.StoryMediaTiming

    func duration(text: String? = nil, link: Bool = false, media: Media? = nil, video: Double? = nil) -> Double? {
        StoriesScreen.storyDuration(text: text, hasLinkPreview: link, media: media, videoDuration: video)
    }

    @Test func textStories() {
        #expect(duration(text: String(repeating: "a", count: 15)) == 5)
        #expect(duration(text: String(repeating: "a", count: 16)) == 6)
        #expect(duration(text: String(repeating: "a", count: 31)) == 7)
        #expect(duration(text: "👍🏽👍🏽", link: true) == 7)                    // graphemes, +2 s for the link
        #expect(duration(text: "", link: true) == 6)                           // upstream: ceil(0/15) - 1 = -1 s
    }

    @Test func mediaStories() {
        let photo = Media(failed: false, isDownloaded: true, isGIF: false, isVideo: false, caption: nil)
        #expect(duration(media: photo) == 5)
        var captioned = photo
        captioned.caption = String(repeating: "c", count: 20)
        #expect(duration(media: captioned) == 6)
        let video = Media(failed: false, isDownloaded: true, isGIF: false, isVideo: true, caption: nil)
        #expect(duration(media: video) == nil)                                 // waits for its length
        #expect(duration(media: video, video: 12.5) == 12.5)
        #expect(duration(media: video, video: 45) == 30)
        let gif = Media(failed: false, isDownloaded: true, isGIF: true, isVideo: true, caption: nil)
        #expect(duration(media: gif, video: 1) == 5 && duration(media: gif, video: 4) == 12 && duration(media: gif, video: 20) == 30)
        #expect(duration(media: Media(failed: false, isDownloaded: false, isGIF: false, isVideo: true, caption: nil)) == nil)
        #expect(duration(media: Media(failed: true, isDownloaded: false, isGIF: false, isVideo: true, caption: nil)) == 5)
        #expect(duration() == 5)
    }
}
