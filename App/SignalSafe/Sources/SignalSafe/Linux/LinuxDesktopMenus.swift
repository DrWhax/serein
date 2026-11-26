import Foundation
import SignalI18n
import SignalUI
@_spi(Qt) import SwiftUI

@MainActor struct LinuxDesktopMenus: Commands {
    let model: AppModel
    let session: SignalSession
    let i18n: Localizer
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel, session: SignalSession, i18n: Localizer) {
        self.model = model
        self.session = session
        self.i18n = i18n
    }

    var body: some Commands {
        let menus = MainMenu.template(.init(platform: "linux", includeSetup: model.appView == .installer,
                                            includeSignalLinks: false), i18n: i18n)
        section("icu:mainMenuFile", in: menus)
        section("icu:mainMenuEdit", in: menus)
        section("icu:mainMenuView", in: menus)
        section("icu:mainMenuWindow", in: menus)
        section("icu:mainMenuHelp", in: menus)
    }

    @CommandsBuilder private func section(_ key: String, in menus: [MainMenu.Item]) -> some Commands {
        let title = i18n(key)
        if let menu = menus.first(where: { if case .submenu(let label, _, _) = $0 { label == title } else { false } }),
           case .submenu(_, _, let items) = menu {
            CommandMenu(MainMenu.displayLabel(title)) {
                ForEach(items.indices, id: \.self) { index in row(items[index]) }
            }
        }
    }

    @ViewBuilder private func row(_ item: MainMenu.Item) -> some View {
        switch item {
        case .separator: Divider()
        case let .item(label, accelerator, role, action):
            Button(MainMenu.displayLabel(label)) {
                if let role { perform(role) }
                if let action { perform(action) }
            }
            .disabled(action == .showDebugLog || action == .setupAsNewDevice ||
                      (action == .openArtCreator && session.stickerUpload() == nil))
            .keyboardShortcut(Self.shortcut(accelerator: accelerator, role: role))
        case let .submenu(label, _, items):
            Menu(MainMenu.displayLabel(label)) {
                ForEach(items.indices, id: \.self) { index in AnyView(row(items[index])) }
            }
        }
    }

    private func perform(_ role: MainMenu.Role) {
        if let command = QtDesktop.EditCommand(rawValue: role.rawValue) {
            QtDesktop.perform(command)
            return
        }
        switch role {
        case .minimize: QtDesktop.minimizeWindow()
        case .togglefullscreen: QtDesktop.toggleFullScreen()
        case .quit: DesktopActions.quit(session)
        default: break
        }
    }

    private func perform(_ action: MainMenu.Action) {
        switch action {
        case .showWindow: openWindow(id: "main")
        case .showAbout: openWindow(id: "about")
        case .showKeyboardShortcuts: model.isShowingShortcutGuide = true
        case .showSettings: model.selectedTab = .settings
        case .zoomReset: model.zoomLevel = 0
        case .zoomIn: model.zoomLevel += 1
        case .zoomOut: model.zoomLevel -= 1
        case .openArtCreator: StickerCreatorWindow.show(session: session, i18n: i18n)
        default: break
        }
    }

    private static func shortcut(accelerator: String?, role: MainMenu.Role?) -> KeyboardShortcut? {
        if let accelerator {
            let keys = accelerator.split(separator: "+")
            guard let key = keys.last, key.count == 1, let character = key.lowercased().first else { return nil }
            var modifiers: EventModifiers = []
            for modifier in keys.dropLast() {
                switch modifier {
                case "CmdOrCtrl", "CommandOrControl", "Ctrl": modifiers.insert(.control)
                case "Shift": modifiers.insert(.shift)
                case "Alt": modifiers.insert(.option)
                default: return nil
                }
            }
            return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
        }
        switch role {
        case .undo: return KeyboardShortcut("z", modifiers: .control)
        case .redo: return KeyboardShortcut("z", modifiers: [.control, .shift])
        case .cut: return KeyboardShortcut("x", modifiers: .control)
        case .copy: return KeyboardShortcut("c", modifiers: .control)
        case .paste: return KeyboardShortcut("v", modifiers: .control)
        case .pasteAndMatchStyle: return KeyboardShortcut("v", modifiers: [.control, .shift])
        case .selectAll: return KeyboardShortcut("a", modifiers: .control)
        case .quit: return KeyboardShortcut("q", modifiers: .control)
        default: return nil
        }
    }
}

struct LinuxAbout: View {
    let i18n: Localizer
    @Environment(\.dismissWindow) private var dismissWindow
    private static let version = (try? String(contentsOfFile: "/opt/serein/share/version", encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    init(i18n: Localizer) { self.i18n = i18n }

    var body: some View {
        About(appEnv: "production", platform: "linux", version: Self.version) { dismissWindow() }
            .environment(\.i18n, i18n)
            .environment(\.brandLogo, BundledImage.named("serein-logo"))
    }
}
