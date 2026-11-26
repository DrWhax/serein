#if os(macOS)
import AppKit
import UniformTypeIdentifiers

@MainActor enum DesktopActions {
    static var isActive: Bool { NSApp.isActive }
    static func requestAttention() { NSApp.requestUserAttention(.criticalRequest) }
    static func setBadgeCount(_ count: Int) { NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil }
    static func applyTheme(_ setting: String) {
        NSApp.appearance = switch setting {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }
    static func saveFile(named name: String, directory: URL? = nil, types: [UTType] = []) -> URL? {
        let panel = NSSavePanel()
        panel.directoryURL = directory
        panel.nameFieldStringValue = name
        if !types.isEmpty { panel.allowedContentTypes = types }
        return panel.runModal() == .OK ? panel.url : nil
    }
    static func chooseFiles(types: [UTType] = [], directory: URL? = nil, folders: Bool = false,
                            multiple: Bool = false, prompt: String? = nil) -> [URL] {
        let panel = NSOpenPanel()
        panel.directoryURL = directory
        panel.canChooseDirectories = folders
        panel.canChooseFiles = !folders
        panel.canCreateDirectories = folders
        panel.allowsMultipleSelection = multiple
        if let prompt { panel.prompt = prompt }
        if !types.isEmpty { panel.allowedContentTypes = types }
        return panel.runModal() == .OK ? panel.urls : []
    }
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
