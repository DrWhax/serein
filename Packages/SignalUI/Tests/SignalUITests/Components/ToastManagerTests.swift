// ToastManager: every message key it uses exists in the English strings, and the
// `BasicUsage` story (captured with its fixed-position toast container).

import Foundation
import SignalI18n
import SwiftUI
import Testing
@testable import SignalUI

@Suite struct ToastManagerTests {
    @Test func messageKeysExist() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/SignalUI/Components/ToastManager.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let keys = Set(text.matches(of: /"(icu:[A-Za-z0-9_\-]+)"/).map { String($0.1) })
        #expect(keys.count > 80)
        let i18n = DefaultLocalizer.english
        for key in keys.sorted() {
            #expect(i18n.message(key) != nil, "missing \(key)")
        }
    }

    /// `BasicUsage`: the "Select a toast type" line, and at the bottom of the viewport the
    /// AddingUserToGroup toast over the UsernameOnboarding megaphone.
    @MainActor
    @Test(arguments: ["light", "dark"])
    func basicUsage(theme: String) throws {
        let view = ZStack(alignment: .topLeading) {
            CSSText("Select a toast type in controls", type: .bodyLarge, color: .labelPrimary)
            ToastManager(toast: .addingUserToGroup(contact: "Sam Mirete"), megaphone: AnyView(UsernameMegaphone()))
        }
        .frame(width: 1168, height: 884, alignment: .topLeading)
        try Snapshot.assertMatches(TimelineMessageTests.stage(view), story: "components-toastmanager--basic-usage", theme: theme)
    }
}
