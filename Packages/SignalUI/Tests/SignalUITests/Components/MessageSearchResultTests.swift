// MessageSearchResult stories (ts/components/conversationList/MessageSearchResult.dom.stories.tsx).
// `someone`, `me` and `group` come from getDefaultConversation with the seeded randomness.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct MessageSearchResultTests {
    static let someone = MessageSearchResultPerson(title: "Some Person",
        avatar: ConversationAvatarData(title: "Some Person", color: "A180", image: fixtureImage("kitten-2-64-64.jpg")))
    static let me = MessageSearchResultPerson(title: "Me", isMe: true,
        avatar: ConversationAvatarData(title: "Me", color: "A130", image: fixtureImage("kitten-2-64-64.jpg")))
    static let group = MessageSearchResultPerson(title: "Group Chat", type: .group)

    func result(from: MessageSearchResultPerson, to: MessageSearchResultPerson, snippet: String = "What's <<left>>going<<right>> on?",
                body: String = "What's going on?", bodyRanges: [BodyRange] = []) -> MessageSearchResult {
        MessageSearchResult(id: "", conversationId: "", from: from, to: to, sentAt: fixedNow.addingTimeInterval(-24 * 60), snippet: snippet,
                            body: body, bodyRanges: bodyRanges)
    }

    func check(_ view: some View, _ story: String, _ theme: String) throws {
        // The first row's 2px top margin collapses out of the story root (the capture starts at it).
        try Snapshot.assertMatches(view.padding(.top, -2).environment(\.conversationListNow, fixedNow).environment(\.timeZone, TimeZone(identifier: "GMT")!),
                                   story: "components-messagesearchresult--\(story)", theme: theme)
    }

    static let simple: [(String, KeyPath<MessageSearchResultTests.Type, MessageSearchResultPerson>, KeyPath<MessageSearchResultTests.Type, MessageSearchResultPerson>)] = [
        ("default", \.someone, \.me), ("selected", \.someone, \.me), ("from-you", \.me, \.someone),
        ("searching-in-conversation", \.me, \.someone), ("from-you-to-yourself", \.me, \.me), ("from-you-to-group", \.me, \.group),
        ("from-someone-to-group", \.someone, \.group),
    ]

    @Test(arguments: ["light", "dark"], 0..<7)
    func simple(theme: String, index: Int) throws {
        let (name, from, to) = Self.simple[index]
        try check(result(from: Self.self[keyPath: from], to: Self.self[keyPath: to]), name, theme)
    }

    @Test(arguments: ["light", "dark"])
    func longSearchResult(theme: String) throws {
        // The items are block-level flex boxes: their 2px margins collapse between them.
        let view = VStack(spacing: -2) {
            result(from: Self.someone, to: Self.me,
                   snippet: "This is a really <<left>>detail<<right>>ed long line which will wrap and only be cut off after it gets to three lines. So maybe this will make it in as well?",
                   body: "This is a really detailed long line which will wrap and only be cut off after it gets to three lines. So maybe this will make it in as well?")
            result(from: Self.someone, to: Self.me,
                   snippet: "Okay, here are the <<left>>detail<<right>>s:\n\n1355 Ridge Way\nCode: 234\n\nI'm excited!",
                   body: "Okay, here are the details:\n\n1355 Ridge Way\nCode: 234\n\nI'm excited!")
        }
        try check(view, "long-search-result", theme)
    }

    static let longBody = "moss banana twine sound lake zoo brain count vacuum work stairs try power forget hair dry diary years no results \u{FFFC} elephant sorry umbrella potato igloo kangaroo home Georgia bayonet vector orange forge diary zebra turtle rise front \u{FFFC}"
    static func mention(_ name: String, at start: Int) -> BodyRange {
        BodyRange(start: start, length: 1, kind: .mention(aci: "", conversationID: "x", replacementText: name))
    }

    @Test(arguments: ["light", "dark"])
    func mention(theme: String) throws {
        try check(result(from: Self.someone, to: Self.me,
                         snippet: "<<truncation>>forget hair dry diary years no <<left>>results<<right>> \u{FFFC} <<left>>elephant<<right>> sorry umbrella potato igloo kangaroo home Georgia<<truncation>>",
                         body: Self.longBody, bodyRanges: [Self.mention("Shoe", at: 113), Self.mention("Shoe", at: 237)]), "mention", theme)
    }

    @Test(arguments: ["light", "dark"])
    func mentionRegexp(theme: String) throws {
        try check(result(from: Self.someone, to: Self.me,
                         snippet: "\u{FFFC} This is a (long) /text/ ^$ that is ... <<left>>specially<<right>> **crafted** to (test) our regexp escaping mechanism<<truncation>>",
                         body: "\u{FFFC} This is a (long) /text/ ^$ that is ... specially **crafted** to (test) our regexp escaping mechanism! Making sure that the code we write works in all sorts of scenarios",
                         bodyRanges: [Self.mention("RegExp", at: 0)]), "mention-regexp", theme)
    }

    @Test(arguments: ["light", "dark"])
    func mentionNoMatches(theme: String) throws {
        try check(result(from: Self.someone, to: Self.me, snippet: "\u{FFFC} hello", body: "\u{FFFC} hello",
                         bodyRanges: [Self.mention("Neo", at: 0)]), "mention-no-matches", theme)
    }

    @Test(arguments: ["light", "dark"])
    func mentionNoMatches2(theme: String) throws {
        try check(result(from: Self.someone, to: Self.me,
                         snippet: "<<truncation>>forget hair dry diary years no results \u{FFFC} elephant sorry umbrella potato igloo kangaroo home Georgia<<truncation>>",
                         body: Self.longBody, bodyRanges: [Self.mention("Shoe", at: 113), Self.mention("Shoe", at: 237)]), "mention-no-matches-2", theme)
    }

    @Test(arguments: ["light", "dark"])
    func doubleMention(theme: String) throws {
        try check(result(from: Self.someone, to: Self.me, snippet: "<<left>>Hey<<right>> \u{FFFC} \u{FFFC} --- test! <<truncation>>",
                         body: "Hey \u{FFFC} \u{FFFC} --- test! Two mentions!",
                         bodyRanges: [Self.mention("Alice", at: 4), Self.mention("Bob", at: 6)]), "double-mention", theme)
    }

    @Test(arguments: ["light", "dark"])
    func withFormatting(theme: String) throws {
        try check(result(from: Self.someone, to: Self.me,
                         snippet: "<<truncation>>playing with formatting in <<left>>fun<<right>> ways<<truncation>>",
                         body: "We're playing with formatting in fun ways like you do!",
                         bodyRanges: [BodyRange(start: 0, length: 19, kind: .formatting(.bold)), BodyRange(start: 0, length: 54, kind: .formatting(.italic)),
                                      BodyRange(start: 19, length: 10, kind: .formatting(.monospace)),
                                      BodyRange(start: 29, length: 25, kind: .formatting(.strikethrough))]), "with-formatting", theme)
    }
}
