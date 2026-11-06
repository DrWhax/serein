import Foundation
import ImagePNG
import SwiftUI
import Testing
@testable import SignalUI

func pngFixture(_ name: String) -> RGBAImage? {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Signal-Desktop/fixtures/\(name)")
    guard let data = try? Data(contentsOf: url), let png = try? PNGDecoder.decode([UInt8](data)) else { return nil }
    return RGBAImage(png.stillImage)
}

/// CallingScreenSharingController stories: the controller fills Storybook's 1200×932 viewport
/// (its vw / vh units), offset by the story's 16px padding and clipped to the capture.
@MainActor
@Suite struct ScreenShareSnapshotTests {
    func controller(_ status: ScreenShareStatus = .connected, name: String = "Application") -> some View {
        CallingScreenSharingController(status: status, presentedSourceName: name, viewport: CGSize(width: 1200, height: 931.98),
                                       onStopSharing: {}, onCloseController: {})
            .frame(width: 1168, height: 931.98)
            .frame(width: 1168, height: 916, alignment: .top)
            .clipped()
    }

    @Test(arguments: ["light", "dark"])
    func controller(theme: String) throws {
        try Snapshot.assertMatches(controller(), story: "components-callingscreensharingcontroller--controller", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func reallyLongAppName(theme: String) throws {
        try Snapshot.assertMatches(controller(name: "A really long application name that is super long"),
                                   story: "components-callingscreensharingcontroller--really-long-app-name", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func reconnecting(theme: String) throws {
        try Snapshot.assertMatches(controller(.reconnecting), story: "components-callingscreensharingcontroller--reconnecting", theme: theme)
    }

    /// CallingSelectPresentingSourcesModal--default (the thumbnails are 640×416 / 640×430).
    @Test(arguments: ["light", "dark"])
    func selectPresentingSourcesModal(theme: String) throws {
        let screen = pngFixture("presenting-source-screen.png"), window = pngFixture("presenting-source-window.png")
        let sources = [
            PresentableSource(id: "SOURCE_SCREEN", name: "Screen 1", isScreen: true, thumbnail: screen, thumbnailSize: CGSize(width: 640, height: 416)),
            PresentableSource(id: "SOURCE_WINDOW_1", name: "Bozirro Airhorse", isScreen: false, thumbnail: window, thumbnailSize: CGSize(width: 640, height: 430)),
            PresentableSource(id: "SOURCE_WINDOW_2", name: "Discoverer", isScreen: false, thumbnail: window, thumbnailSize: CGSize(width: 640, height: 430)),
            PresentableSource(id: "SOURCE_WINDOW_BROKEN", name: "Signal Beta", isScreen: false, thumbnail: nil, thumbnailSize: CGSize(width: 640, height: 430)),
            PresentableSource(id: "SOURCE_WINDOW_LONG_NAME", name: "Window that has a really long name and overflows", isScreen: false,
                              thumbnail: window, thumbnailSize: CGSize(width: 640, height: 430)),
        ]
        let view = SmallDialogsTests.modal(CallingSelectPresentingSourcesModal(sources: sources, onSourceSelect: { _ in }, onCancel: {}))
        // SwiftUI places rows on the 0.5pt grid where Chromium keeps fractional offsets (the
        // window row starts 0.62pt lower, its 1px card and dialog edges move); inside the
        // dialog that is 1.37% in light (0.85% dark), the whole capture 0.43%.
        try Snapshot.assertMatches(view, story: "components-callingselectpresentingsourcesmodal--default", theme: theme, maxRatio: 0.015)
    }
}
