import Testing
@testable import CodecCore

@Suite struct DeflateRoundTripTests {
    static func pseudoRandom(_ n: Int, seed: UInt64) -> [UInt8] {
        var s = seed
        return (0..<n).map { _ in s = s &* 6364136223846793005 &+ 1442695040888963407; return UInt8(truncatingIfNeeded: s >> 33) }
    }

    static let inputs: [(String, [UInt8])] = [
        ("empty", []), ("one", [42]), ("two", [1, 2]),
        ("zeros 100k", [UInt8](repeating: 0, count: 100_000)),
        ("random 70k", pseudoRandom(70_000, seed: 1)),
        ("text", Array(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 3000).utf8)),
        ("small alphabet", pseudoRandom(200_000, seed: 2).map { $0 & 3 }),
        ("runs", (0..<150_000).map { UInt8(($0 / 300) & 0xFF) }),
        ("one literal type", [UInt8](repeating: 7, count: 2)),
    ]

    @Test(arguments: inputs)
    func roundTripsThroughOurInflate(name: String, data: [UInt8]) throws {
        let z = ZlibWriter.compress(data)
        let back = try Zlib.decompress(ByteSlice(z), maxOutput: data.count + 1)
        #expect(back == data, "\(name)")
    }

    @Test func compressesComparablyToZlib() {
        // zlib -6 on this text is ~0.6% of the input; require < 2%.
        let text = Array(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 3000).utf8)
        #expect(Deflate.compress(text).count * 50 < text.count)
        // Random data must not expand by more than stored-block overhead
        // (5 bytes per ≤65535-byte stored block, plus alignment).
        let rnd = Self.pseudoRandom(70_000, seed: 3)
        #expect(Deflate.compress(rnd).count <= rnd.count + 5 * 4 + 2)
    }

    @Test func packageMergeRespectsTheLengthLimit() {
        // Fibonacci frequencies force very deep unrestricted Huffman trees.
        var f = [1, 1]
        while f.count < 30 { f.append(f[f.count - 1] + f[f.count - 2]) }
        let lens = Deflate.Huffman.lengths(f, maxBits: 15)
        #expect(lens.max()! <= 15)
        // Kraft equality: a complete code.
        let kraft = lens.reduce(0.0) { $0 + ($1 == 0 ? 0 : 1 / Double(1 << Int($1))) }
        #expect(abs(kraft - 1) < 1e-12)
    }
}
