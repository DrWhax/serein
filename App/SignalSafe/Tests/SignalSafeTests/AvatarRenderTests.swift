// Preset group avatars are drawn by us and encoded by our PNG encoder (no ImageIO); decoding
// the result with our PNG decoder gives the drawing back.

import CodecCore
import ImagePNG
import SignalUI
import Testing
@testable import SignalSafe

@MainActor @Suite struct AvatarRenderTests {
    @Test func presetAvatarIsOurPNG() throws {
        let png = try #require(SignalSession.renderAvatar(AvatarData(id: "t", color: "A110", text: "AB")))
        #expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let image = try PNGDecoder.decode([UInt8](png)).stillImage
        #expect(image.width == 512 && image.height == 512)
        // A corner is the A110 background (light: #dde7fc), opaque.
        let corner = Array(image.rgba[0..<4])
        #expect(abs(Int(corner[0]) - 0xDD) <= 2 && abs(Int(corner[1]) - 0xE7) <= 2 && abs(Int(corner[2]) - 0xFC) <= 2 && corner[3] == 255)
        // The text is drawn in the foreground colour somewhere in the middle.
        let mid = (256 * 512 + 256) * 4
        #expect(image.rgba[mid ..< mid + 4] != image.rgba[0..<4] || image.rgba.contains { $0 < 0x80 })
    }

    @Test func straightAlphaFromPremultiplied() throws {
        let png = try #require(SignalSession.renderAvatar(AvatarData(id: "t", color: "A100", icon: nil, text: "x")))
        let image = try PNGDecoder.decode([UInt8](png)).stillImage
        #expect(stride(from: 3, to: image.rgba.count, by: 4).allSatisfy { image.rgba[$0] == 255 })
    }
}
