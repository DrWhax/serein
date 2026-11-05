import Foundation
import Testing
import CodecCore
@testable import ImageJPEG

/// Conformance: bit-exact against libjpeg-turbo 3.2.1 `djpeg -dct int -ppm`
/// (References/djpeg.json, Tools/gen-codec-references.py).
@Suite struct JPEGConformance {
    struct Ref: Decodable, Sendable { var width: Int; var height: Int; var rgbMD5: String }
    static let refs: [String: Ref?] = try! JSONDecoder().decode([String: Ref?].self, from: Data(Resources.bytes("References/djpeg.json")))
    static let files = refs.keys.sorted()

    /// Processes SignalSafe rejects by policy (djpeg decodes them).
    static let rejected: Set<String> = [
        "ljt_testimgari.jpg", "cjpeg_testorig_arith.jpg", "cjpeg_odd97x61_arith.jpg",  // arithmetic coding
        "ljt_monkey12.jpg",                                                              // 12-bit precision
    ]

    static func rgb(_ img: PixelBuffer) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(img.width * img.height * 3)
        for i in stride(from: 0, to: img.rgba.count, by: 4) { out += img.rgba[i..<(i + 3)] }
        return out
    }

    @Test(arguments: files)
    func matchesDjpeg(name: String) throws {
        let bytes = Resources.bytes("JPEG/" + name)
        if Self.rejected.contains(name) {
            #expect(throws: ParseFailure.self, "\(name) is rejected by policy") { try JPEGDecoder.decode(bytes) }
            return
        }
        let ref = try #require(Self.refs[name] ?? nil, "\(name): no reference")
        let file = try JPEGGrammar.file(ByteSlice(bytes))
        let img = try JPEGDecoder.decodeRaw(file)
        try #require(img.width == ref.width && img.height == ref.height, "\(name) size \(img.width)x\(img.height) vs \(ref.width)x\(ref.height)")
        let ok = md5Hex(Self.rgb(img)) == ref.rgbMD5
        #expect(ok, "\(name): \(file.frame.process) \(file.frame.components.map { "\($0.h)x\($0.v)" }) \(file.colorTransform) — RGB differs from djpeg")
    }

    @Test func truncationsFailCleanlyOrDecode() throws {
        // Every prefix either decodes (libjpeg zero-fill semantics) or throws; never traps.
        let bytes = Resources.bytes("JPEG/cjpeg_odd97x61_prog.jpg")
        for n in stride(from: 0, to: bytes.count, by: 97) {
            _ = try? JPEGDecoder.decode(Array(bytes[0..<n]))
        }
    }

    static let soi: [UInt8] = [0xFF, 0xD8]
    static let eoi: [UInt8] = [0xFF, 0xD9]
    static let malformed: [(String, [UInt8])] = [
        ("no SOI", [0x00, 0x00]),
        ("SOS before SOF", soi + [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00] + eoi),
        ("lossless SOF3", soi + [0xFF, 0xC3, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00] + eoi),
        ("zero height", soi + [0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00] + eoi),
        ("bad sampling", soi + [0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x51, 0x00] + eoi),
        ("DHT oversubscribed", soi + [0xFF, 0xC4, 0x00, 0x16, 0x00, 3] + [UInt8](repeating: 0, count: 15) + [0, 1, 2] + eoi),
        ("segment length 1", soi + [0xFF, 0xFE, 0x00, 0x01] + eoi),
        ("unknown marker", soi + [0xFF, 0xC8, 0x00, 0x02] + eoi),
    ]

    @Test(arguments: malformed)
    func malformedStructureIsRejected(label: String, bytes: [UInt8]) {
        #expect(throws: ParseFailure.self, "\(label)") { try JPEGGrammar.file(ByteSlice(bytes)) }
    }
}

/// Differential: ImageIO (Apple's JPEG decoder; different IDCT/upsampling, so a
/// PSNR bound rather than exact equality) and EXIF orientation agreement.
@Suite struct JPEGDifferential {
    static let files = JPEGConformance.files.filter { !JPEGConformance.rejected.contains($0) }

    static func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var se = 0.0
        for i in 0..<a.count where i % 4 != 3 { let d = Double(Int(a[i]) - Int(b[i])); se += d * d }
        let mse = se / Double(a.count / 4 * 3)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    /// ImageIO converts CMYK through a colour profile; SignalSafe (like djpeg and
    /// Chromium without a profile) uses R = C·K/255 and matches djpeg bit-exactly.
    static let imageIODiffers: Set<String> = [
        "pillow_pil_sample_cmyk.jpg",
        "pillow_app13.jpg",          // 4x4 with 2x2 chroma: libjpeg box-upsamples (width ≤ 2), Apple interpolates
        "pillow_ultrahdr.jpg",       // ImageIO returns the gain-map HDR rendition, not the SDR base image
        "pillow_hopper_bad_exif.jpg", // corrupt entropy data: each decoder conceals errors differently
    ]

    /// Copy of a JPEG without APP2 segments (ICC profiles).
    static func withoutICC(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0xFF, 0xD8]
        var i = 2
        while i + 4 <= b.count, b[i] == 0xFF {
            let m = b[i + 1]
            if m == 0xDA || m == 0xD9 { break }
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            let end = min(b.count, i + 2 + len)
            if m != 0xE2 { out += b[i..<end] }
            i = end
        }
        return out + b[i...]
    }

    @Test(arguments: files)
    func matchesImageIO(name: String) throws {
        let bytes = Resources.bytes("JPEG/" + name)
        let file = try JPEGGrammar.file(ByteSlice(bytes))
        let ours = try JPEGDecoder.decodeRaw(file)
        // ImageIO colour-manages embedded ICC profiles; SignalSafe does not. Strip APP2 for the oracle.
        guard let ref = ImageIOOracle.frame(Self.withoutICC(bytes), index: 0) else { return }  // ImageIO refuses
        try #require(ref.width == ours.width && ref.height == ours.height, "\(name) size")
        let p = Self.psnr(ours.rgba, ref.rgba)
        #expect(p > 30 || Self.imageIODiffers.contains(name), "\(name): PSNR \(fixed(p, 1)) dB vs ImageIO")
    }

    @Test(arguments: files)
    func orientationMatchesImageIO(name: String) throws {
        let bytes = Resources.bytes("JPEG/" + name)
        let file = try JPEGGrammar.file(ByteSlice(bytes))
        #expect(file.orientation == ImageIOOracle.orientation(bytes), "\(name)")
    }

    @Test(arguments: ["Landscape", "Portrait"], 2...8)
    func orientedExamplesMatchTheUprightOne(kind: String, n: Int) throws {
        let upright = try JPEGDecoder.decode(Resources.bytes("JPEG/exif_\(kind)_1.jpg"))
        let other = try JPEGDecoder.decode(Resources.bytes("JPEG/exif_\(kind)_\(n).jpg"))
        try #require(other.width == upright.width && other.height == upright.height, "\(kind)_\(n) size")
        // Each example is a separately re-encoded rotation, so transposed orientations
        // (5-8) carry ~29 dB of block-grid re-encoding loss.
        #expect(Self.psnr(other.rgba, upright.rgba) > 28, "\(kind)_\(n)")
    }
}
