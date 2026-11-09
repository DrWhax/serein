// The main process (app/main.main.ts) for macOS: one main window with a hidden title bar
// (`titleBarStyle: 'hidden'`), 800×610 by default and at least 300×200, the native menu
// from app/menu.std.ts, the dock badge, and hide-on-close / show-on-reopen.

import AppKit
import SignalI18n
import SignalSafeSystem
import SignalUI
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    let session = SignalSession()
    var keyMonitor: Any?
    /// Serein: upstream's strings that name the desktop app say "Serein"; the nonprofit line
    /// becomes the non-affiliation notice.
    let i18n = Localizer(locale: Localizer.match(Locale.preferredLanguages), rebrand: Rebrand(name: "Serein", messages: [
        "icu:signalNonProfit": "{appName} is not affiliated with or endorsed by Signal Messenger LLC.",
        "icu:EntryPoint--nonprofit": "{appName} is not affiliated with or endorsed by Signal Messenger LLC.",
    ]))
    var window: NSWindow?
    var isQuitting = false
    var badgeTask: Task<Void, Never>?
    lazy var notifications = SystemNotifications(i18n: i18n)

    func applicationDidFinishLaunching(_ notification: Notification) {
        AxoFonts.register()
        CallingLink.smokeTestIfRequested()
        let options = MainMenu.Options(platform: "darwin", isProduction: true, includeSetup: model.appView == .installer,
                                          includeSignalLinks: false)
        NSApp.mainMenu = MainMenu.build(MainMenu.template(options, i18n: i18n)) { [weak self] in self?.perform($0) }
        model.applyTheme()
        createWindow()
        session.start()
        installKeyboardShortcuts()
        wireNotifications()
        model.contentProtection.setEnabled(model.hasContentProtection)
        model.pendingCrashReports = model.crashReports.count
        notifications.log = { SignalSession.trace($0) }
        Task { await notifications.enable() }
        NSApp.activate()
    }

    /// Received messages → system notifications (after the policy and the user's settings);
    /// the Dock badge follows the unread count; a click opens the chat.
    func wireNotifications() {
        notifications.onClick = { [weak self] click in
            guard let self else { return }
            model.selectedTab = .chats
            session.open(conversationId: click.conversationId)
            showWindow()
        }
        session.onEvent = { [weak self] event, session in
            guard let self else { return }
            switch event {
            case .typing(let sender, let started, _, let groupId):
                session.receivedTyping(sender: sender, started: started, groupId: groupId)
                return
            case .message(let messageId, let conversationId, _, _, _, _, _, _), .storyReply(let messageId, _, let conversationId, _):
                // Visible in the open chat of the focused window: read now, no notification.
                if NSApp.isActive, conversationId == session.selectedConversationId, model.selectedTab == .chats {
                    session.markRead(conversationId, force: true)
                    return
                }
                Task {
                    guard let (pending, settings) = await session.notification(for: messageId) else { return SignalSession.trace("notifications: none for this message (policy)") }
                    self.notifications.add(pending, settings: settings)
                }
            default:
                break
            }
            if badgeTask == nil, let updates = session.badgeUpdates() {
                badgeTask = Task { [weak self] in
                    do { for try await n in updates { self?.notifications.setBadgeCount(n) } } catch {}
                }
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        notifications.clear()
        if model.selectedTab == .chats, let id = session.selectedConversationId { session.markRead(id) }
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
        let host = NSHostingView(rootView: RootView(model: model, session: session, i18n: i18n).environment(\.spellCheckEnabled, model.spellCheckAtLaunch)
            .environment(\.brandLogo, BundledImage.named("serein-logo")))
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
        case .openArtCreator:
            StickerCreatorWindow.show(session: session, i18n: i18n)
        case .showAbout:
            showAbout()
        case .showDebugLog, .setupAsNewDevice:
            break
        }
    }

    private var aboutWindow: NSWindow?

    /// app/main.main.ts showAbout: a 500×500 fixed-size window, titled "About …".
    func showAbout() {
        if let aboutWindow { return aboutWindow.makeKeyAndOrderFront(nil) }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 500), styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.title = i18n("icu:aboutSignalDesktop")
        window.isReleasedWhenClosed = false
        let about = About(appEnv: "production", version: version, closeAbout: { [weak window] in window?.close() })
        window.contentView = NSHostingView(rootView: about.environment(\.i18n, i18n).environment(\.brandLogo, BundledImage.named("serein-logo")))
        window.center()
        aboutWindow = window
        window.makeKeyAndOrderFront(nil)
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

    /// The timeline's keyboard shortcuts that are not menu items (upstream's keydown handlers):
    /// ⌘⇧E toggles the reaction picker.
    func installKeyboardShortcuts() {
        let session = session, model = model
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Escape in the call lobby: don't call after all (the lobby's ✕ does the same).
            if event.keyCode == 53, mods.isEmpty, MainActor.assumeIsolated({ session.activeCall?.stage == .lobby }) {
                MainActor.assumeIsolated { session.endCallUI() }
                return nil
            }
            if mods == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "e",
               model.selectedTab == .chats, session.selectedConversationId != nil {
                MainActor.assumeIsolated { session.toggleReactionPickerShortcut() }
                return nil
            }
            return event
        }
    }
}
