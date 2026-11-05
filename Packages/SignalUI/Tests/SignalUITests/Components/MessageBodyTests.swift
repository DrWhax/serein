// MessageBody stories (ts/components/conversation/MessageBody.dom.stories.tsx). Every story is
// incoming, in the timeline, with links and jumbomoji enabled unless stated. `<hr>` between
// variants is a 1px line in the text colour.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct MessageBodyTests {
    static func mention(_ start: Int, _ name: String, _ id: String = "x") -> BodyRange {
        BodyRange(start: start, length: 1, kind: .mention(aci: "aci-\(start)", conversationID: id, replacementText: name))
    }
    static func style(_ start: Int, _ length: Int, _ s: BodyRange.Style) -> BodyRange {
        BodyRange(start: start, length: length, kind: .formatting(s))
    }

    static func body(_ text: String, original: String? = nil, ranges: [BodyRange] = [], direction: MessageDirection = .incoming,
                     disableJumbomoji: Bool = false, disableLinks: Bool = false, textAttachment: MessageBodyTextAttachment = .init(),
                     expanded: [Int: Bool] = [:]) -> MessageBody {
        MessageBody(text: text, originalText: original, bodyRanges: ranges, direction: direction, disableJumbomoji: disableJumbomoji,
                    disableLinks: disableLinks, renderLocation: .timeline, isSpoilerExpanded: expanded, textAttachment: textAttachment)
    }

    /// Variants separated by `<hr>` (or by `<br>` when `hr` is false).
    static func stack(_ views: [MessageBody], hr: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(views.indices, id: \.self) { i in
                if i > 0, hr { HR() }
                views[i].frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// `<hr>`: a 1px top border in the story's text colour.
    struct HR: View {
        @Environment(\.cssTextColor) var color
        var body: some View { Rectangle().fill(color).frame(height: 1) }
    }

    static let signal = "Check out https://www.signal.org"

    static let formattingBasicText = "… It’s in words that the magic is – Abracadabra, Open Sesame, and the rest – but the magic words in one story aren’t magical in the next. The real magic is to understand which words work, and when, and for what; the trick is to learn the trick. … And those words are made from the letters of our alphabet: a couple-dozen squiggles we can draw with the pen. This is the key! And the treasure, too, if we can only get our hands on it! It’s as if – as if the key to the treasure is the treasure!"
    static let formattingBasicRanges = [style(36, 11, .bold), style(46, 10, .italic), style(357, 75, .monospace), style(138, 73, .strikethrough),
                                        style(446, 46, .spoiler), style(110, 27, .none)]

    static let spoilerText = "This is a very secret https://somewhere.com 💡 thing, \u{FFFC} and \u{FFFC}, that you shouldn't be able to read. Stay away!"
    static let spoilerRanges = [style(8, 60, .spoiler), style(68, 29, .spoiler), style(94, 6, .spoiler), style(46, 22, .monospace),
                                style(72, 12, .bold), style(90, 7, .italic), mention(54, "🅰️ Alice", "a"), mention(60, "🅱️ Bob", "b")]

    static let nestingText = "Italic Start and Bold Start .\u{FFFC}. Bold EndStrikethrough Start .\u{FFFC}. Mono\u{FFFC}pace Pop! .\u{FFFC}. Strikethrough End Ital\u{FFFC}c End"
    static let nestingRanges = [style(0, 40, .bold), style(0, 111, .italic), style(40, 60, .strikethrough), style(64, 14, .monospace),
                                mention(29, "🅰️ Alice", "a"), mention(61, "🅱️ Bob", "b"), mention(68, "Charlie", "c"), mention(80, "Dan", "d"),
                                mention(105, "Eve", "e")]

    static let complexText = "Computational processes \u{FFFC} are abstract beings that inhabit computers. "
        + "As they evolve, processes manipulate other abstract things called data. "
        + "The evolution of a process is directed by a pattern of rules called a program. "
        + "People create programs to direct processes. In effect, we conjure the spirits of "
        + "the computer with our spells.\n\n"
        + "link preceded by emoji: 🤖https://signal.org/\n\n"
        + "link overlapping strikethrough: https://signal.org/ (up to \"...//signal\")\n\n"
        + "strikethrough going through mention \u{FFFC} all the way"
    static let complexRanges = [mention(24, "🤖 Hello"), style(14, 31, .bold), style(29, 39, .italic), style(397, 29, .strikethrough),
                                style(465, 31, .strikethrough), mention(491, "🤖 Hello")]

    static let zalgo = "T̸͎̆̏̇̊̄͜ͅh̸͙̟͎̯̍͋͜͜i̸̪͚̼̜̦̲̇͒̇͝͝ś̴̡̩͙͜͝ ̴̼̣̩͂͑͠i̸̡̞̯͗s̵͙̔͛͊͑̔ ̶͇̒͝f̴̗͇͙̳͕̅̈́̏̉ò̵̲͉̤̬̖̱ȓ̶̳̫͗͝m̶̗͚̓ą̶̘̳͉̣̿̋t̴͎͎̞̤̱̅̓͝͝t̶̝͊͗é̵̛̥̔̃̀d̸̢̘̹̥̋͆ ̸̘͓͐̓̅̚ẕ̸͉̊̊͝a̴̙̖͎̥̥̅̽́͑͘ͅl̴͔̪͙͔̑̈́g̴͔̝̙̰̊͆̎͌́ǫ̵̪̤̖̖͗̑̎̿̄̎ ̵̪͈̲͇̫̼͌̌͛̚t̸̠́ẽ̴̡̺̖͘x̵͈̰̮͔̃̔͗̑̓͘t"

    static let stories: [(String, [MessageBody])] = [
        ("links-enabled", [body(signal)]),
        ("links-disabled", [body(signal, disableLinks: true)]),
        ("emoji-size-based-on-count", ["😹", "😹😹😹", "😹😹😹😹😹", "😹😹😹😹😹😹😹", "😹😹😹😹😹😹😹😹😹"].map { body($0) }),
        ("jumbomoji-enabled", [body("😹")]),
        ("jumbomoji-disabled", [body("😹", disableJumbomoji: true)]),
        ("jumbomoji-disabled-by-text", [body("not a jumbo kitty 😹")]),
        ("text-pending", [body(signal, textAttachment: .init(pending: true))]),
        ("message-too-long", [body(signal, textAttachment: .init(wasTooBig: true))]),
        ("mention", [body("Like \u{FFFC} once said: My story is a lot like yours, only more interesting because it involves robots",
                          ranges: [mention(5, "Bender B Rodriguez 🤖")])]),
        ("multiple-mentions", { let r = [mention(2, "Philip J Fry"), mention(4, "Professor Farnsworth"), mention(0, "Yancy Fry")]
            return [body("\u{FFFC} \u{FFFC} \u{FFFC}", ranges: r), body("\u{FFFC} \u{FFFC} \u{FFFC}", ranges: r, disableLinks: true)] }()),
        ("complex-message-body", { let t = "Hey \u{FFFC}\nCheck out https://www.signal.org I think you will really like it 😍\n\ncc \u{FFFC} \u{FFFC}"
            let r = [mention(78, "Acid Burn"), mention(80, "Cereal Killer"), mention(4, "Zero Cool")]
            // createProps hardcodes `direction: incoming` (the story's outgoing is dropped).
            return [body(t, ranges: r), body(t, ranges: r, disableLinks: true)] }()),
        ("formatting-basic", [body(formattingBasicText, ranges: formattingBasicRanges),
                              body(formattingBasicText, ranges: formattingBasicRanges, disableLinks: true)]),
        ("formatting-spoiler", [body(spoilerText, ranges: spoilerRanges), body(spoilerText, ranges: spoilerRanges, disableLinks: true),
                                body(spoilerText, ranges: spoilerRanges), body(spoilerText, ranges: spoilerRanges, disableLinks: true)]),
        ("formatting-nesting", [body(nestingText, ranges: nestingRanges), body(nestingText, ranges: nestingRanges, disableLinks: true)]),
        ("formatting-complex", [body(complexText, ranges: complexRanges)]),
        ("zalgo-text", [body(zalgo, ranges: [style(0, 39, .bold), style(49, 13, .italic), style(65, 73, .strikethrough), style(145, 92, .monospace)])]),
        ("link-over-read-more-boundary", [body("https://hello.me", original: "https://hello.me123")]),
    ]

    @Test(arguments: ["light", "dark"], 0..<17)
    func story(theme: String, index: Int) throws {
        let (name, views) = Self.stories[index]
        // zalgo-text: the base text, formatting and Chromium's per-cluster font fallback
        // (Courier / Helvetica Neue clusters) match; the stacked combining marks are placed by
        // HarfBuzz's mark/mkmk positioning in Chromium and by CoreText here, and differ.
        try Snapshot.assertMatches(Self.stack(views, hr: name != "emoji-size-based-on-count"), story: "components-conversation-messagebody--\(name)",
                                   theme: theme, maxRatio: name == "zalgo-text" ? 0.06 : nil)
    }

    @Test func jumboCount() {
        #expect(MessageBody.jumboEmojiCount("😹") == 1)
        #expect(MessageBody.jumboEmojiCount(" 😹 😹 ") == 2)
        #expect(MessageBody.jumboEmojiCount("😹😹😹😹😹😹") == nil)
        #expect(MessageBody.jumboEmojiCount("a 😹") == nil)
        #expect(MessageBody.jumboEmojiSize("😹😹😹😹") == 36)
    }

    @Test func actionsRoundTrip() {
        for a in [MessageTextAction.link("https://signal.org"), .mention(conversationID: "abc"), .expandSpoiler(3), .readMore, .downloadBody] {
            #expect(MessageTextAction(encoded: a.encoded) == a)
        }
    }
}
