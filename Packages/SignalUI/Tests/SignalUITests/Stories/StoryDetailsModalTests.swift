// StoryDetailsModal stories (ts/components/StoryDetailsModal.dom.stories.tsx): full-viewport
// portal captures. The recipients (getDefaultConversation names, colours and kittens) and
// their casual.unix_time timestamps are read back from the capture's DOM.

import Foundation
import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct StoryDetailsModalTests {
    static let now = StoriesListTests.now

    /// "Jan 12, 1970, 1:27 AM" (UTC) → the date.
    static func parse(_ text: String) -> Date? {
        if text.hasPrefix("Today ") { return now }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM d, yyyy, h:mm a"
        return f.date(from: text.replacingOccurrences(of: "\u{202F}", with: " "))
    }

    static func data(_ story: String, _ theme: String) -> (sender: StoryDetailsRecipient, sendState: [StoryDetailsRecipient]?) {
        let dom = StoryDOM("components-storydetailsmodal--\(story)", theme: theme)
        var groups: [(SendStatus?, [StoryDetailsRecipient])] = []
        var current: SendStatus?
        var index = 0
        let headers: [String: SendStatus] = ["Failed": .failed, "Viewed by": .viewed, "Read by": .read, "Delivered to": .delivered,
                                             "Sent to": .sent, "Pending": .pending]
        for contact in dom.groups(startingWith: "StoryDetailsModal__contact-group__header") {
            current = headers[contact[0].text ?? ""]
            groups.append((current, []))
            for row in [contact].flatMap({ StoryDOMSlice($0).rows }) {
                let name = row.first { $0.tag == "span" && $0.cls.isEmpty && $0.text != nil }?.text ?? ""
                let color = CallingAdhocCallInfoTests.colorName(row.first { $0.cls == "module-Avatar__contents" }?.style["color"])
                let image = row.first { $0.cls.contains("module-Avatar__image") }?.fixture.flatMap { fixtureImage($0) }
                let time = row.first { $0.cls == "StoryDetailsModal__status-timestamp" }?.text.flatMap(parse)
                index += 1
                groups[groups.count - 1].1.append(StoryDetailsRecipient(id: "c\(index)", title: name, color: color, avatar: image,
                                                                        status: current ?? .sent, updatedAt: time))
            }
        }
        let all = groups.flatMap(\.1)
        if story == "other-story" {
            return (all[0], nil)
        }
        return (StoryDetailsRecipient(id: "me", title: "Me", status: .sent), all)
    }

    @Test(arguments: ["my-story", "other-story"], ["light", "dark"])
    func story(name: String, theme: String) throws {
        let (sender, sendState) = Self.data(name, theme)
        #expect(sender.title.isEmpty == false)
        let view = StoryDetailsModal(sender: sender, sendState: sendState, timestamp: Self.now)
            .environment(\.conversationListNow, Self.now)
        try Snapshot.assertMatches(view, story: "components-storydetailsmodal--\(name)", theme: theme)
    }
}

/// The `StoryDetailsModal__contact` rows in a group's nodes.
struct StoryDOMSlice {
    let rows: [[StoryDOM.Node]]
    init(_ nodes: [StoryDOM.Node]) {
        var out: [[StoryDOM.Node]] = []
        for n in nodes {
            if n.cls == "StoryDetailsModal__contact" { out.append([n]) } else if !out.isEmpty { out[out.count - 1].append(n) }
        }
        rows = out
    }
}
