// ts/components/fun/FunGif.dom.stories.tsx. PreviewLoading and PreviewError are captured
// while loading (their state changes after 2s). Basic and PreviewSizing show frames of a
// remote Giphy MP4 and wait for the Swift H.264 decoder (Phase 5).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct FunGifTests {
    @Test(arguments: ["light", "dark"])
    func previews(theme: String) throws {
        for s in ["preview-loading", "preview-error"] {
            try Snapshot.assertMatches(FunGifPreview(frame: nil, state: .loading, width: 480, height: 418, maxHeight: 400)
                                        .frame(width: 1168, alignment: .leading),
                                       story: "components-fun-fungif--\(s)", theme: theme)
        }
    }
}

/// ts/components/fun/FunSticker.dom.stories.tsx: the GIF sticker under reduced motion (its
/// first frame) and with ignoreReducedMotion (the capture caught frame 8 of the animation).
@MainActor
@Suite struct FunStickerTests {
    @Test(arguments: ["light", "dark"])
    func story(theme: String) throws {
        let first = try #require(fixtureGIFFrame("giphy-GVNvOUpeYmI7e.gif", 0))
        let playing = try #require(fixtureGIFFrame("giphy-GVNvOUpeYmI7e.gif", 8))
        let view = VStack(alignment: .leading, spacing: 0) {
            CSSText("with reduce motion:", style: LegacyType.body1())
            FunSticker(still: first, accessibilityLabel: "Sticker")
            CSSText("without reduce motion:", style: LegacyType.body1())
            FunSticker(still: playing, ignoreReducedMotion: true, accessibilityLabel: "Sticker")
        }
        .frame(width: 1168, alignment: .leading)
        try Snapshot.assertMatches(view, story: "components-fun-funsticker--default", theme: theme)
    }
}
