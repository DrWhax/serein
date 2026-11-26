#if os(macOS)
import AppKit

@MainActor enum DesktopActions {
    static func openURL(_ url: URL) { NSWorkspace.shared.open(url) }
    static func revealFile(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    static func quit(_ session: SignalSession) { NSApp.terminate(nil) }
}
#endif
