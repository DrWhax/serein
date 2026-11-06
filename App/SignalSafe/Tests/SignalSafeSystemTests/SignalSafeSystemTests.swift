import AppKit
import Testing
@testable import SignalSafeSystem

@MainActor
@Suite struct SignalSafeSystemTests {
    @Test func displaySleepIsBlockedOnlyWhileEnabled() {
        let service = PreventDisplaySleepService()
        #expect(!service.isEnabled)
        service.setEnabled(true)
        service.setEnabled(true)        // idempotent
        #expect(service.isEnabled)
        service.setEnabled(false)
        #expect(!service.isEnabled)
    }

    @Test func contentProtectionHidesWindowsFromCapture() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ContentProtectionController(enabled: true)
        controller.apply(to: window)
        #expect(window.sharingType == .none)
        controller.setEnabled(false)
        controller.apply(to: window)
        #expect(window.sharingType == .readOnly)
    }
}

import SignalCore
import SignalI18n

@MainActor
@Suite struct NotificationContentTests {
    let i18n = Localizer(locale: "en")
    func pending(group: String? = nil, expiring: Bool = false, story: String? = nil) -> PendingNotification {
        PendingNotification(kind: .message, conversationId: "c", messageId: "m", storyId: story, senderName: "Alice", groupTitle: group,
                            body: "hello there", isExpiringMessage: expiring, sentAt: 1)
    }

    @Test func modes() throws {
        #expect(NotificationContent.content(pending(), setting: .off, i18n: i18n) == nil)
        let full = try #require(NotificationContent.content(pending(), setting: .message, i18n: i18n))
        #expect(full.title == "Alice" && full.body == "hello there")
        let name = try #require(NotificationContent.content(pending(), setting: .name, i18n: i18n))
        #expect(name.title == "Alice" && name.body == i18n("icu:newMessage"))
        let count = try #require(NotificationContent.content(pending(), setting: .count, i18n: i18n))
        #expect(count.title == "Signal" && count.body == i18n("icu:newMessage"))
        let group = try #require(NotificationContent.content(pending(group: "Book club"), setting: .message, i18n: i18n))
        #expect(group.title == i18n("icu:notificationSenderInGroup", ["sender": .string("Alice"), "group": .string("Book club")]))
        #expect(group.title.contains("Alice") && group.title.contains("Book club"))
        let hidden = try #require(NotificationContent.content(pending(expiring: true), setting: .message, i18n: i18n, hideExpiringMessageBody: true))
        #expect(hidden.body == i18n("icu:newMessage"))
    }

    @Test func queuedNotificationWithoutPermissionDoesNothing() {
        let n = SystemNotifications(i18n: i18n, center: nil)
        n.add(pending(), settings: NotificationSettings())
        n.flush()
        #expect(!n.isEnabled)
        n.setBadgeCount(3)
    }
}

@Suite struct CrashReportsTests {
    @Test func findsSummarisesAndErases() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let header = #"{"app_name":"SignalSafe","timestamp":"2026-11-06 10:00:00.00 +0100","app_version":"0.1.0","bug_type":"309","name":"SignalSafe"}"#
        let body = #"{"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"faultingThread":0,"threads":[{"triggered":true,"frames":[{"imageOffset":4096,"symbol":"main","imageIndex":0}]}],"usedImages":[{"name":"SignalSafe"}],"osVersion":{"train":"macOS 27.0","build":"26A425"}}"#
        try Data((header + "\n" + body).utf8).write(to: dir.appendingPathComponent("SignalSafe-2026-11-06-100000.ips"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("Other-2026-11-06-100000.ips"))
        let defaults = try #require(UserDefaults(suiteName: "crash-tests-\(UUID())"))
        let reports = CrashReports(directory: dir, processName: "SignalSafe", defaults: defaults)
        #expect(reports.count == 1)
        let summaries = reports.writeToLog()
        #expect(summaries.first?.exceptionType == "EXC_BREAKPOINT" && summaries.first?.frames == ["SignalSafe + 4096 (main)"])
        #expect(summaries.first?.logText.contains("macOS 27.0") == true)
        #expect(reports.count == 0)
    }
}
