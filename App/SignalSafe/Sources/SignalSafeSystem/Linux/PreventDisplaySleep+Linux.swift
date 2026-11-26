#if os(Linux)
import CLinuxDesktop

@MainActor
public final class PreventDisplaySleepService {
    private var cookie: UInt64?
    public init() {}
    public var isEnabled: Bool { cookie != nil }

    public func setEnabled(_ enabled: Bool) {
        if enabled && cookie == nil {
            let result = serein_display_inhibit()
            if result != 0 { cookie = result }
        } else if !enabled, let cookie {
            serein_display_uninhibit(cookie)
            self.cookie = nil
        }
    }
    deinit {
        if let cookie { serein_display_uninhibit(cookie) }
    }
}
#endif
