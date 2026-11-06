// StoriesTab stories (ts/components/StoriesTab.dom.stories.tsx): the 380px sidebar and the
// placeholder. getFakeStory's senders, rings (coin flips) and replies are read back from each
// capture's rows; the ages and pictures are the story's.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct StoriesTabTests {
    static let now = StoriesListTests.now

    /// The story rows after "My Story(ies)": title, avatar, ring, replies.
    static func rows(_ id: String, _ theme: String) -> [(title: String, image: RGBAImage?, color: String, unread: Bool, replies: Bool)] {
        StoryDOM(id, theme: theme).groups(startingWith: "StoryListItem__button").dropFirst().compactMap { nodes in
            guard nodes.contains(where: { $0.cls.contains("module-Avatar--with-story") }) else { return nil }
            let title = nodes.first { $0.cls.contains("StoryListItem__info--title") }?.text ?? ""
            let image = nodes.first { $0.cls.contains("module-Avatar__image") }?.fixture.flatMap { fixtureImage($0) }
            let color = CallingAdhocCallInfoTests.colorName(nodes.first { $0.cls.contains("module-Avatar__contents") }?.style["color"])
            return (title, image, color, nodes.contains { $0.cls.contains("with-story--unread") }, nodes.contains { $0.cls.contains("replies") })
        }
    }

    static func stories(_ rows: ArraySlice<(title: String, image: RGBAImage?, color: String, unread: Bool, replies: Bool)>,
                        _ fakes: [(minutes: Double, file: String, group: String?)]) -> [ConversationStoryData] {
        zip(rows, fakes).enumerated().map { i, pair in
            let (row, fake) = pair
            let person = StoryConversation(id: "p\(i)", title: row.title, color: row.color, avatar: row.image)
            let picture = fixtureImage(fake.file)
            let view = StoryViewData(messageId: "m\(i)", sender: fake.group == nil ? person : StoryConversation(id: "s\(i)", title: "Sender"),
                                     attachment: StoryAttachmentData(image: picture, thumbnail: picture), isUnread: row.unread,
                                     timestamp: now.addingTimeInterval(-fake.minutes * 60))
            return ConversationStoryData(conversationId: "c\(i)", group: fake.group == nil ? nil : person, hasReplies: row.replies, storyView: view)
        }
    }

    static let many: [(minutes: Double, file: String, group: String?)] = [
        (2, "tina-rolf-269345-unsplash.jpg", nil), (5, "koushik-chowdavarapu-105425-unsplash.jpg", nil), (65, "nathan-anderson-316188-unsplash.jpg", "BBQ"),
        (92, "snow.jpg", nil), (164, "kitten-1-64-64.jpg", nil), (380, "kitten-2-64-64.jpg", "Science"), (421, "kitten-3-64-64.jpg", nil),
    ]
    static let hidden = Array(many[4...])
    static let visible = [many[0], many[3]]

    @Test(arguments: ["blank", "many", "hidden-stories", "my-stories"], ["light", "dark"])
    func story(name: String, theme: String) throws {
        let id = "components-storiestab--\(name)"
        let dom = StoryDOM(id, theme: theme)
        let meImage = dom.nodes.first { $0.cls.contains("module-Avatar__image") }?.fixture.flatMap { fixtureImage($0) }
        let meColor = CallingAdhocCallInfoTests.colorName(dom.nodes.first { $0.cls.contains("module-Avatar__contents") }?.style["color"])
        let rows = Self.rows(id, theme)
        let stories: [ConversationStoryData]
        switch name {
        case "many": stories = Self.stories(rows[...], Self.many)
        case "hidden-stories", "my-stories": stories = Self.stories(rows[...], Self.visible)
        default: stories = []
        }
        let hidden = name == "hidden-stories" || name == "my-stories" ? Self.stories([], Self.hidden) : []
        let my = name == "my-stories" ? StoriesListTests.myStories(count: 2) : []
        let view = StoriesTab(me: StoryConversation(id: "me", title: "Me", color: meColor, avatar: meImage), myStories: my, stories: stories,
                              hiddenStories: hidden, hasViewReceiptSetting: false, preferredLeftPaneWidth: 380, actions: StoriesActions()) { EmptyView() }
        try Snapshot.assertMatches(view.environment(\.conversationListNow, Self.now), story: id, theme: theme)
    }
}
