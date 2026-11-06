// The sticker creator's flow: files in (converted or refused), emoji, details, upload, share.

import Foundation
import SignalI18n
import Testing
@testable import SignalUI

@MainActor
@Suite struct StickerCreatorTests {
    nonisolated static let preview = RGBAImage(width: 1, height: 1, pixels: Data([0, 0, 0, 255]))

    @Test func flowThroughTheStages() async throws {
        let i18n = Localizer(locale: "en")
        var uploadedCount = 0
        let model = StickerCreatorModel(process: { data in
            data.first == 0 ? .refused("StickerCreator--Toasts--errorProcessing") : .sticker(data: data, contentType: "image/webp", preview: Self.preview)
        }, upload: { title, author, stickers, cover, progress in
            #expect(title == "Cats" && author == "Me" && stickers.count == 2 && cover == Data([1]))
            for _ in stickers { progress() }
            uploadedCount = stickers.count
            return URL(string: "https://signal.art/addstickers/#pack_id=a&pack_key=b")!
        })
        model.add([(name: "a.png", data: Data([1])), (name: "b.png", data: Data([2])), (name: "bad.png", data: Data([0]))], i18n: i18n)
        for _ in 0..<50 where model.arts.contains(where: { $0.data == nil }) { await Task.yield() }
        #expect(model.arts.count == 2 && model.canGoToEmoji)
        #expect(model.toast != nil)
        model.stage = .emoji
        #expect(!model.emojisReady)
        for art in model.arts { model.setEmoji("😺", for: art.id) }
        #expect(model.emojisReady)
        model.stage = .meta
        model.title = "Cats"
        #expect(!model.metaReady)
        model.author = "Me"
        #expect(model.metaReady && model.cover?.data == Data([1]))
        model.startUpload(i18n: i18n)
        for _ in 0..<50 where model.stage != .share { await Task.yield() }
        #expect(model.stage == .share && uploadedCount == 2 && model.uploaded == 2 && model.packURL != nil)
        model.reset()
        #expect(model.stage == .drop && model.arts.isEmpty)
    }

    @Test func atMost200Stickers() {
        let model = StickerCreatorModel(process: { _ in .refused("x") }, upload: { _, _, _, _, _ in URL(string: "https://x")! })
        model.add((0..<250).map { (name: "\($0)", data: Data([UInt8($0 % 200 + 1)])) }, i18n: Localizer(locale: "en"))
        #expect(model.arts.count == 200)
    }
}
