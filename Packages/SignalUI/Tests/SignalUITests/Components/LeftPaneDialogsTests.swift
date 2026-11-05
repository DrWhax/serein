// Stories of the left-pane banners (ts/components/Dialog*.dom.stories.tsx), each inside
// FakeLeftPaneContainer (wide 350px, narrow 130px).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
func FakeLeftPaneContainer(_ breakpoint: WidthBreakpoint, @ViewBuilder content: () -> some View) -> some View {
    content().frame(width: breakpoint == .wide ? 350 : breakpoint == .medium ? 280 : 130)
}

@MainActor
@Suite struct LeftPaneDialogsTests {
    /// story, isOnline, isOutage, socketStatus, breakpoint
    static let network: [(String, Bool, Bool, SocketStatus, WidthBreakpoint)] = [
        ("knobs-playground", true, false, .connecting, .wide),
        ("connecting-wide", true, false, .connecting, .wide), ("closing-wide", true, false, .closing, .wide),
        ("closed-wide", true, false, .closed, .wide), ("offline-wide", false, false, .connecting, .wide),
        ("outage-wide", false, true, .connecting, .wide),
        ("connecting-narrow", true, false, .connecting, .narrow), ("closing-narrow", true, false, .closing, .narrow),
        ("closed-narrow", true, false, .closed, .narrow), ("offline-narrow", false, false, .connecting, .narrow),
        ("outage-narrow", false, true, .connecting, .narrow),
    ]

    @Test(arguments: ["light", "dark"], 0..<11)
    func networkStatus(theme: String, index: Int) throws {
        let (name, isOnline, isOutage, socketStatus, width) = Self.network[index]
        let view = FakeLeftPaneContainer(width) {
            DialogNetworkStatus(containerWidthBreakpoint: width, isOnline: isOnline, isOutage: isOutage, socketStatus: socketStatus)
        }
        try Snapshot.assertMatches(view, story: "components-dialognetworkstatus--\(name)", theme: theme)
    }

    @Test(arguments: ["light", "dark"], [false, true])
    func relink(theme: String, standalone: Bool) throws {
        let view = VStack(alignment: .leading, spacing: 0) {
            StoryText("Unlinked (wide container)")
            FakeLeftPaneContainer(.wide) { DialogRelink(containerWidthBreakpoint: .wide, weArePrimaryDevice: standalone) }
            Color.clear.frame(height: 20)    // <br />
            StoryText("Unlinked (narrow container)")
            FakeLeftPaneContainer(.narrow) { DialogRelink(containerWidthBreakpoint: .narrow, weArePrimaryDevice: standalone) }
        }
        try Snapshot.assertMatches(view, story: "components-dialogrelink--iterations\(standalone ? "-standalone" : "")", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func clockSkew(theme: String) throws {
        // The captures' Date.now(): 2026-11-04 14:34:14 (light) / :15 (dark) GMT.
        let now = Date(timeIntervalSince1970: 1_793_802_854 + (theme == "dark" ? 1 : 0))
        let view = FakeLeftPaneContainer(.wide) { DialogClockSkew(containerWidthBreakpoint: .wide, now: now) }
            .environment(\.timeZone, TimeZone(identifier: "GMT")!)
        try Snapshot.assertMatches(view, story: "components-dialogclockskew--default", theme: theme)
    }

    @Test(arguments: ["light", "dark"], [false, true])
    func expiredBuild(theme: String, isMAS: Bool) throws {
        let view = FakeLeftPaneContainer(.wide) { DialogExpiredBuild(containerWidthBreakpoint: .wide, isMAS: isMAS) }
        try Snapshot.assertMatches(view, story: "components-dialogexpiredbuild--\(isMAS ? "mas" : "basic")", theme: theme)
    }
}
