// Linkify and AddNewLines stories (ts/components/conversation/*.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct LinkifyStoryTests {
    static let body = CSSTextStyle(AxoType.bodyLarge)

    static let linkify: [(String, String)] = [
        ("only-link", "https://www.signal.org"),
        ("links-with-text", "you should see this: https://www.signal.org - it is good. Also: https://placekitten.com!"),
        ("links-with-emoji-without-space", "👍https://www.signal.org😎"),
        ("links-with-emoji-and-text", "https://example.com ⚠️ 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ https://example.com"),
        ("no-link", "I am fond of cats"),
        ("blocked-protocols", "smailto:someone@somewhere.com - ftp://something.com - //local/share - \\localshare"),
        ("missing-protocols", "I love example.com. I also love кц.рф. I also love مثال.تونس. But I do not love test.example."),
    ]

    @Test(arguments: ["light", "dark"], 0..<7)
    func linkify(theme: String, index: Int) throws {
        let (name, text) = Self.linkify[index]
        try Snapshot.assertMatches(Linkify(text, style: Self.body), story: "components-conversation-linkify--\(name)", theme: theme)
    }

    static let newlines: [(String, String)] = [
        ("all-newlines", "\n\n\n"), ("starting-ending-with-newlines", "\nSome text\n"), ("newlines-in-the-middle", "Some\ntext"), ("no-newlines", "Some text"),
    ]

    @Test(arguments: ["light", "dark"], 0..<4)
    func addNewLines(theme: String, index: Int) throws {
        let (name, text) = Self.newlines[index]
        try Snapshot.assertMatches(CSSText(text, style: Self.body), story: "components-conversation-addnewlines--\(name)", theme: theme)
    }

    static let aquamarine = AxoColor(RGBA(127 / 255, 1, 212 / 255))

    /// `CustomTextRender`: each non-link piece is `renderNonLink`'s aquamarine `<div>` (a
    /// block), so the links sit on their own lines (anonymous blocks) between them.
    @Test(arguments: ["light", "dark"])
    func linkifyCustomTextRender(theme: String) throws {
        let runs = Linkify.runs("you should see this: https://www.signal.org - it is good. Also: https://placekitten.com!")
        let view = VStack(spacing: 0) {
            ForEach(runs.indices, id: \.self) { i in
                let run = runs[i]
                if run.action != nil {
                    CSSText(runs: [run], style: Self.body).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    CSSText(runs: CSSTextRun.collapsingWhiteSpace([run]), style: Self.body)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Self.aquamarine)
                }
            }
        }
        .cssTextColor(.labelPrimary)
        try Snapshot.assertMatches(SmallComponentStoriesTests.top(view), story: "components-conversation-linkify--custom-text-render", theme: theme)
    }

    /// `CustomRenderFunction`: `renderNonNewLine` draws the text in an aquamarine `<div>`.
    @Test(arguments: ["light", "dark"])
    func addNewLinesCustomRenderFunction(theme: String) throws {
        let view = CSSText("Some text", style: Self.body, color: Self.aquamarine).frame(maxWidth: .infinity, alignment: .leading)
        try Snapshot.assertMatches(SmallComponentStoriesTests.top(view), story: "components-conversation-addnewlines--custom-render-function", theme: theme)
    }
}
