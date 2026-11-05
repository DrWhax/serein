// MainMenu: app/menu.std.ts createTemplate + updateForMac (labels from _locales/en).

import AppKit
import SignalI18n
import Testing
@testable import SignalUI

@MainActor
@Suite struct MainMenuTests {
    let i18n = Localizer(locale: "en")

    func titles(_ items: [MainMenu.Item]) -> [String] {
        items.map {
            switch $0 {
            case .separator: "-"
            case let .item(label, _, _, _): MainMenu.displayLabel(label)
            case let .submenu(label, _, _): MainMenu.displayLabel(label)
            }
        }
    }

    func submenu(_ items: [MainMenu.Item], _ i: Int) -> [MainMenu.Item] {
        if case let .submenu(_, _, sub) = items[i] { return sub }
        Issue.record("item \(i) is not a submenu")
        return []
    }

    @Test func macTemplate() {
        let t = MainMenu.template(.init(platform: "darwin"), i18n: i18n)
        #expect(titles(t) == ["Signal Desktop", "File", "Edit", "View", "Window", "Help"])
        #expect(titles(submenu(t, 0)) == ["About Signal Desktop", "-", "Preferences…", "-", "Services", "-", "Hide", "Hide Others",
                                          "Show All", "-", "Quit Signal"])
        #expect(titles(submenu(t, 1)) == ["Create/upload sticker pack", "-", "Close Window"])
        #expect(titles(submenu(t, 2)) == ["Undo", "Redo", "-", "Cut", "Copy", "Paste", "Paste and Match Style", "Delete", "Select All",
                                          "-", "Speech"])
        #expect(titles(submenu(t, 3)) == ["Actual Size", "Zoom In", "Zoom Out", "-", "Toggle Full Screen", "-", "Debug Log"])
        #expect(titles(submenu(t, 4)) == ["Minimize", "Zoom", "Show", "-", "Bring All to Front"])
        #expect(titles(submenu(t, 5)) == ["Show Keyboard Shortcuts", "-", "Contact Us", "Go to Release Notes", "Go to Forums",
                                          "Go to Support Page", "Join the Beta"])
    }

    @Test func setupItems() {
        let t = MainMenu.template(.init(platform: "darwin", includeSetup: true), i18n: i18n)
        #expect(titles(submenu(t, 1)) == ["Set Up as New Device", "-", "Create/upload sticker pack", "-", "Close Window"])
    }

    @Test func accelerators() throws {
        let show = try #require(MainMenu.keyEquivalent("CmdOrCtrl+Shift+0"))
        #expect(show.key == "0" && show.modifiers == [.command, .shift])
        let zoomOut = try #require(MainMenu.keyEquivalent("CmdOrCtrl+-"))
        #expect(zoomOut.key == "-" && zoomOut.modifiers == [.command])
        let full = try #require(MainMenu.keyEquivalent("Ctrl+Cmd+F"))
        #expect(full.key == "f" && full.modifiers == [.control, .command])
        #expect(MainMenu.displayLabel("&File") == "File" && MainMenu.displayLabel("A && B") == "A & B")
    }

    @Test func nsMenu() {
        let bar = MainMenu.build(MainMenu.template(.init(platform: "darwin"), i18n: i18n)) { _ in }
        let help = bar.items[5].submenu
        let shortcuts = help?.items.first
        #expect(shortcuts?.keyEquivalent == "/" && shortcuts?.keyEquivalentModifierMask == [.command])
        #expect(bar.items[2].submenu?.items[3].action == NSSelectorFromString("cut:"))
        #expect(bar.items[2].submenu?.items[3].keyEquivalent == "x")
    }
}
