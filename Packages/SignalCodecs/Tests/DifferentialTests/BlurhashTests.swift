import Foundation
import Testing
import Blurhash
import CodecCore
import ImageGIF
import ImagePNG

/// Conformance: woltapp's C reference implementation (built with -ffp-contract=off),
/// on PngSuite and Pillow images. See Tools/gen-codec-references.py.
@Suite struct BlurhashConformance {
    struct EncodeRef: Decodable, Sendable { var image: String; var x: Int; var y: Int; var hash: String }
    struct DecodeRef: Decodable, Sendable { var hash: String; var width: Int; var height: Int; var punch: Int; var rgbaMD5: String }
    struct Refs: Decodable { var encode: [EncodeRef]; var decode: [DecodeRef] }
    static let refs = try! JSONDecoder().decode(Refs.self, from: Data(Resources.bytes("References/blurhash.json")))

    static func image(_ path: String) throws -> PixelBuffer {
        let bytes = Resources.bytes(path)
        if path.hasSuffix(".gif") {
            return try GIFDecoder.decode(bytes).stillImage
        }
        return try PNGDecoder.decode(bytes).stillImage
    }

    @Test(arguments: refs.encode)
    func encodeMatchesReference(ref: EncodeRef) throws {
        let hash = Blurhash.encode(try Self.image(ref.image), xComponents: ref.x, yComponents: ref.y)
        #expect(hash == ref.hash, "\(ref.image) \(ref.x)x\(ref.y)")
    }

    @Test(arguments: refs.decode)
    func decodeMatchesReference(ref: DecodeRef) throws {
        let px = try Blurhash.decode(ref.hash, width: ref.width, height: ref.height, punch: ref.punch)
        #expect(md5Hex(px.rgba) == ref.rgbaMD5, "\(ref.hash) at \(ref.width)x\(ref.height) punch \(ref.punch)")
    }

    @Test(arguments: [
        "", "0", "00000", "L", "LEHV6nWB2yk8pyo0adR*.7kCMdn",       // wrong length
        "LEHV6nWB2yk8pyo0adR*.7kCMdnjX",                            // too long
        "LEHV6nWB2yk8pyo0adR*.7kCMd j",                             // not base83
        "~~HV6nWB2yk8pyo0adR*.7kCMdnj",                             // size flag 82
        "LEHV6nWB2yk8pyo0adR*.7kCMdné",                             // non-ASCII
    ])
    func malformedHashesAreRejected(hash: String) {
        #expect(throws: ParseFailure.self, "\(hash)") { try Blurhash.parse(hash) }
    }

    /// Out-of-range DC / AC values decode as the references decode them (no range check; the
    /// red channel's excess saturates): Signal Desktop's Image story uses such a hash.
    @Test func outOfRangeComponentsDecodeLikeTheReference() throws {
        #expect(try Blurhash.parse("00~~~~").dc > 0xFF_FFFF)
        #expect(try Blurhash.parse("10Jkot~~").ac == [6888])
        let px = try Blurhash.decode("thisisafakeblurhashthatwasmadeup", width: 36, height: 27)
        // Its DC red is 389: the top-left pixel saturates red, as Chromium shows the story.
        #expect(px.rgba[0] == 255 && px.rgba[3] == 255)
    }
}

/// Differential: the hash of ImageIO's decode of each opaque reference image equals
/// the reference hash (decoder-independent pipeline check).
@Suite struct BlurhashDifferential {
    static let opaque = BlurhashConformance.refs.encode.filter { $0.x == 4 && $0.y == 3 }

    @Test(arguments: opaque)
    func imageIOPixelsGiveTheSameHash(ref: BlurhashConformance.EncodeRef) throws {
        let bytes = Resources.bytes(ref.image)
        let ours = try BlurhashConformance.image(ref.image)
        guard !ours.rgba.enumerated().contains(where: { $0.offset % 4 == 3 && $0.element != 255 }) else { return }  // opaque only
        let oracleBytes = ref.image.hasSuffix(".png") ? PngSuiteDifferential.withoutColourChunks(bytes) : bytes
        let io = try #require(ImageIOOracle.frame(oracleBytes, index: 0))
        let img = PixelBuffer(width: io.width, height: io.height, rgba: io.rgba)
        #expect(Blurhash.encode(img, xComponents: 4, yComponents: 3) == ref.hash, "\(ref.image)")
    }
}
