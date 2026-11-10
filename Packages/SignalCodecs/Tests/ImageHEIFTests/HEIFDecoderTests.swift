// HEIF / AVIF / HEIC images (Tools/gen-heif-fixtures.sh): composed planes bit-exact against
// avifdec (AVIF) and ffmpeg (HEIC), RGBA against avifdec's PNG (irot / imir / clap applied)
// within a conversion tolerance, the codec gate, and malformed files.

import CodecCore
import ContainerMP4
import CryptoKit
import Foundation
import ImagePNG
import Testing
@testable import ImageHEIF

enum HEIFFixture {
    static let directory = Bundle.module.url(forResource: "Resources", withExtension: nil)!
    static func bytes(_ name: String) throws -> [UInt8] { Array(try Data(contentsOf: directory.appendingPathComponent(name))) }
    /// name → (MD5 of the decoded planes, whether the alpha plane is part of it).
    static var goldens: [String: (md5: String, alpha: Bool)] {
        let text = (try? String(contentsOf: directory.appendingPathComponent("fixtures.txt"), encoding: .utf8)) ?? ""
        var out: [String: (md5: String, alpha: Bool)] = [:]
        for line in text.split(separator: "\n") {
            let p = line.split(separator: " ")
            if p.count == 3 { out[String(p[0])] = (String(p[1]), p[2] == "1") }
        }
        return out
    }
}

func md5Hex(_ bytes: [UInt8]) -> String {
    Insecure.MD5.hash(data: bytes).map { let s = String($0, radix: 16); return s.count == 1 ? "0" + s : s }.joined()
}

/// The primary item's planes (and alpha), before conversion and geometry.
func decodedPlanes(_ bytes: [UInt8], codec: HEIFCodec) throws -> (HEIFPlanes, HEIFPlanes?) {
    let file = try HEIFParser.parse(bytes)
    let primary = try #require(file.item(file.primaryItemID))
    let colour = try HEIFDecoder.planes(of: primary, in: file, codec: codec, limits: .default, depth: 0)
    var alpha: HEIFPlanes? = nil
    for id in file.referrers("auxl", to: primary.id) {
        if let a = file.item(id), let urn = a.auxiliaryType, HEIFDecoder.alphaURNs.contains(urn) {
            alpha = try HEIFDecoder.planes(of: a, in: file, codec: codec, limits: .default, depth: 0)
        }
    }
    return (colour, alpha)
}

func planeBytes(_ planes: [[UInt16]], bitDepth: Int) -> [UInt8] {
    var out: [UInt8] = []
    for p in planes {
        for s in p {
            if bitDepth == 8 { out.append(UInt8(s)) } else { out.append(UInt8(s & 0xFF)); out.append(UInt8(s >> 8)) }
        }
    }
    return out
}

@Suite struct HEIFDecoderTests {
    static let avifNames = ["avif8", "avif10", "avif444", "avif400", "avifgrid", "avifgrid444", "avifalpha", "avifprem", "avifgridalpha",
                            "avifrot", "avifmir0", "avifmir1", "avifclap"]

    @Test(arguments: avifNames) func avifPlanesBitExact(_ name: String) throws {
        let want = try #require(HEIFFixture.goldens[name])
        let (c, a) = try decodedPlanes(try HEIFFixture.bytes("\(name).avif"), codec: .av1)
        var planes = c.chromaFormat == 0 ? [c.y] : [c.y, c.u, c.v]
        if want.alpha {
            let alpha = try #require(a)
            planes.append(alpha.y)
        }
        #expect(md5Hex(planeBytes(planes, bitDepth: c.bitDepth)) == want.md5, "\(name) \(c.width)x\(c.height) format \(c.chromaFormat) alpha \(a != nil)")
    }

    @Test(arguments: ["heicgrid", "heicalpha"]) func heicPlanesBitExact(_ name: String) throws {
        let want = try #require(HEIFFixture.goldens[name])
        let (c, a) = try decodedPlanes(try HEIFFixture.bytes("\(name).heic"), codec: .hevc)
        #expect(c.chromaFormat == 1 && c.bitDepth == 8)
        #expect(md5Hex(planeBytes([c.y, c.u, c.v], bitDepth: 8)) == want.md5, "\(name) \(c.width)x\(c.height)")
        if name == "heicalpha" { #expect(a != nil, "alpha auxiliary item") }
    }

    /// RGBA against libavif's own conversion (avifdec's PNG, geometry applied): YUV → RGB is
    /// not normative, so a small difference per channel is allowed.
    @Test(arguments: avifNames) func avifRGBAMatchesLibavif(_ name: String) throws {
        let image = try HEIFDecoder.decode(try HEIFFixture.bytes("\(name).avif"), codecs: [.av1]).image
        let r = try PNGDecoder.decode(try HEIFFixture.bytes("\(name).ref.png")).stillImage
        #expect(image.width == r.width && image.height == r.height, "\(name): \(image.width)x\(image.height) vs \(r.width)x\(r.height)")
        guard image.width == r.width, image.height == r.height else { return }
        var maxDiff = 0, sum = 0
        for i in 0..<(image.width * image.height) {
            let a = Int(r.rgba[i * 4 + 3])
            for c in 0..<4 {
                // Colour under (nearly) transparent alpha is not meaningful.
                if c < 3 && a < 16 { continue }
                let d = abs(Int(image.rgba[i * 4 + c]) - Int(r.rgba[i * 4 + c]))
                maxDiff = max(maxDiff, d)
                sum += d
            }
        }
        let mean = Double(sum) / Double(image.width * image.height * 4)
        #expect(maxDiff <= 8 && mean < 1.0, "\(name): max \(maxDiff), mean \(mean)")
    }

    @Test func codecGate() throws {
        #expect(throws: ParseFailure.self) { try HEIFDecoder.decode(try HEIFFixture.bytes("heicgrid.heic"), codecs: [.av1]) }
        #expect(throws: ParseFailure.self) { try HEIFDecoder.decode(try HEIFFixture.bytes("avif8.avif"), codecs: [.hevc]) }
        #expect(HEIFDecoder.primaryCodec(try HEIFFixture.bytes("heicgrid.heic")) == .hevc)
        #expect(HEIFDecoder.primaryCodec(try HEIFFixture.bytes("avifgrid.avif")) == .av1)
    }

    @Test func heicDecodesWithGeometryAndAlpha() throws {
        let grid = try HEIFDecoder.decode(try HEIFFixture.bytes("heicgrid.heic"), codecs: [.hevc])
        #expect(grid.image.width == 700 && grid.image.height == 450 && !grid.hasAlpha)
        let alpha = try HEIFDecoder.decode(try HEIFFixture.bytes("heicalpha.heic"), codecs: [.hevc])
        #expect(alpha.hasAlpha)
        // The source's alpha ramps from 0 (left) to 255 (right).
        let w = alpha.image.width
        #expect(alpha.image.rgba[3] < 16 && alpha.image.rgba[(w - 1) * 4 + 3] > 240)
    }

    @Test(arguments: ["avifgridalpha.avif", "heicgrid.heic", "avif10.avif"]) func malformedFilesFailCleanly(_ name: String) throws {
        let full = try HEIFFixture.bytes(name)
        let codecs: Set<HEIFCodec> = [.av1, .hevc]
        for cut in stride(from: 0, to: full.count, by: max(1, full.count / 150)) {
            _ = try? HEIFDecoder.decode(Array(full.prefix(cut)), codecs: codecs)
        }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<150 {
            var b = full
            for _ in 0..<3 {
                // Bias towards the box structure at the front of the file.
                let i = Int.random(in: 0..<min(b.count, 1200), using: &rng)
                b[i] = UInt8.random(in: 0...255, using: &rng)
            }
            _ = try? HEIFDecoder.decode(b, codecs: codecs)
        }
    }
}

/// Timing aid: HEIF_TIME=<comma-separated files> decodes each one and prints how long it took.
@Test func timeDecodes() throws {
    guard let list = ProcessInfo.processInfo.environment["HEIF_TIME"] else { return }
    for path in list.split(separator: ",") {
        let bytes = Array(try Data(contentsOf: URL(fileURLWithPath: String(path))))
        let clock = ContinuousClock()
        var size = (0, 0)
        let t = try clock.measure {
            let img = try HEIFDecoder.decode(bytes, codecs: [.av1, .hevc])
            size = (img.image.width, img.image.height)
        }
        print("TIME \(path.split(separator: "/").last ?? "") \(size.0)x\(size.1): \(t)")
    }
}
