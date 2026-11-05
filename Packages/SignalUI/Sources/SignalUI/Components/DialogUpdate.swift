// DialogUpdate (ts/components/DialogUpdate.dom.tsx): the auto-update banner in its states
// (available, downloading, downloaded, cannot update, read-only volume, App Store).

import SignalI18n
import SwiftUI

/// `DialogType` (ts/types/Dialogs.std.ts)
public enum UpdateDialogType: Sendable {
    case none, autoUpdate, cannotUpdate, cannotUpdateRequireManual, unsupportedOS, macOSReadOnly
    case downloadReady, fullDownloadReady, downloading, downloadedUpdate, masUpdate
}

public struct DialogUpdate: View {
    static let productionDownloadURL = "https://signal.org/download/"
    static let betaDownloadURL = "https://support.signal.org/beta"
    static let contactSupportURL = "https://support.signal.org/hc/requests/new?desktop"

    let containerWidthBreakpoint: WidthBreakpoint
    let dialogType: UpdateDialogType
    let disableDismiss: Bool
    let downloadSize: Int?
    let downloadedSize: Int?
    let version: String?
    let currentVersion: String
    let dismissDialog: () -> Void
    let snoozeUpdate: () -> Void
    let startUpdate: () -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.openURL) var openURL

    public init(containerWidthBreakpoint: WidthBreakpoint, dialogType: UpdateDialogType, disableDismiss: Bool = false,
                downloadSize: Int? = nil, downloadedSize: Int? = nil, version: String? = nil, currentVersion: String,
                dismissDialog: @escaping () -> Void = {}, snoozeUpdate: @escaping () -> Void = {}, startUpdate: @escaping () -> Void = {}) {
        self.containerWidthBreakpoint = containerWidthBreakpoint
        self.dialogType = dialogType
        self.disableDismiss = disableDismiss
        self.downloadSize = downloadSize
        self.downloadedSize = downloadedSize
        self.version = version
        self.currentVersion = currentVersion
        self.dismissDialog = dismissDialog
        self.snoozeUpdate = snoozeUpdate
        self.startUpdate = startUpdate
    }

    /// ts/util/version.std.ts `isBeta`
    static func isBeta(_ version: String) -> Bool { version.contains("-beta") }

    /// `.LeftPaneDialog__message span`: font-body-1, inline-block.
    var spanStyle: CSSTextStyle { LegacyType.body1() }

    func open(_ s: String) { if let url = URL(string: s) { openURL(url) } }

    func detail(_ key: String, _ args: [String: I18nArgument], tags: [String: I18nTagStyle], elements: [String: CSSTextRun]) -> some View {
        CSSText(runs: CSSTextRun.runs(i18n.richText(key, args), tags: tags, elements: elements), style: spanStyle) { action in
            switch action {
            case "retry": startUpdate()
            case "support": open(Self.contactSupportURL)
            default: open(action)
            }
        }
    }

    public var body: some View {
        switch dialogType {
        case .cannotUpdate, .cannotUpdateRequireManual:
            let url = Self.isBeta(currentVersion) ? Self.betaDownloadURL : Self.productionDownloadURL
            let retry = dialogType == .cannotUpdate
            LeftPaneDialog(type: .warning, title: i18n("icu:cannotUpdate"), containerWidthBreakpoint: containerWidthBreakpoint) {
                detail(retry ? "icu:cannotUpdateDetail-v2" : "icu:cannotUpdateRequireManualDetail-v2", ["url": .element("url")],
                       tags: ["retryUpdateButton": I18nTagStyle(fontName: AxoFonts.interName(weight: 600), action: "retry"),
                              "contactSupportLink": I18nTagStyle(fontName: AxoFonts.interName(weight: 700), action: "support")],
                       elements: ["url": CSSTextRun(url, fontName: AxoFonts.interName(weight: 700), action: url)])
            }
        case .macOSReadOnly:
            LeftPaneDialog(type: .warning, title: i18n("icu:cannotUpdate"), containerWidthBreakpoint: containerWidthBreakpoint,
                           onClose: dismissDialog, closeLabel: i18n("icu:close")) {
                detail("icu:readOnlyVolume", ["app": .element("app"), "folder": .element("folder")], tags: [:],
                       elements: ["app": CSSTextRun("Signal.app", fontName: AxoFonts.interName(weight: 700)),
                                  "folder": CSSTextRun("/Applications", fontName: AxoFonts.interName(weight: 700))])
            }
        case .unsupportedOS, .none:
            EmptyView()    // UnsupportedOS is shown as UnsupportedOSDialog in LeftPane
        case .downloading:
            let width = Int((Double(downloadedSize ?? 0 > 0 ? downloadedSize! : 1) / Double(downloadSize ?? 0 > 0 ? downloadSize! : 1) * 100).rounded(.up))
            LeftPaneDialog(icon: .update, title: i18n("icu:DialogUpdate__downloading"), hoverText: versionTitle,
                           containerWidthBreakpoint: containerWidthBreakpoint) {
                LeftPaneDialogProgress(percent: width)
            }
        default:
            available
        }
    }

    var versionTitle: String? {
        version.map { i18n("icu:DialogUpdate--version-available", ["version": .string($0)]) }
    }

    var available: some View {
        var title = i18n("icu:autoUpdateNewVersionTitle")
        if let downloadSize, downloadSize > 0, dialogType == .downloadReady || dialogType == .fullDownloadReady {
            title += " (\(formatFileSize(downloadSize)))"
        }
        var clickLabel = i18n("icu:autoUpdateNewVersionMessage")
        var type: LeftPaneDialogType?
        switch dialogType {
        case .downloadReady: clickLabel = i18n("icu:downloadNewVersionMessage")
        case .fullDownloadReady:
            clickLabel = i18n("icu:downloadFullNewVersionMessage")
            type = .warning
        case .downloadedUpdate: title = i18n("icu:DialogUpdate__downloaded")
        case .masUpdate: clickLabel = i18n("icu:DialogUpdate__upgrade-mas")
        default: break
        }
        return LeftPaneDialog(type: type, icon: .update, title: title, hoverText: versionTitle, containerWidthBreakpoint: containerWidthBreakpoint,
                              onClick: startUpdate, clickLabel: clickLabel, hasAction: true,
                              onClose: disableDismiss ? nil : snoozeUpdate, closeLabel: disableDismiss ? nil : i18n("icu:autoUpdateIgnoreButtonLabel"))
    }
}

/// `.LeftPaneDialog__progress--container` / `--bar`: a 4px track (max 210, margins 10/6)
/// with the gradient bar translated to `percent`.
struct LeftPaneDialogProgress: View {
    let percent: Int
    @Environment(\.layoutDirection) var direction
    var body: some View {
        let stops = [LegacyColor.whiteAlpha40, LegacyColor.whiteAlpha60, LegacyColor.whiteAlpha90, LegacyColor.whiteAlpha60, LegacyColor.whiteAlpha40]
        GeometryReader { geo in
            // background-size 200%: the visible half of the gradient (background-position 100%).
            LinearGradient(colors: stops.map { Color(.sRGB, red: $0.r, green: $0.g, blue: $0.b, opacity: $0.a) },
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 2)
                .offset(x: -geo.size.width)
                .frame(width: geo.size.width, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .offset(x: geo.size.width * CGFloat(percent - 100) / 100 * (direction == .rightToLeft ? -1 : 1))
        }
        .frame(height: 4)
        .background(RoundedRectangle(cornerRadius: 2).fill(AxoColor(LegacyColor.whiteAlpha20)))
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .frame(maxWidth: 210)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}
