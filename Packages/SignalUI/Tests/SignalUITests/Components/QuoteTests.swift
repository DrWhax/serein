// Quote stories (ts/components/conversation/Quote.dom.stories.tsx): the standalone `Template`
// stories, a 1168px block (forest bubble colour, close button). Author names are the seeded
// getDefaultConversation values the captures show.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct QuoteTests {
    static let sax = fixturePNG("freepngs-2cd43b_bed7d1327e88454487397574d87b64dc_mv2.png")
    static let longWord = String(repeating: "thisisthewordthatneverends", count: 10)

    static func q(_ author: String = "Default Sender", text: String? = "A sample message from a pal", _ configure: (inout QuoteModel) -> Void = { _ in }) -> QuoteModel {
        var m = QuoteModel(authorTitle: author, text: text)
        m.bubbleColor = .preset("forest")
        configure(&m)
        return m
    }

    static func png(thumb: Bool) -> QuotedAttachment { QuotedAttachment(contentType: "image/png", fileName: "sax.png", thumbnail: thumb ? sax : nil) }
    static func mp4(thumb: Bool) -> QuotedAttachment { QuotedAttachment(contentType: "video/mp4", fileName: "great-video.mp4", thumbnail: thumb ? sax : nil) }
    static let mp3 = QuotedAttachment(contentType: "audio/mp3", fileName: "great-video.mp3")
    static let voice = QuotedAttachment(contentType: "audio/mp3", fileName: "great-video.mp3", isVoiceMessage: true)
    static let json = QuotedAttachment(contentType: "application/json", fileName: "great-data.json")

    /// CSS `hsl(h s% l%)`.
    static func hsl(_ h: Double, _ s: Double, _ l: Double) -> RGBA {
        RGBA.hsl(h, s / 100, l / 100)
    }

    static var stories: [(String, [(QuoteModel, Bool)])] {
        func one(_ m: QuoteModel, close: Bool = true) -> [(QuoteModel, Bool)] { [(m, close)] }
        return [
            ("outgoing-by-another-author", one(q("Bernadine Feil"))),
            ("outgoing-by-me", one(q { $0.isFromMe = true })),
            ("incoming-by-another-author", one(q("Regan Murazik") { $0.direction = .incoming })),
            ("incoming-by-another-with-label", one(q("Nyah Stroman") {
                $0.direction = .incoming
                $0.authorLabel = ContactLabel(labelString: "First", labelEmoji: "1\u{FE0F}\u{20E3}")
            })),
            ("incoming-by-me", one(q { $0.isFromMe = true; $0.direction = .incoming })),
            ("image-only", one(q(text: "") { $0.rawAttachment = png(thumb: true) })),
            ("image-attachment", one(q { $0.rawAttachment = png(thumb: true) })),
            ("long-unbreakable-word", one(q(text: longWord))),
            ("long-unbreakable-word-with-image-attachment", one(q(text: longWord) { $0.rawAttachment = png(thumb: true) })),
            ("image-attachment-undownloaded", one(q { $0.rawAttachment = png(thumb: false) })),
            ("image-attachment-downloading", one(q { $0.rawAttachment = png(thumb: false) })),
            ("image-attachment-no-thumbnail", one(q { $0.rawAttachment = png(thumb: false) })),
            ("image-tap-to-view", one(q(text: "") { $0.isViewOnce = true; $0.rawAttachment = png(thumb: false) })),
            ("video-only", one(q(text: nil) { $0.rawAttachment = mp4(thumb: true) })),
            ("video-attachment", one(q { $0.rawAttachment = mp4(thumb: true) })),
            ("video-attachment-undownloaded", one(q { $0.rawAttachment = mp4(thumb: false) })),
            ("video-attachment-downloading", one(q { $0.rawAttachment = mp4(thumb: false) })),
            ("video-attachment-no-thumbnail", one(q { $0.rawAttachment = mp4(thumb: false) })),
            ("video-tap-to-view", one(q(text: "") { $0.isViewOnce = true; $0.rawAttachment = mp4(thumb: false) })),
            ("audio-only", one(q(text: nil) { $0.rawAttachment = mp3 })),
            ("audio-attachment", one(q { $0.rawAttachment = mp3 })),
            ("voice-message-only", one(q(text: nil) { $0.rawAttachment = voice })),
            ("voice-message-attachment", one(q { $0.rawAttachment = voice })),
            ("gif-attachment-only", one(q(text: nil) { $0.rawAttachment = QuotedAttachment(contentType: "image/gif", fileName: "sax.png") })),
            ("other-file-only", one(q(text: nil) { $0.rawAttachment = json })),
            ("media-tap-to-view", one(q(text: "") { $0.isViewOnce = true; $0.rawAttachment = mp3 })),
            ("other-file-attachment", one(q { $0.rawAttachment = json })),
            ("long-message-attachment-should-be-hidden", one(q {
                $0.rawAttachment = QuotedAttachment(contentType: "text/x-signal-plain", fileName: "signal-long-message-123.txt")
            })),
            ("no-close-button", one(q(), close: false)),
            ("mention-outgoing-another-author", one(q("Tony Stark", text: "@Captain America Lunch later?"))),
            ("mention-outgoing-me", one(q(text: "@Captain America Lunch later?") { $0.isFromMe = true })),
            ("mention-incoming-another-author", one(q("Captain America", text: "@Tony Stark sure") { $0.direction = .incoming })),
            ("mention-incoming-me", one(q(text: "@Tony Stark sure") { $0.isFromMe = true; $0.direction = .incoming })),
            ("custom-color", [
                (q(text: "Solid + Gradient") { $0.direction = .incoming; $0.bubbleColor = .solid(hsl(82, 35, 30)) }, true),
                (q(text: "A gradient") {
                    $0.bubbleColor = .gradient(CSSLinearGradient(deg: 270 - 192, start: hsl(304, 85, 40.33), end: hsl(231, 76, 47)))
                }, true),
            ]),
            ("is-story-reply", one(q("Amanda", text: "Wow!") { $0.isStoryReply = true; $0.rawAttachment = mp4(thumb: false) }, close: false)),
            ("is-story-reply-emoji", one(q("Arvid") {
                $0.isStoryReply = true
                $0.rawAttachment = png(thumb: true)
                $0.reactionEmoji = "\u{1F3CB}\u{FE0F}"
            }, close: false)),
        ]
    }

    @Test(arguments: ["light", "dark"], 0..<36)
    func story(theme: String, index: Int) throws {
        let (name, quotes) = Self.stories[index]
        let view = VStack(spacing: 0) {
            ForEach(quotes.indices, id: \.self) { i in
                Quote(quotes[i].0, onClick: {}, onClose: quotes[i].1 ? {} : nil)
            }
        }
        .frame(width: 1168)
        .environment(\.chatColorViewport, CGRect(x: -16, y: -16, width: 1200, height: 900))
        try Snapshot.assertMatches(view, story: "components-conversation-quote--\(name)", theme: theme)
    }

    /// `renderInMessage`: an incoming and an outgoing TimelineMessage ("Person X", direct, the
    /// default text) quoting `quote`, a <br> (20px) apart.
    static func inMessage(_ quote: QuoteModel, color: String = "forest") -> some View {
        func message(_ d: MessageDirection) -> some View {
            Message(props: TimelineMessageTests.props("This is really interesting.", direction: d, author: "Person X") {
                $0.bubbleColor = .preset(color)
                $0.quote = quote
                $0.scrollToQuotedMessage = {}
            })
        }
        return VStack(spacing: 20) { message(.incoming); message(.outgoing) }
    }

    static let conversationColors = ["ultramarine", "crimson", "vermilion", "burlap", "forest", "wintergreen", "teal", "blue", "indigo", "violet",
                                     "plum", "taupe", "steel", "ember", "midnight", "infrared", "lagoon", "fluorescent", "basil", "sublime",
                                     "sea", "tangerine"]

    static var inMessageStories: [(String, AnyView)] {
        [
            ("message-not-found", AnyView(inMessage(q { $0.referencedMessageNotFound = true }))),
            ("incoming-outgoing-colors", AnyView(VStack(spacing: 0) {
                ForEach(conversationColors, id: \.self) { c in
                    inMessage(q { $0.authorLabel = ContactLabel(labelString: "First", labelEmoji: "1\u{FE0F}\u{20E3}") }, color: c)
                }
            })),
        ]
    }

    @Test(arguments: ["light", "dark"], 0..<2)
    func inMessageStory(theme: String, index: Int) throws {
        let (name, view) = Self.inMessageStories[index]
        let id = "components-conversation-quote--\(name)"
        try Snapshot.assertMatches(TimelineMessageTests.stage(view.frame(width: 1168), storyHeight: try Snapshot.referenceHeight(id, theme)),
                                   story: id, theme: theme)
    }

    @Test func storyCount() { #expect(Self.stories.count == 36) }

    /// The computed backgrounds of the captures (Quote.scss css-lighten / css-darken of forest).
    @Test func forestBackground() {
        let forest = AxoTokens.ChatBubble.solid("forest")!
        let l = forest.cssLighten(0.6), d = forest.cssDarken(0.4)
        #expect(abs(l.r - 0.651922) < 0.002 && abs(l.g - 0.828862) < 0.002 && abs(l.b - 0.680929) < 0.002)
        _ = d
    }
}
