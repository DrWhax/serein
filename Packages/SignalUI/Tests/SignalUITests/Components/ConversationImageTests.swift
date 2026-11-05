// Image stories (ts/components/conversation/Image.dom.stories.tsx): a 300×200 sax.png (the
// fixture is 800×1200, the attachment says 800×600) at the story root, with createProps'
// theme 'light' for the default blurhash unless a story passes the page's theme.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct ConversationImageTests {
    static let sax = fixturePNG("freepngs-2cd43b_bed7d1327e88454487397574d87b64dc_mv2.png")
    static let fakeHash = BlurHashImage.trusted("thisisafakeblurhashthatwasmadeup", intrinsicWidth: 800, intrinsicHeight: 600)

    static func attachment(downloaded: Bool = true, pending: Bool = false, size: Int = 10304, totalDownloaded: Int? = nil) -> MessageAttachment {
        var a = MessageAttachment(contentType: "image/png", fileName: "sax.png", size: size)
        a.isDownloaded = downloaded
        a.pending = pending
        a.totalDownloaded = totalDownloaded
        return a
    }

    static func image(_ a: MessageAttachment = attachment(), url: RGBAImage? = sax, blurHash: RGBAImage? = nil, blurHashDark: Bool? = false,
                      corners: ConversationImage.Corners = .init(), _ configure: (inout ConversationImage.Options) -> Void = { _ in }) -> some View {
        var o = ConversationImage.Options()
        configure(&o)
        return ConversationImage(attachment: a, url: url, blurHash: blurHash, width: 300, height: 200, corners: corners, options: o,
                                 blurHashDark: blurHashDark, startDownload: {}, cancelDownload: {}, showVisualAttachment: {}, onClickClose: {})
    }

    static func notDownloaded(pending: Bool = false, totalDownloaded: Int? = nil, incremental: Bool = false) -> some View {
        image(attachment(downloaded: false, pending: pending, size: 5_300_000, totalDownloaded: totalDownloaded), url: nil, blurHash: fakeHash) {
            $0.incremental = incremental
            $0.playIconOverlay = incremental
        }
    }

    static var stories: [(String, AnyView)] {
        [
            ("url-with-height-width", AnyView(image())),
            ("caption", AnyView(image { $0.caption = "<Saxophone Pun>" })),
            ("play-icon", AnyView(image { $0.playIconOverlay = true })),
            ("close-button", AnyView(image { $0.closeButton = true })),
            ("no-border-or-background", AnyView(image { $0.noBackground = true; $0.noBorder = true }
                .frame(maxWidth: .infinity, alignment: .leading).background(RGBA(hex: 0x999999).color))),
            ("not-downloaded-not-incremental-not-pending", AnyView(notDownloaded())),
            ("pending-w-download-queued-not-incremental", AnyView(notDownloaded(pending: true))),
            ("pending-w-download-progress", AnyView(notDownloaded(pending: true, totalDownloaded: 1_230_000))),
            ("not-pending-w-download-progress", AnyView(notDownloaded(totalDownloaded: 1_230_000))),
            ("pending-incremental-no-progress", AnyView(notDownloaded(pending: true, incremental: true))),
            ("pending-incremental-download-progress", AnyView(notDownloaded(pending: true, totalDownloaded: 1_230_000, incremental: true))),
            ("not-pending-incremental-no-progress", AnyView(notDownloaded(incremental: true))),
            ("not-pending-incremental-w-progress", AnyView(notDownloaded(totalDownloaded: 1_230_000, incremental: true))),
            ("curved-corners", AnyView(image(corners: .all(.normal)))),
            ("small-curve-top-left", AnyView(image(corners: .init(topLeft: .small)))),
            ("soft-corners", AnyView(image(corners: .all(.tiny)))),
            ("bottom-overlay", AnyView(image { $0.bottomOverlay = true })),
            ("full-overlay-with-text", AnyView(image { $0.darkOverlay = true; $0.overlayText = "Honk!" })),
            ("blurhash", AnyView(image(url: nil, blurHash: fakeHash))),
            ("undefined-blur-hash", AnyView(image(url: nil, blurHashDark: nil))),
            // url 'random' fails to load: the default (light) blurhash shows.
            ("missing-image", AnyView(image(url: nil))),
        ]
    }

    @Test(arguments: ["light", "dark"], 0..<21)
    func story(theme: String, index: Int) throws {
        let (name, view) = Self.stories[index]
        try Snapshot.assertMatches(view.frame(width: 1168, alignment: .leading), story: "components-conversation-image--\(name)", theme: theme)
    }
}
