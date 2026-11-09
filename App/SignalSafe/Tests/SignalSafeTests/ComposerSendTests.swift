// The composer's outgoing body is trimmed like the plain text was; its ranges move with it and
// are clipped to what remains.

import SignalUI
import Testing
@testable import SignalSafe

@MainActor @Suite struct ComposerSendTests {
    @Test func trimmingMovesRanges() {
        let body = "  hi \u{FFFC} bold  "
        let ranges = [BodyRange(start: 5, length: 1, kind: .mention(aci: "a", conversationID: "a", replacementText: "A")),
                      BodyRange(start: 7, length: 6, kind: .formatting(.bold))]    // "bold  " runs into the trailing spaces
        let (out, moved) = SignalSession.trimmed((body, ranges), fallback: "")
        #expect(out == "hi \u{FFFC} bold")
        #expect(moved == [BodyRange(start: 3, length: 1, kind: .mention(aci: "a", conversationID: "a", replacementText: "A")),
                          BodyRange(start: 5, length: 4, kind: .formatting(.bold))])
    }

    @Test func fallsBackToTheDraft() {
        let (out, ranges) = SignalSession.trimmed(("", []), fallback: " plain ")
        #expect(out == "plain" && ranges.isEmpty)
    }
}
