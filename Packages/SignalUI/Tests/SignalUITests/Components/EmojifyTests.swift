// Emojify stories (ts/components/conversation/Emojify.dom.stories.tsx), including the two
// "tens of thousands" stress stories (40000 emoji, 10k / 23k px tall: only the first 5000
// emoji become boxes, the rest stay text in the font stack's Signal Emoji).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct EmojifyTests {
    /// The story root's body text (type-body-large).
    static let body = CSSTextStyle(AxoType.bodyLarge)

    static let cases: [(String, String, CGFloat?)] = [
        ("emoji-only", "😹😹😹", nil), ("skin-color-modifier", "👍🏾", nil), ("jumbo", "😹😹😹", 56), ("extra-large", "😹😹😹", 48),
        ("large", "😹😹😹", 40), ("medium", "😹😹😹", 36), ("small", "😹😹😹", 32), ("plus-text", "this 😹 cat 😹 is 😹 so 😹 joyful", nil),
        ("all-text-no-emoji", "this cat is so joyful", nil), ("non-qualified-emoji", "\u{00AE}", nil), ("overly-qualified-emoji", "\u{26AA}\u{FE0F}", nil),
    ]

    @Test(arguments: ["light", "dark"], 0..<11)
    func story(theme: String, index: Int) throws {
        let (name, text, size) = Self.cases[index]
        try Snapshot.assertMatches(Emojify(text, fontSizeOverride: size, style: Self.body), story: "components-conversation-emojify--\(name)", theme: theme)
    }

    @Test(arguments: ["light", "dark"], [("tens-of-thousands-of-emoji", "💅"), ("tens-of-thousands-of-emoji-interspersed-with-text", "💅 hi ")])
    func stressStory(theme: String, story: (String, String)) throws {
        let text = String(repeating: story.1, count: 40000)
        // The story root's colour: label-primary in light, the dark page's opaque #e9e9e9 in
        // dark (emoji left as text take its alpha).
        let color = AxoColor(light: RGBA(0, 0, 0, 0.9), dark: RGBA(233 / 255, 233 / 255, 233 / 255))
        try Snapshot.assertMatches(Emojify(text, style: Self.body).cssTextColor(color), story: "components-conversation-emojify--\(story.0)", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func customTextRender(theme: String) throws {
        // renderNonEmoji: each text piece in a block <div> with an aquamarine background.
        let pieces = ["this ", "😹", " cat ", "😹", " is ", "😹", " so ", "😹", " joyful"]
        let view = VStack(alignment: .leading, spacing: 0) {
            ForEach(pieces.indices, id: \.self) { i in
                let piece = pieces[i]
                if piece == "😹" {
                    Emojify(piece, style: Self.body)
                } else {
                    CSSText(piece, style: Self.body).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.sRGB, red: 127 / 255, green: 1, blue: 212 / 255))
                }
            }
        }
        try Snapshot.assertMatches(view, story: "components-conversation-emojify--custom-text-render", theme: theme)
    }

    /// TensOfThousandsOfEmojiInterspersedWithText: "💅 hi " repeats every 39.14px in the capture
    /// (a 20px box and " hi " at -0.084px tracking), however long the paragraph.
    @Test func longParagraphKeepsTracking() {
        func width(_ n: Int) -> CGFloat {
            CSSTextLayout.make(runs: [Emojify.run(String(repeating: "💅 hi ", count: n))], Self.body, wrap: .wrap, maxWidth: 1168, colors: nil).widths[0]
        }
        // Full first lines: the same whether the paragraph is short or past CoreText's
        // bounded-layout limit (~12k UTF-16 units), where tracking used to drop.
        #expect(abs(width(100) - width(3000)) < 0.01)
        #expect(width(3000) < 1168 && width(3000) > 1168 - 40)
    }

    /// MAX_EMOJI_TO_MATCH: an Emojify run boxes at most 5000 emoji (the TensOfThousandsOfEmoji
    /// capture has 5000 FunInlineEmoji); the rest stay text.
    @Test func boxesAtMost5000Emoji() {
        #expect(CSSTextLayout.inlineBoxes([Emojify.run(String(repeating: "💅", count: 40000))], Self.body).count == 5000)
        #expect(CSSTextLayout.inlineBoxes([Emojify.run(String(repeating: "💅", count: 12))], Self.body).count == 12)
    }
}
