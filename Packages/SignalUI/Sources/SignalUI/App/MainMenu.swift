// The native menu bar: app/menu.std.ts `createTemplate` (+ `updateForMac`) as data, and an
// NSMenu built from it. Labels, order, separators and accelerators are upstream's; Electron
// menu roles map to the AppKit selectors Electron itself uses for them on macOS.

import Foundation
import SignalI18n

public enum MainMenu {
    /// Electron menu-item roles used by the template.
    public enum Role: String, Sendable {
        case undo, redo, cut, copy, paste, pasteAndMatchStyle, delete, selectAll
        case togglefullscreen, minimize, zoom, close, front, quit, hide, hideOthers, unhide
        case services, startSpeaking, stopSpeaking, window, help

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
        /// Help's links to Signal's support site, release notes, forums and beta (off in a
        /// rebranded build: they are Signal's).
        public var includeSignalLinks: Bool
        public init(platform: String = "darwin", isProduction: Bool = true, includeSetup: Bool = false, includeSignalLinks: Bool = true) {
            self.includeSignalLinks = includeSignalLinks
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
        ]
        if options.includeSignalLinks {
            help += [
                .separator,
                .item(label: t("contactUs"), action: .openContactUs),
                .item(label: t("goToReleaseNotes"), action: .openReleaseNotes),
                .item(label: t("goToForums"), action: .openForums),
                .item(label: t("goToSupportPage"), action: .openSupportPage),
            ]
            if options.isProduction { help.append(.item(label: t("joinTheBeta"), action: .openJoinTheBeta)) }
        }
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

}
