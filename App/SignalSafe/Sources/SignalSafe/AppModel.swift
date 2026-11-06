// Window-level state (upstream: the main process + the redux `app`/`nav` slices that the
// shell needs). Persisted bits use the upstream item keys once SignalCore is wired in.

import AppKit
import Observation
import SignalUI

@MainActor @Observable final class AppModel {
    var appView: AppViewType = .inbox
    var selectedTab: NavTab = .chats
    var navTabsCollapsed = false
    /// `preferredLeftPaneWidth` item (default 320 upstream).
    var preferredLeftPaneWidth: CGFloat = 320
    var isShowingShortcutGuide = false
    /// Calls tab: the history search, the missed-calls filter and the new-call search.
    var callsHistoryQuery = ""
    var callsMissedOnly = false
    var newCallQuery = ""
    var isFullScreen = false
    /// ZoomFactorService: factor = 1.2^level, level steps of 1, reset to 0.
    var zoomLevel: Double = 0
    var zoomFactor: CGFloat { CGFloat(pow(1.2, zoomLevel)) }

    /// `app.setBadgeCount`: the dock tile shows the count, nothing at 0.
    var badgeCount = 0 {
        didSet { NSApplication.shared.dockTile.badgeLabel = badgeCount > 0 ? String(badgeCount) : nil }
    }
}
