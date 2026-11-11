// The live composer's rich text: a mention pill becomes one U+FFFC with a mention range, a
// style toggled on a selection becomes a style range (offsets after the mention placeholder),
// and deleting into a pill removes all of it.

import AppKit
import Testing
@testable import SignalUI

@MainActor @Suite struct ComposerControllerTests {
    func make(_ text: String) -> (ComposerController, PlaceholderTextView) {
        let tv = PlaceholderTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        tv.string = text
        let c = ComposerController()
        c.textView = tv
        tv.controller = c
        return (c, tv)
    }

    @Test func mentionAndStyleRanges() {
        let (c, tv) = make("hi @al")
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        #expect(c.mentionQuery()?.query == "al")
        c.insertMention(.init(aci: "aci-1", title: "Alice"))
        #expect(tv.string == "hi @Alice ")
        tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
        tv.insertText("bold", replacementRange: tv.selectedRange())
        tv.setSelectedRange(NSRange(location: 10, length: 4))
        c.toggle(.bold)
        let out = c.outgoing()
        #expect(out.body == "hi \u{FFFC} bold")
        #expect(out.ranges.contains(BodyRange(start: 3, length: 1, kind: .mention(aci: "aci-1", conversationID: "aci-1", replacementText: "Alice"))))
        #expect(out.ranges.contains(BodyRange(start: 5, length: 4, kind: .formatting(.bold))))
        // Toggling again on the same text removes the style.
        c.toggle(.bold)
        #expect(!c.outgoing().ranges.contains { if case .formatting = $0.kind { true } else { false } })
    }

    @Test func savedDraftRoundTrips() {
        let (c, tv) = make("")
        let ranges = [BodyRange(start: 3, length: 1, kind: .mention(aci: "aci-1", conversationID: "aci-1", replacementText: "Alice")),
                      BodyRange(start: 5, length: 4, kind: .formatting(.bold)),
                      BodyRange(start: 7, length: 5, kind: .formatting(.italic))]
        c.load(body: "hi \u{FFFC} bold 🎉ok", ranges: ranges)
        #expect(tv.string == "hi @Alice bold 🎉ok")
        let out = c.outgoing()
        #expect(out.body == "hi \u{FFFC} bold 🎉ok")
        #expect(Set(out.ranges) == Set(ranges))
    }

    @Test func deletingIntoAPillRemovesIt() {
        let (c, tv) = make("@a")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        c.insertMention(.init(aci: "aci-2", title: "Bob"))
        #expect(tv.string == "@Bob ")
        // Backspace over the last letter of the pill.
        #expect(c.expandDeletion(NSRange(location: 3, length: 1)) == NSRange(location: 0, length: 4))
        // Mentions are not looked up inside a pill.
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(c.mentionQuery() == nil)
    }

    /// The emoji picker types at the caret: the pill and the bold text around it stay as they were.
    @Test func emojiGoesInAtTheCaret() {
        let (c, tv) = make("")
        let ranges = [BodyRange(start: 3, length: 1, kind: .mention(aci: "aci-1", conversationID: "aci-1", replacementText: "Alice")),
                      BodyRange(start: 5, length: 4, kind: .formatting(.bold))]
        c.load(body: "hi \u{FFFC} bold", ranges: ranges)
        tv.setSelectedRange(NSRange(location: 3, length: 0))     // before the pill
        #expect(c.insert("👍"))
        let out = c.outgoing()
        #expect(out.body == "hi 👍\u{FFFC} bold")
        // The pill and the bold run move with the inserted text (👍 is two UTF-16 units).
        #expect(out.ranges.contains(BodyRange(start: 5, length: 1, kind: .mention(aci: "aci-1", conversationID: "aci-1", replacementText: "Alice"))))
        #expect(out.ranges.contains(BodyRange(start: 7, length: 4, kind: .formatting(.bold))))
        #expect(tv.selectedRange() == NSRange(location: 5, length: 0), "the caret follows the emoji")
    }

    @Test func emojiWithoutAComposerIsNotTaken() {
        let c = ComposerController()
        #expect(!c.insert("👍"))
    }
}
