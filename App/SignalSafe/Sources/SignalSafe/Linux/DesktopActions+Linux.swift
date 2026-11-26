#if os(Linux)
import Foundation
import SignalSafeSystem
@_spi(Qt) import SwiftUI

@MainActor enum DesktopActions {
    static var isActive: Bool { QtDesktop.isActive }
    static func requestAttention() { QtDesktop.requestAttention() }
    static func setBadgeCount(_ count: Int) { DesktopPortal.setBadgeCount(count) }
    static func applyTheme(_ setting: String) {
        QtDesktop.setAppearance(setting == "dark" ? .dark : setting == "light" ? .light : nil)
    }
    static func saveFile(named name: String, directory: URL? = nil, types: [UTType] = []) -> URL? {
        QtDesktop.saveFile(named: name, directory: directory, types: types)
    }
    static func chooseFiles(types: [UTType] = [], directory: URL? = nil, folders: Bool = false,
                            multiple: Bool = false, prompt: String? = nil) -> [URL] {
        QtDesktop.chooseFiles(types: types, directory: directory, folders: folders, multiple: multiple, prompt: prompt)
    }
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
