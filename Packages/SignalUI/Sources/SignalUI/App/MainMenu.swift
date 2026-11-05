// The native menu bar: app/menu.std.ts `createTemplate` (+ `updateForMac`) as data, and an
// NSMenu built from it. Labels, order, separators and accelerators are upstream's; Electron
// menu roles map to the AppKit selectors Electron itself uses for them on macOS.

import AppKit
import SignalI18n

public enum MainMenu {
    /// Electron menu-item roles used by the template.
    public enum Role: String, Sendable {
        case undo, redo, cut, copy, paste, pasteAndMatchStyle, delete, selectAll
        case togglefullscreen, minimize, zoom, close, front, quit, hide, hideOthers, unhide
        case services, startSpeaking, stopSpeaking, window, help

        /// The responder-chain action Electron sends for the role on macOS.
        var selector: Selector? {
            switch self {
            case .undo: NSSelectorFromString("undo:")
            case .redo: NSSelectorFromString("redo:")
            case .cut: NSSelectorFromString("cut:")
            case .copy: NSSelectorFromString("copy:")
            case .paste: NSSelectorFromString("paste:")
            case .pasteAndMatchStyle: NSSelectorFromString("pasteAsPlainText:")
            case .delete: NSSelectorFromString("delete:")
            case .selectAll: NSSelectorFromString("selectAll:")
            case .togglefullscreen: NSSelectorFromString("toggleFullScreen:")
            case .minimize: NSSelectorFromString("performMiniaturize:")
            case .zoom: NSSelectorFromString("performZoom:")
            case .close: NSSelectorFromString("performClose:")
            case .front: NSSelectorFromString("arrangeInFront:")
            case .quit: NSSelectorFromString("terminate:")
            case .hide: NSSelectorFromString("hide:")
            case .hideOthers: NSSelectorFromString("hideOtherApplications:")
            case .unhide: NSSelectorFromString("unhideAllApplications:")
            case .startSpeaking: NSSelectorFromString("startSpeaking:")
            case .stopSpeaking: NSSelectorFromString("stopSpeaking:")
            case .services, .window, .help: nil
            }
        }

        /// Electron's default accelerator for the role on macOS (used when the template sets none).
        var defaultAccelerator: String? {
            switch self {
            case .undo: "CmdOrCtrl+Z"
            case .redo: "Shift+CmdOrCtrl+Z"
            case .cut: "CmdOrCtrl+X"
            case .copy: "CmdOrCtrl+C"
            case .paste: "CmdOrCtrl+V"
            case .pasteAndMatchStyle: "Shift+CmdOrCtrl+Alt+V"
            case .selectAll: "CmdOrCtrl+A"
            case .togglefullscreen: "Ctrl+Cmd+F"
            case .minimize: "CmdOrCtrl+M"
            case .close: "CmdOrCtrl+W"
            case .quit: "CmdOrCtrl+Q"
            case .hide: "CmdOrCtrl+H"
            case .hideOthers: "Alt+CmdOrCtrl+H"
            default: nil
            }
        }
    }

    /// The `click` handlers of `MenuActionsType` that the template uses.
    public enum Action: String, Sendable, CaseIterable {
        case openArtCreator, showSettings, zoomReset, zoomIn, zoomOut, showDebugLog, showKeyboardShortcuts
        case openContactUs, openReleaseNotes, openForums, openSupportPage, openJoinTheBeta, showAbout, showWindow
        case setupAsNewDevice
    }

    public indirect enum Item: Equatable, Sendable {
        case separator
        case item(label: String, accelerator: String? = nil, role: Role? = nil, action: Action? = nil)
        case submenu(label: String, role: Role? = nil, items: [Item])
    }

    public struct Options: Sendable {
        public var platform: String
        public var isProduction: Bool
        /// Not linked yet: File starts with "Set Up as New Device".
        public var includeSetup: Bool
        public init(platform: String = "darwin", isProduction: Bool = true, includeSetup: Bool = false) {
            self.platform = platform
            self.isProduction = isProduction
            self.includeSetup = includeSetup
        }
    }

    /// `createTemplate` (dev-tools, force-update, standalone and backup-staging items are
    /// development-only upstream and omitted here).
    public static func template(_ options: Options, i18n: Localizer) -> [Item] {
        func t(_ key: String) -> String { i18n("icu:" + key) }
        var file: [Item] = [
            .item(label: t("mainMenuCreateStickers"), action: .openArtCreator),
            .item(label: t("mainMenuSettings"), accelerator: "CommandOrControl+,", action: .showSettings),
            .separator,
            .item(label: t("appMenuQuit"), role: .quit),
        ]
        var edit: [Item] = [
            .item(label: t("editMenuUndo"), role: .undo),
            .item(label: t("editMenuRedo"), role: .redo),
            .separator,
            .item(label: t("editMenuCut"), role: .cut),
            .item(label: t("editMenuCopy"), role: .copy),
            .item(label: t("editMenuPaste"), role: .paste),
            .item(label: t("editMenuPasteAndMatchStyle"), role: .pasteAndMatchStyle),
            .item(label: t("editMenuDelete"), role: .delete),
            .item(label: t("editMenuSelectAll"), role: .selectAll),
        ]
        let view: [Item] = [
            .item(label: t("viewMenuResetZoom"), accelerator: "CmdOrCtrl+0", action: .zoomReset),
            .item(label: t("viewMenuZoomIn"), accelerator: "CmdOrCtrl+=", action: .zoomIn),
            .item(label: t("viewMenuZoomOut"), accelerator: "CmdOrCtrl+-", action: .zoomOut),
            .separator,
            .item(label: t("viewMenuToggleFullScreen"), role: .togglefullscreen),
            .separator,
            .item(label: t("debugLog"), action: .showDebugLog),
        ]
        var window: [Item] = [.item(label: t("windowMenuMinimize"), role: .minimize)]
        var help: [Item] = [
            .item(label: t("helpMenuShowKeyboardShortcuts"), accelerator: "CmdOrCtrl+/", action: .showKeyboardShortcuts),
            .separator,
            .item(label: t("contactUs"), action: .openContactUs),
            .item(label: t("goToReleaseNotes"), action: .openReleaseNotes),
            .item(label: t("goToForums"), action: .openForums),
            .item(label: t("goToSupportPage"), action: .openSupportPage),
        ]
        if options.isProduction { help.append(.item(label: t("joinTheBeta"), action: .openJoinTheBeta)) }
        help += [.separator, .item(label: t("aboutSignalDesktop"), action: .showAbout)]

        if options.includeSetup {
            file.insert(contentsOf: [.item(label: t("menuSetupAsNewDevice"), action: .setupAsNewDevice), .separator], at: 0)
        }

        guard options.platform == "darwin" else {
            return [
                .submenu(label: t("mainMenuFile"), items: file),
                .submenu(label: t("mainMenuEdit"), items: edit),
                .submenu(label: t("mainMenuView"), items: view),
                .submenu(label: t("mainMenuWindow"), role: .window, items: window),
                .submenu(label: t("mainMenuHelp"), role: .help, items: help),
            ]
        }

        // updateForMac
        help.removeLast(2)
        file.removeLast(3)
        file += [.separator, .item(label: t("windowMenuClose"), accelerator: "CmdOrCtrl+W", role: .close)]
        let app: [Item] = [
            .item(label: t("aboutSignalDesktop"), action: .showAbout),
            .separator,
            .item(label: t("mainMenuSettings"), accelerator: "CommandOrControl+,", action: .showSettings),
            .separator,
            .submenu(label: t("appMenuServices"), role: .services, items: []),
            .separator,
            .item(label: t("appMenuHide"), role: .hide),
            .item(label: t("appMenuHideOthers"), role: .hideOthers),
            .item(label: t("appMenuUnhide"), role: .unhide),
            .separator,
            .item(label: t("appMenuQuit"), role: .quit),
        ]
        edit += [.separator, .submenu(label: t("speech"), items: [
            .item(label: t("editMenuStartSpeaking"), role: .startSpeaking),
            .item(label: t("editMenuStopSpeaking"), role: .stopSpeaking),
        ])]
        window = [
            .item(label: t("windowMenuMinimize"), accelerator: "CmdOrCtrl+M", role: .minimize),
            .item(label: t("windowMenuZoom"), role: .zoom),
            .item(label: t("show"), accelerator: "CmdOrCtrl+Shift+0", action: .showWindow),
            .separator,
            .item(label: t("windowMenuBringAllToFront"), role: .front),
        ]
        return [
            .submenu(label: t("signalDesktop"), items: app),
            .submenu(label: t("mainMenuFile"), items: file),
            .submenu(label: t("mainMenuEdit"), items: edit),
            .submenu(label: t("mainMenuView"), items: view),
            .submenu(label: t("mainMenuWindow"), role: .window, items: window),
            .submenu(label: t("mainMenuHelp"), role: .help, items: help),
        ]
    }

    /// Electron's label handling on macOS: `&` mnemonics are dropped (`&&` is a literal `&`).
    public static func displayLabel(_ label: String) -> String {
        var out = "", chars = Array(label), i = 0
        while i < chars.count {
            if chars[i] == "&" {
                if i + 1 < chars.count, chars[i + 1] == "&" { out.append("&"); i += 2; continue }
                i += 1
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// An Electron accelerator ("CmdOrCtrl+Shift+0") as an AppKit key equivalent.
    public static func keyEquivalent(_ accelerator: String) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        var parts = accelerator.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "CmdOrCtrl+=" and "CmdOrCtrl+-" split cleanly; a trailing "+" key would leave "".
        guard let last = parts.popLast() else { return nil }
        var mods: NSEvent.ModifierFlags = []
        for p in parts {
            switch p.lowercased() {
            case "cmdorctrl", "commandorcontrol", "cmd", "command": mods.insert(.command)
            case "ctrl", "control": mods.insert(.control)
            case "alt", "option": mods.insert(.option)
            case "shift": mods.insert(.shift)
            default: return nil
            }
        }
        let key = last.count == 1 ? last.lowercased() : last
        guard key.count == 1 else { return nil }
        return (key, mods)
    }

    /// Builds the NSMenu bar. Items with an `action` call `perform`; role items go down the
    /// responder chain; the Services, Window and Help menus are registered with NSApp.
    @MainActor public static func build(_ items: [Item], perform: @escaping @MainActor (Action) -> Void) -> NSMenu {
        let target = ActionTarget(perform: perform)
        ActionTarget.current = target
        let bar = NSMenu()
        for item in items { bar.addItem(menuItem(item, target: target, topLevel: true)) }
        return bar
    }

    @MainActor static func menuItem(_ item: Item, target: ActionTarget, topLevel: Bool = false) -> NSMenuItem {
        switch item {
        case .separator:
            return .separator()
        case let .item(label, accelerator, role, action):
            let mi = NSMenuItem(title: displayLabel(label), action: nil, keyEquivalent: "")
            if let action {
                mi.action = #selector(ActionTarget.performAction(_:))
                mi.target = target
                mi.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            } else if let role {
                mi.action = role.selector
            }
            if let acc = accelerator ?? role?.defaultAccelerator, let (key, mods) = keyEquivalent(acc) {
                mi.keyEquivalent = key
                mi.keyEquivalentModifierMask = mods
            }
            return mi
        case let .submenu(label, role, items):
            let title = displayLabel(label)
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            for child in items { sub.addItem(menuItem(child, target: target)) }
            mi.submenu = sub
            switch role {
            case .services: NSApplication.shared.servicesMenu = sub
            case .window: NSApplication.shared.windowsMenu = sub
            case .help: NSApplication.shared.helpMenu = sub
            default: break
            }
            return mi
        }
    }

    @MainActor final class ActionTarget: NSObject {
        /// NSMenuItem.target is weak: the current bar's target is kept alive here.
        static var current: ActionTarget?
        let perform: @MainActor (Action) -> Void
        init(perform: @escaping @MainActor (Action) -> Void) { self.perform = perform }

        @objc func performAction(_ sender: NSMenuItem) {
            if let raw = sender.identifier?.rawValue, let action = Action(rawValue: raw) { perform(action) }
        }
    }
}
