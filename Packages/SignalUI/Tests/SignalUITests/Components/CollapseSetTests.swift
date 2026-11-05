// CollapseSet stories (ts/components/conversation/CollapseSet.dom.stories.tsx). Items render as
// the story's `<div class="py-2.5 text-center">Message {id} - <a>Use Signal</a></div>`. The
// button row's 10px margins collapse out of the story root at its edges.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct CollapseSetTests {
    static func item(_ id: String) -> some View {
        var link = CSSTextRun("Use Signal")
        link.color = Linkify.uaLinkColor
        link.underline = true
        return CSSText(runs: [CSSTextRun("Message \(id) - "), link], style: CSSTextStyle(AxoType.bodyLarge), alignment: .center)
            .frame(maxWidth: .infinity).padding(.vertical, 10)
    }

    static func m(_ ids: ClosedRange<Int>, unseen: Set<Int> = [], boundary: Set<Int> = []) -> [CollapsedMessage] {
        ids.map { CollapsedMessage(id: "id\($0)", isUnseen: unseen.contains($0), atDateBoundary: boundary.contains($0)) }
    }

    struct Case {
        var name: String
        var kind: CollapseSetViewer<AnyView>.Kind
        var messages: [CollapsedMessage]
        var isSelected = false
        var isSelectMode = false
        var targeted: String?
        /// The button is the story root's first / last box (its margins collapse out).
        var trimTop = true
        var trimBottom = false
    }

    static let ten = m(1...10, boundary: [4, 8])
    static let cases: [Case] = [
        Case(name: "group-with-two", kind: .groupUpdates, messages: m(1...2), trimBottom: true),
        Case(name: "group-with-two-selected-cannot-collapse", kind: .groupUpdates, messages: m(1...2), isSelected: true),
        Case(name: "autoexpand-if-targeted", kind: .groupUpdates, messages: m(1...2), targeted: "id1"),
        Case(name: "group-with-one-that-has-extra", kind: .groupUpdates,
             messages: [CollapsedMessage(id: "id1 (with one extra)", extraItems: 1)], trimBottom: true),
        Case(name: "group-with-two-that-have-extra", kind: .groupUpdates,
             messages: [CollapsedMessage(id: "id1 (with one extra)", extraItems: 1), CollapsedMessage(id: "id2 (with two extra)", extraItems: 2)],
             trimBottom: true),
        Case(name: "timer-with-two-undefined", kind: .timerChanges(endingState: nil), messages: m(1...2), trimBottom: true),
        Case(name: "timer-with-two-zero", kind: .timerChanges(endingState: 0), messages: m(1...2, boundary: [2]), trimBottom: true),
        Case(name: "timer-with-two-zero-in-select-mode", kind: .timerChanges(endingState: 0), messages: m(1...2, boundary: [2]), isSelectMode: true,
             trimBottom: true),
        Case(name: "timer-with-two-at-15-m", kind: .timerChanges(endingState: 900), messages: m(1...2), trimBottom: true),
        Case(name: "timer-with-ten-at-1-hr", kind: .timerChanges(endingState: 3600), messages: ten, trimBottom: true),
        Case(name: "group-with-two-one-unseen", kind: .groupUpdates, messages: m(1...2, unseen: [2]), trimTop: false),
        Case(name: "group-with-four-two-unseen", kind: .groupUpdates, messages: m(1...4, unseen: [3, 4], boundary: [3])),
        Case(name: "group-with-four-three-unseen", kind: .groupUpdates, messages: m(1...4, unseen: [2, 3, 4]), trimTop: false),
        Case(name: "group-with-with-update-after-delay", kind: .groupUpdates, messages: m(1...4, unseen: [3, 4], boundary: [2])),
    ]

    static func viewer(_ c: Case) -> some View {
        CollapseSetViewer(kind: c.kind, messages: c.messages, isGroup: true, isSelectMode: c.isSelectMode, isSelected: c.isSelected,
                          targetedMessageId: c.targeted) { AnyView(item($0.id)) }
            .padding(.top, c.trimTop ? -10 : 0).padding(.bottom, c.trimBottom ? -10 : 0)
    }

    @Test(arguments: ["light", "dark"], 0..<14)
    func story(theme: String, index: Int) throws {
        let c = Self.cases[index]
        try Snapshot.assertMatches(Self.viewer(c), story: "components-conversation-collapseset--\(c.name)", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func groupWithTen(theme: String) throws {
        let view = VStack(spacing: 0) {
            Self.item("id0")
            CollapseSetViewer(kind: .groupUpdates, messages: Self.ten, isGroup: true) { AnyView(Self.item($0.id)) }
            Self.item("id11")
        }
        try Snapshot.assertMatches(view, story: "components-conversation-collapseset--group-with-ten", theme: theme)
    }
}
