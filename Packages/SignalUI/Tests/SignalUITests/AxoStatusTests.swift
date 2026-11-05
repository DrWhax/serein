// AxoLoadingIndicator and AxoProgressIndicator stories
// (ts/axo/status/AxoLoadingIndicator.dom.stories.tsx, AxoProgressIndicator.dom.stories.tsx).
//
// The progress stories animate fake progress (useFakeProgress: random increments every
// 100–500 ms from 0), so the captured ring is at a random early value; the twins show a
// fixed early value (15 of 100).

import SwiftUI
import Testing
@testable import SignalUI

/// `flex gap-2` of fixed-size spinners (replaced elements keep their height).
@MainActor func spinnerRow(@ViewBuilder _ content: () -> some View) -> some View {
    HStack(alignment: .top, spacing: 8) { content() }.frame(maxWidth: .infinity, alignment: .leading)
}

/// Story `AxoProgressIndicator/Indeterminate`: two labelled checkboxes and a ring,
/// `flex flex-col items-start gap-3`.
struct AxoProgressIndicatorIndeterminateStory: View {
    @State var completed = false
    @State var total = true

    struct Checkbox: View {
        let label: String
        @Binding var checked: Bool
        var body: some View {
            HStack(alignment: .top, spacing: 8) {                     // flex gap-2
                AxoCheckbox.Root(variant: .square, checked: $checked)
                StoryText(label, wrap: .nowrap)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Checkbox(label: "Known completed amount", checked: $completed)
            Checkbox(label: "Known total amount", checked: $total)
            AxoProgressIndicator.Root(size: .md, completed: completed ? .value(30) : .indeterminate,
                                      total: total ? .value(100) : .indeterminate, noTrack: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
@Suite struct AxoStatusTests {
    static let progress = (completed: 15.0, total: 100.0)

    static let stories: [(String, @MainActor () -> AnyView)] = [
        ("axo-status-axoloadingindicator--basic", { AnyView(AxoLoadingIndicator.Root(size: .md)) }),
        ("axo-status-axoloadingindicator--sizes", { AnyView(spinnerRow {
            ForEach(AxoLoadingIndicator.Size.allCases, id: \.self) { AxoLoadingIndicator.Root(size: $0) }
        }) }),
        ("axo-status-axoloadingindicator--weights", { AnyView(spinnerRow {
            ForEach([AxoBaseSpinner.Weight.thin, .light, .regular, .medium], id: \.self) { AxoLoadingIndicator.Root(size: .md, weight: $0) }
        }) }),
        ("axo-status-axoprogressindicator--basic", { AnyView(
            AxoProgressIndicator.Root(size: .md, completed: progress.completed, total: progress.total)) }),
        ("axo-status-axoprogressindicator--no-track", { AnyView(
            AxoProgressIndicator.Root(size: .md, completed: progress.completed, total: progress.total, noTrack: true)) }),
        ("axo-status-axoprogressindicator--indeterminate", { AnyView(AxoProgressIndicatorIndeterminateStory()) }),
        ("axo-status-axoprogressindicator--sizes", { AnyView(spinnerRow {
            ForEach(AxoProgressIndicator.Size.allCases, id: \.self) {
                AxoProgressIndicator.Root(size: $0, completed: progress.completed, total: progress.total)
            }
        }) }),
        ("axo-status-axoprogressindicator--weights", { AnyView(spinnerRow {
            ForEach([AxoBaseSpinner.Weight.thin, .light, .regular, .medium], id: \.self) {
                AxoProgressIndicator.Root(size: .md, weight: $0, completed: progress.completed, total: progress.total)
            }
        }) }),
    ]

    nonisolated static let ids = [
        "axo-status-axoloadingindicator--basic", "axo-status-axoloadingindicator--sizes", "axo-status-axoloadingindicator--weights",
        "axo-status-axoprogressindicator--basic", "axo-status-axoprogressindicator--no-track", "axo-status-axoprogressindicator--indeterminate",
        "axo-status-axoprogressindicator--sizes", "axo-status-axoprogressindicator--weights",
    ]

    @Test(arguments: ids, ["light", "dark"])
    func story(id: String, theme: String) throws {
        let view = Self.stories.first { $0.0 == id }!.1()
        try Snapshot.assertMatches(view, story: id, theme: theme)
    }
}
