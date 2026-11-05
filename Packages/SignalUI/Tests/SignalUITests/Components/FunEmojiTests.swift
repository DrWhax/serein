// ts/components/fun/FunEmoji.dom.stories.tsx. "All" lays every emoji variant out 8 to a row
// (16px FunStaticEmoji, each outlined, 4px apart) in a 400px bordered scroller; only the first
// rows are visible (Fixtures/emoji-all-variants-head.json, from build/emoji-data.json order).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct FunEmojiTests {
    static let variants: [String] = {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/emoji-all-variants-head.json")
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }()

    struct AllStory: View {
        @Environment(\.cssTextColor) var color
        var body: some View {
            let rows = stride(from: 0, to: FunEmojiTests.variants.count, by: 8).map { Array(FunEmojiTests.variants[$0..<min($0 + 8, FunEmojiTests.variants.count)]) }
            let grid = VStack(alignment: .leading, spacing: 4) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 4) {
                        ForEach(rows[r], id: \.self) { e in
                            FunStaticEmoji(e, size: 16)
                                .overlay(Rectangle().inset(by: -1).strokeBorder(color, lineWidth: 1))   // outline: 1px solid
                        }
                    }
                    .frame(height: 16)
                }
            }
            Color.clear.frame(height: 400).overlay(alignment: .topLeading) { grid.fixedSize().padding(11) }
            .frame(maxWidth: .infinity)
            .clipped()      // 1px border + 10px padding (border-box)
            .overlay(Rectangle().strokeBorder(color, lineWidth: 1))
        }
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        try Snapshot.assertMatches(AllStory(), story: "components-fun-funemoji--all", theme: theme)
        let text = "🍤 Lorem, ipsum dolor sit amet consectetur adipisicing elit. Repellat voluptates, mollitia tempora alias libero repudiandae nesciunt. "
            + "Deleniti ducimus dolorum, debitis, reprehenderit at ut deserunt fuga corrupti provident quae natus a! 🍤 Consectetur quibusdam "
            + "accusantium magni ipsum nemo eligendi quisquam dolor, recusandae vero dolore reiciendis doloribus ducimus officiis minima! Unde "
            + "accusantium ut eaque error quidem soluta! Distinctio dicta rem nemo aut quo. 🍤"
        try Snapshot.assertMatches(CSSText(runs: [Emojify.run(text)], style: LegacyType.body1()).frame(width: 1168, alignment: .leading),
                                   story: "components-fun-funemoji--inline", theme: theme)
    }
}
