// Port of ts/components/installScreen/InstallScreenUpdateDialog.dom.tsx: what the install
// screen shows when this version may not link (expired, or an update in progress): checking /
// downloading progress centred on the screen, or a confirm dialog for each update state.

import AppKit
import SignalI18n
import SwiftUI

public struct InstallScreenUpdateDialog: View {
    let dialogType: UpdateDialogType
    let isCheckingForUpdates: Bool
    let downloadSize: Int?
    let downloadedSize: Int?
    let currentVersion: String
    let os: String
    let forceCheck: () -> Void
    let startUpdate: () -> Void
    let onClose: () -> Void
    @Environment(\.i18n) var i18n

    public init(dialogType: UpdateDialogType, isCheckingForUpdates: Bool = false, downloadSize: Int? = nil, downloadedSize: Int? = nil,
                currentVersion: String, os: String, forceCheck: @escaping () -> Void = {}, startUpdate: @escaping () -> Void = {},
                onClose: @escaping () -> Void = {}) {
        self.dialogType = dialogType
        self.isCheckingForUpdates = isCheckingForUpdates
        self.downloadSize = downloadSize
        self.downloadedSize = downloadedSize
        self.currentVersion = currentVersion
        self.os = os
        self.forceCheck = forceCheck
        self.startUpdate = startUpdate
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            InstallScreenSignalLogo(relativeToViewport: false)
            inline
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { TitlebarDragArea() }
        .viewportPortal {
            if let modal { AxoBaseDialog.Host { modal } }
        }
    }

    func title(_ key: String) -> some View {
        CSSText(i18n(key), style: CSSTextStyle(AxoType.titleMedium.weight(600)), alignment: .center).frame(width: 328)
    }

    /// `CenteredElement`: absolute, centred, `max-w-[calc(100%-32px)]`.
    @ViewBuilder var inline: some View {
        if dialogType == .none && isCheckingForUpdates {
            VStack(spacing: 0) {
                title("icu:InstallScreenUpdateDialog--checking-for-updates").padding(.bottom, 16)
                ProgressBar(fractionComplete: nil, isRTL: false).frame(width: 328)
            }
            .padding(.bottom, 17)
        } else if dialogType == .downloading {
            let fraction = downloadSize.map { $0 > 0 ? SpinnerV2.roundFraction(Double(downloadedSize ?? 0) / Double($0)) : 0 }
            VStack(spacing: 0) {
                title("icu:InstallScreenUpdateDialog--updating-signal").padding(.bottom, 16)
                ProgressBar(fractionComplete: fraction, isRTL: false).frame(width: 328).padding(.bottom, 17)
                if let fraction {
                    CSSText(i18n("icu:InstallScreenUpdateDialog--download-progress", [
                        "currentBytes": .string(formatFileSize(downloadedSize ?? 0)), "totalBytes": .string(formatFileSize(downloadSize ?? 1)),
                        "percentage": .number(fraction),
                    ]), style: CSSTextStyle(AxoType.caption.weight(500)), alignment: .center)
                    .frame(width: 328)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    static func open(_ url: String) { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }

    var modal: AnyView? {
        switch dialogType {
        case .none:
            if isCheckingForUpdates { return nil }
            return AnyView(updateRequired(isMas: false, action: forceCheck))
        case .masUpdate:
            return AnyView(updateRequired(isMas: true, action: startUpdate))
        case .unsupportedOS:
            let runs = CSSTextRun.runs(i18n.richText("icu:UnsupportedOSErrorDialog__body", ["OS": .string(os)]),
                                       tags: ["learnMoreLink": I18nTagStyle(color: .labelPrimary, action: UnsupportedOSDialog.unsupportedOSURL)])
                .map { run -> CSSTextRun in var r = run; if r.action != nil { r.underline = true }; return r }
            return AnyView(AxoConfirmDialog.Root(title: i18n("icu:InstallScreenUpdateDialog--unsupported-os__title"), description: {
                AxoAlertDialog.Description(runs: runs, onTap: Self.open)
            }, actions: {}))
        case .downloadedUpdate:
            return AnyView(AxoConfirmDialog.Root(title: i18n("icu:DialogUpdate__downloaded"), description: i18n("icu:InstallScreenUpdateDialog--downloaded__body")) {
                AxoConfirmDialog.Action(i18n("icu:autoUpdateRestartButtonLabel"), variant: .strongPrimary, action: startUpdate)
            })
        case .autoUpdate, .downloadReady, .fullDownloadReady:
            let ready = dialogType != .autoUpdate
            let label = ready ? i18n("icu:InstallScreenUpdateDialog--manual-update__action", ["downloadSize": .string("(\(formatFileSize(downloadSize ?? 0)))")])
                : i18n("icu:autoUpdateRestartButtonLabel")
            let runs: [CSSTextRun]? = ready ? CSSTextRun.runs(i18n.richText("icu:InstallScreenUpdateDialog--manual-update__action", ["downloadSize": .element("size")]),
                                                              elements: ["size": CSSTextRun("(\(formatFileSize(downloadSize ?? 0)))", fontName: AxoFonts.interName(weight: 400))]) : nil
            return AnyView(AxoConfirmDialog.Root(title: i18n("icu:autoUpdateNewVersionTitle"), description: i18n("icu:InstallScreenUpdateDialog--auto-update__body")) {
                AxoConfirmDialog.Action(label, variant: .strongPrimary, labelRuns: runs, action: startUpdate)
            })
        case .downloading:
            return nil
        case .cannotUpdate, .cannotUpdateRequireManual:
            let url = DialogUpdate.isBeta(currentVersion) ? DialogUpdate.betaDownloadURL : DialogUpdate.productionDownloadURL
            var link = CSSTextRun(url, color: .labelPrimary, action: url)
            link.underline = true
            let runs = CSSTextRun.runs(i18n.richText("icu:InstallScreenUpdateDialog--cannot-update__body", ["downloadUrl": .element("url")]), elements: ["url": link])
            let manual = dialogType == .cannotUpdateRequireManual
            return AnyView(AxoConfirmDialog.Root(title: i18n("icu:cannotUpdate"), description: {
                AxoAlertDialog.Description(runs: runs, onTap: Self.open)
            }, actions: {
                if !manual { AxoConfirmDialog.Action(i18n("icu:autoUpdateRetry"), variant: .strongPrimary, action: startUpdate) }
            }))
        case .macOSReadOnly:
            let bold = AxoFonts.interName(weight: 700)
            let runs = CSSTextRun.runs(i18n.richText("icu:readOnlyVolume", ["app": .element("app"), "folder": .element("folder")]),
                                       elements: ["app": CSSTextRun("Signal.app", fontName: bold), "folder": CSSTextRun("/Applications", fontName: bold)])
            return AnyView(AxoConfirmDialog.Root(title: i18n("icu:cannotUpdate"), description: { AxoAlertDialog.Description(runs: runs) }, actions: {}))
        }
    }

    func updateRequired(isMas: Bool, action: @escaping () -> Void) -> some View {
        AxoConfirmDialog.Root(title: i18n("icu:InstallScreenUpdateDialog--update-required__title"),
                              description: i18n("icu:InstallScreenUpdateDialog--update-required__body")) {
            AxoConfirmDialog.Action(i18n(isMas ? "icu:InstallScreenUpdateDialog--update-required__action-update__mas"
                                         : "icu:InstallScreenUpdateDialog--update-required__action-update"), variant: .strongPrimary, action: action)
        }
    }
}
