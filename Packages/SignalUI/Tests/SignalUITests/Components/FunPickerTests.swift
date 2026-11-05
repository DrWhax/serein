// ts/components/Select.dom.stories.tsx and ts/components/fun/FunEmojiPicker.dom.stories.tsx
// (the picker open under its trigger, beside the story's skin-tone Select).

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
            FunStickerPicker(panel: FunPanelStickers(packs: packs, favorites: [k1, k2], recents: [abe, k1, k2, k3, tall, wide, k2]))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(x: 12, y: 44)
        }
    }

    @Test(arguments: ["light", "dark"])
    func stickerPicker(theme: String) throws {
        try Snapshot.assertMatches(Self.stickerStage(), story: "components-fun-funstickerpicker--default", theme: theme)
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
}
