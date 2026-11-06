// StoryViewer stories (ts/components/StoryViewer.dom.stories.tsx), full window. The sender
// (getDefaultConversation) and how far the progress bar had played are read back from each
// capture; the pictures and captions are the story's.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct StoryViewerTests {
    static let now = StoriesListTests.now
    static let snowycle = "Snowycle, snowycle, snowycle\nI want to ride my snowycle, snowycle, snowycle\nI want to ride my snowycle\nI want to ride my snow\nI want to ride my snowycle\nI want to ride it where I like\n"

    static func data(_ story: String, _ theme: String) -> StoryViewerData {
        let dom = StoryDOM("components-storyviewer--\(story)", theme: theme)
        let title = dom.nodes.first { $0.cls == "StoryViewer__meta--title" }?.text ?? ""
        let avatars = dom.nodes.filter { $0.cls.contains("module-Avatar__image") }
        let contents = dom.nodes.filter { $0.cls.split(separator: " ").contains("module-Avatar__contents") }
        let image = avatars.first?.fixture.flatMap { fixtureImage($0) }
        let color = CallingAdhocCallInfoTests.colorName(contents.first?.style["color"])
        let segments = dom.nodes.filter { $0.cls == "StoryProgressSegment" }
        let bars = dom.nodes.filter { $0.cls == "StoryProgressSegment__bar" }
        // The current segment: the first whose bar is not full.
        let current = Array(zip(segments, bars)).firstIndex { pair in pair.1.rect[0] + pair.1.rect[2] < pair.0.rect[0] + pair.0.rect[2] - 0.5 }
            .map { max(0, $0 == 0 ? 0 : $0) } ?? max(0, segments.count - 1)
        let fill: (Int) -> Double = { i in
            guard i < segments.count, i < bars.count else { return 0 }
            return max(0, min(1, (bars[i].rect[0] + bars[i].rect[2] - segments[i].rect[0]) / segments[i].rect[2]))
        }
        let isMe = story.hasPrefix("your-story") || story == "read-receipts-off"
        let file: String = switch story {
        case "wide-story", "caption", "emoji-caption", "your-story", "your-story-failed", "read-receipts-off": "nathan-anderson-316188-unsplash.jpg"
        case "long-caption": "snow.jpg"
        case "multi-story": "kitten-4-112-112.jpg"
        default: "tina-rolf-269345-unsplash.jpg"
        }
        let picture = fixtureImage(file)
        let caption: String? = switch story {
        case "caption": "This place looks lovely"
        case "emoji-caption": "WOOOOOOOOW 🥰"
        case "long-caption": String((snowycle + snowycle + snowycle).dropLast())
        default: nil
        }
        let status: StorySendStatus = story == "your-story-failed" ? .partiallySent : isMe ? .sending : .sent
        let view = StoryViewData(messageId: "m", sender: StoryConversation(id: "s", title: title, color: color, avatar: image),
                                 attachment: StoryAttachmentData(contentType: story == "multi-story" ? "video/mp4" : "image/jpeg", image: picture, thumbnail: picture),
                                 timestamp: now.addingTimeInterval(-120), sendStatus: status)
        let group = story == "in-a-group"
            ? StoryConversation(id: "g", title: "Family Group", color: CallingAdhocCallInfoTests.colorName(contents.dropFirst().first?.style["color"]),
                                avatar: fixtureImage("kitten-4-112-112.jpg"))
            : nil
        return StoryViewerData(story: view, caption: caption, group: group, distributionListName: story.hasPrefix("your-story") ? "Close Friends" : nil,
                               isMe: isMe, numStories: max(1, segments.count), currentIndex: current, progress: fill(current),
                               hasAudio: false, isSent: isMe, hasViewReceiptSetting: story != "read-receipts-off")
    }

    /// Not compared: multi-story (its "video" is a JPEG Storybook cannot play) and long-caption
    /// (13%): in both, Chromium's 90px backdrop blur leaves the backdrop near the right and
    /// bottom edges barely blurred (tile detail shows through), which a uniform Gaussian blur
    /// does not reproduce.
    @Test(arguments: ["someones-story", "wide-story", "in-a-group", "caption", "emoji-caption", "your-story",
                      "your-story-failed", "read-receipts-off"], ["light", "dark"])
    func story(name: String, theme: String) throws {
        let view = StoryViewer(data: Self.data(name, theme)).environment(\.conversationListNow, Self.now)
        try Snapshot.assertMatches(view, story: "components-storyviewer--\(name)", theme: theme)
    }
}
