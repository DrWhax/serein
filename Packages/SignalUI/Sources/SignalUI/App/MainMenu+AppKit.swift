#if canImport(AppKit)
import AppKit

extension MainMenu.Role {
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
}

extension MainMenu {
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
#endif
