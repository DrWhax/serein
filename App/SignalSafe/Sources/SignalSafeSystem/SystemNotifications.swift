// System notifications (upstream services/notifications NotificationService on macOS's
// Notification Center): one notification at a time (each new one replaces the last), only
// while the app isn't focused, debounced by a second; the text by `notification-setting`
// (name and message / name only / no name or message), the pop sound unless sounds are off,
// "draw attention" bouncing the Dock icon, and the Dock badge with the unread count.

import AppKit
import SignalCore
import SignalI18n
import UserNotifications

/// What a click opens (`NotificationClickData`).
public struct NotificationClick: Sendable, Hashable {
    public var conversationId: String
    public var messageId: String?
    public var storyId: String?
}

public enum NotificationContent {
    public static let fallbackTitle = "Signal"

    /// `redactMessageNotificationContent`: title and body for the setting (nil when off).
    public static func content(_ p: PendingNotification, setting: NotificationSetting, i18n: Localizer,
                               hideExpiringMessageBody: Bool = false) -> (title: String, body: String)? {
        switch setting {
        case .off: return nil
        case .count: return (fallbackTitle, i18n("icu:newMessage"))
        case .name, .message:
            let sender = p.senderName ?? i18n("icu:unknownContact")
            let title = p.groupTitle.map { i18n("icu:notificationSenderInGroup", ["sender": .string(sender), "group": .string($0)]) } ?? sender
            let body: String
            if (p.isExpiringMessage && hideExpiringMessageBody) || setting == .name {
                body = i18n("icu:newMessage")
            } else if p.storyId != nil {
                body = p.body
            } else if case .reaction(let emoji) = p.kind {
                body = i18n("icu:notificationReactionMessage", ["sender": .string(sender), "emoji": .string(emoji), "message": .string(p.body)])
            } else {
                body = p.body
            }
            return (title, body)
        }
    }
}

@MainActor
public final class SystemNotifications: NSObject, UNUserNotificationCenterDelegate {
    public var onClick: (NotificationClick) -> Void = { _ in }
    /// Diagnostics (no content): permission, skipped and failed posts.
    public var log: (String) -> Void = { _ in }
    private let center: UNUserNotificationCenter?
    private let i18n: Localizer
    private var queued: (PendingNotification, NotificationSettings)?
    private var debounce: Task<Void, Never>?
    private var lastShown: String?
    public private(set) var isEnabled = false

    /// `center` nil: nothing is posted (tests, or an unbundled binary that has no center).
    public init(i18n: Localizer, center: UNUserNotificationCenter? = Bundle.main.bundleIdentifier != nil ? .current() : nil) {
        self.i18n = i18n
        self.center = center
        super.init()
        center?.delegate = self
    }

    /// Asks once for permission (alerts, sounds, badge).
    public func enable() async {
        guard let center else { return log("notifications: no notification center (unbundled)") }
        do {
            isEnabled = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            isEnabled = false
            log("notifications: authorization failed: \(error)")
        }
        let settings = await center.notificationSettings()
        log("notifications: enabled \(isEnabled), status \(settings.authorizationStatus.rawValue), alerts \(settings.alertSetting.rawValue)")
    }

    public func disable() { isEnabled = false }

    /// `add`: shown a second later, unless replaced or the app is focused by then.
    public func add(_ pending: PendingNotification, settings: NotificationSettings) {
        queued = (pending, settings)
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// `#fastUpdate`
    func flush() {
        guard let (pending, settings) = queued else { return }
        queued = nil
        if NSApp?.isActive == true { return log("notifications: skipped (app focused)") }
        guard isEnabled else { return log("notifications: skipped (not authorized)") }
        guard let content = NotificationContent.content(pending, setting: settings.setting, i18n: i18n) else { return log("notifications: skipped (setting off)") }
        if settings.drawAttention { NSApp?.requestUserAttention(.informationalRequest) }
        post(title: content.title, body: content.body, sound: settings.playSound ? "pop.wav" : nil,
             click: NotificationClick(conversationId: pending.conversationId, messageId: pending.messageId, storyId: pending.storyId))
    }

    /// `rawNotify`: replaces the last shown notification.
    public func post(title: String, body: String, sound: String?, click: NotificationClick) {
        clearLastShown()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound.map { UNNotificationSound(named: UNNotificationSoundName($0)) }
        content.threadIdentifier = click.conversationId
        content.userInfo = ["conversationId": click.conversationId, "messageId": click.messageId ?? "", "storyId": click.storyId ?? ""]
        let id = UUID().uuidString
        lastShown = id
        guard let center else { return }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            do {
                try await center.add(request)
                log("notifications: posted")
            } catch {
                log("notifications: post failed: \(error)")
            }
        }
    }

    /// `clear`: the shown notification goes (a chat was opened, the app focused).
    public func clear() {
        queued = nil
        debounce?.cancel()
        clearLastShown()
    }

    private func clearLastShown() {
        if let lastShown { center?.removeDeliveredNotifications(withIdentifiers: [lastShown]) }
        lastShown = nil
    }

    /// The Dock badge (`setBadgeCount`).
    public func setBadgeCount(_ count: Int) {
        NSApp?.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    // MARK: UNUserNotificationCenterDelegate

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let conversationId = info["conversationId"] as? String else { return }
        let messageId = (info["messageId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let storyId = (info["storyId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        await MainActor.run {
            NSApp?.activate()
            onClick(NotificationClick(conversationId: conversationId, messageId: messageId, storyId: storyId))
        }
    }

    /// Shown while the app is in front too (upstream only posts when unfocused; calls do post).
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions
    {
        [.banner, .sound]
    }
}
