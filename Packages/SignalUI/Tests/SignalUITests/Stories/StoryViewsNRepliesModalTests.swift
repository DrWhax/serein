// StoryViewsNRepliesModal stories (ts/components/StoryViewsNRepliesModal.dom.stories.tsx):
// full-viewport portal captures. getViewsAndReplies' people (getDefaultConversation names,
// colours and kittens) are read back from each capture's DOM; the views' and replies' ages
// are the story's. "Cant reply" renders nothing upstream (no capture).

import Foundation
import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct StoryViewsNRepliesModalTests {
    static let now = StoriesListTests.now

    struct Person {
        var title = ""
        var color = "A200"
        var avatar: RGBAImage?
    }

    static func avatar(_ nodes: [StoryDOM.Node]) -> (String, RGBAImage?) {
        let color = CallingAdhocCallInfoTests.colorName(nodes.first { $0.cls.split(separator: " ").contains("module-Avatar__contents") }?.style["color"])
        let image = nodes.first { $0.cls.contains("module-Avatar__image") }?.fixture.flatMap { fixtureImage($0) }
        return (color, image)
    }

    static func minutes(_ text: String?) -> Double {
        guard let text, text != "Now" else { return 0 }
        return Double(text.dropLast()) ?? 0
    }

    static func data(_ story: String, _ theme: String) -> (views: [StoryDetailsRecipient], replies: [StoryReply]) {
        let dom = StoryDOM("components-storyviewsnrepliesmodal--\(story)", theme: theme)
        // Views, newest first as shown.
        let views = dom.groups(startingWith: "StoryViewsNRepliesModal__view").enumerated().map { i, row in
            let (color, image) = avatar(row)
            let name = row.first { $0.tag == "span" && $0.cls.isEmpty && $0.text != nil }?.text ?? ""
            let age = minutes(row.first { $0.cls == "StoryViewsNRepliesModal__view--timestamp" }?.text)
            return StoryDetailsRecipient(id: "v\(i)", title: name, color: color, avatar: image, status: .viewed,
                                         updatedAt: now.addingTimeInterval(-age * 60))
        }
        // Replies and reactions: p2, p3 ×3, p4's reaction, p6 (me).
        var rows: [[StoryDOM.Node]] = []
        for n in dom.nodes {
            if n.cls == "StoryViewsNRepliesModal__reply" || n.cls == "StoryViewsNRepliesModal__reaction" { rows.append([n]) }
            else if !rows.isEmpty { rows[rows.count - 1].append(n) }
        }
        func person(name nameRow: Int, avatar avatarRow: Int) -> Person {
            guard rows.count > max(nameRow, avatarRow) else { return Person(title: "Someone") }
            let title = rows[nameRow].first { $0.tag == "span" && $0.cls.isEmpty && $0.text != nil }?.text ?? ""
            let (color, image) = avatar(rows[avatarRow])
            return Person(title: title, color: color, avatar: image)
        }
        let p2 = person(name: 0, avatar: 0), p3 = person(name: 1, avatar: 3), p4 = person(name: 4, avatar: 4), p6 = person(name: 5, avatar: 5)
        func author(_ p: Person, _ id: String, isMe: Bool = false) -> MessageProps.Author {
            var a = MessageProps.Author(id: id, title: p.title)
            a.color = p.color
            a.avatar = p.avatar
            a.isMe = isMe
            return a
        }
        let ago: (Double) -> Date = { now.addingTimeInterval(-$0 * 60) }
        let replies = [
            StoryReply(id: "r1", author: author(p2, "p2"), conversationId: "p2", body: "So cute ❤️", timestamp: ago(24)),
            StoryReply(id: "r2", author: author(p3, "p3"), conversationId: "p3", body: "That's awesome", timestamp: ago(13)),
            StoryReply(id: "r3", author: author(p3, "p3"), conversationId: "p3", body: "Very awesome", timestamp: ago(13)),
            StoryReply(id: "r4", author: author(p3, "p3"), conversationId: "p3", body: "Did I mention how awesome this is?", timestamp: ago(12)),
            StoryReply(id: "r5", author: author(p4, "p4"), conversationId: "p4", reactionEmoji: "❤️", timestamp: ago(5)),
            StoryReply(id: "r6", author: author(p6, "p6", isMe: true), conversationId: "p6", body: "Thanks everyone!", timestamp: now),
        ]
        return (views, replies)
    }

    static func modal(_ story: String, _ theme: String) -> StoryViewsNRepliesModal {
        let (views, replies) = data(story, theme)
        let group = story.hasPrefix("in-a-group") || story == "group-read-receipts-off"
        let canReply = !["views-only", "no-views", "in-a-group-cant-reply", "read-receipts-turned-off"].contains(story)
        let viewsCapability = ["views-only", "no-views", "in-a-group", "read-receipts-turned-off", "group-read-receipts-off"].contains(story)
        let withReplies = ["in-a-group", "in-a-group-cant-reply", "in-a-group-but-left", "group-read-receipts-off"].contains(story)
        let withViews = ["views-only", "in-a-group", "in-a-group-cant-reply", "read-receipts-turned-off", "group-read-receipts-off"].contains(story)
        return StoryViewsNRepliesModal(authorTitle: "Mattie Grady", canReply: canReply, isGroup: group, groupLeft: story == "in-a-group-but-left",
                                       hasViewReceiptSetting: !story.contains("read-receipts"), hasViewsCapability: viewsCapability,
                                       replies: withReplies ? replies : [], views: withViews ? views : [])
    }

    @Test(arguments: ["can-reply", "views-only", "no-views", "in-a-group-no-replies", "in-a-group", "in-a-group-cant-reply",
                      "read-receipts-turned-off", "in-a-group-but-left", "group-read-receipts-off"], ["light", "dark"])
    func story(name: String, theme: String) throws {
        let view = Self.modal(name, theme).environment(\.conversationListNow, Self.now)
        try Snapshot.assertMatches(view, story: "components-storyviewsnrepliesmodal--\(name)", theme: theme)
    }
}
