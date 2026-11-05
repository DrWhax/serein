// MessageTimestamp, ExpireTimer, LastSeenIndicator, ScrollDownButton and SystemMessage stories
// (ts/components/conversation/*.dom.stories.tsx). Captures run at a fixed clock
// (2026-11-04T12:00:00Z) in UTC.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct TimelinePartsTests {
    static let now = Date(timeIntervalSince1970: 1_793_793_600)
    static let body = CSSTextStyle(AxoType.bodyLarge)
    static let bold = { var s = body; s.fontName = AxoFonts.interName(weight: 700); return s }()

    static func fixed(_ v: some View) -> some View {
        v.environment(\.conversationListNow, now).environment(\.timeZone, TimeZone(identifier: "UTC")!)
    }

    @Test(arguments: ["light", "dark"])
    func messageTimestamp(theme: String) throws {
        let rows: [(String, TimeInterval)] = [("500ms ago", -0.5), ("30s ago", -30), ("1m ago", -60), ("30m ago", -1800), ("45m ago", -2700),
                                              ("1h ago", -3600), ("12:01am today", -(12 * 3600 - 60)), ("24h ago", -86_400),
                                              ("7d ago", -7 * 86_400), ("366d ago", -366 * 86_400)]
        // <table>: two auto-width columns, no spacing; <th> bold and centred.
        let table = Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                CSSText("Description", style: Self.bold, wrap: .nowrap).gridCellAnchor(.center)
                CSSText("Timestamp", style: Self.bold, wrap: .nowrap).gridCellAnchor(.center)
            }
            ForEach(rows, id: \.0) { row in
                GridRow {
                    CSSText(row.0, style: Self.body, wrap: .nowrap)
                    MessageTimestamp(timestamp: Self.now.addingTimeInterval(row.1))
                }
            }
        }
        let view = table.frame(maxWidth: .infinity, alignment: .leading)
        try Snapshot.assertMatches(Self.fixed(view), story: "components-conversation-messagetimestamp--normal", theme: theme)
        try Snapshot.assertMatches(Self.fixed(MessageTimestamp(timestamp: Self.now).frame(maxWidth: .infinity, alignment: .leading)),
                                   story: "components-conversation-messagetimestamp--knobs", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func expireTimer(theme: String) throws {
        let cases: [(String, TimeInterval, TimeInterval)] = [("30-seconds", 30, 30), ("2-minutes", 120, 120), ("in-progress", 30, 15),
                                                              ("expired", 30, -30), ("expiration-too-far-out", 30, 150)]
        for (name, length, remaining) in cases {
            // An inline-block in the story's 20px line: margin-start 6, bottom margin edge (2px) on the baseline.
            let view = ExpireTimer(expirationLength: length, expirationTimestamp: Self.now.addingTimeInterval(remaining))
                .padding(EdgeInsets(top: 1, leading: 6, bottom: 7, trailing: 0)).frame(maxWidth: .infinity, alignment: .leading)
            try Snapshot.assertMatches(Self.fixed(view), story: "components-conversation-expiretimer--\(name)", theme: theme)
        }
    }

    @Test(arguments: ["light", "dark"])
    func lastSeenIndicator(theme: String) throws {
        try Snapshot.assertMatches(LastSeenIndicator(count: 1), story: "components-conversation-lastseenindicator--one", theme: theme)
        try Snapshot.assertMatches(LastSeenIndicator(count: 5), story: "components-conversation-lastseenindicator--more-than-one", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func scrollDownButton(theme: String) throws {
        try Snapshot.assertMatches(ScrollDownButton(variant: .unreadMessages) {}.frame(maxWidth: .infinity, alignment: .leading),
                                   story: "components-conversation-scrolldownbutton--unread-messages", theme: theme)
        try Snapshot.assertMatches(ScrollDownButton(variant: .unreadMentions) {}.frame(maxWidth: .infinity, alignment: .leading),
                                   story: "components-conversation-scrolldownbutton--unread-mentions", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func systemMessage(theme: String) throws {
        try Snapshot.assertMatches(SystemMessage(.icon("v3/phone/phone-compact"), text: "Some nice text"),
                                   story: "components-conversation-systemmessage--plain-system-message", theme: theme)
        try Snapshot.assertMatches(SystemMessage(.icon("v3/phone/phone-compact"), text: "Some loud danger text", kind: .danger),
                                   story: "components-conversation-systemmessage--danger-system-message", theme: theme)
        try Snapshot.assertMatches(SystemMessage(.icon("v3/error/error-circle-compact"), text: "Some error text", kind: .error),
                                   story: "components-conversation-systemmessage--error-system-message", theme: theme)
    }
}

