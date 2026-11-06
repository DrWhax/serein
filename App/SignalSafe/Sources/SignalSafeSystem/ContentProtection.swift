// Screen security (`setContentProtection` on every window, Privacy → "Screen security"):
// with it on, no window can be captured by screenshots, screen recording or sharing
// (NSWindow.sharingType .none); windows opened later get the same.

import AppKit

@MainActor
public final class ContentProtectionController {
    public private(set) var isEnabled: Bool
    private var observer: (any NSObjectProtocol)?

    public init(enabled: Bool) {
        isEnabled = enabled
        // A window opened later becomes key: it gets the setting then.
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAll() }
        }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        applyAll()
    }

    func applyAll() {
        for window in NSApp?.windows ?? [] { apply(to: window) }
    }

    public func apply(to window: NSWindow) {
        let wanted: NSWindow.SharingType = isEnabled ? .none : .readOnly
        if window.sharingType != wanted { window.sharingType = wanted }
    }
}
