// The Calls list's row rules (CallsList.dom.tsx `rows`); the tab has no Storybook stories.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct CallsTabTests {
    static let group = CallHistoryGroup(type: .audio, direction: .incoming, status: .missed, timestamp: Date(timeIntervalSince1970: 0), children: [])
    static let item = CallsListItem(id: "1", peerId: "c1", group: group, conversation: CallingConversation(id: "c1", title: "Alice"))

    func rows(_ items: [CallsListItem]?, query: String = "", missed: Bool = false) -> [CallsList.Row] {
        CallsList(items: items, query: .constant(query), missedOnly: .constant(missed), hasActiveCall: false, selected: nil,
                  onCreateCallLink: {}, onSelect: { _ in }, onCall: { _ in }).rows
    }

    @Test func listRows() {
        #expect(rows([Self.item]) == [.createCallLink, .item(Self.item)])
        #expect(rows([]) == [.createCallLink])
        #expect(rows([], query: "bob") == [.emptyState])
        #expect(rows([], missed: true) == [.filterHeader, .emptyState, .clearFilterButton])
        #expect(rows([Self.item], missed: true) == [.filterHeader, .item(Self.item), .clearFilterButton])
        #expect(rows([Self.item], query: " a ") == [.item(Self.item)])
        #expect(rows(nil).count == 10)
        #expect(Self.item.wasMissed && !Self.item.wasDeclined)
    }
}
