import Foundation
import Testing
import CodecCore
import ImageBMP
import ImagePNG

/// Conformance: BMP Suite 2.8 (Jason Summers). g/ must match the reference exactly;
/// q/ must match one of its references or be on the documented rejection list;
/// b/ must be rejected.
@Suite struct BMPConformance {
    static let references: [String: [String]] = try! JSONDecoder().decode(
        [String: [String]].self, from: Data(Resources.bytes("BMPSuite/references.json")))
    static let good = references.keys.filter { $0.hasPrefix("g/") }.sorted()
    static let questionable = references.keys.filter { $0.hasPrefix("q/") }.sorted()
    static let bad = references.keys.filter { $0.hasPrefix("b/") }.sorted()

    /// q/ features SignalSafe rejects on purpose (see DIBGrammar policy).
    static let rejected: Set<String> = [
        "q/rgb24jpeg.bmp", "q/rgb24png.bmp",          // embedded JPEG / PNG
        "q/rgb24rle24.bmp", "q/pal1huffmsb.bmp",      // OS/2 RLE24, Huffman 1D
        "q/rgba64.bmp",                               // 64-bit linear-light
    ]
    /// b/ files whose defect is in a field browsers ignore (density, file size, image size).
    static let renderedDespiteDefect: Set<String> = ["b/rgb16-880.bmp", "b/baddens1.bmp", "b/baddens2.bmp",
                                                     "b/badfilesize.bmp", "b/badbitssize.bmp"]
    /// Rendering depends on the embedded ICC profile; SignalSafe does no colour management.
    static let iccDependent: Set<String> = ["q/rgb24prof2.bmp"]

    /// Equality that ignores the colour of fully transparent pixels. For bitfield
    /// images with non-standard masks the suite's reference is an independent 8-bit
    /// quantisation of the same continuous colours, so ±1 is inherent there.
    static func sameImage(_ a: PixelBuffer, _ b: PixelBuffer, tolerance: Int = 0) -> Bool {
        guard a.width == b.width && a.height == b.height else { return false }
        return compare(premultiplied(a), premultiplied(b), tolerance: tolerance).samplesOverTolerance == 0
    }

    static let standardMasks: [DIBMasks] = [
        DIBMasks(r: 0x7C00, g: 0x03E0, b: 0x001F, a: 0), DIBMasks(r: 0xF800, g: 0x07E0, b: 0x001F, a: 0),
        DIBMasks(r: 0xFF_0000, g: 0xFF00, b: 0xFF, a: 0), DIBMasks(r: 0xFF_0000, g: 0xFF00, b: 0xFF, a: 0xFF00_0000),
    ]
    static func tolerance(_ bytes: [UInt8]) -> Int {
        guard let d = try? DIBGrammar.bmp(ByteSlice(bytes)), let m = d.masks else { return 0 }
        return standardMasks.contains(m) ? 0 : 1
    }

    func reference(_ png: String) throws -> PixelBuffer {
        try PNGDecoder.decode(Resources.bytes("BMPSuite/html/" + png)).stillImage
    }

    @Test(arguments: good)
    func goodFilesMatchReference(path: String) throws {
        let img = try BMPDecoder.decode(Resources.bytes("BMPSuite/" + path))
        let refs = try Self.references[path]!.map(reference)
        let ok = refs.contains { Self.sameImage(img, $0) }
        #expect(ok, "\(path): \(refs.map { mismatch(img, $0) })")
    }

    @Test(arguments: questionable)
    func questionableFilesMatchAReferenceOrAreRejected(path: String) throws {
        let bytes = Resources.bytes("BMPSuite/" + path)
        if Self.rejected.contains(path) {
            #expect(throws: ParseFailure.self, "\(path) is on the rejection list") { try BMPDecoder.decode(bytes) }
            return
        }
        let img = try BMPDecoder.decode(bytes)
        if Self.iccDependent.contains(path) { return }
        let names = Self.references[path]!.filter { $0.hasSuffix(".png") }
        let refs = try names.map(reference)
        let t = Self.tolerance(bytes)
        let ok = refs.contains { Self.sameImage(img, $0, tolerance: t) }
        #expect(ok, "\(path): \(refs.map { mismatch(img, $0) })")
    }

    @Test(arguments: bad)
    func badFilesAreRejected(path: String) throws {
        let bytes = Resources.bytes("BMPSuite/" + path)
        if Self.renderedDespiteDefect.contains(path) {
            _ = try BMPDecoder.decode(bytes)
            return
        }
        #expect(throws: ParseFailure.self, "\(path) must be rejected") { try BMPDecoder.decode(bytes) }
    }
}

/// Differential: ImageIO on every BMP both decoders accept.
///
/// Known ImageIO deviations, each handled explicitly:
///  * low-depth bitfield channels are bit-shifted instead of rescaled (≤ 256>>bits error);
///  * pixels skipped by RLE deltas/early end are filled instead of left transparent;
///  * OS/2 2.x headers are misread (our output matches the BMP Suite reference).
@Suite struct BMPDifferential {
    static let files = BMPConformance.references.keys.filter { $0.hasPrefix("g/") || $0.hasPrefix("q/") }.sorted()
    static let imageIOMisreads: Set<String> = [
        "q/pal8os2sp.bmp", "q/pal8os2v2-16.bmp",                              // OS/2 2.x headers
        "g/rgb16bfdef.bmp",                                                   // BITFIELDS carrying the default 5-5-5 masks
        "q/rgba16-1924.bmp", "q/rgba16-4444.bmp", "q/rgba16-5551.bmp",        // ignores 16-bit alpha masks
    ]

    @Test(arguments: files)
    func matchesImageIO(path: String) throws {
        let bytes = Resources.bytes("BMPSuite/" + path)
        guard let dib = try? DIBGrammar.bmp(ByteSlice(bytes)), let ours = try? BMPDecoder.decode(bytes) else { return }
        guard let ref = ImageIOOracle.frame(bytes, index: 0) else { return }  // ImageIO refuses; we follow the suite
        if Self.imageIOMisreads.contains(path) || BMPConformance.iccDependent.contains(path) { return }
        try #require(ref.width == ours.width && ref.height == ours.height, "\(path) size")

        var tolerance = 1
        let defaultMasks: DIBMasks? = dib.bitsPerPixel == 16 ? DIBMasks(r: 0x7C00, g: 0x03E0, b: 0x1F, a: 0) : nil
        if let m = dib.masks ?? defaultMasks {
            let widths: [Int] = [m.r, m.g, m.b, m.a].filter { $0 != 0 }.map { $0.nonzeroBitCount }
            let narrowest: Int = widths.min() ?? 8
            if narrowest < 8 { tolerance = max(tolerance, 256 >> narrowest) }
            if m.a != 0 { tolerance *= 2 }  // alpha error compounds through premultiplication
        }
        let mine = premultiplied(ours)
        var bad = 0, worst = 0
        for i in stride(from: 0, to: mine.count, by: 4) {
            if (dib.compression == .rle4 || dib.compression == .rle8) && ours.rgba[i + 3] == 0 { continue }
            for k in 0..<4 {
                let e = abs(Int(mine[i + k]) - Int(ref.rgba[i + k]))
                worst = max(worst, e)
                if e > tolerance { bad += 1 }
            }
        }
        #expect(bad == 0, "\(path): \(bad) samples over tolerance \(tolerance), worst \(worst)")
    }
}

/// ICO: conformance against Pillow's renderings, differential against ImageIO.
@Suite struct ICOTests {
    static let files = Resources.files("Pillow") { $0.hasSuffix(".ico") || $0.hasSuffix(".cur") }
    static let pillowRefs = Set(Resources.files("References/Pillow"))

    @Test(arguments: files)
    func matchesPillow(name: String) throws {
        let bytes = Resources.bytes("Pillow/" + name)
        guard Self.pillowRefs.contains(name + ".png") else {
            #expect(throws: ParseFailure.self, "\(name): Pillow rejects it, so must we") { try ICODecoder.decode(bytes) }
            return
        }
        let ours = try ICODecoder.decode(bytes)
        let ref = try PNGDecoder.decode(Resources.bytes("References/Pillow/\(name).png")).stillImage
        try #require(ours.width == ref.width && ours.height == ref.height, "\(name) size \(ours.width)x\(ours.height) vs \(ref.width)x\(ref.height)")
        // Compare premultiplied: colour under a fully transparent pixel is irrelevant.
        let d = compare(premultiplied(ours), premultiplied(ref), tolerance: 0)
        #expect(d.samplesOverTolerance == 0, "\(name): \(d)")
    }

    @Test(arguments: files)
    func matchesImageIO(name: String) throws {
        let bytes = Resources.bytes("Pillow/" + name)
        guard let ours = try? ICODecoder.decode(bytes) else { return }
        // ImageIO exposes every entry as a frame; compare with the one of our size.
        let frames = (0..<ImageIOOracle.frameCount(bytes)).compactMap { ImageIOOracle.frame(bytes, index: $0) }
        if frames.isEmpty || Self.imageIOUsesDirectorySize.contains(name) { return }  // ImageIO decodes nothing / sizes from the directory
        guard let ref = frames.last(where: { $0.width == ours.width && $0.height == ours.height }) else {
            Issue.record("\(name): ImageIO has no \(ours.width)x\(ours.height) frame (\(frames.map { "\($0.width)x\($0.height)" }))")
            return
        }
        let d = compare(premultiplied(ours), ref.rgba, tolerance: 1)
        #expect(d.samplesOverTolerance == 0, "\(name): \(d)")
    }

    /// The DIB header disagrees with the directory entry; ImageIO trusts the directory,
    /// Pillow and SignalSafe trust the DIB.
    static let imageIOUsesDirectorySize: Set<String> = ["hopper_unexpected.ico"]

    /// ImageIO exposes every entry as a frame; pick the one our decoder chooses.
    static func largestIndex(_ bytes: [UInt8]) -> Int {
        guard let entries = try? ICOGrammar.file(ByteSlice(bytes)) else { return 0 }
        let best = entries.indices.max { (entries[$0].width * entries[$0].height, entries[$0].bitCount) < (entries[$1].width * entries[$1].height, entries[$1].bitCount) }!
        return best
    }
}

/// XBM: conformance against Pillow (inverted to X11 semantics). ImageIO has no XBM
/// decoder, so the differential decodes Pillow's PNG rendering of each XBM with ImageIO.
@Suite struct XBMTests {
    static let files = Resources.files("Pillow") { $0.hasSuffix(".xbm") }

    @Test(arguments: files)
    func matchesPillow(name: String) throws {
        let ours = try XBMDecoder.decode(Resources.bytes("Pillow/" + name))
        let ref = try PNGDecoder.decode(Resources.bytes("References/Pillow/\(name).png")).stillImage
        let ok = ours == ref
        #expect(ok, "\(name): \(mismatch(ours, ref))")
    }

    @Test(arguments: files)
    func matchesImageIODecodeOfReferenceRendering(name: String) throws {
        let ours = try XBMDecoder.decode(Resources.bytes("Pillow/" + name))
        let ref = try #require(ImageIOOracle.frame(Resources.bytes("References/Pillow/\(name).png"), index: 0))
        let ok = premultiplied(ours) == ref.rgba
        #expect(ok, "\(name)")
    }

    @Test func x10ShortFormatAndHotspot() throws {
        let src = "/* x10 */\n#define t_width 3\n#define t_height 2\n#define t_x_hot 1\n#define t_y_hot 0\nstatic short t_bits[] = { 0x0005, 0x0002 };"
        let img = try XBMDecoder.decode(Array(src.utf8))
        #expect(img.width == 3 && img.height == 2)
        #expect(img.rgba.enumerated().filter { $0.offset % 4 == 0 }.map(\.element) == [0, 255, 0, 255, 0, 255])
    }

    @Test(arguments: [
        "#define a_width 8\n#define a_height 1\nstatic char a_bits[] = { 0x01, 0x02 };",   // too many values
        "#define a_width 8\n#define a_height 2\nstatic char a_bits[] = { 0x01 };",         // too few
        "#define a_width 8\n#define a_height 1\nstatic char a_bits[] = { 0x100 };",        // value too wide
        "#define a_width 8\n#define a_height 1\nstatic char a_bits[] = { 0x01 } junk",     // trailing tokens
        "#define a_width 8\nstatic char a_bits[] = { 0x01 };",                             // missing height
        "#define a_width 8\n#define a_height 1\nstatic char a_bits[] = { 0x01 }; /* open",
        "#define a_width 8\n#define a_height 1\nstatic char a_bits[] = { 1z };",
    ])
    func malformedSourcesAreRejected(src: String) {
        #expect(throws: ParseFailure.self) { try XBMDecoder.decode(Array(src.utf8)) }
    }
}
