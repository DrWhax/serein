// The main process (app/main.main.ts) for macOS: one main window with a hidden title bar
// (`titleBarStyle: 'hidden'`), 800×610 by default and at least 300×200, the native menu
// from app/menu.std.ts, the dock badge, and hide-on-close / show-on-reopen.

import AppKit
import SignalI18n
import SignalUI
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    let i18n = Localizer(locale: Localizer.match(Locale.preferredLanguages))
    var window: NSWindow?
    var isQuitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AxoFonts.register()
        let options = MainMenu.Options(platform: "darwin", isProduction: true, includeSetup: model.appView == .installer)
        NSApp.mainMenu = MainMenu.build(MainMenu.template(options, i18n: i18n)) { [weak self] in self?.perform($0) }
        createWindow()
        NSApp.activate()
    }

    func createWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 610),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.title = i18n("icu:signalDesktop")
        window.minSize = NSSize(width: 300, height: 200)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let host = NSHostingView(rootView: RootView(model: model, i18n: i18n))
        host.sizingOptions = [.minSize]    // the window keeps its own size; SwiftUI only sets the minimum
        window.contentView = host
        window.setContentSize(NSSize(width: 800, height: 610))
        window.center()
        window.setFrameAutosaveName("SignalSafeMainWindow")    // upstream persists window bounds
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func showWindow() {
        guard let window else { return createWindow() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func perform(_ action: MainMenu.Action) {
        switch action {
        case .showWindow: showWindow()
        case .showKeyboardShortcuts: model.isShowingShortcutGuide = true
        case .showSettings: model.selectedTab = .settings; showWindow()
        case .zoomIn: model.zoomLevel += 1
        case .zoomOut: model.zoomLevel -= 1
        case .zoomReset: model.zoomLevel = 0
        case .openContactUs: open(Self.supportURL(locale: Locale.preferredLanguages.first ?? "en-us"))
        case .openReleaseNotes: open("https://github.com/signalapp/Signal-Desktop/releases")
        case .openForums: open("https://community.signalusers.org/")
        case .openSupportPage: open("https://support.signal.org/hc/sections/360001602812")
        case .openJoinTheBeta: open("https://support.signal.org/hc/articles/360007318471")
        case .showAbout, .showDebugLog, .openArtCreator, .setupAsNewDevice:
            break    // About / DebugLog windows and the sticker creator: Phase 3 step 7 / Phase 7
        }
    }

    /// ts/util/createSupportUrl.std.ts
    static func supportURL(locale: String) -> String {
        let languages = ["ar", "bn", "de", "en-us", "es", "fr", "hi", "hi-in", "hc", "id", "it", "ja", "ko", "mr", "ms", "nl", "pl", "pt",
                         "ru", "sv", "ta", "te", "tr", "uk", "ur", "vi", "zh-cn", "zh-tw"]
        let language = languages.contains(locale) ? locale : "en-us"
        return "https://support.signal.org/hc/\(language)/requests/new?desktop="
    }

    func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    // MARK: lifecycle

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isQuitting = true
        return .terminateNow
    }

    /// macOS: closing the main window hides it; the app keeps running (upstream `close` handler).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isQuitting { return true }
        sender.orderOut(nil)
        return false
    }

    func windowWillEnterFullScreen(_ notification: Notification) { model.isFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) { model.isFullScreen = false }
}
