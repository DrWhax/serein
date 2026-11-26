#if os(macOS)
import AppKit

@MainActor enum DesktopActions {
    static func openURL(_ url: URL) { NSWorkspace.shared.open(url) }
    static func revealFile(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    static func relaunch(_ session: SignalSession) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
    static func quit(_ session: SignalSession) { NSApp.terminate(nil) }
}
#endif

extension DesktopActions {
    /// ts/util/createSupportUrl.std.ts
    static func supportURL(locale: String) -> String {
        let languages = ["ar", "bn", "de", "en-us", "es", "fr", "hi", "hi-in", "hc", "id", "it", "ja", "ko", "mr", "ms", "nl", "pl", "pt",
                         "ru", "sv", "ta", "te", "tr", "uk", "ur", "vi", "zh-cn", "zh-tw"]
        let language = languages.contains(locale) ? locale : "en-us"
        // The support page needs `?desktop`, not `?desktop=`.
        return "https://support.signal.org/hc/\(language)/requests/new?desktop"
    }
}
