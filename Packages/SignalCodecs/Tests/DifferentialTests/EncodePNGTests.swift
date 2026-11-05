import Foundation
import Testing
import CodecCore
import EncodePNG
import ImagePNG

/// PNG encoder on every decodable PngSuite image:
/// conformance = our own grammar accepts the file and decodes it losslessly;
/// differential = ImageIO decodes our file to the same pixels.
@Suite struct EncodePNGTests {
    static let files = Corpus.valid

    @Test(arguments: files)
    func roundTripsAndImageIOAgrees(name: String) throws {
        let source = try PNGDecoder.decode(Corpus.bytes(name)).stillImage
        let png = PNGEncoder.encode(source)
        // Conformance: recognised by the strict grammar (CRCs, zlib Adler, chunk order) and lossless.
        let back = try PNGDecoder.decode(png).stillImage
        let lossless = back == source
        #expect(lossless, "\(name): \(mismatch(back, source))")
        // Differential: ImageIO reads exactly the same pixels.
        let io = try #require(ImageIOOracle.frame(png, index: 0), "\(name): ImageIO cannot read our PNG")
        let d = compare(premultiplied(source), io.rgba, tolerance: 1)
        #expect(d.samplesOverTolerance == 0, "\(name): \(d)")
    }
}
