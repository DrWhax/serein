// PinReminderMegaphone, RemoteMegaphone and UsernameMegaphone stories.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct MegaphoneTests {
    @Test(arguments: ["light", "dark"])
    func pinReminder(theme: String) throws {
        try Snapshot.assertMatches(PinReminderMegaphone(isFullSize: true), story: "components-pinremindermegaphone--defaults", theme: theme)
    }

    static let remote: [(String, String, String, String, String, Bool)] = [
        ("defaults", "Donate to Signal", "Signal is powered by people like you. Show your support today!", "Donate", "Not now", true),
        ("alternate-text", "Donate Today", "As a nonprofit, Signal needs your support", "Donate", "Not now", true),
        ("short-text", "Donate Today", "Pls halp", "Donate", "Not now", true),
        ("long-text", "We Need Your Help, Donate to Signal Today", "As a nonprofit, Signal is powered by people like you. Show your support today!", "Donate", "Not now", true),
        ("long-buttons", "Donate Today", Self.longBody, "Donate Donate Donate Donate", "Remind me later Remind me later", true),
        ("narrow-sidebar", "Donate to Signal", "Signal is powered by people like you. Show your support today!", "Donate", "Not now", false),
    ]
    static let longBody = "As a nonprofit, Signal needs your support. As a nonprofit, Signal needs your support. As a nonprofit, Signal needs your support. As a nonprofit, Signal needs your support."

    @Test(arguments: ["light", "dark"], 0..<6)
    func remote(theme: String, index: Int) throws {
        let (name, title, body, primary, secondary, full) = Self.remote[index]
        let view = RemoteMegaphone(remoteMegaphoneId: "a", title: title, body: body, image: BundledImage.named("donate-heart"),
                                   primaryCtaId: "donate", secondaryCtaId: "snooze", primaryCtaText: primary, secondaryCtaText: secondary,
                                   isFullSize: full)
        try Snapshot.assertMatches(view, story: "components-remotemegaphone--\(name)", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func username(theme: String) throws {
        try Snapshot.assertMatches(UsernameMegaphone(), story: "components-usernamemegaphone--defaults", theme: theme)
    }
}
