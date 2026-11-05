// ts/components/stickers/StickerPreviewModal.dom.stories.tsx: pack "Foo" with a wide, a tall
// and 101 Abe stickers (/fixtures/512x515-thumbs-up-lincoln.webp, 1000x50-green.jpeg,
// 50x1000-teal.jpeg).

import Foundation
import ImageJPEG
import ImageWebP
import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct StickerPreviewModalTests {
    static func fixture(_ name: String) -> RGBAImage? {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Signal-Desktop/fixtures/\(name)")
        guard let data = try? Data(contentsOf: url) else { return nil }
        if name.hasSuffix(".webp") { return (try? WebPDecoder.decode([UInt8](data))).map { RGBAImage($0.stillImage) } }
        return (try? JPEGDecoder.decode([UInt8](data))).map { RGBAImage($0) }
    }

    static var pack: StickerPack {
        let abe = fixture("512x515-thumbs-up-lincoln.webp")
        let stickers = [Sticker(id: -2, emoji: "🤯", image: fixture("1000x50-green.jpeg")), Sticker(id: -3, emoji: "🔥", image: fixture("50x1000-teal.jpeg"))]
            + (0..<101).map { Sticker(id: $0, emoji: "🎩", image: abe) }
        return StickerPack(id: "foo", key: "foo", title: "Foo", author: "Foo McBarrington", status: .downloaded, cover: abe, stickerCount: 101, stickers: stickers)
    }

    static var stories: [(String, StickerPreviewModal)] {
        let base = pack
        var blessed = base; blessed.isBlessed = true
        var small = base; small.stickerCount = 4; small.stickers = Array(repeating: Sticker(id: -1, emoji: "🎩", image: base.cover), count: 4)
        var installed = base; installed.status = .installed
        var pending = base; pending.status = .pending
        var error = base; error.status = .error
        return [
            ("pack", StickerPreviewModal(pack: base)),
            ("official-pack", StickerPreviewModal(pack: blessed)),
            ("small-pack", StickerPreviewModal(pack: small)),
            ("pack-installed", StickerPreviewModal(pack: installed)),
            ("pack-install-pending", StickerPreviewModal(pack: pending)),
            ("initial-download", StickerPreviewModal(pack: StickerPack(id: "", title: "", status: .ephemeral))),
            ("pack-error", StickerPreviewModal(pack: error)),
        ]
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        for (name, view) in Self.stories {
            try Snapshot.assertMatches(PortalStage { EmptyView() } modal: { AxoBaseDialog.Host { view } },
                                       story: "components-stickers-stickerpreviewmodal--\(name)", theme: theme)
        }
    }
}
