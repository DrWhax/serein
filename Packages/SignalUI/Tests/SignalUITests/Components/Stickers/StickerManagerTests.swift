// ts/components/stickers/StickerManager.dom.stories.tsx (createPack from
// ts/test-helpers/stickersMocks.std.ts: "<id> title", covers kitten-1 / kitten-2).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct StickerManagerTests {
    static func pack(_ id: String, _ status: StickerPack.Status, kitten: Int, blessed: Bool = false, author: String = "") -> StickerPack {
        StickerPack(id: id, title: "\(id) title", author: author, isBlessed: blessed, status: status, cover: fixtureImage("kitten-\(kitten)-64-64.jpg"))
    }

    static let received = [pack("received-pack-1", .downloaded, kitten: 1), pack("received-pack-2", .downloaded, kitten: 2)]
    static let installed = [pack("installed-pack-1", .installed, kitten: 1), pack("installed-pack-2", .installed, kitten: 2)]
    static let blessed = [pack("blessed-pack-1", .downloaded, kitten: 1, blessed: true, author: "Ann Chovy"),
                          pack("blessed-pack-2", .downloaded, kitten: 2, blessed: true, author: "Tom Ato")]

    static var stories: [(String, StickerManager)] {
        var blessedWithInstalled = blessed
        blessedWithInstalled[0].status = .installed
        return [
            ("full", StickerManager(blessedPacks: blessed, receivedPacks: received, installedPacks: installed)),
            ("received-packs", StickerManager(blessedPacks: blessed, receivedPacks: received, installedPacks: [])),
            ("installed-packs", StickerManager(blessedPacks: blessedWithInstalled, receivedPacks: installed, installedPacks: installed)),
            // Known packs are downloaded on appear; until then they are not listed.
            ("installed-and-known-packs", StickerManager(blessedPacks: blessed, receivedPacks: installed, installedPacks: installed)),
            ("empty", StickerManager(blessedPacks: [], receivedPacks: [], installedPacks: [])),
        ]
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        for (name, view) in Self.stories {
            try Snapshot.assertMatches(view.frame(width: 1168), story: "components-stickers-stickermanager--\(name)", theme: theme)
        }
    }
}
