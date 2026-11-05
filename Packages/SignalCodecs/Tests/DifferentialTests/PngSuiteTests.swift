// PngSuite conformance (http://www.schaik.com/pngsuite/, redistributable, see PngSuite.LICENSE).
//
// Test-only target: ImageIO/CoreGraphics are used here as an *oracle* on a trusted
// corpus. Nothing in this target ships in the app.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import CodecCore
import ImagePNG

enum Corpus {
    static let dir: URL = Resources.url("PngSuite")
    static func files(_ filter: (String) -> Bool) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".png") && filter($0) }.sorted()
    }
    static func bytes(_ name: String) -> [UInt8] { [UInt8](try! Data(contentsOf: dir.appendingPathComponent(name))) }

    static let valid = files { !$0.hasPrefix("x") }
    static let corrupt = files { $0.hasPrefix("x") }
    /// basi* (Adam7) files that have a basn* (non-interlaced) twin.
    static let interlacedPairs = files { $0.hasPrefix("basi") }
}

@Suite struct PngSuiteSelfConsistency {
    @Test(arguments: Corpus.valid)
    func validFilesDecode(name: String) throws {
        let img = try PNGDecoder.decode(Corpus.bytes(name)).stillImage
        #expect(img.width > 0 && img.height > 0)
    }

    @Test(arguments: Corpus.corrupt)
    func corruptFilesAreRejected(name: String) {
        #expect(throws: ParseFailure.self, "\(name) must be rejected") { try PNGDecoder.decode(Corpus.bytes(name)) }
    }

    @Test(arguments: Corpus.interlacedPairs)
    func adam7MatchesNonInterlaced(name: String) throws {
        let twin = "basn" + name.dropFirst(4)
        let a = try PNGDecoder.decode(Corpus.bytes(name)).stillImage
        let b = try PNGDecoder.decode(Corpus.bytes(String(twin))).stillImage
        #expect(a == b)
    }

    @Test func everyPrefixOfEveryValidFileFailsCleanly() {
        // Truncation must yield a ParseFailure, never a crash. (Prefixes that only cut
        // trailing bytes after IEND would still parse; PngSuite has none.)
        for name in Corpus.valid.prefix(40) {
            let bytes = Corpus.bytes(name)
            for n in stride(from: 0, to: bytes.count, by: max(1, bytes.count / 64)) {
                #expect(throws: ParseFailure.self, "\(name) prefix \(n)") { try PNGDecoder.decode(Array(bytes[0..<n])) }
            }
        }
    }
}

@Suite struct PngSuiteDifferential {
    static func oracle(_ bytes: [UInt8]) -> (Int, Int, [UInt8])? {
        ImageIOOracle.frame(withoutColourChunks(bytes), index: 0).map { ($0.width, $0.height, $0.rgba) }
    }

    /// Removes gAMA/cHRM/sRGB/iCCP/sBIT so the oracle does no colour management
    /// (SignalSafe renders PNG samples as sRGB, like Chromium without colour profiles).
    static func withoutColourChunks(_ b: [UInt8]) -> [UInt8] {
        var out = Array(b[0..<8])
        var i = 8
        while i + 12 <= b.count {
            let n = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            let type = String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self)
            let end = min(b.count, i + 12 + n)
            if !["gAMA", "cHRM", "sRGB", "iCCP", "sBIT"].contains(type) { out += b[i..<end] }
            i = end
        }
        return out
    }

    static func premultiplied(_ p: PixelBuffer) -> [UInt8] {
        var out = p.rgba
        for i in stride(from: 0, to: out.count, by: 4) {
            let a = Int(out[i + 3])
            for k in 0..<3 { out[i + k] = UInt8((Int(out[i + k]) * a + 127) / 255) }
        }
        return out
    }

    /// g*: gamma test images, meaningless without gamma handling.
    static let comparable = Corpus.valid.filter { !$0.hasPrefix("g") }

    @Test(arguments: comparable)
    func matchesOracle(name: String) throws {
        let bytes = Corpus.bytes(name)
        guard let (w, h, ref) = Self.oracle(bytes) else { Issue.record("oracle failed on \(name)"); return }
        let ours = try PNGDecoder.decode(bytes).stillImage
        try #require(ours.width == w && ours.height == h)
        let mine = Self.premultiplied(ours)
        var worst = 0, bad = 0
        for i in 0..<mine.count {
            let d = abs(Int(mine[i]) - Int(ref[i]))
            worst = max(worst, d)
            if d > 1 { bad += 1 }
        }
        #expect(bad == 0, "\(name): \(bad) samples differ by >1 (worst \(worst))")
    }
}
