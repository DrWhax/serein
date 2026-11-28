// GzipStream: the same output as Gzip.decompress whatever the pieces the input comes in, the
// same errors at the end, and a bound on what one block may hold.

import Foundation
import Testing
@testable import CodecCore

@Suite struct GzipStreamTests {
    /// The whole output of `gzip` fed in pieces of `piece` bytes (read after each).
    static func stream(_ gzip: [UInt8], piece: Int, atLeast: Int = 1 << 20, maxOutput: Int = .max,
                       maxBlockInput: Int = GzipStream.defaultMaxBlockInput, maxBlockOutput: Int = GzipStream.defaultMaxBlockOutput,
                       allowsZeroPadding: Bool = false) throws(ParseFailure) -> [UInt8] {
        var s = GzipStream(maxOutput: maxOutput, maxBlockInput: maxBlockInput, maxBlockOutput: maxBlockOutput, allowsZeroPadding: allowsZeroPadding)
        var out: [UInt8] = []
        var i = 0
        while i < gzip.count {
            try s.append(Array(gzip[i..<min(gzip.count, i + piece)]))
            i += piece
            while true {
                let more = try s.read(atLeast: atLeast)
                if more.isEmpty { break }
                out += more
            }
        }
        try s.finish()
        return out
    }

    static let inputs: [(String, [UInt8])] = [
        ("empty", []), ("one", [42]),
        ("zeros 300k", [UInt8](repeating: 0, count: 300_000)),
        ("random 90k", DeflateRoundTripTests.pseudoRandom(90_000, seed: 3)),
        ("text", Array(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 6000).utf8)),
        // Parallel Deflate chunks: sync-flush stored blocks between them, matches across them.
        ("chunked 1.3M", (0..<1_300_000).map { i in i % 400_000 < 200_000 ? UInt8((i / 7) & 0x3F) : UInt8(truncatingIfNeeded: i &* 2654435761 >> 13) }),
    ]

    @Test(arguments: inputs)
    func piecesGiveTheWholeOutput(name: String, data: [UInt8]) throws {
        let gz = Gzip.compress(data)
        #expect(try Gzip.decompress(ByteSlice(gz), maxOutput: data.count + 1) == data)
        for piece in [1, 7, 16, 4096, 65_537, gz.count] where piece <= max(gz.count, 1) && (piece > 16 || gz.count < 40_000) {
            #expect(try Self.stream(gz, piece: piece) == data, "\(name) in pieces of \(piece)")
        }
        // Little output per read: the rest stays for the next.
        #expect(try Self.stream(gz, piece: 50_000, atLeast: 1) == data, "\(name), a block per read")
    }

    /// zlib's own blocks (the system gzip), header fields included.
    @Test func zlibsOutput() throws {
        let gzipTool = URL(fileURLWithPath: "/usr/bin/gzip")
        guard FileManager.default.isExecutableFile(atPath: gzipTool.path) else { return }
        let data = Array(String((0..<40_000).map { "line \($0 * 7919 % 10007) of the history\n" }.joined()).utf8)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gzipstream-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.txt")
        try Data(data).write(to: file)
        let p = Process()
        p.executableURL = gzipTool
        p.arguments = ["-k", "-9", file.path]   // keeps FNAME in the header
        try p.run()
        p.waitUntilExit()
        let gz = [UInt8](try Data(contentsOf: dir.appendingPathComponent("history.txt.gz")))
        #expect(gz[3] & 0x08 != 0, "a name in the header")
        for piece in [3, 1000, 1 << 16] { #expect(try Self.stream(gz, piece: piece) == data) }
    }

    @Test func endsAreChecked() throws {
        let data = Array(String(repeating: "abcdefgh", count: 20_000).utf8)
        let gz = Gzip.compress(data)
        // Cut short: no output is lost silently.
        for cut in [5, 12, gz.count / 2, gz.count - 8, gz.count - 1] {
            #expect(throws: ParseFailure.self, "cut at \(cut)") { _ = try Self.stream(Array(gz.prefix(cut)), piece: 1000) }
        }
        // Something after the member.
        #expect(throws: ParseFailure.self) { _ = try Self.stream(gz + [0], piece: 1000) }
        #expect(throws: ParseFailure.self) { _ = try Self.stream(gz + gz, piece: gz.count) }
        // A wrong CRC or size.
        for at in [gz.count - 8, gz.count - 1] {
            var bad = gz
            bad[at] ^= 1
            #expect(throws: ParseFailure.self, "trailer byte \(at)") { _ = try Self.stream(bad, piece: 4096) }
        }
        #expect(throws: ParseFailure.self) { _ = try Self.stream([0x1F, 0x8C] + gz.dropFirst(2), piece: 4096) }
    }

    /// A Signal backup's zero padding after the member: dropped when allowed, in whatever pieces
    /// it comes (with the trailer, or after it); anything else after the member is still refused.
    @Test func zeroPaddingWhenAllowed() throws {
        let data = Array(String(repeating: "abcdefgh", count: 20_000).utf8)
        let gz = Gzip.compress(data)
        for padding in [1, 7, 189_346] {
            let padded = gz + [UInt8](repeating: 0, count: padding)
            #expect(throws: ParseFailure.self, "\(padding) zeros, not allowed") { _ = try Self.stream(padded, piece: 1000) }
            for piece in [3, 1000, gz.count, padded.count] {
                #expect(try Self.stream(padded, piece: piece, allowsZeroPadding: true) == data, "\(padding) zeros in pieces of \(piece)")
            }
        }
        for tail: [UInt8] in [[1], [0, 0, 0, 2], [0x1F, 0x8B]] + [[UInt8](repeating: 0, count: 5000) + [9]] {
            for piece in [1000, gz.count + tail.count] {
                #expect(throws: ParseFailure.self, "\(tail.count)-byte tail in pieces of \(piece)") {
                    _ = try Self.stream(gz + tail, piece: piece, allowsZeroPadding: true)
                }
            }
        }
        #expect(throws: ParseFailure.self) { _ = try Self.stream(gz + gz, piece: gz.count, allowsZeroPadding: true) }
    }

    @Test func limits() throws {
        let zeros = [UInt8](repeating: 0, count: 1 << 20)
        let gz = Gzip.compress(zeros)
        // The whole output.
        #expect(throws: ParseFailure.self) { _ = try Self.stream(gz, piece: 4096, maxOutput: zeros.count - 1) }
        #expect(try Self.stream(gz, piece: 4096, maxOutput: zeros.count) == zeros)
        // What one block may give, and what it may take before it is all there.
        #expect(throws: ParseFailure.self) { _ = try Self.stream(gz, piece: gz.count, maxBlockOutput: 1000) }
        let noise = Gzip.compress(DeflateRoundTripTests.pseudoRandom(200_000, seed: 9).map { $0 & 0x7F })
        #expect(throws: ParseFailure.self) { _ = try Self.stream(noise, piece: 1000, maxBlockInput: 2000) }
        #expect(try Self.stream(noise, piece: 1000).count == 200_000)
    }
}
