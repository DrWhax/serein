// Port of ts/components/DebugLogWindow.dom.tsx (stylesheets/components/DebugLogWindow.scss):
// the debug log window — fetch the log (the first lines shown, monospace), save it, or
// submit it and then copy the published link or report an issue.

import AppKit
import SignalI18n
import SwiftUI

public struct DebugLogWindow: View {
    public enum Mode: Sendable { case submit, close }
    enum LoadState { case notStarted, started, loaded, submitting }

    let mode: Mode
    let closeWindow: () -> Void
    let downloadLog: (String) -> Void
    let fetchLogs: @Sendable () async -> String
    let uploadLogs: @Sendable (String) async throws -> String
    /// `createSupportUrl({ query: { debugLog } })`
    let supportURL: (String) -> URL?
    @State private var loadState: LoadState
    @State private var logText: String?
    @State private var publicLogURL: String?
    @State private var toast: String?
    @Environment(\.i18n) var i18n

    /// `initialLogs`: logs already fetched (the window then skips `fetchLogs`).
    public init(mode: Mode = .submit, initialLogs: String? = nil, closeWindow: @escaping () -> Void = {}, downloadLog: @escaping (String) -> Void = { _ in },
                fetchLogs: @escaping @Sendable () async -> String = { "" }, uploadLogs: @escaping @Sendable (String) async throws -> String = { _ in "" },
                supportURL: @escaping (String) -> URL? = { _ in URL(string: "https://support.signal.org/hc/requests/new?desktop") }) {
        self.mode = mode
        self.closeWindow = closeWindow
        self.downloadLog = downloadLog
        self.fetchLogs = fetchLogs
        self.uploadLogs = uploadLogs
        self.supportURL = supportURL
        _logText = State(initialValue: initialLogs)
        _loadState = State(initialValue: initialLogs == nil ? .notStarted : .loaded)
    }

    static let subtitleColor = AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25)

    /// The text area shows the first lines (window height / 5), then the hint to save.
    func preview(_ text: String) -> String {
        let lines = Int((min(NSScreen.main.map { $0.frame.height } ?? 900, 2000) / 5).rounded(.up))
        return text.split(separator: "\n", omittingEmptySubsequences: false).prefix(lines).joined(separator: "\n") + "\n\n\n" + i18n("icu:debugLogLogIsIncomplete")
    }

    func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CSSText(title, style: LegacyType.title2(), color: .labelPrimary).accessibilityAddTraits(.isHeader)
            CSSText(subtitle, style: LegacyType.body2(), color: Self.subtitleColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let publicLogURL {
                header(i18n("icu:debugLogSuccess"), i18n("icu:debugLogSuccessNextSteps"))
                TextField("", text: .constant(publicLogURL))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(AxoColor(light: LegacyColor.gray25, dark: LegacyColor.gray45), lineWidth: 1))
                    .frame(maxHeight: .infinity)
                footer {
                    LegacyButton(i18n("icu:reportIssue"), variant: .secondary) { if let url = supportURL(publicLogURL) { NSWorkspace.shared.open(url) } }
                    LegacyButton(i18n("icu:debugLogCopy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(publicLogURL, forType: .string)
                        toast = i18n("icu:debugLogLinkCopied")
                    }
                }
            } else {
                header(i18n("icu:submitDebugLog"), i18n(mode == .close ? "icu:debugLogExplanation--close" : "icu:debugLogExplanation"))
                if loadState == .started || loadState == .submitting || logText == nil {
                    Spinner(svgSize: .normal).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let logText {
                    // __scroll_area: 1px gray-45 border; the text monospace 12px, pre-line.
                    ScrollView {
                        CSSText(preview(logText), style: CSSTextStyle(fontName: AxoFonts.monospaceName, size: 12, lineHeight: 20),
                                color: AxoColor(light: AxoColor.labelPrimary.light, dark: LegacyColor.gray02))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(1)
                    .background(AxoColor(light: RGBA(0, 0, 0, 0), dark: LegacyColor.gray90))
                    .overlay(Rectangle().strokeBorder(AxoColor(LegacyColor.gray45), lineWidth: 1))
                    .fixedSize(horizontal: false, vertical: true)
                }
                footer {
                    LegacyButton(i18n("icu:debugLogSave"), variant: .secondary, disabled: logText == nil) { if let logText { downloadLog(logText) } }
                    if mode == .close {
                        LegacyButton(i18n("icu:close"), action: closeWindow)
                    } else {
                        LegacyButton(i18n("icu:submit"), disabled: logText == nil || loadState == .submitting, action: submit)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottomLeading) {
            if let toast { Toast(toast) { self.toast = nil }.padding(16) }
        }
        .onExitCommand(perform: closeWindow)
        .task {
            guard loadState == .notStarted else { return }
            loadState = .started
            let text = await fetchLogs()
            logText = text
            loadState = .loaded
        }
    }

    func footer(@ViewBuilder _ buttons: () -> some View) -> some View {
        HStack(spacing: 8) { buttons() }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 16)
    }

    func submit() {
        guard let text = logText, !text.isEmpty else { return }
        loadState = .submitting
        Task {
            do {
                publicLogURL = try await uploadLogs(text)
            } catch {
                loadState = .loaded
                toast = i18n("icu:debugLogError")
            }
        }
    }
}
