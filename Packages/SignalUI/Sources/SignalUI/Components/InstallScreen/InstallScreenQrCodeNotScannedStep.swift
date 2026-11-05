// Port of ts/components/installScreen/InstallScreenQrCodeNotScannedStep.dom.tsx
// (stylesheets/components/InstallScreenQrCodeNotScannedStep.scss): the white card with the
// linking QR code (or its loading / error state) and the instructions, and the alert that
// confirms deleting this device's data before relinking. Standalone registration (the back
// button) is not offered: this app only links.

import AppKit
import SignalI18n
import SwiftUI

/// `InstallScreenQRCodeError`
public enum InstallScreenQRCodeError: String, Sendable { case timeout, unknown, networkIssue, maxRotations }

/// `Loadable<string, InstallScreenQRCodeError>`
public enum InstallScreenProvisioningURL: Sendable, Hashable {
    case loading
    case loaded(String)
    case loadFailed(InstallScreenQRCodeError)
}

public struct InstallScreenQrCodeNotScannedStep: View {
    let provisioningUrl: InstallScreenProvisioningURL
    let isStaging: Bool
    let retryGetQrCode: () -> Void
    let isConfirmingDataDeletion: Bool
    let restartInstall: () -> Void
    let continueInstallWithDataDeletion: () -> Void
    /// Shown instead of the step when the build has expired or an update is downloading.
    let updateDialog: InstallScreenUpdateDialog?
    @Environment(\.i18n) var i18n
    @Environment(\.colorScheme) var scheme

    static let supportPage = URL(string: "https://support.signal.org/hc/articles/360007320551-Linked-Devices")!
    static let ultramarine = AxoColor(LegacyColor.ultramarine)

    public init(provisioningUrl: InstallScreenProvisioningURL, isStaging: Bool = false, retryGetQrCode: @escaping () -> Void = {},
                isConfirmingDataDeletion: Bool = false, restartInstall: @escaping () -> Void = {},
                continueInstallWithDataDeletion: @escaping () -> Void = {}, updateDialog: InstallScreenUpdateDialog? = nil) {
        self.updateDialog = updateDialog
        self.provisioningUrl = provisioningUrl
        self.isStaging = isStaging
        self.retryGetQrCode = retryGetQrCode
        self.isConfirmingDataDeletion = isConfirmingDataDeletion
        self.restartInstall = restartInstall
        self.continueInstallWithDataDeletion = continueInstallWithDataDeletion
    }

    public var body: some View {
        if let updateDialog { updateDialog } else { step }
    }

    var step: some View {
        let dark = scheme == .dark
        return InstallScreenFrame {
            // __contents: white, radius 8; padding 22 (44 and a 44px top margin in dark, clear of the logo).
            HStack(alignment: .center, spacing: 0) {
                InstallScreenQrCode(provisioningUrl: provisioningUrl, retryGetQrCode: retryGetQrCode)
                    .padding(.vertical, 8).padding(.leading, 8).padding(.trailing, 38)
                instructions.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(dark ? 44 : 22)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
            .frame(maxWidth: dark ? 804 : 760)
            .padding(.top, dark ? 44 : 0)
            .environment(\.colorScheme, .light)
        }
        .viewportPortal {
            if isConfirmingDataDeletion {
                AxoBaseDialog.Host {
                    AxoAlertDialog.Content {
                        AxoAlertDialog.Body {
                            AxoAlertDialog.Title(i18n("icu:Install__confirm-data-deletion__title"))
                            AxoAlertDialog.Description(i18n("icu:Install__confirm-data-deletion__body"))
                        }
                        AxoAlertDialog.Footer {
                            AxoAlertDialog.Action(i18n("icu:cancel"), variant: .subtleSecondary, action: restartInstall)
                            AxoAlertDialog.Action(i18n("icu:Install__confirm-data-deletion__continue"), variant: .strongDestructive,
                                                  action: continueInstallWithDataDeletion)
                        }
                    }
                }
            }
        }
    }

    static let black = AxoColor(LegacyColor.black)
    /// `ol`: font-body-1 at line-height 26px.
    static let listStyle = CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 14, lineHeight: 26, letterSpacing: -0.08)

    func bold(_ key: String) -> CSSTextRun { CSSTextRun(i18n(key), fontName: AxoFonts.interName(weight: 700)) }

    func item(_ n: Int, _ runs: [CSSTextRun]) -> some View {
        CSSText(runs: [CSSTextRun("\(n). ")] + runs, style: Self.listStyle, color: Self.black)
    }

    var instructions: some View {
        VStack(alignment: .leading, spacing: 0) {
            CSSText(i18n("icu:Install__scan-this-code"), style: LegacyType.title2(), color: Self.black).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                item(1, [CSSTextRun(i18n("icu:Install__instructions__1"))])
                item(2, CSSTextRun.runs(i18n.richText("icu:Install__instructions__2", ["settings": .element("settings"), "linkedDevices": .element("linkedDevices")]),
                                        elements: ["settings": bold("icu:Install__instructions__2__settings"), "linkedDevices": bold("icu:linkedDevices")]))
                item(3, CSSTextRun.runs(i18n.richText("icu:Install__instructions__3", ["linkNewDevice": .element("linkNewDevice")]),
                                        elements: ["linkNewDevice": bold("icu:linkNewDevice")]))
            }
            .padding(.vertical, 8)
            // The link sits in a 30px line (the screen's line-height).
            Group {
                if isStaging {
                    CSSText("THIS IS A STAGING DESKTOP", style: LegacyType.body1(), color: Self.black)
                } else {
                    Button { NSWorkspace.shared.open(Self.supportPage) } label: {
                        CSSText(i18n("icu:Install__support-link"), style: LegacyType.body1(), color: Self.ultramarine)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isLink)
                }
            }
            .frame(height: 30)
        }
    }
}

/// `InstallScreenQrCode`: 256px, a 1.5px border (drawn 1px, as Chromium floors it), margins
/// set by the card.
struct InstallScreenQrCode: View {
    let provisioningUrl: InstallScreenProvisioningURL
    let retryGetQrCode: () -> Void
    @Environment(\.i18n) var i18n

    static let gray60 = AxoColor(LegacyColor.gray60)

    var body: some View {
        let failed: Bool = if case .loadFailed = provisioningUrl { true } else { false }
        let justButton = provisioningUrl == .loadFailed(.maxRotations)
        contents
            .frame(width: 256, height: 256)
            .padding(1)
            .background {
                let shape = RoundedRectangle(cornerRadius: failed ? 10 : 0)
                if case .loaded = provisioningUrl {
                    shape.fill(Color.white)
                } else if justButton {
                    shape.fill(AxoColor(LegacyColor.gray05))
                }
            }
            .overlay { if failed { RoundedRectangle(cornerRadius: 10).strokeBorder(AxoColor(LegacyColor.gray05), lineWidth: 1) } }
    }

    @ViewBuilder var contents: some View {
        switch provisioningUrl {
        case .loading:
            Spinner(svgSize: .small, size: 24)
        case .loaded(let link):
            // <svg viewBox="0 0 16 16"> on white.
            BrandedQRCode(size: 16, link: link, color: .black)
                .background(Color.white)
                .accessibilityElement()
                .accessibilityLabel(i18n("icu:Install__scan-this-code"))
                .accessibilityAddTraits(.isImage)
        case .loadFailed(let error):
            VStack(spacing: 0) {
                switch error {
                case .timeout:
                    errorMessage([CSSTextRun(i18n("icu:Install__qr-failed-load__error--timeout"))])
                    retry(i18n("icu:Install__qr-failed-load__retry"))
                case .unknown:
                    // <paragraph> pieces, one per line.
                    errorMessage(Self.paragraphs(i18n.richText("icu:Install__qr-failed-load__error--unknown", [:])))
                    retry(i18n("icu:Install__qr-failed-load__retry"))
                case .networkIssue:
                    errorMessage([CSSTextRun(i18n("icu:Install__qr-failed-load__error--network"))])
                    link(i18n("icu:Install__qr-failed-load__get-help"))
                case .maxRotations:
                    justButtonRetry(i18n("icu:Install__qr-max-rotations__retry"))
                }
            }
        }
    }

    /// `<paragraph>` runs as one line each (`<p>` blocks).
    static func paragraphs(_ rich: RichText) -> [CSSTextRun] {
        rich.runs.enumerated().compactMap { i, run in
            guard case .text(let text) = run.content else { return nil }
            return CSSTextRun(i < rich.runs.count - 1 ? text + "\n" : text)
        }
    }

    /// `__error-message`: a 22px red error icon 8px above body-2 text, 24px inline margins.
    func errorMessage(_ runs: [CSSTextRun]) -> some View {
        VStack(spacing: 8) {
            SignalIcon("v3/error/error-circle", size: 22, color: AxoColor(LegacyColor.accentRed), mask: true)
            CSSText(runs: runs, style: LegacyType.body2(), alignment: .center, color: Self.gray60)
        }
        .padding(.horizontal, 24)
    }

    /// `__link`: body-2 bold ultramarine with a 16px refresh icon, 16px below.
    func retry(_ label: String) -> some View {
        Button(action: retryGetQrCode) {
            HStack(spacing: 4) {
                SignalIcon("v3/refresh/refresh-bold", size: 16, color: InstallScreenQrCodeNotScannedStep.ultramarine, mask: true)
                CSSText(label, style: LegacyType.body2(weight: 600), color: InstallScreenQrCodeNotScannedStep.ultramarine)
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 16)
    }

    /// `__get-help`
    func link(_ label: String) -> some View {
        Button { NSWorkspace.shared.open(InstallScreenQrCodeNotScannedStep.supportPage) } label: {
            HStack(spacing: 4) {
                SignalIcon("v3/open/open-compact-bold", size: 16, color: InstallScreenQrCodeNotScannedStep.ultramarine, mask: true)
                CSSText(label, style: LegacyType.body2(weight: 600), color: InstallScreenQrCodeNotScannedStep.ultramarine)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isLink)
        .padding(.top, 16)
    }

    /// `--just-button __link`: a white pill, body-1 medium black, refresh icon.
    func justButtonRetry(_ label: String) -> some View {
        Button(action: retryGetQrCode) {
            HStack(spacing: 4) {
                SignalIcon("v3/refresh/refresh-bold", size: 16, color: AxoColor(LegacyColor.black), mask: true)
                CSSText(label, style: LegacyType.body1(weight: 500), color: AxoColor(LegacyColor.black))
            }
            .padding(.vertical, 8).padding(.horizontal, 16)
            .background(Capsule().fill(Color.white))
        }
        .buttonStyle(.plain)
    }
}
