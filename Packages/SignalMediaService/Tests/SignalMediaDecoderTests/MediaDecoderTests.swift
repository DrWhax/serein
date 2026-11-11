import CodecCore
import EncodePNG
import Foundation
import MediaXPCInterface
import Testing
@testable import SignalMediaDecoder

@Suite struct MediaDecoderTests {
    /// A 300×200 PNG: left half red, right half blue.
    static func sample() -> Data {
        var px = [UInt8]()
        for _ in 0..<200 { for x in 0..<300 { px += x < 150 ? [255, 0, 0, 255] : [0, 0, 255, 255] } }
        return Data(PNGEncoder.encode(PixelBuffer(width: 300, height: 200, rgba: px)))
    }

    @Test func sniffsFormats() {
        #expect(MediaDecoder.sniff(Array(Self.sample())) == .png)
        #expect(MediaDecoder.sniff([0xFF, 0xD8, 0xFF, 0xE0]) == .jpeg)
        #expect(MediaDecoder.sniff(Array("GIF89a".utf8)) == .gif)
        #expect(MediaDecoder.sniff(Array("RIFF\0\0\0\0WEBP".utf8)) == .webp)
        #expect(MediaDecoder.sniff([1, 2, 3]) == nil)
    }

    @Test func imageInfo() async throws {
        let info = try await MediaDecoder().imageInfo(Self.sample()).validated()
        #expect(info.width == 300 && info.height == 200 && !info.isAnimated)
        #expect(info.blurHash.count == 28)
    }

    @Test func thumbnailIsCoverCropped() async throws {
        let t = try await MediaDecoder().thumbnail(Self.sample(), size: 150).validated(size: 150)
        let (img, _) = try MediaDecoder.decode(t.png)
        #expect(img.width == 150 && img.height == 150)
        // Cover: the 200px height fills 150, so the crop keeps the middle 200 of 300 columns.
        #expect(img.pixel(x: 10, y: 75) == (255, 0, 0, 255))
        #expect(img.pixel(x: 140, y: 75) == (0, 0, 255, 255))
    }

    /// Noise compresses badly, so a 4000×3000 image walks down the dimension ladder.
    @Test func scalesToLevel() async throws {
        var rng = SystemRandomNumberGenerator()
        var px = [UInt8](repeating: 255, count: 2400 * 1800 * 4)
        for i in stride(from: 0, to: px.count, by: 4) { px[i] = UInt8.random(in: 0...255, using: &rng); px[i + 1] = UInt8.random(in: 0...255, using: &rng) }
        let big = Data(PNGEncoder.encode(PixelBuffer(width: 2400, height: 1800, rgba: px)))
        let out = try await MediaDecoder().scaleForSending(big, contentType: "image/png", level: .one).validated(maxDimension: 1600)
        #expect(out.contentType == "image/jpeg" && max(out.width, out.height) <= 1600 && out.width * 3 == out.height * 4)
        #expect(out.data.count <= 1 << 20 || max(out.width, out.height) == 512)
        // Small images keep their type (re-encoded).
        let small = try await MediaDecoder().scaleForSending(Self.sample(), contentType: "image/png", level: .one)
        #expect(small.contentType == "image/png" && small.width == 300)
    }

    @Test func rejectsUnknownBytes() async {
        await #expect(throws: MediaProcessingError.unsupportedFormat) { try await MediaDecoder().imageInfo(Data([1, 2, 3, 4])) }
    }
}

import CodecCore
import EncodePNG

@Suite struct StickerImageTests {
    @Test func stillImageBecomesA512WebP() async throws {
        var rgba = [UInt8](repeating: 0, count: 300 * 150 * 4)
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba[i] = 200; rgba[i + 3] = 255 }
        let png = Data(PNGEncoder.encode(PixelBuffer(width: 300, height: 150, rgba: rgba)))
        let sticker = try await MediaDecoder().stickerImage(png).validated()
        #expect(sticker.contentType == "image/webp" && sticker.refusal == nil)
        let (decoded, _) = try MediaDecoder.decode(sticker.data)
        #expect(decoded.width == 512 && decoded.height == 512)
        // Contained and centred: transparent above and below the 512×256 band.
        #expect(decoded.rgba[3] == 0 && decoded.rgba[(256 * 512 + 256) * 4 + 3] == 255)
    }

    @Test func garbageIsRefused() async throws {
        let s = try await MediaDecoder().stickerImage(Data([1, 2, 3])).validated()
        #expect(s.refusal == .errorProcessing)
    }
}

import Foundation

/// The whole XPC path in process: an anonymous listener with the service's handler, and the
/// app's client connected to it.
@Suite struct MediaXPCTests {
    @Test func requestsRoundTripThroughXPC() async throws {
        let listener = XPCServer.anonymous(requirement: nil, MediaXPCHandler())
        let client = MediaXPCClient(timeout: .seconds(10), decoder: .endpoint(listener.endpoint))
        var rgba = [UInt8](repeating: 0, count: 40 * 20 * 4)
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba[i + 1] = 255; rgba[i + 3] = 255 }
        let png = Data(PNGEncoder.encode(PixelBuffer(width: 40, height: 20, rgba: rgba)))
        let info = try await client.imageInfo(png)
        #expect(info.width == 40 && info.height == 20)
        let shown = try await client.displayImage(png, maxDimension: 16)
        #expect(shown.width == 16 && shown.height == 8 && shown.originalWidth == 40 && shown.rgba.count == 16 * 8 * 4)
        #expect(Array(shown.rgba.prefix(4)) == [0, 255, 0, 255])
        let sticker = try await client.stickerImage(png)
        #expect(sticker.contentType == "image/webp")
        await #expect(throws: MediaProcessingError.self) { try await client.imageInfo(Data([1, 2, 3])) }
        listener.cancel()
    }
}
