// ts/components/installScreen/*.dom.stories.tsx. The screens are 100vw × 100vh; the captures
// grew the viewport to 932px for the 916px story, and clip them at the root's 1168px width.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct InstallScreenTests {
    /// A full-window step as Storybook shows it: at (16, 16) in a 1200 × 932 viewport.
    static func stage(_ view: some View) -> some View {
        view.environment(\.viewportOrigin, CGPoint(x: 16, y: 16))
            .frame(width: 1200, height: 932)
            .frame(width: 1168, height: 916, alignment: .topLeading)
            .clipped()
    }

    @Test(arguments: ["light", "dark"])
    func linkInProgress(theme: String) throws {
        try Snapshot.assertMatches(Self.stage(InstallScreenLinkInProgressStep()), story: "components-installscreen-installscreenlinkinprogressstep--default",
                                   theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func errorStep(theme: String) throws {
        for (name, error) in [("too-many-devices", InstallScreenError.tooManyDevices), ("too-old", .tooOld), ("connection-failed", .connectionFailed)] {
            try Snapshot.assertMatches(Self.stage(InstallScreenErrorStep(error: error)), story: "components-installscreen-installscreenerrorstep--\(name)",
                                       theme: theme)
        }
    }

    static let loadedURL = "sgnl://linkdevice?uuid=b33f6338-aaf1-4853-9aff-6652369f6b52&pub_key=BTpRKRtFeJGga1M3Na4PzZevMvVIWmTWQIpn0BJI3x10"

    /// The Simulated* stories switch from Loading after 2s, after the capture: all show Loading.
    /// The *StandaloneIsSupported stories are not ported (this app only links).
    @Test(arguments: ["light", "dark"])
    func qrCodeNotScanned(theme: String) throws {
        let stories: [(String, InstallScreenQrCodeNotScannedStep)] = [
            ("qr-code-loading", .init(provisioningUrl: .loading)),
            ("qr-code-failed-to-load", .init(provisioningUrl: .loadFailed(.unknown))),
            ("qr-code-loaded", .init(provisioningUrl: .loaded(Self.loadedURL))),
            ("confirm-data-deletion", .init(provisioningUrl: .loaded(Self.loadedURL), isConfirmingDataDeletion: true)),
        ] + ["simulated-loading", "simulated-max-rotations-error", "simulated-network-issue", "simulated-timeout", "simulated-unknown-error"]
            .map { ($0, .init(provisioningUrl: .loading)) }
        for (name, view) in stories {
            let story = "components-installscreen-installscreenqrcodenotscannedstep--\(name)"
            if name == "confirm-data-deletion" {
                // Captured as the whole 1200 × 900 viewport (the alert is a portal); the screen
                // (100vh, so 900 tall here) sits at (16, 16) in it.
                try Snapshot.assertMatches(Self.portalStage(view), story: story, theme: theme)
            } else {
                try Snapshot.assertMatches(Self.stage(view), story: story, theme: theme)
            }
        }
    }

    /// A portal story: the whole 1200 × 900 viewport, the component (`size`) at (16, 16).
    static func portalStage(_ view: some View, width: CGFloat = 1200) -> some View {
        view.environment(\.viewportOrigin, CGPoint(x: 16, y: 16)).environment(\.viewportSize, CGSize(width: 1200, height: 900))
            .frame(width: width, height: 900).offset(x: 16, y: 16)
            .frame(width: 1200, height: 900, alignment: .topLeading).clipped()
    }

    @Test(arguments: ["light", "dark"])
    func updateDialog(theme: String) throws {
        func d(_ type: UpdateDialogType, checking: Bool = false, size: Int? = nil, downloaded: Int? = nil) -> InstallScreenUpdateDialog {
            InstallScreenUpdateDialog(dialogType: type, isCheckingForUpdates: checking, downloadSize: size, downloadedSize: downloaded,
                                      currentVersion: "v1.0.0", os: "macos")
        }
        let inline: [(String, InstallScreenUpdateDialog)] = [
            ("2-is-checking-for-updates", d(.none, checking: true)),
            ("4-downloading", d(.downloading, size: 100_000_000, downloaded: 50_000_000)),
        ]
        for (name, view) in inline {
            // The container is the root's 1168px wide, 100vh (the grown 932px) tall.
            try Snapshot.assertMatches(view.frame(width: 1168, height: 932).frame(width: 1168, height: 916, alignment: .top).clipped(),
                                       story: "components-installscreen-installscreenupdatedialog--\(name)", theme: theme)
        }
        let modals: [(String, InstallScreenUpdateDialog)] = [
            ("1-no-dialog-not-checking-for-updates", d(.none)),
            ("flow", d(.none, size: 42 * 1024 * 1024)),
            ("3-error-unsupported-os", d(.unsupportedOS)),
            ("3-error-mas-update", d(.masUpdate)),
            ("3-download-ready", d(.downloadReady, size: 100_000)),
            ("3-full-download-ready", d(.fullDownloadReady, size: 100_000_000)),
            ("3-auto-update", d(.autoUpdate)),
            ("5-downloaded-update", d(.downloadedUpdate)),
            ("6-error-cannot-update", d(.cannotUpdate)),
            ("6-error-cannot-update-require-manual", d(.cannotUpdateRequireManual)),
            ("6-error-macos-read-only", d(.macOSReadOnly)),
        ]
        for (name, view) in modals {
            try Snapshot.assertMatches(Self.portalStage(view, width: 1168), story: "components-installscreen-installscreenupdatedialog--\(name)", theme: theme)
        }
        // The QR step past its expiry shows the update dialog (AutoUpdate, v6.0.0); it is 100vw wide.
        let expired = InstallScreenQrCodeNotScannedStep(provisioningUrl: .loaded(Self.loadedURL), updateDialog: InstallScreenUpdateDialog(
            dialogType: .autoUpdate, downloadSize: 67 * 1024 * 1024, downloadedSize: 15 * 1024 * 1024, currentVersion: "v6.0.0", os: "macOS"))
        try Snapshot.assertMatches(Self.portalStage(expired, width: 1168), story: "components-installscreen-installscreenqrcodenotscannedstep--with-update-knobs",
                                   theme: theme)
    }
}
