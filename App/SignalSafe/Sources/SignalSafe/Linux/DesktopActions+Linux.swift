#if os(Linux)
import Foundation
import SignalSafeSystem

@MainActor enum DesktopActions {
    static func openURL(_ url: URL) { _ = DesktopPortal.open(url) }
    static func revealFile(_ path: String) { DesktopPortal.revealFile(at: path) }

    static func quit(_ session: SignalSession) { finish(session, status: 0) }

    // The Docker supervisor starts a fresh application and a fresh set of services.
    static func relaunch(_ session: SignalSession) { finish(session, status: 75) }

    private static func finish(_ session: SignalSession, status: Int32) {
        if session.activeCall != nil { session.endCallUI() }
        Task {
            await session.shutdownClient(timeout: .seconds(3))
            _ = UserDefaults.standard.synchronize()
            exit(status)
        }
    }
}
#endif
