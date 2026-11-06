// Round trips through our VP8L decoder: flat art, gradients, noise, alpha, odd sizes.

import CodecCore
@testable import EncodeWebP
import ImageWebP
import Foundation
import Testing

@Suite struct EncodeWebPTests {
    static func image(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> PixelBuffer {
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let p = f(x, y); let i = (y * w + x) * 4; rgba[i] = p.0; rgba[i + 1] = p.1; rgba[i + 2] = p.2; rgba[i + 3] = p.3 } }
        return PixelBuffer(width: w, height: h, rgba: rgba)
    }

    static func roundTrip(_ img: PixelBuffer) throws -> Int {
        let webp = WebPEncoder.encodeLossless(img)
        if let dir = ProcessInfo.processInfo.environment["WEBP_ARTIFACTS"] {
            try Data(webp).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(img.width)x\(img.height)-\(webp.count).webp"))
        }
        let decoded = try WebPDecoder.decode(webp)
        let still = decoded.stillImage
        #expect(still.width == img.width && still.height == img.height)
        #expect(still.rgba == img.rgba)
        return webp.count
    }

    @Test func flatColour() throws {
        let size = try Self.roundTrip(Self.image(512, 512) { _, _ in (255, 0, 0, 255) })
        #expect(size < 200)
    }

    @Test func stickerLikeArt() throws {
        // A disc on transparency: two colours plus anti-aliased-ish edge rings.
        let size = try Self.roundTrip(Self.image(512, 512) { x, y in
            let dx = x - 256, dy = y - 256, d = dx * dx + dy * dy
            if d < 180 * 180 { return (255, 200, 0, 255) }
            if d < 190 * 190 { return (UInt8(x & 0xFF), 40, 40, 128) }
            return (0, 0, 0, 0)
        })
        #expect(size < 30_000)
    }

    @Test func gradientAndNoise() throws {
        _ = try Self.roundTrip(Self.image(97, 61) { x, y in (UInt8(x * 2), UInt8(y * 4), UInt8((x * y) & 0xFF), 255) })
        var seed: UInt32 = 1
        _ = try Self.roundTrip(Self.image(33, 17) { _, _ in
            seed = seed &* 1_103_515_245 &+ 12345
            return (UInt8(seed >> 24), UInt8(seed >> 16 & 0xFF), UInt8(seed >> 8 & 0xFF), UInt8(seed & 0xFF))
        })
        _ = try Self.roundTrip(Self.image(1, 1) { _, _ in (1, 2, 3, 4) })
    }

    @Test func prefixCoding() {
        // Inverse of the decoder's prefix → value mapping.
        for v in 1...5000 {
            let p = WebPEncoder.prefix(v)
            let value = p.code < 4 ? p.code + 1 : ((2 + (p.code & 1)) << ((p.code - 2) >> 1)) + p.extra + 1
            #expect(value == v)
        }
    }
}
