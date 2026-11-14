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
        // Several parallel chunks (Deflate.parallelChunk): matches across chunk boundaries,
        // random chunks stored, a partial last chunk.
        ("chunked mixed 1.3M", (0..<1_300_000).map { i in i % 400_000 < 200_000 ? UInt8((i / 7) & 0x3F) : UInt8(truncatingIfNeeded: i &* 2654435761 >> 13) }),
        ("chunked text 1M", Array(String(repeating: "Signal-safe parallel deflate, chunk after chunk. ", count: 21_000).utf8)),
    ]

    @Test(arguments: inputs)
    func roundTripsThroughOurInflate(name: String, data: [UInt8]) throws {
        let z = ZlibWriter.compress(data)
        let back = try Zlib.decompress(ByteSlice(z), maxOutput: data.count + 1)
        #expect(back == data, "\(name)")
    }

    /// Chunks compress about as well as one stream (their history is the previous 32 KiB).
    @Test func chunkedOutputStaysSmall() {
        let text = Array(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 30_000).utf8)
        #expect(text.count > 3 * Deflate.parallelChunk)
        #expect(Deflate.compress(text).count * 50 < text.count)
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

@Suite struct GzipTests {
    @Test(arguments: DeflateRoundTripTests.inputs.map(\.1))
    func roundTrips(data: [UInt8]) throws {
        let gz = Gzip.compress(data)
        #expect(try Gzip.decompress(ByteSlice(gz), maxOutput: data.count + 1) == data)
    }

    /// `printf 'hello gzip\n' | gzip -n` (FLG 0) and with a file name (FNAME).
    @Test func readsGzipOutput() throws {
        let plain: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x57, 0x48, 0xAF, 0xCA, 0x2C,
                              0xE0, 0x02, 0x00, 0x39, 0x7C, 0x63, 0x56, 0x0B, 0x00, 0x00, 0x00]
        #expect(try Gzip.decompress(ByteSlice(plain), maxOutput: 100) == Array("hello gzip\n".utf8))
        var named = Array(plain.prefix(10))
        named[3] = 0x08
        named += Array("a.txt".utf8) + [0] + Array(plain.dropFirst(10))
        #expect(try Gzip.decompress(ByteSlice(named), maxOutput: 100) == Array("hello gzip\n".utf8))
    }

    @Test func refusesDamage() throws {
        var gz = Gzip.compress(Array("some text, some text, some text".utf8))
        #expect(throws: ParseFailure.self) { try Gzip.decompress(ByteSlice(gz), maxOutput: 10) }        // over the cap
        gz[gz.count - 6] ^= 1                                                                             // CRC
        #expect(throws: ParseFailure.self) { try Gzip.decompress(ByteSlice(gz), maxOutput: 100) }
        #expect(throws: ParseFailure.self) { try Gzip.decompress(ByteSlice([0x1F, 0x8B, 9, 0]), maxOutput: 100) }
        #expect(throws: ParseFailure.self) { try Gzip.decompress(ByteSlice(Gzip.compress([1, 2, 3]) + [0]), maxOutput: 100) }
    }
}
