// ts/components/Select.dom.stories.tsx and ts/components/fun/FunEmojiPicker.dom.stories.tsx
// (the picker open under its trigger, beside the story's skin-tone Select).

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct FunPickerTests {
    static let recents = ["😀", "😁", "😂", "🤣", "😃", "😄", "😅", "😆", "😉", "😊", "😋", "😎", "😍", "😘", "😗", "😙", "😚", "☺️", "🙂", "🤗",
                          "🤩", "🤔", "🤨", "😐", "😑", "😶", "🙄", "😏", "😣", "😥", "😮", "🤐"]
    static let thisMessage = ["👍", "👍\u{1F3FE}", "🤘\u{1F3FB}", "🤘\u{1F3FC}", "😄", "😅"]

    @Test(arguments: ["light", "dark"])
    func select(theme: String) throws {
        let c = "components-select--"
        try Snapshot.assertMatches(Select(options: [.init(text: "1", value: "1"), .init(text: "2", value: "2"), .init(text: "3", value: "3")],
                                          value: "0") { _ in }, story: c + "normal", theme: theme)
        try Snapshot.assertMatches(Select(options: [.init(text: "Apples", value: "a"), .init(text: "Bananas", value: "b", disabled: true),
                                                    .init(text: "Cabbage", value: "c"), .init(text: "Durian", value: "d", disabled: true)],
                                          value: "c") { _ in }, story: c + "with-disabled-options", theme: theme)
    }

    static func emojiStage(_ messageEmojis: [String]) -> some View {
        PortalStage {
            HStack(spacing: 16) {
                Select(options: [.init(text: "Default", value: "")], value: "") { _ in }.frame(width: 195)
                CSSText("Open EmojiPicker", style: LegacyType.body1(), wrap: .nowrap)
            }
        } modal: {
            FunEmojiPicker(panel: FunPanelEmojis(recentEmojis: recents, messageEmojis: messageEmojis))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(x: 108.17, y: 64)
        }
    }

    @Test(arguments: ["light", "dark"])
    func emojiPicker(theme: String) throws {
        let c = "components-fun-funemojipicker--"
        try Snapshot.assertMatches(Self.emojiStage([]), story: c + "default", theme: theme)
        try Snapshot.assertMatches(Self.emojiStage(Self.thisMessage), story: c + "with-this-message-reactions", theme: theme)
    }

    /// ts/test-helpers/stickersMocks.std.ts (the seeded `sample` of the 20 packs' covers read
    /// off the capture for the visible ones).
    static func sticker(_ id: Int, _ pack: String, _ file: String) -> FunStickerItem {
        FunStickerItem(id: id, packId: pack, image: fixtureByURL("/fixtures/" + file))
    }

    static func stickerStage() -> some View {
        let k1 = sticker(1, "foo", "kitten-1-64-64.jpg"), k2 = sticker(2, "bar", "kitten-2-64-64.jpg"), k3 = sticker(3, "baz", "kitten-3-64-64.jpg")
        let abe = sticker(4, "abe", "512x515-thumbs-up-lincoln.webp")
        let wide = sticker(5, "wide", "1000x50-green.jpeg"), tall = sticker(6, "tall", "50x1000-teal.jpeg")
        func pack(_ id: String, _ s: FunStickerItem) -> FunStickerPack {
            FunStickerPack(id: id, title: "\(id) title", cover: s.image, stickers: (0..<101).map { var x = s; x.id = $0; return x })
        }
        let covers = [k2, k3, k3, k2, k1, k1] + Array(repeating: k1, count: 14)
        let packs = [pack("tall", tall), pack("wide", wide)] + covers.enumerated().map { pack("pack-\($0.offset)", $0.element) }
        return PortalStage {
            CSSText("Open StickerPicker", style: LegacyType.body1(), wrap: .nowrap)
        } modal: {
            // Upstream's padding (the grid leaning left): the shipped grid is centred, see
            // stickerGridIsCentred.
            FunStickerPicker(panel: { var p = FunPanelStickers(packs: packs, favorites: [k1, k2], recents: [abe, k1, k2, k3, tall, wide, k2]); p.centersGrid = false; return p }())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(x: 12, y: 44)
        }
    }

    @Test(arguments: ["light", "dark"])
    func stickerPicker(theme: String) throws {
        try Snapshot.assertMatches(Self.stickerStage(), story: "components-fun-funstickerpicker--default", theme: theme)
    }

    @Observable final class Frame { var rect = CGRect.zero }

    /// The sticker grid sits in the middle of what the scroller shows (with this Mac's scroller
    /// style; a legacy scroller takes 17pt), and the scroller stays inside the panel.
    @Test func stickerGridIsCentred() async throws {
        _ = NSApplication.shared
        let grid = Frame()
        let view = FunScroller(centering: 320) {
            VStack(spacing: 0) {
                Color.red.frame(width: 320, height: 80).onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { grid.rect = $0 }
                ForEach(0..<20) { _ in Color.blue.frame(width: 320, height: 80) }
            }
        }
        .frame(width: FunMetrics.dialogWidth, height: FunMetrics.panelHeight)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: FunMetrics.dialogWidth, height: FunMetrics.panelHeight), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(scrollViews) }
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // Laid out once the grid has its frame and the scroller its width (slow under load).
        for _ in 0..<200 {
            if grid.rect.width > 0, let sv = scrollViews(host).first, sv.contentView.bounds.width > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let scroller = try #require(scrollViews(host).first)
        let visible = scroller.contentView.bounds.width
        #expect(scroller.frame.width == FunMetrics.dialogWidth)
        #expect(grid.rect.width == 320 && abs(grid.rect.minX - (visible - grid.rect.maxX)) <= 0.5, "left \(grid.rect.minX), right \(visible - grid.rect.maxX)")
    }

    @Test(arguments: ["light", "dark"])
    func funPicker(theme: String) throws {
        let stage = PortalStage {
            CSSText("Open FunPicker", style: LegacyType.body1(), wrap: .nowrap)
        } modal: {
            FunPicker(tab: .constant(.emojis)) {
                FunPanelEmojis(recentEmojis: Self.recents)
            } stickers: { EmptyView() } gifs: { EmptyView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(x: 12, y: 44)
        }
        try Snapshot.assertMatches(stage, story: "components-fun-funpicker--default", theme: theme)
    }

    /// FunPicker `Default` with the GIFs tab clicked (CAPTURE_CLICK=GIFs CAPTURE_CLICK_PAGE=1):
    /// MOCK_GIFS_PAGINATED_ONE_PAGE's 30 GIFs, whose 1-byte files never play (empty cells).
    @Test(arguments: ["light", "dark"])
    func funPickerGifs(theme: String) throws {
        let media = FunGifMedia(url: URL(string: "https://media2.giphy.com/media/x/200w.mp4")!, width: 200, height: 178)
        let page = FunGifsPage(next: nil, gifs: (0 ..< 30).map {
            FunGifItem(id: "\($0)", title: "", description: "", previewMedia: media, attachmentMedia: FunGifMedia(url: media.url, width: 480, height: 418))
        })
        let source = FunGifsDataSource(trending: { _, _ in page }, search: { _, _, _ in page }, previewPlayer: { _ in nil })
        let stage = PortalStage {
            CSSText("Open FunPicker", style: LegacyType.body1(), wrap: .nowrap)
        } modal: {
            FunPicker(tab: .constant(.gifs)) { EmptyView() } stickers: { EmptyView() } gifs: {
                FunPanelGifs(recentGifs: [], source: source, prefetched: page)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .offset(x: 12, y: 44)
        }
        try Snapshot.assertMatches(stage, story: "components-fun-funpicker--default--gifs", theme: theme)
    }
}
