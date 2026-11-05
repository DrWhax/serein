// MessageBodyReadMore stories (ts/components/conversation/MessageBodyReadMore.dom.stories.tsx):
// incoming, timeline, at the initial display limit.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct MessageBodyReadMoreTests {
    static func view(_ text: String, ranges: [BodyRange] = []) -> some View {
        MessageBodyReadMore(text: text, bodyRanges: ranges, direction: .incoming, renderLocation: .timeline, messageExpanded: { _ in })
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func longText() throws -> String {
        let dir = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return try String(contentsOf: dir.appendingPathComponent("messagebodyreadmore-long-text.txt"), encoding: .utf8)
    }

    static let goal = "ready? set... g" + String(repeating: "o", count: 1000) + "al! bold italic"

    static func stories() throws -> [(String, [BodyRange], String)] {
        [
            ("long-text-100-more", [], String(repeating: "test ", count: 160) + String(repeating: "extra ", count: 10)),
            ("lots-of-cake-with-some-cherries-on-top", [], "x" + String(repeating: "🍰", count: 399) + String(repeating: "🍒", count: 100)),
            ("leafy-not-buffered", [], "x" + String(repeating: "🌿", count: 450)),
            ("long-text-with-mention", [BodyRange(start: 800, length: 1, kind: .mention(aci: "a", conversationID: "x", replacementText: "Alice"))],
             String(repeating: "x ", count: 400) + "\u{FFFC} woo!" + String(repeating: "y ", count: 100)),
            ("long-text-with-formatting", [BodyRange(start: 0, length: 5, kind: .formatting(.italic)), BodyRange(start: 7, length: 3, kind: .formatting(.bold)),
                                           BodyRange(start: 1019, length: 4, kind: .formatting(.bold)), BodyRange(start: 1024, length: 6, kind: .formatting(.italic))],
             goal),
            ("long-text-mostly-spoiler", [BodyRange(start: 7, length: 1010, kind: .formatting(.spoiler))], goal),
            ("links", [], String(repeating: "test ", count: 176) + "https://www.signal.org"),
            ("excessive-amounts-of-cake", [], "x" + String(repeating: "🍰", count: 20000)),
            ("long-text", [], try longText()),
        ]
    }

    @Test(arguments: ["light", "dark"], 0..<9)
    func story(theme: String, index: Int) throws {
        let (name, ranges, text) = try Self.stories()[index]
        try Snapshot.assertMatches(Self.view(text, ranges: ranges), story: "components-conversation-messagebodyreadmore--\(name)", theme: theme)
    }

    @Test func slicing() {
        #expect(MessageBodyReadMore.slice("short", length: 800).hasReadMore == false)
        let s = MessageBodyReadMore.slice(String(repeating: "a", count: 1000), length: 800)
        #expect(s.text.utf16.count == 800 && s.hasReadMore)
        // A link across the cut is kept whole.
        let linked = String(repeating: "a ", count: 398) + "https://www.signal.org/" + String(repeating: " b", count: 100)
        #expect(MessageBodyReadMore.slice(linked, length: 800).text.hasSuffix("https://www.signal.org/"))
    }
}
