// Key frames decoded by VideoAV1, bit-exact against dav1d (Tools/gen-av1-fixtures.sh; the
// goldens are cross-checked against aomdec when the fixtures are generated).

import CodecCore
import CryptoKit
import Foundation
import Testing
@testable import VideoAV1

enum AV1Fixture {
    static let directory = Bundle.module.url(forResource: "Resources", withExtension: nil)!

    static var goldens: [String: String] {
        let text = (try? String(contentsOf: directory.appendingPathComponent("fixtures.txt"), encoding: .utf8)) ?? ""
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2 { out[String(parts[0])] = String(parts[1]) }
        }
        return out
    }

    static func stream(_ name: String) throws -> [UInt8] { Array(try Data(contentsOf: directory.appendingPathComponent("\(name).obu"))) }
}

/// The raw layout dav1d writes: Y, then U and V (none for 4:0:0), 16-bit LE above 8 bits.
func rawBytes(_ f: AV1Frame) -> [UInt8] {
    var bytes: [UInt8] = []
    for plane in f.monochrome ? [f.y] : [f.y, f.u, f.v] {
        for s in plane {
            if f.bitDepth == 8 { bytes.append(UInt8(s)) } else { bytes.append(UInt8(s & 0xFF)); bytes.append(UInt8(s >> 8)) }
        }
    }
    return bytes
}

func md5Hex(_ bytes: [UInt8]) -> String {
    Insecure.MD5.hash(data: bytes).map { let s = String($0, radix: 16); return s.count == 1 ? "0" + s : s }.joined()
}

@Suite struct AV1DecoderTests {
    static let names = ["basic8", "odd8", "big8", "sb128", "tiles8", "ten420", "i444", "ten444", "mono", "lossless", "qm", "screen",
                        "screen444", "palette10", "nocdef", "restoration", "superres", "grain", "grain10", "grain444", "deltaq",
                        "segments", "fullhdr", "highq", "lowq", "goodcdef", "goodaq", "deltalf", "cdef8", "svt", "svtscreen", "svtgrain"]

    @Test(arguments: names) func bitExact(_ name: String) throws {
        let want = try #require(AV1Fixture.goldens[name])
        let frame = try AV1Decoder.decodeStill(ByteSlice(try AV1Fixture.stream(name)))
        let bytes = rawBytes(frame)
        if let dir = ProcessInfo.processInfo.environment["AV1_DUMP"] {
            try Data(bytes).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).yuv"))
        }
        #expect(md5Hex(bytes) == want, "\(name) \(frame.width)x\(frame.height) \(frame.bitDepth)-bit")
    }

    @Test func truncatedStreamsFailCleanly() throws {
        let full = try AV1Fixture.stream("big8")
        for cut in stride(from: 1, to: full.count, by: 97) {
            _ = try? AV1Decoder.decodeStill(ByteSlice(Array(full.prefix(cut))))
        }
    }

    @Test func corruptedStreamsFailCleanly() throws {
        let full = try AV1Fixture.stream("screen")
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            var b = full
            for _ in 0..<4 { b[Int.random(in: 0..<b.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            _ = try? AV1Decoder.decodeStill(ByteSlice(b))
        }
    }
}

@Suite struct AV1CoverageTests {
    /// Every intra tool the decoder implements is exercised by at least one fixture.
    @Test func fixturesCoverEveryTool() throws {
        var total = [Int](repeating: 0, count: AV1Tool.allCases.count)
        var report: [String] = []
        for name in AV1DecoderTests.names {
            let (_, stats) = try AV1Decoder.decodeStillWithStats(ByteSlice(try AV1Fixture.stream(name)))
            for (i, v) in stats.enumerated() { total[i] += v }
            report.append("\(name): " + AV1Tool.allCases.filter { stats[$0.rawValue] > 0 }.map { "\($0)" }.joined(separator: " "))
        }
        print(report.joined(separator: "\n"))
        for t in AV1Tool.allCases { #expect(total[t.rawValue] > 0, "no fixture uses \(t)") }
    }
}

/// Debugging aid: AV1_PROBE=<comma-separated .obu paths> prints the tools each stream uses.
@Test func probeStreams() throws {
    guard let list = ProcessInfo.processInfo.environment["AV1_PROBE"] else { return }
    for path in list.split(separator: ",") {
        let bytes = Array(try Data(contentsOf: URL(fileURLWithPath: String(path))))
        let (frame, stats) = try AV1Decoder.decodeStillWithStats(ByteSlice(bytes))
        print("PROBE \(path.split(separator: "/").last ?? "") \(frame.width)x\(frame.height) md5=\(md5Hex(rawBytes(frame))): "
              + AV1Tool.allCases.filter { stats[$0.rawValue] > 0 }.map { "\($0)" }.joined(separator: " "))
    }
}
