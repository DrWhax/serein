// AxoBadge stories (ts/axo/AxoBadge.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor func badge(variant: AxoBadge.Variant = .primary, size: AxoBadge.Size = .lg, value: AxoBadge.Value = .count(1), max: Int? = 99) -> AxoBadge.Root {
    AxoBadge.Root(variant: variant, size: size, value: value, max: max, label: nil)
}

/// `flex gap-4` row (align-items: stretch, but badges are fixed-size flex containers that stretch).
@MainActor func badgeRow(_ badges: [AxoBadge.Root]) -> some View {
    CSSFlex(.row, gap: 16) { ForEach(Array(badges.enumerated()), id: \.offset) { _, b in b } }
        .frame(maxWidth: .infinity, alignment: .leading)
}

@MainActor
@Suite struct AxoBadgeTests {
    static let stories: [(String, @MainActor () -> AnyView)] = [
        ("basic", { AnyView(badge()) }),
        ("digits", { AnyView(badgeRow([10, 99, 999, 9999, 999_999_999].map { badge(value: .count($0), max: nil) })) }),
        ("max", { AnyView(badgeRow([(9, 9), (10, 9), (99, 99), (100, 99), (999, 999), (1000, 999), (9999, 9999), (10000, 9999)]
            .map { badge(value: .count($0.0), max: $0.1) })) }),
        ("mention", { AnyView(badge(value: .mention)) }),
        ("unread", { AnyView(badge(value: .unread)) }),
        ("error", { AnyView(badge(variant: .destructive, value: .error)) }),
        ("variants", { AnyView(badgeRow([badge(variant: .primary), badge(variant: .destructive), badge(variant: .secondary)])) }),
        ("sizes", { AnyView(badgeRow(AxoBadge.Size.allCases.map { badge(size: $0) })) }),
        ("dot", { AnyView(badgeRow([badge(size: .dot, value: .unread), badge(variant: .destructive, size: .dot, value: .unread)])) }),
    ]

    @Test(arguments: ["basic", "digits", "max", "mention", "unread", "error", "variants", "sizes", "dot"], ["light", "dark"])
    func story(name: String, theme: String) throws {
        let view = Self.stories.first { $0.0 == name }!.1()
        try Snapshot.assertMatches(view, story: "axo-axobadge--\(name)", theme: theme)
    }
}
