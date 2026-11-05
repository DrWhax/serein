// DialogUpdate stories (ts/components/DialogUpdate.dom.stories.tsx). The unsupported-os
// stories render nothing (LeftPane shows UnsupportedOSDialog instead) and are not captured.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct DialogUpdateTests {
    /// story suffix (before -wide / -narrow), type, currentVersion, downloadSize override
    static let cases: [(String, UpdateDialogType, String, Int?)] = [
        ("update", .autoUpdate, "5.24.0", nil), ("downloaded", .downloadedUpdate, "5.24.0", nil),
        ("download-ready", .downloadReady, "5.24.0", 30_123_456), ("full-download-ready", .fullDownloadReady, "5.24.0", 300_123_456),
        ("downloading", .downloading, "5.24.0", nil), ("cannot-update", .cannotUpdate, "5.24.0", nil),
        ("cannot-update-beta", .cannotUpdate, "5.24.0-beta.1", nil),
        ("cannot-update-require-manual", .cannotUpdateRequireManual, "5.24.0", nil),
        ("cannot-update-require-manual-beta", .cannotUpdateRequireManual, "5.24.0-beta.1", nil),
        ("mac-os-read-only", .macOSReadOnly, "5.24.0", nil), ("mas-update", .masUpdate, "5.24.0", nil),
    ]

    func view(_ c: (String, UpdateDialogType, String, Int?), _ width: WidthBreakpoint) -> some View {
        FakeLeftPaneContainer(width) {
            DialogUpdate(containerWidthBreakpoint: width, dialogType: c.1, downloadSize: c.3 ?? 116_504_357,
                         // DownloadingWide/Narrow animate downloadedSize from 0; the capture shows 0.
                         downloadedSize: c.1 == .downloading ? 0 : 61_003_110, version: "v7.7.7", currentVersion: c.2)
        }
    }

    @Test(arguments: ["light", "dark"], 0..<11)
    func wide(theme: String, index: Int) throws {
        let c = Self.cases[index]
        // MASUpdate's wide story has no suffix.
        let id = c.0 == "mas-update" ? "components-dialogupdate--mas-update" : "components-dialogupdate--\(c.0)-wide"
        try Snapshot.assertMatches(view(c, .wide), story: id, theme: theme)
    }

    @Test(arguments: ["light", "dark"], 0..<11)
    func narrow(theme: String, index: Int) throws {
        let c = Self.cases[index]
        try Snapshot.assertMatches(view(c, .narrow), story: "components-dialogupdate--\(c.0)-narrow", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func knobsPlayground(theme: String) throws {
        try Snapshot.assertMatches(view(Self.cases[0], .wide), story: "components-dialogupdate--knobs-playground", theme: theme)
    }

    @Test func fileSizes() {
        #expect(formatFileSize(30_123_456) == "30.1 MB")
        #expect(formatFileSize(300_123_456) == "300.1 MB")
        #expect(formatFileSize(116_504_357) == "116.5 MB")
        #expect(formatFileSize(999) == "999 B")
        #expect(formatFileSize(12_345) == "12 kB")
        #expect(formatFileSize(2_000_000) == "2 MB")
    }
}
