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
