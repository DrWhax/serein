// ts/components/conversation/ReactionViewer.dom.stories.tsx and ReactionPicker.dom.stories.tsx.
// Avatars are the seeded kittens the captures show. In SelectedReaction each of the seven
// pickers focuses its first button after a delay; the last one keeps focus.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct ReactionTests {
    static let now = TimelineMessageTests.now

    static func r(_ emoji: String, _ t: Double, _ title: String, _ kitten: Int, isMe: Bool = false, id: String? = nil) -> ReactionViewerReaction {
        ReactionViewerReaction(emoji: emoji, timestamp: Date(timeIntervalSince1970: t),
                               from: .init(id: id ?? title, title: title, isMe: isMe, avatar: fixtureImage("kitten-\(kitten)-64-64.jpg")))
    }

    static var stories: [(String, ReactionViewer)] {
        let n = now.timeIntervalSince1970
        let tones = ["", "\u{1F3FB}", "\u{1F3FC}", "\u{1F3FD}", "\u{1F3FE}", "\u{1F3FF}"]
        let thumbKittens = [2, 1, 2, 3, 3, 2], okKittens = [1, 1, 2, 3, 3, 1]
        let skin: [ReactionViewerReaction] =
            tones.indices.map { i in r("👍" + tones[i], n + Double(i), "Thumbs Up \(i + 1)", thumbKittens[i]) }
            + tones.indices.map { i in r("👌" + tones.reversed()[i], n + Double(i), "Ok Hand \(i + 1)", okKittens[i]) }
        let pair = [r("❤️", n, "Amelia", 2, isMe: true), r("👍", n, "Joel", 1)]
        return [
            ("all-reactions", ReactionViewer(reactions: [
                r("❤️", 1, "Amelia", 2), r("❤️", 2, "Adam", 1), r("❤️", 3, "Rick", 2), r("❤️", 4, "Bojack", 3),
                r("👍", 9, "Adam", 3), r("👎", 10, "Rick", 2), r("😂", 11, "Bojack", 1), r("😮", 12, "Cayce", 1),
                r("😢", 13, "Foo", 2), r("😡", 14, "Foo", 3),
            ])),
            ("picked-reaction", ReactionViewer(reactions: pair, pickedReaction: "❤️")),
            ("picked-missing-reaction", ReactionViewer(reactions: pair, pickedReaction: "😡")),
            ("reaction-skin-tones", ReactionViewer(reactions: skin, pickedReaction: "😡")),
        ]
    }

    @Test(arguments: ["light", "dark"])
    func viewer(theme: String) throws {
        for (name, view) in Self.stories {
            try Snapshot.assertMatches(TimelineMessageTests.stage(view), story: "components-conversation-reactionviewer--\(name)", theme: theme)
        }
    }

    @Test(arguments: ["light", "dark"])
    func picker(theme: String) throws {
        try Snapshot.assertMatches(ReactionPicker(onPick: { _ in }), story: "components-conversation-reactionpicker--base", theme: theme)
        let selections = ["❤️", "👍", "👎", "😂", "😮", "😢", "😡"]
        let list = VStack(alignment: .leading, spacing: 0) {
            ForEach(selections.indices, id: \.self) { i in
                ReactionPicker(selected: selections[i], autoFocus: i == selections.count - 1, onPick: { _ in })
                    .frame(height: 100, alignment: .topLeading)
            }
        }
        try Snapshot.assertMatches(list, story: "components-conversation-reactionpicker--selected-reaction", theme: theme)
    }
}
