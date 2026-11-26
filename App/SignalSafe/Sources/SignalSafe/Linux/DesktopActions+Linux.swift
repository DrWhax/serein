#if os(Linux)
import Foundation
import SignalSafeSystem

@MainActor enum DesktopActions {
    static func openURL(_ url: URL) { _ = DesktopPortal.open(url) }
    static func revealFile(_ path: String) { DesktopPortal.revealFile(at: path) }

    static func quit(_ session: SignalSession) {
        if session.activeCall != nil { session.endCallUI() }
        Task {
            await session.shutdownClient(timeout: .seconds(3))
            exit(0)
        }
    }
}
#endif
