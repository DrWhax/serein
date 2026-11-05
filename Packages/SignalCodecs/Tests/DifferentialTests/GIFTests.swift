import Foundation
import Testing
import CodecCore
@testable import ImageGIF
import ImagePNG

/// Conformance: GIF test suite (Robert Ancell, CC-BY-SA), expected frames per test.
@Suite struct GIFConformance {
    struct Conf {
        var sections: [String: [String: String]] = [:]
        init(_ text: String) {
            var current = ""
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                if line.hasPrefix("[") { current = String(line.dropFirst().dropLast()); continue }
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { sections[current, default: [:]][parts[0]] = parts[1] }
            }
        }
        var config: [String: String] { sections["config"] ?? [:] }
        var frameNames: [String] {
            (config["frames"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    static let tests = Resources.text("GIFTestSuite/TESTS").split(separator: "\n").map(String.init).filter { !$0.isEmpty }

    static var limits: DecodeLimits {
        var l = DecodeLimits()
        l.maxDimension = 65_535  // max-width / max-height tests use the full u16 range
        return l
    }

    func expectedPixels(_ frame: [String: String]) -> [UInt8]? {
        if let rgba = frame["pixels"] { return Resources.bytes("GIFTestSuite/" + rgba) }
        if let png = frame["image"], let img = try? PNGDecoder.decode(Resources.bytes("GIFTestSuite/" + png)).stillImage { return img.rgba }
        return nil
    }

    /// Same pixel equality as the suite's own runner: fully transparent pixels match
    /// regardless of their colour channels.
    static func samePixels(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        for i in stride(from: 0, to: a.count, by: 4) where !(a[i + 3] == 0 && b[i + 3] == 0) {
            if a[i..<(i + 4)] != b[i..<(i + 4)] { return false }
        }
        return true
    }

    /// Spec violations SignalSafe rejects (the suite gives no reference image for them).
    static let mustReject: Set<String> = ["invalid-code", "invalid-colors", "overflow-codes", "overflow-codes-max",
                                          "zero-width", "zero-height", "zero-size",
                                          "max-size"]  // 65535x65535 exceeds DecodeLimits.maxPixels (upstream runner skips it too)

    @Test(arguments: tests)
    func matchesExpectedFrames(name: String) throws {
        let conf = Conf(Resources.text("GIFTestSuite/\(name).conf"))
        let input = conf.config["input"] ?? "\(name).gif"
        let bytes = Resources.bytes("GIFTestSuite/" + input)
        let expectedFrames = conf.frameNames

        if Self.mustReject.contains(name) {
            #expect(throws: ParseFailure.self, "\(name) must be rejected") {
                _ = try GIFDecoder.composite(try GIFGrammar.file(ByteSlice(bytes), limits: Self.limits), limits: Self.limits)
            }
            return
        }
        let file = try GIFGrammar.file(ByteSlice(bytes), limits: Self.limits)
        let anim = try GIFDecoder.composite(file, limits: Self.limits)
        guard !expectedFrames.isEmpty else { return }  // suite has no reference (e.g. plain-text)

        #expect(anim.width == Int(conf.config["width"] ?? "") && anim.height == Int(conf.config["height"] ?? ""))
        if conf.config["force-animation"] != "yes" {
            switch conf.config["loop-count"] {
            case "infinite": #expect(file.loopCount == 0, "\(name) loop")
            case "0", nil: #expect(file.loopCount == nil, "\(name) loop")
            case let n?: #expect(file.loopCount == Int(n), "\(name) loop")
            }
        }

        // Final displayed canvas must equal the last reference frame (the suite runner's check).
        let lastSection = conf.sections[expectedFrames.last!] ?? [:]
        let lastExpected = try #require(expectedPixels(lastSection), "\(name): no reference")
        #expect(Self.samePixels(anim.frames.last!.image.rgba, lastExpected), "\(name) final frame")

        // Where the suite's frame grouping is one image per frame, every frame must match.
        if anim.frames.count == expectedFrames.count {
            for (i, frameName) in expectedFrames.enumerated() {
                let section = conf.sections[frameName] ?? [:]
                guard let expected = expectedPixels(section) else { continue }
                #expect(Self.samePixels(anim.frames[i].image.rgba, expected), "\(name) frame \(i)")
                if let delay = section["delay"] {
                    #expect(anim.frames[i].delayMilliseconds == Int(delay)! * 10, "\(name) frame \(i) delay")
                }
            }
        }
    }
}

/// Differential: ImageIO on the GIF test suite and Pillow's GIF corpus.
///
/// ImageIO composites differently from browsers (it paints the background colour,
/// draws images without a Graphic Control Extension stand-alone, and crops a lone
/// image to its own rectangle). Compositing is covered by `GIFConformance`; here we
/// compare what both decoders must agree on per spec: every opaque pixel each image
/// paints (LZW, colour table, interlacing, placement and clipping).
@Suite struct GIFDifferential {
    static let files = Resources.files("GIFTestSuite") { $0.hasSuffix(".gif") }.map { "GIFTestSuite/" + $0 }
        + Resources.files("Pillow") { $0.hasSuffix(".gif") }.map { "Pillow/" + $0 }

    /// Files we reject on purpose; ImageIO repairs them (see GIFGrammar policy).
    static let rejectedByPolicy: Set<String> = ["GIFTestSuite/invalid-code.gif", "GIFTestSuite/invalid-colors.gif"]

    @Test(arguments: files)
    func paintedPixelsMatchImageIO(path: String) throws {
        let bytes = Resources.bytes(path)
        guard let file = try? GIFGrammar.file(ByteSlice(bytes)) else {
            #expect(Self.rejectedByPolicy.contains(path) || ImageIOOracle.frame(bytes, index: 0) == nil,
                    "\(path): rejected by us, decoded by ImageIO")
            return
        }
        if Self.rejectedByPolicy.contains(path) {
            #expect(throws: ParseFailure.self) { try GIFDecoder.composite(file) }
            return
        }
        let anim = try GIFDecoder.composite(file)
        let count = min(ImageIOOracle.frameCount(bytes), file.images.count, 16)
        var checked = 0
        for i in 0..<count {
            let image = file.images[i]
            guard let ref = ImageIOOracle.frame(bytes, index: i),
                  let palette = image.localPalette ?? file.globalPalette else { continue }
            // Lone image cropped to its rectangle by ImageIO.
            let (ox, oy) = (ref.width == file.width && ref.height == file.height) ? (0, 0) : (image.left, image.top)
            let indices = try GIFDecoder.lzw(image, rule: "lzw")
            let rows = GIFDecoder.rowOrder(height: image.height, interlaced: image.interlaced)
            let transparent = image.control?.transparentIndex.map(Int.init) ?? -1
            for (srcRow, dstRow) in rows.enumerated() {
                for x in 0..<image.width {
                    let n = srcRow * image.width + x
                    guard n < indices.count, Int(indices[n]) != transparent, Int(indices[n]) < palette.count else { continue }
                    let cx = image.left + x, cy = image.top + dstRow
                    guard cx < file.width, cy < file.height else { continue }
                    let rx = cx - ox, ry = cy - oy
                    guard rx >= 0, ry >= 0, rx < ref.width, ry < ref.height else { continue }
                    let ours = anim.frames[i].image.pixel(x: cx, y: cy)
                    let r = (ry * ref.width + rx) * 4
                    let theirs = Array(ref.rgba[r..<(r + 4)])
                    #expect([ours.r, ours.g, ours.b, ours.a] == theirs, "\(path) frame \(i) pixel \(cx),\(cy)")
                    checked += 1
                    if checked > 200_000 { return }
                }
            }
        }
    }
}
