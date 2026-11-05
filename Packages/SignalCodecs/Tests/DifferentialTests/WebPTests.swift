import Foundation
import Testing
import CodecCore
@testable import ImageWebP

/// Conformance: stills bit-exact with libwebp 1.6.0 `dwebp -pam` (References/dwebp.json);
/// animations frame-exact with libwebp's WebPAnimDecoder via Pillow (References/webp-anim.json).
@Suite struct WebPConformance {
    struct Still: Decodable, Sendable { var width: Int; var height: Int; var rgbaMD5: String }
    struct Frame: Decodable, Sendable { var md5: String; var duration: Int? }
    /// mode "RGB": the reference only carries RGB (Pillow reads alpha-less canvases as RGBX).
    struct Anim: Decodable, Sendable { var width: Int; var height: Int; var loop: Int?; var mode: String; var frames: [Frame] }
    static let stills: [String: Still?] = try! JSONDecoder().decode([String: Still?].self, from: Data(Resources.bytes("References/dwebp.json")))
    static let anims: [String: Anim] = try! JSONDecoder().decode([String: Anim].self, from: Data(Resources.bytes("References/webp-anim.json")))
    static let stillFiles = stills.filter { $0.value != nil }.keys.sorted()
    static let animFiles = anims.keys.sorted()

    @Test(arguments: stillFiles)
    func stillMatchesDwebp(name: String) throws {
        let ref = Self.stills[name]!!
        let img = try WebPDecoder.decode(Resources.bytes("WebP/" + name)).stillImage
        try #require(img.width == ref.width && img.height == ref.height, "\(name) size \(img.width)x\(img.height)")
        let ok = md5Hex(img.rgba) == ref.rgbaMD5
        #expect(ok, "\(name): RGBA differs from dwebp")
    }

    @Test(arguments: animFiles)
    func animationMatchesLibwebp(name: String) throws {
        let ref = Self.anims[name]!
        let file = try WebPGrammar.file(ByteSlice(Resources.bytes("WebP/" + name)))
        let anim = try WebPDecoder.composite(file)
        try #require(anim.width == ref.width && anim.height == ref.height)
        try #require(anim.frames.count == ref.frames.count, "\(name): \(anim.frames.count) frames, expected \(ref.frames.count)")
        #expect(anim.loopCount == ref.loop ?? 0, "\(name) loop")
        for (i, f) in ref.frames.enumerated() {
            let px = anim.frames[i].image.rgba
            let bytes = ref.mode == "RGB" ? stride(from: 0, to: px.count, by: 4).flatMap { px[$0..<($0 + 3)] } : px
            let ok = md5Hex(bytes) == f.md5
            #expect(ok, "\(name) frame \(i)")
            if let d = f.duration { #expect(anim.frames[i].delayMilliseconds == d, "\(name) frame \(i) duration") }
        }
    }

    @Test func everyTruncationOfALossyAndALosslessFileFailsCleanly() {
        for name in ["test.webp", "lossless1.webp", "lossy_alpha1.webp"] {
            let bytes = Resources.bytes("WebP/" + name)
            for n in stride(from: 0, to: bytes.count, by: max(1, bytes.count / 97)) {
                _ = try? WebPDecoder.decode(Array(bytes[0..<n]))  // must not trap
            }
        }
    }
}

/// Differential: ImageIO (Apple's WebP decoder) on stills and composited animation frames.
@Suite struct WebPDifferential {
    static let files = Resources.files("WebP") { $0.hasSuffix(".webp") }
    /// Files Apple renders differently from libwebp (whose output, matched bit-exactly in
    /// WebPConformance, is what Chromium shows):
    ///  * gif2webp_high-color_*: ImageIO paints canvas areas no frame has covered opaque
    ///    (ANIM background colour); libwebp leaves them transparent (the colour is only a hint);
    ///  * bad_palette_index: libwebp decodes out-of-range palette indices as transparent black.
    static let imageIODiffers: Set<String> = [
        "gif2webp_high-color_lossless.webp", "gif2webp_high-color_lossy.webp", "gif2webp_high-color_mixed.webp",
        "bad_palette_index.webp",
    ]

    @Test(arguments: files)
    func matchesImageIO(name: String) throws {
        let bytes = Resources.bytes("WebP/" + name)
        guard let decoded = try? WebPDecoder.decode(bytes) else { return }  // conformance covers rejection
        let count = ImageIOOracle.frameCount(bytes)
        guard count > 0 else { return }
        let ours: [PixelBuffer]
        switch decoded {
        case .still(let p): ours = [p]
        case .animated(let a, _): ours = a.frames.map(\.image)
        }
        for i in 0..<min(count, ours.count, 6) {
            guard let ref = ImageIOOracle.frame(bytes, index: i) else { continue }
            try #require(ref.width == ours[i].width && ref.height == ours[i].height, "\(name) size")
            // Lossy: Apple's YUV→RGB/upsampling differ slightly from libwebp's.
            let d = compare(premultiplied(ours[i]), ref.rgba, tolerance: 4)
            let ok = Double(d.samplesOverTolerance) / Double(ref.rgba.count) < 0.01 && d.meanError < 1.5
            #expect(ok || Self.imageIODiffers.contains(name), "\(name) frame \(i): \(d)")
        }
    }
}
