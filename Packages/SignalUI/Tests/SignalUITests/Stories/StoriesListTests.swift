// StoryListItem and MyStoriesButton stories. getDefaultConversation's avatars (kitten-N) and
// colours are read back from each capture; stories are 2 minutes old (getFakeStoryView).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct StoriesListTests {
    static let now = Date(timeIntervalSince1970: 1_793_793_600)

    static func avatar(_ dom: StoryDOM) -> (RGBAImage?, String) {
        let image = dom.nodes.first { $0.cls.contains("module-Avatar__image") }?.fixture.flatMap { fixtureImage($0) }
        let color = CallingAdhocCallInfoTests.colorName(dom.nodes.first { $0.cls.contains("module-Avatar__contents") }?.style["color"])
        return (image, color)
    }

    static let tina = fixtureImage("tina-rolf-269345-unsplash.jpg")

    static func myStories(count: Int, status: StorySendStatus = .sent) -> [MyStoryList] {
        let me = StoryConversation(id: "me", title: "Me")
        let story = StoryViewData(messageId: "s", sender: me, attachment: StoryAttachmentData(image: tina, thumbnail: tina), timestamp: now.addingTimeInterval(-120),
                                  views: 3, hasLocalFile: true)
        return (0..<count).map { i in MyStoryList(id: "list-\(i)", name: "List \(i)", stories: [story, story], reducedSendStatus: i == 0 ? status : .sent) }
    }

    @Test(arguments: ["light", "dark"])
    func storyListItem(theme: String) throws {
        let id = "components-storylistitem--someones-story"
        let (image, color) = Self.avatar(StoryDOM(id, theme: theme))
        let sender = StoryConversation(id: "sender", title: "Sender")
        let view = StoryListItem(conversationId: "c", story: StoryViewData(messageId: "123", sender: sender, attachment: StoryAttachmentData(isNotResolved: true),
                                                                           isUnread: true, timestamp: Self.now),
                                 group: StoryConversation(id: "g", title: "Sports Group", color: color, avatar: image), hasReplies: true)
        try Snapshot.assertMatches(view.environment(\.conversationListNow, Self.now), story: id, theme: theme)
    }

    @Test(arguments: [("no-story", 0, StorySendStatus.sent), ("one-story", 1, .sent), ("many-stories", 2, .sent), ("sending-story", 2, .sending),
                      ("failed-send-story", 2, .failed)], ["light", "dark"])
    func myStoriesButton(_ s: (String, Int, StorySendStatus), theme: String) throws {
        let id = "components-mystoriesbutton--\(s.0)"
        let (image, color) = Self.avatar(StoryDOM(id, theme: theme))
        // The story's play() opens and closes the add menu: with no story, focus returns to the
        // whole row (the trigger).
        let view = MyStoryButton(me: StoryConversation(id: "me", title: "Me", color: color, avatar: image), myStories: Self.myStories(count: s.1, status: s.2),
                                 addButtonFocused: s.1 == 0)
        try Snapshot.assertMatches(view.environment(\.conversationListNow, Self.now), story: id, theme: theme)
    }

    /// MyStories: each list's title then its stories (2–6, read from the capture). The play()
    /// ends by picking Forward from the first story's more menu, so that button has focus.
    static func myStoriesFromDOM(_ id: String, _ theme: String, failedFirst: Bool) -> [MyStoryList] {
        let dom = StoryDOM(id, theme: theme)
        var lists: [MyStoryList] = []
        var expectingTitle = false
        for n in dom.nodes {
            if n.cls.contains("MyStories__distribution__title") {
                expectingTitle = true
            } else if expectingTitle, let t = n.text, !t.isEmpty {
                // getFakeMyStory's `name || id === MY_STORY_ID ? 'My Stories' : …` names every list "My Stories".
                expectingTitle = false
                lists.append(MyStoryList(id: t == "My Story" ? MyStoryList.myStoryId : "list-\(lists.count)", name: t, stories: []))
            } else if n.cls.split(separator: " ").contains("MyStories__story"), !lists.isEmpty {
                let i = lists[lists.count - 1].stories.count
                let failed = failedFirst && lists.count == 1 && i == 0
                lists[lists.count - 1].stories.append(StoryViewData(messageId: "\(lists.count)-\(i)", sender: StoryConversation(id: "me", title: "Me"),
                                                                    attachment: StoryAttachmentData(image: tina, thumbnail: tina),
                                                                    timestamp: now.addingTimeInterval(-120), sendStatus: failed ? .failed : .sent,
                                                                    views: 5, hasLocalFile: true))
            }
        }
        return lists
    }

    @Test(arguments: ["no-stories", "single-list-stories", "multi-list-stories", "failed-sent-story"], ["light", "dark"])
    func myStories(story: String, theme: String) throws {
        let id = "components-mystories--\(story)"
        let lists = Self.myStoriesFromDOM(id, theme, failedFirst: story == "failed-sent-story")
        let view = MyStories(myStories: lists, hasViewReceiptSetting: false, preferredLeftPaneWidth: .nan, onBack: {}, actions: StoriesActions(),
                             focusedMoreStoryId: story == "no-stories" ? nil : lists.first?.stories.first?.messageId,
                             focusedMoreShowsTooltip: story == "multi-list-stories")
        // With the tooltip open the capture is the whole viewport, the story 16px in.
        let portal = story == "multi-list-stories"
        try Snapshot.assertMatches(view.environment(\.conversationListNow, Self.now).padding(portal ? 16 : 0)
                                       .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).axoLayerHost(),
                                   story: id, theme: theme)
    }
}
