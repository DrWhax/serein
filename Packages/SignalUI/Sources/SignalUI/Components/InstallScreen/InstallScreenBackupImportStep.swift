// InstallScreenBackupImportStep (link and sync): "Syncing messages" with a progress bar while
// the primary prepares its archive (indeterminate), then while it is imported. Its stylesheet:
// the title in font-title-2 with 20px below it, the bar at least 326px wide with 18px below,
// the hint in font-caption weight 500, the description in font-caption.
//
// Not ported: cancelling (the transfer runs to its end or fails, and the device then continues
// without history) and the unsupported-version update dialog.

import SwiftUI

public enum InstallScreenBackupStep: Equatable, Sendable {
    case waitForBackup
    case download
    /// Imported `current` of `total` parts.
    case process(current: Int, total: Int)
}

public struct InstallScreenBackupImportStep: View {
    @Environment(\.i18n) var i18n
    let step: InstallScreenBackupStep

    public init(step: InstallScreenBackupStep) { self.step = step }

    /// rgba($color-black-alpha-40, 0.8): black at 40% × 0.8.
    static let hintColor = AxoColor(light: RGBA(0, 0, 0, 0.32), dark: LegacyColor.gray25)
    static let descriptionColor = AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25)

    var fraction: Double? {
        guard case .process(let current, let total) = step, total > 0 else { return nil }
        return (Double(current) / Double(total) * 100).rounded() / 100
    }

    var hint: String {
        switch step {
        case .waitForBackup, .download: i18n("icu:BackupImportScreen__progressbar-hint--preparing")
        case .process: i18n("icu:BackupImportScreen__progressbar-hint--processing")
        }
    }

    public var body: some View {
        InstallScreenFrame {
            VStack(spacing: 0) {
                InstallScreenFrame<EmptyView>.h1(i18n("icu:BackupImportScreen__title")).padding(.bottom, 20)
                ProgressBar(fractionComplete: fraction, isRTL: i18n.direction == .rightToLeft)
                    .frame(minWidth: 326).fixedSize(horizontal: true, vertical: false)
                    .padding(.bottom, 18)
                CSSText(hint, style: LegacyType.caption(weight: 500), alignment: .center, color: Self.hintColor).padding(.bottom, 8)
                CSSText(i18n("icu:BackupImportScreen__description"), style: LegacyType.caption(), alignment: .center, color: Self.descriptionColor)
            }
            .padding(.top, 64)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
