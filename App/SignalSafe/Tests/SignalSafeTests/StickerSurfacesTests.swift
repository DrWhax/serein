// Sticker surfaces: a sticker pack link opens the pack's preview in the app (upstream
// showStickerPack); other links go elsewhere.

import Foundation
import Testing
@testable import SignalCore
@testable import SignalSafe

@MainActor @Suite struct StickerSurfacesTests {
    @Test func aStickerPackLinkOpensItsPreview() throws {
        let session = SignalSession()
        let id = "9acc9e8aba563d26a4994e69263e3b25", hex = String(repeating: "0f", count: 32)
        #expect(session.openInAppLink(try #require(URL(string: "https://signal.art/addstickers/#pack_id=\(id)&pack_key=\(hex)"))))
        #expect(session.stickerPackPreview?.id == id)
        #expect(session.stickerPackPreview?.key == Data(repeating: 0x0f, count: 32).base64EncodedString())
        session.stickerPackPreview = nil
        #expect(!session.openInAppLink(try #require(URL(string: "https://example.com/addstickers/#pack_id=\(id)&pack_key=\(hex)"))))
        #expect(session.stickerPackPreview == nil)
    }
}
