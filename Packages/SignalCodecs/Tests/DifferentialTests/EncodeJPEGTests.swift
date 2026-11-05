import Foundation
import Testing
import CodecCore
import EncodeJPEG
import ImageJPEG
import ImagePNG

/// Conformance: byte-identical to libjpeg-turbo 3.2.1 `cjpeg -baseline -quality Q -dct int
/// [-sample 1x1|2x2]` (C paths), References/cjpeg.json.
/// Differential: ImageIO and our decoder read our output alike, and close to the source.
@Suite struct EncodeJPEGTests {
    struct Ref: Decodable, Sendable { var image: String; var quality: Int; var sampling: String; var md5: String; var size: Int }
    static let refs = try! JSONDecoder().decode([Ref].self, from: Data(Resources.bytes("References/cjpeg.json")))

    static let natural: Set<String> = ["testorig", "flower97x61", "hopper", "basn2c08"]

    static func sampling(_ s: String) -> JPEGEncoder.Sampling {
        s == "yuv444" ? .yuv444 : s == "yuv420" ? .yuv420 : .grayscale
    }

    @Test(arguments: refs)
    func byteIdenticalToCjpeg(ref: Ref) throws {
        let src = try PNGDecoder.decode(Resources.bytes("JPEGEncode/\(ref.image).png")).stillImage
        let jpeg = JPEGEncoder.encode(src, quality: ref.quality, sampling: Self.sampling(ref.sampling))
        #expect(md5Hex(jpeg) == ref.md5, "\(ref.image) q\(ref.quality) \(ref.sampling): \(jpeg.count) bytes vs \(ref.size)")
    }

    @Test(arguments: refs.filter { $0.quality >= 75 })
    func imageIODecodesOurOutput(ref: Ref) throws {
        let src = try PNGDecoder.decode(Resources.bytes("JPEGEncode/\(ref.image).png")).stillImage
        let jpeg = JPEGEncoder.encode(src, quality: ref.quality, sampling: Self.sampling(ref.sampling))
        let io = try #require(ImageIOOracle.frame(jpeg, index: 0), "ImageIO cannot read our JPEG")
        try #require(io.width == src.width && io.height == src.height)
        let ours = try JPEGDecoder.decode(jpeg)  // strict grammar accepts it
        // Tiny images with 4:2:0 legitimately differ between upsamplers (see JPEGDifferential).
        guard src.width >= 16 && src.height >= 16 else { return }
        let agree = JPEGDifferential.psnr(io.rgba, ours.rgba)
        #expect(agree > 28, "\(ref.image) q\(ref.quality) \(ref.sampling): decoders differ, PSNR \(fixed(agree, 1)) dB")
        // PngSuite's s*n3p04 patterns are saturated 1-pixel colour checkerboards that 4:2:0
        // cannot represent; fidelity under chroma subsampling is checked on natural images.
        guard ref.sampling != "yuv420" || Self.natural.contains(ref.image) else { return }
        let fidelity = JPEGDifferential.psnr(io.rgba, src.rgba)
        #expect(fidelity > 25, "\(ref.image) q\(ref.quality) \(ref.sampling): PSNR \(fixed(fidelity, 1)) dB vs source")
    }
}
