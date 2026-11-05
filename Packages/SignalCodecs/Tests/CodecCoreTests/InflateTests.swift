import Testing
@testable import CodecCore

@Suite struct InflateTests {
    func inflate(_ bytes: [UInt8], max: Int = 1 << 20) throws(ParseFailure) -> [UInt8] {
        var r = LSBBitReader(ByteSlice(bytes))
        return try Inflate.decode(&r, maxOutput: max)
    }

    @Test func fixedHuffmanBlock() throws {
        #expect(try inflate(DeflateVectors.fixed) == DeflateVectors.fixedText)
    }

    @Test func dynamicHuffmanBlock() throws {
        #expect(try inflate(DeflateVectors.dynamic) == DeflateVectors.dynamicText)
    }

    @Test func storedBlock() throws {
        #expect(try inflate(DeflateVectors.stored) == DeflateVectors.storedText)
    }

    @Test func zlibContainerVerifiesAdler() throws {
        let out = try Zlib.decompress(ByteSlice(DeflateVectors.zlibHello), maxOutput: 1 << 20)
        #expect(out == DeflateVectors.fixedText)

        var corrupt = DeflateVectors.zlibHello
        corrupt[corrupt.count - 1] ^= 0xFF
        do {
            _ = try Zlib.decompress(ByteSlice(corrupt), maxOutput: 1 << 20)
            Issue.record("expected checksum failure")
        } catch {
            guard case .checksum = error.reason else { Issue.record("wrong reason \(error)"); return }
        }
    }

    @Test func zlibRejectsBadHeaderAndPresetDictionary() {
        #expect(throws: ParseFailure.self) { try Zlib.decompress(ByteSlice([0x78, 0x00, 0x03, 0x00]), maxOutput: 10) }  // FCHECK
        #expect(throws: ParseFailure.self) { try Zlib.decompress(ByteSlice([0x79, 0x9C]), maxOutput: 10) }  // CM=9
        #expect(throws: ParseFailure.self) { try Zlib.decompress(ByteSlice([0x78, 0xBB, 0, 0, 0, 0]), maxOutput: 10) }  // FDICT
    }

    @Test func zlibExpectedSizeIsEnforced() {
        #expect(throws: ParseFailure.self) {
            try Zlib.decompress(ByteSlice(DeflateVectors.zlibHello), maxOutput: 1 << 20, expectedSize: 5)
        }
    }

    @Test func outputCapStopsDecompressionBombs() {
        do {
            _ = try inflate(DeflateVectors.dynamic, max: 100)
            Issue.record("expected limit")
        } catch {
            guard case .limitExceeded = error.reason else { Issue.record("wrong reason \(error)"); return }
        }
    }

    @Test(arguments: [
        ("distTooFar", DeflateVectors.distTooFar),
        ("badLenSym", DeflateVectors.badLenSym),
        ("badDistSym", DeflateVectors.badDistSym),
        ("oversubscribed", DeflateVectors.oversubscribed),
        ("reservedBType", [0x07] as [UInt8]),
        ("storedBadNLEN", [0x01, 0x05, 0x00, 0x00, 0x00] as [UInt8]),
        ("truncatedStored", [0x01, 0x05, 0x00, 0xFA, 0xFF, 0x61] as [UInt8]),
        ("empty", [] as [UInt8]),
    ])
    func malformedStreamsAreRejected(name: String, bytes: [UInt8]) {
        #expect(throws: ParseFailure.self, "\(name)") { try inflate(bytes) }
    }

    @Test func everyTruncationOfAValidStreamFailsCleanly() {
        let s = DeflateVectors.dynamic
        for n in 0..<s.count {
            // Cutting only the final byte's padding may still be a complete stream;
            // anything that decodes must then be exactly the original.
            if let out = try? inflate(Array(s[0..<n])) {
                #expect(n == s.count - 1 && out == DeflateVectors.dynamicText, "truncation at \(n) decoded")
            }
        }
    }
}
