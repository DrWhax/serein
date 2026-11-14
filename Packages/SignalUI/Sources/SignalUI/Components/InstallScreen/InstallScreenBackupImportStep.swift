// InstallScreenBackupImportStep (link and sync): "Syncing messages" with a progress bar while
// the primary prepares its archive (indeterminate), while it downloads (bytes of the size) and
// while it is imported; the security note in the footer, and a Cancel button once the transfer
// is under way (it asks first: cancelling unlinks this device). A retriable error offers Retry
// or cancel, a fatal one only cancelling, and an unsupported backup version the update dialog.
// Its stylesheet: the content centred in what the footer leaves, from 64px down; the title in
// font-title-2 with 20px below it, the bar at least 326px wide with 18px below, the hint in
// font-caption weight 500, the description in font-caption; the footer 110px high at least, 36px
// above the bottom, its parts 26px apart.

import SignalI18n
import SwiftUI

public enum InstallScreenBackupStep: Equatable, Sendable {
    case waitForBackup
    case download(currentBytes: Int64, totalBytes: Int64)
    case process(currentBytes: Int64, totalBytes: Int64)
}

/// upstream InstallScreenBackupError.
public enum InstallScreenBackupError: Equatable, Sendable {
    case retriable, fatal, canceled, unsupportedVersion
}

public struct InstallScreenBackupImportStep: View {
    @Environment(\.i18n) var i18n
    @Environment(\.titleBarDragAreaHeight) var dragAreaHeight
    let step: InstallScreenBackupStep
    let error: InstallScreenBackupError?
    let onCancel: () -> Void
    let onRetry: () -> Void
    let openURL: (URL) -> Void
    @State var isConfirmingCancel: Bool

    /// `SYNCING_MESSAGES_SECURITY_URL`
    static let securityURL = URL(string: "https://support.signal.org/hc/articles/360007320391")!

    public init(step: InstallScreenBackupStep, error: InstallScreenBackupError? = nil, isConfirmingCancel: Bool = false,
                onCancel: @escaping () -> Void = {}, onRetry: @escaping () -> Void = {}, openURL: @escaping (URL) -> Void = { _ in }) {
        self.step = step
        self.error = error
        self.onCancel = onCancel
        self.onRetry = onRetry
        self.openURL = openURL
        _isConfirmingCancel = State(initialValue: isConfirmingCancel)
    }

    /// rgba($color-black-alpha-40, 0.8): black at 40% × 0.8.
    static let hintColor = AxoColor(light: RGBA(0, 0, 0, 0.32), dark: LegacyColor.gray25)
    static let descriptionColor = AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25)
    /// rgba($color-gray-60, 0.8) / gray-25: the security note and its lock.
    static let securityColor = AxoColor(light: RGBA(LegacyColor.gray60.r, LegacyColor.gray60.g, LegacyColor.gray60.b, 0.8), dark: LegacyColor.gray25)
    /// An `<a>` without a colour of its own: Chromium's link blue.
    static let linkColor = AxoColor(RGBA(0, 0, 0xEE / 255, 1))
    /// `button-blue-text`, then gray-80 in the dark theme; on gray-05.
    static let cancelColor = AxoColor(light: LegacyColor.ultramarine, dark: LegacyColor.gray80)

    var isCanceled: Bool { error == .canceled }

    var bytes: (current: Int64, total: Int64)? {
        switch step {
        case .waitForBackup: nil
        case .download(let c, let t), .process(let c, let t): (c, t)
        }
    }

    var fraction: Double? {
        guard !isCanceled, let bytes else { return nil }
        return SpinnerV2.roundFraction(bytes.total > 0 ? Double(bytes.current) / Double(bytes.total) : 0)
    }

    var hint: String {
        if isCanceled { return i18n("icu:BackupImportScreen__progressbar-hint--canceling") }
        switch step {
        case .waitForBackup: return i18n("icu:BackupImportScreen__progressbar-hint--preparing")
        case .download(let current, let total):
            return i18n("icu:BackupImportScreen__progressbar-hint", ["currentSize": .string(formatFileSize(Int(clamping: current))),
                                                                    "totalSize": .string(formatFileSize(Int(clamping: total))),
                                                                    "fractionComplete": .number(fraction ?? 0)])
        case .process: return i18n("icu:BackupImportScreen__progressbar-hint--processing")
        }
    }

    public var body: some View {
        if error == .unsupportedVersion {
            InstallScreenUpdateDialog(dialogType: .none, currentVersion: "", os: "macOS", onClose: { isConfirmingCancel = true })
                .viewportPortal { if isConfirmingCancel { cancelConfirmation } }
        } else {
            screen
        }
    }

    var screen: some View {
        InstallScreenFrame {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    InstallScreenFrame<EmptyView>.h1(i18n("icu:BackupImportScreen__title")).padding(.bottom, 20)
                    ProgressBar(fractionComplete: fraction, isRTL: i18n.direction == .rightToLeft)
                        .frame(minWidth: 326).fixedSize(horizontal: true, vertical: false)
                        .padding(.bottom, 18)
                    CSSText(hint, style: LegacyType.caption(weight: 500), alignment: .center, color: Self.hintColor).padding(.bottom, 8)
                    if !isCanceled {
                        CSSText(i18n("icu:BackupImportScreen__description"), style: LegacyType.caption(), alignment: .center, color: Self.descriptionColor)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
                .frame(maxHeight: .infinity)
                .padding(.top, 64 + dragAreaHeight)
                footer
            }
        }
        .viewportPortal { dialogs }
    }

    var footer: some View {
        VStack(spacing: 26) {
            VStack(spacing: 4) {
                SignalIcon("v3/lock/lock", size: 16, color: Self.securityColor).accessibilityHidden(true)
                CSSText(runs: CSSTextRun.runs(i18n.richText("icu:BackupImportScreen__security-description"),
                                              tags: ["learnMoreLink": I18nTagStyle(color: Self.linkColor, action: "learnMore")]),
                        style: LegacyType.caption(), alignment: .center, color: Self.securityColor, onTap: { _ in openURL(Self.securityURL) })
                    .frame(maxWidth: 336)
            }
            if !isCanceled, bytes != nil {
                Button { isConfirmingCancel = true } label: {
                    CSSText(i18n("icu:BackupImportScreen__cancel"), style: LegacyType.body1(weight: 600), color: Self.cancelColor)
                        .padding(.vertical, 8).padding(.horizontal, 24)
                        .background(Capsule().fill(AxoColor(LegacyColor.gray05)))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 110, alignment: .top)
        .padding(.bottom, 36)
    }

    @ViewBuilder var dialogs: some View {
        switch error {
        case .retriable where !isConfirmingCancel:
            AxoBaseDialog.Host {
                AxoConfirmDialog.Root(title: i18n("icu:BackupImportScreen__error__title"), description: i18n("icu:BackupImportScreen__error__body")) {
                    AxoConfirmDialog.Cancel(i18n("icu:BackupImportScreen__cancel-confirmation__confirm")) { isConfirmingCancel = true }
                    AxoConfirmDialog.Action(i18n("icu:BackupImportScreen__error__confirm"), variant: .strongPrimary) {
                        isConfirmingCancel = false
                        onRetry()
                    }
                }
            }
        case .fatal:
            AxoBaseDialog.Host {
                AxoConfirmDialog.Root(title: i18n("icu:BackupImportScreen__error__title"), description: i18n("icu:BackupImportScreen__error-fatal__body")) {
                    AxoConfirmDialog.Action(i18n("icu:BackupImportScreen__error__confirm"), variant: .strongPrimary, action: onCancel)
                }
            }
        default:
            if isConfirmingCancel { cancelConfirmation }
        }
    }

    var cancelConfirmation: some View {
        AxoBaseDialog.Host {
            AxoConfirmDialog.Root(title: i18n("icu:BackupImportScreen__cancel-confirmation__title"),
                                  description: i18n("icu:BackupImportScreen__cancel-confirmation__body")) {
                AxoConfirmDialog.Cancel(i18n("icu:BackupImportScreen__cancel-confirmation__cancel")) { isConfirmingCancel = false }
                AxoConfirmDialog.Action(i18n("icu:BackupImportScreen__cancel-confirmation__confirm"), variant: .strongDestructive) {
                    isConfirmingCancel = false
                    onCancel()
                }
            }
        }
    }
}
