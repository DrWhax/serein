// Window-level state (upstream: the main process + the redux `app`/`nav` slices that the
// shell needs). Persisted bits use the upstream item keys once SignalCore is wired in.

import AppKit
import Observation
import SignalSafeSystem
import SignalUI

@MainActor @Observable final class AppModel {
    var appView: AppViewType = .inbox
    var selectedTab: NavTab = .chats
    /// The Settings tab's page (other places open a page: chat folders, notifications).
    var settingsPage: SettingsPage = .general
    /// A new chat folder started from a chat's context menu ("Create new folder"): that chat.
    var newChatFolderWith: String?
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

    // macOS integration (SignalSafeSystem): settings drive the services directly.
    let contentProtection = ContentProtectionController(enabled: UserDefaults.standard.bool(forKey: "hasContentProtection"))
    let displaySleep = PreventDisplaySleepService()
    /// Privacy → Screen security (`setContentProtection` on every window).
    var hasContentProtection = UserDefaults.standard.bool(forKey: "hasContentProtection") {
        didSet {
            UserDefaults.standard.set(hasContentProtection, forKey: "hasContentProtection")
            contentProtection.setEnabled(hasContentProtection)
        }
    }
    /// Chats → spell check; applies at the next launch, as upstream ("will be enabled…").
    let spellCheckAtLaunch = UserDefaults.standard.object(forKey: "spellCheck") as? Bool ?? true
    var spellCheck = UserDefaults.standard.object(forKey: "spellCheck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(spellCheck, forKey: "spellCheck") }
    }
    /// General → start at login (SMAppService); nil while unsupported (unbundled runs).
    var openAtLogin: Bool? = Bundle.main.bundleIdentifier != nil ? LoginItem.isEnabled : nil
    func setOpenAtLogin(_ on: Bool) {
        try? LoginItem.setEnabled(on)
        openAtLogin = LoginItem.isEnabled
    }
    /// A call is in progress: the display may not sleep (`preventDisplaySleepService`).
    var isCallActive = false {
        didSet { displaySleep.setEnabled(isCallActive) }
    }
    /// Appearance → theme (`themeSetting`: system / light / dark) for every window.
    var themeSetting = UserDefaults.standard.string(forKey: "themeSetting") ?? "system" {
        didSet {
            UserDefaults.standard.set(themeSetting, forKey: "themeSetting")
            applyTheme()
        }
    }
    func applyTheme() {
        NSApplication.shared.appearance = switch themeSetting {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }
    /// Crashes since the last launch (CrashReportDialog when > 0).
    var pendingCrashReports = 0
    let crashReports = CrashReports()

    /// CrashReportDialog "Send": there is no debug-log upload (user decision), so the crash
    /// summaries are saved to a file the user picks (to share as they like), then dismissed.
    func saveCrashReports() {
        let text = crashReports.writeToLog().map(\.logText).joined(separator: "\n\n")
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Serein crash reports.txt"
        if panel.runModal() == .OK, let url = panel.url { try? Data(text.utf8).write(to: url) }
        eraseCrashReports()
    }

    func eraseCrashReports() {
        crashReports.erase()
        pendingCrashReports = 0
    }

    /// `app.setBadgeCount`: the dock tile shows the count, nothing at 0.
    var badgeCount = 0 {
        didSet { NSApplication.shared.dockTile.badgeLabel = badgeCount > 0 ? String(badgeCount) : nil }
    }
}
