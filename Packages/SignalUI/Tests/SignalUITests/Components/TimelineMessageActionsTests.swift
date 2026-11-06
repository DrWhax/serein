// TimelineMessage's actions: MessageContextMenu's items and their order, SelectModeActions'
// rules, and the actions being invisible until hovered (the Storybook captures match with
// and without them).

import AppKit
import EncodePNG
import Foundation
import SignalI18n
import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite(.serialized) struct TimelineMessageActionsTests {
    let i18n = DefaultLocalizer.english

    func full() -> TimelineMessageActions {
        var a = TimelineMessageActions()
        a.react = { _, _ in }
        a.reply = {}
        a.download = {}
        a.edit = {}
        a.forward = {}
        a.select = {}
        a.copy = {}
        a.pin = {}
        a.moreInfo = {}
        a.delete = {}
        return a
    }

    @Test func menuOrder() {
        let a = full()
        #expect(a.entries(i18n, shouldShowAdditional: false, openReactionPicker: {}).map(\.title) == [
            i18n("icu:MessageContextMenu__forward"), i18n("icu:edit"), i18n("icu:MessageContextMenu__select"), i18n("icu:copy"),
            i18n("icu:MessageContextMenu__PinMessage"), i18n("icu:MessageContextMenu__info"), i18n("icu:MessageContextMenu__deleteMessage"),
        ])
        // A long body (or a narrow timeline): download, reply and react join the menu first.
        #expect(a.entries(i18n, shouldShowAdditional: true, openReactionPicker: {}).prefix(3).map(\.symbol) == ["download", "reply", "heart-plus"])
        var pinned = a
        pinned.pin = nil
        pinned.unpin = {}
        #expect(pinned.entries(i18n, shouldShowAdditional: false, openReactionPicker: {}).map(\.symbol).contains("pin-slash"))
        // Nothing offered: an empty menu.
        #expect(TimelineMessageActions().entries(i18n, shouldShowAdditional: true, openReactionPicker: {}).isEmpty)
    }

    @Test func menuReactOpensPicker() {
        var opened = false
        let e = full().entries(i18n, shouldShowAdditional: true, openReactionPicker: { opened = true })
        e.first { $0.symbol == "heart-plus" }?.action()
        #expect(opened)
    }

    @Test func selectModeActions() {
        func make(_ n: Int, _ forwardable: Bool) -> SelectModeActions {
            SelectModeActions(selectedCount: n, areSelectedMessagesForwardable: forwardable, onExitSelectMode: {}, onDeleteMessages: {}, onForwardMessages: {})
        }
        #expect(!make(0, true).canDelete && !make(0, true).canForward)
        #expect(make(2, true).canDelete && make(2, true).canForward)
        #expect(!make(2, false).canForward)
        #expect(make(31, true).tooMany && !make(31, true).canForward && make(31, true).canDelete)
    }

    /// The buttons are hidden until the row is hovered: a message renders the same with them.
    @Test(arguments: [MessageDirection.incoming, .outgoing])
    func actionsInvisibleUntilHovered(direction: MessageDirection) throws {
        let id = "components-conversation-timelinemessage--multi-select"
        let (info, _) = try Snapshot.reference(id, "light")
        let plain = TimelineMessageTests.props("Hello there", direction: direction, author: "Celia Barton")
        var withActions = plain
        withActions.actions = full()
        let a = try Snapshot.render(TimelineMessageTests.stage(Message(props: plain)), info: info)
        let b = try Snapshot.render(TimelineMessageTests.stage(Message(props: withActions)), info: info)
        var diff = 0, minX = Int.max, maxX = 0, minY = Int.max, maxY = 0
        for i in stride(from: 0, to: min(a.rgba.count, b.rgba.count), by: 4) where a.rgba[i] != b.rgba[i] || a.rgba[i + 1] != b.rgba[i + 1] || a.rgba[i + 2] != b.rgba[i + 2] {
            diff += 1
            let px = i / 4, x = px % a.width, y = px / a.width
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        #expect(diff == 0, "\(diff) pixels differ in x \(minX)...\(maxX), y \(minY)...\(maxY) of \(a.width)x\(a.height)")
    }

    /// HOVER_PNG=<path>: writes short and long messages with their buttons shown (a visual check).
    @Test func hoverButtonsPNG() throws {
        guard let path = ProcessInfo.processInfo.environment["HOVER_PNG"] else { return }
        let id = "components-conversation-timelinemessage--multi-select"
        var (info, _) = try Snapshot.reference(id, "light")
        info.height = 360
        let rows = VStack(spacing: 0) {
            ForEach(Array([("Hi", MessageDirection.incoming), ("Hi", .outgoing),
                           ("A much longer message that fills more of the row, to see where the buttons go", .incoming),
                           ("A much longer message that fills more of the row, to see where the buttons go", .outgoing)].enumerated()), id: \.offset) { _, m in
                Message(props: TimelineMessageTests.props(m.0, direction: m.1, author: "Celia Barton") { $0.actions = full() })
            }
        }
        let png = try Snapshot.render(TimelineMessageTests.stage(rows.environment(\.messageMenuAlwaysVisible, true)), info: info)
        try Data(PNGEncoder.encode(png)).write(to: URL(fileURLWithPath: path))
    }

    /// STICKERS_PNG=<path>: the Fun picker's sticker tab with two packs (a visual check).
    @Test func stickersPNG() throws {
        guard let path = ProcessInfo.processInfo.environment["STICKERS_PNG"] else { return }
        func img(_ v: UInt8) -> RGBAImage {
            var px: [UInt8] = []
            for y in 0..<256 { for x in 0..<256 { px += [v, UInt8(x), UInt8(y), (x - 128) * (x - 128) + (y - 128) * (y - 128) < 120 * 120 ? 255 : 0] } }
            return RGBAImage(width: 256, height: 256, pixels: Data(px), scale: 2)
        }
        let packs = (0..<2).map { p in
            FunStickerPack(id: "p\(p)", title: "Pack \(p)", cover: img(200), stickers: (0..<7).map { FunStickerItem(id: $0, packId: "p\(p)", image: img(UInt8(40 * $0)), emoji: "🙂") })
        }
        let id = "components-conversation-timelinemessage--multi-select"
        var (info, _) = try Snapshot.reference(id, "light")
        info.width = 400
        info.height = 560
        let view = FunPicker(tab: .constant(.stickers)) { EmptyView() } stickers: {
            FunPanelStickers(packs: packs, favorites: [], recents: [])
        } gifs: { EmptyView() }
        let png = try Snapshot.render(view.padding(20), info: info)
        try Data(PNGEncoder.encode(png)).write(to: URL(fileURLWithPath: path))
    }

    /// A long sticker pack title stays within the width offered (it once widened the grid,
    /// which the scroll view then centred, pushing the first column out of sight).
    @Test func longGridHeaderFitsWidth() {
        let title = String(repeating: "A very long sticker pack title ", count: 4)
        let host = NSHostingController(rootView: FunGridHeader(title: title) { EmptyView() }.environment(\.i18n, i18n))
        let size = host.sizeThatFits(in: CGSize(width: 300, height: 1000))
        #expect(size.width <= 300.5 && size.height == 28, "\(size)")
    }
}
