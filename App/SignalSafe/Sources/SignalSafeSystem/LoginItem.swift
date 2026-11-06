// "Start Signal when computer starts" (General): the app as a login item through
// ServiceManagement (`app.setLoginItemSettings({ openAtLogin })` upstream).

import ServiceManagement

public enum LoginItem {
    /// Registered (or waiting for the user's approval in System Settings).
    @MainActor public static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: true
        default: false
        }
    }

    /// Asks macOS to approve when the user hasn't yet (System Settings → Login Items).
    @MainActor public static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    @MainActor public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}
