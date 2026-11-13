// Port of ts/components/preferences/SignalAccountKeys.dom.tsx, SignalAccountKeysButton.dom.tsx
// and OSAuthErrorDialog.dom.tsx: the Signal Login page (account ID and recovery key in
// monospace cards, Save as PDF) and the Account page row that opens it after OS auth.
// The print layout (`print:` variants) belongs to the PDF export.

import SignalI18n
import SwiftUI

/// `formatBackupKeyForDisplay`: upper-case, groups of four; `convertAmbiguousChars` maps O → #
/// and 0 → =.
public func formatBackupKeyForDisplay(_ backupKey: String, convertAmbiguousChars: Bool) -> String {
    let compact = backupKey.uppercased().filter { !$0.isWhitespace }
    var groups: [String] = []
    var i = compact.startIndex
    while i < compact.endIndex {
        let j = compact.index(i, offsetBy: 4, limitedBy: compact.endIndex) ?? compact.endIndex
        groups.append(String(compact[i..<j]))
        i = j
    }
    let spaced = groups.joined(separator: " ")
    return convertAmbiguousChars ? spaced.replacingOccurrences(of: "O", with: "#").replacingOccurrences(of: "0", with: "=") : spaced
}

public struct SignalAccountKeys: View {
    let serviceId: String?
    let backupKey: String?
    let saveAccountKeysPDF: (() async -> Void)?
    @State private var isSaving = false
    @Environment(\.i18n) var i18n

    public init(serviceId: String?, backupKey: String?, saveAccountKeysPDF: (() async -> Void)?) {
        self.serviceId = serviceId
        self.backupKey = backupKey
        self.saveAccountKeysPDF = saveAccountKeysPDF
    }

    public var body: some View {
        // flex column, gap 4
        VStack(spacing: 16) {
            // mx-auto mb-2.5: the 98×56 card
            SignalLoginIllustration(width: 98)
                .padding(.bottom, 10)
                .accessibilityLabel(i18n("icu:Preferences__SignalAccount__label"))
            if let serviceId {
                SignalAccountKeySection(label: i18n("icu:Preferences__SignalAccountKeys__AccountID"), text: serviceId.uppercased())
            }
            if let backupKey {
                SignalAccountKeySection(label: i18n("icu:Preferences__SignalAccountKeys__RecoveryKey"),
                                        text: formatBackupKeyForDisplay(backupKey, convertAmbiguousChars: true))
            }
            if let saveAccountKeysPDF {
                AxoButton.Root(i18n("icu:Preferences__SignalAccountKeys__Save"), variant: .subtleSecondary, size: .md, symbol: "download",
                               pending: isSaving) {
                    isSaving = true
                    Task {
                        await saveAccountKeysPDF()
                        isSaving = false
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// `KeySection`: a body-medium semibold heading (px-4 py-2) over a curved-2xl card
/// (surface-card, elevation-0, px-4 py-2.5) of monospace text (max 40ch, tracking 1.12px).
struct SignalAccountKeySection: View {
    let label: String
    let text: String

    static let textStyle = CSSTextStyle.mono(size: 14, lineHeight: 20, letterSpacing: 1.12)
    /// `40ch`: forty widths of the font's "0".
    static let maxTextWidth: CGFloat = 40 * CSSTextLayout.make("0", .mono(size: 14, lineHeight: 20), wrap: .nowrap, maxWidth: nil).width

    var body: some View {
        let shape = SuperellipseRect.curved(AxoRadius._2xl)
        VStack(alignment: .leading, spacing: 0) {
            CSSText(label, type: AxoType.bodyMedium.weight(600), color: .labelPrimary)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .accessibilityAddTraits(.isHeader)
            CSSText(text, style: Self.textStyle, color: .labelPrimary)
                .frame(maxWidth: Self.maxTextWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(shape.fill(AxoColor.surfaceCard))
                .axoShadow(.shadowElevation0, in: shape)
        }
    }
}

/// `PromptOSAuthResultType`
public enum PromptOSAuthResult: Sendable { case success, unsupported, unauthorized, error }

/// `SignalAccountKeysButton`: the 70×40 card, label and key count, opening the keys after OS auth.
public struct SignalAccountKeysButton: View {
    let promptOSAuth: () async -> PromptOSAuthResult
    let onClick: () -> Void
    @State private var authError = false
    @State private var isAuthPending = false
    @Environment(\.i18n) var i18n

    public init(promptOSAuth: @escaping () async -> PromptOSAuthResult, onClick: @escaping () -> Void) {
        self.promptOSAuth = promptOSAuth
        self.onClick = onClick
    }

    public var body: some View {
        let label = i18n("icu:Preferences__SignalAccount__label")
        AxoItem.Root(disabled: isAuthPending) {
            AxoItem.Leading { SignalLoginIllustration(width: 70).frame(minWidth: 70) }
            AxoItem.Content {
                AxoItem.Label(label)
                AxoItem.Description(i18n("icu:Preferences__SignalAccount__description"))
                AxoItem.HiddenTrigger(label: label) {
                    isAuthPending = true
                    Task {
                        let result = await promptOSAuth()
                        isAuthPending = false
                        if result == .success || result == .unsupported { onClick() } else { authError = true }
                    }
                }
                AxoItem.Trailing { AxoItem.Arrow() }
            }
        }
        .viewportPortal {
            if authError {
                AxoBaseDialog.Host { OSAuthErrorDialog { authError = false } }
            }
        }
    }
}

/// `OSAuthErrorDialog`
public struct OSAuthErrorDialog: View {
    let onClose: () -> Void
    @Environment(\.i18n) var i18n
    public init(onClose: @escaping () -> Void) { self.onClose = onClose }
    public var body: some View {
        AxoAlertDialog.Content {
            AxoAlertDialog.Body {
                AxoAlertDialog.Title(i18n("icu:Toast--error"), screenReaderOnly: true)
                AxoAlertDialog.Description(i18n("icu:Preferences__local-backups-auth-error--unauthorized"))
            }
            AxoAlertDialog.Footer { AxoAlertDialog.Ok(i18n("icu:ok"), action: onClose) }
        }
    }
}

/// The AccountKeys page of ts/components/Preferences.dom.tsx: SignalAccountKeys (px-4) under
/// the "Signal Login" title, back to Account.
public struct PreferencesAccountKeysPage: View {
    let serviceId: String?
    let backupKey: String?
    let saveAccountKeysPDF: (() async -> Void)?
    let onBack: () -> Void
    @Environment(\.i18n) var i18n

    public init(serviceId: String?, backupKey: String?, saveAccountKeysPDF: (() async -> Void)?, onBack: @escaping () -> Void = {}) {
        self.serviceId = serviceId
        self.backupKey = backupKey
        self.saveAccountKeysPDF = saveAccountKeysPDF
        self.onBack = onBack
    }

    public var body: some View {
        PreferencesContent(title: i18n("icu:Preferences--signal-login"),
                           backButton: AnyView(PreferencesBackButton(label: i18n("icu:goBack"), action: onBack))) {
            SignalAccountKeys(serviceId: serviceId, backupKey: backupKey, saveAccountKeysPDF: saveAccountKeysPDF)
                .padding(.horizontal, 16)
        }
    }
}
