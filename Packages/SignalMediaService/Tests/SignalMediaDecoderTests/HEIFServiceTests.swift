// AVIF and HEIC in the media service: AVIF is displayed like any supported image type (upstream
// isImageTypeSupported), HEIC is only ever decoded to be converted for sending (upstream
// heicConverterWorker: JPEG at quality 0.75), never displayed, thumbnailed or measured.

import CodecCore
import Foundation
import ImageJPEG
import MediaXPCInterface
import Testing
@testable import SignalMediaDecoder

@Suite struct HEIFServiceTests {
    static func image(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Resources/Image/\(name)"))
    }

    @Test func sniffsByPrimaryItemCodec() throws {
        #expect(MediaDecoder.sniff(Array(try Self.image("avifrot.avif"))) == .avif)
        #expect(MediaDecoder.sniff(Array(try Self.image("heicgrid.heic"))) == .heic)
    }

    @Test func avifIsDisplayedWithItsGeometry() async throws {
        let d = MediaDecoder()
        let avif = try Self.image("avifrot.avif")
        // irot 1 turns the 192x128 image a quarter anticlockwise.
        let info = try await d.imageInfo(avif).validated()
        #expect(info.width == 128 && info.height == 192 && !info.isAnimated)
        let shown = try await d.displayImage(avif, maxDimension: 96).validated(maxDimension: 96)
        #expect(shown.width == 64 && shown.height == 96 && shown.originalWidth == 128)
        _ = try await d.thumbnail(avif, size: MediaConstants.thumbnailSize).validated(size: MediaConstants.thumbnailSize)
        let alpha = try await d.displayImage(try Self.image("avifalpha.avif"), maxDimension: 512)
        #expect(alpha.rgba[3] < 16, "the alpha ramp starts transparent")
        let sticker = try await d.stickerImage(avif).validated()
        #expect(sticker.contentType == "image/webp")
        // Sending an AVIF: re-encoded (PNG below the size threshold, as canvasToBlob falls back).
        let scaled = try await d.scaleForSending(avif, contentType: "image/avif", level: .one).validated(maxDimension: 1600)
        #expect(scaled.contentType == "image/png" && scaled.width == 128)
    }

    @Test func heicIsNeverDisplayed() async throws {
        let d = MediaDecoder()
        let heic = try Self.image("heicgrid.heic")
        await #expect(throws: MediaProcessingError.unsupportedFormat) { try await d.displayImage(heic, maxDimension: 512) }
        await #expect(throws: MediaProcessingError.unsupportedFormat) { try await d.imageInfo(heic) }
        await #expect(throws: MediaProcessingError.unsupportedFormat) { try await d.thumbnail(heic, size: 150) }
        await #expect(throws: MediaProcessingError.unsupportedFormat) { try await d.scaleForSending(heic, contentType: "image/heic", level: .one) }
        let sticker = try await d.stickerImage(heic)
        #expect(sticker.refusal == .errorProcessing)
        // …and an AVIF is not taken for one.
        await #expect(throws: MediaProcessingError.unsupportedFormat) { try await d.convertHEIC(try Self.image("avifrot.avif")) }
    }

    @Test func heicConvertsToAFullSizeJPEG() async throws {
        let d = MediaDecoder()
        let converted = try await d.convertHEIC(try Self.image("heicgrid.heic")).validated()
        #expect(converted.width == 700 && converted.height == 450)
        let jpeg = try JPEGDecoder.decode(Array(converted.data))
        #expect(jpeg.width == 700 && jpeg.height == 450)
        // No metadata segments: only what the encoder itself writes (JFIF, DQT, SOF, DHT, SOS).
        let bytes = Array(converted.data)
        #expect(!bytes.indices.dropLast().contains { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xE1 }, "no Exif APP1")
        // The alpha image keeps its colours (heic-convert drops alpha, it does not composite).
        let alpha = try await d.convertHEIC(try Self.image("heicalpha.heic")).validated()
        let px = try JPEGDecoder.decode(Array(alpha.data))
        #expect(Int(px.rgba[0]) + Int(px.rgba[1]) + Int(px.rgba[2]) > 60, "the transparent edge is not black")
        // The converted JPEG is an ordinary image from here on.
        let info = try await d.imageInfo(converted.data).validated()
        #expect(info.width == 700)
    }

    @Test func convertHEICThroughXPC() async throws {
        let listener = NSXPCListener.anonymous()
        let delegate = MediaXPCListenerDelegate()
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        let client = MediaXPCClient(timeout: .seconds(20)) { NSXPCConnection(listenerEndpoint: endpoint) }
        let converted = try await client.convertHEIC(try Self.image("heicgrid.heic"))
        #expect(converted.width == 700 && converted.data.prefix(2) == Data([0xFF, 0xD8]))
        await #expect(throws: (any Error).self) { try await client.displayImage(try Self.image("heicgrid.heic"), maxDimension: 64) }
        let shown = try await client.displayImage(try Self.image("avifrot.avif"), maxDimension: 64)
        #expect(shown.height == 64)
        listener.invalidate()
    }
}
