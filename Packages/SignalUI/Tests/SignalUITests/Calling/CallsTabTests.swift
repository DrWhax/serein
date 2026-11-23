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

    /// The create row remains clickable under the empty-history overlay. While a request is
    /// in progress, clicking the same spot must not invoke the action a second time.
    @Test func clickCreateWithEmptyHistory() async throws {
        var clicks = 0
        func list(busy: Bool) -> CallsList {
            CallsList(items: [], query: .constant(""), missedOnly: .constant(false), hasActiveCall: false,
                      isCreatingCallLink: busy, selected: nil, onCreateCallLink: { clicks += 1 }, onSelect: { _ in }, onCall: { _ in })
        }
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 320, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: list(busy: false))
        window.contentView = host
        window.orderBack(nil)
        for busy in [false, true] {
            host.rootView = list(busy: busy)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            // Centre of the first row, just below the search field.
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 135, y: 400 - 65), modifierFlags: [],
                                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(50))
            #expect(clicks == 1)
        }
    }
}
