// Port of app/PreventDisplaySleepService.std.ts: while a call is active the display may not
// sleep (Electron's powerSaveBlocker 'prevent-display-sleep'), through a ProcessInfo activity.

import Foundation

@MainActor
public final class PreventDisplaySleepService {
    private var activity: (any NSObjectProtocol)?
    private let processInfo: ProcessInfo

    public init(processInfo: ProcessInfo = .processInfo) { self.processInfo = processInfo }

    public var isEnabled: Bool { activity != nil }

    public func setEnabled(_ enabled: Bool) {
        if enabled {
            guard activity == nil else { return }
            activity = processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Signal call in progress")
        } else if let activity {
            processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
