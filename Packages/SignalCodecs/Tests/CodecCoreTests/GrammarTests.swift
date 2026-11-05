import Testing
@testable import CodecCore

@Suite struct CursorAndCombinatorTests {
    @Test func primitivesReadBigAndLittleEndian() throws {
        var c = ByteCursor([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        #expect(try c.u16be() == 0x0102)
        #expect(try c.u16le() == 0x0403)
        #expect(c.remaining == 2)
        #expect(throws: ParseFailure.self) { try c.u32be() }
    }

    @Test func unexpectedEndReportsOffsetAndRule() {
        var c = ByteCursor([0xAA, 0xBB, 0xCC])
        _ = try? c.u8()
        do {
            _ = try c.u32be("IHDR.width")
            Issue.record("expected failure")
        } catch {
            #expect(error.offset == 1)
            #expect(error.rule == "IHDR.width")
            #expect(error.reason == .unexpectedEnd(needed: 4, available: 2))
        }
    }

    @Test func lengthPrefixedBoundsTheSubGrammar() throws {
        // length=2, then a body grammar that wants 4 bytes: must fail even though
        // 4 bytes exist after the length field.
        let body = Grammar.u32be
        let p = Grammar.lengthPrefixed("box", length: Grammar.u8, maxLength: 100, body)
        var c = ByteCursor([0x02, 0x00, 0x00, 0x00, 0x01])
        #expect(throws: ParseFailure.self) { try p.parse(&c) }

        // And a body that under-consumes is rejected as trailing bytes.
        let p2 = Grammar.lengthPrefixed("box", length: Grammar.u8, maxLength: 100, Grammar.u8)
        var c2 = ByteCursor([0x02, 0x07, 0x08])
        do {
            _ = try p2.parse(&c2)
            Issue.record("expected failure")
        } catch {
            #expect(error.reason == .trailingBytes(1))
        }
    }

    @Test func lengthLimitIsCheckedBeforeReading() {
        let p = Grammar.lengthPrefixed("chunk", length: Grammar.u32be, maxLength: 16, Grammar.u8)
        var c = ByteCursor([0xFF, 0xFF, 0xFF, 0xFF])
        do {
            _ = try p.parse(&c)
            Issue.record("expected failure")
        } catch {
            guard case .limitExceeded = error.reason else { Issue.record("wrong reason \(error)"); return }
        }
    }

    @Test func validateReportsStartOffsetAndPath() {
        let depth = Grammar.u8.named("bitDepth").validate("bit depth must be 1,2,4,8,16") { [1, 2, 4, 8, 16].contains($0) }
        let header = Parser<UInt8>("IHDR") { (c: inout ByteCursor) throws(ParseFailure) in
            _ = try c.u8()
            return try depth.parse(&c)
        }
        var c = ByteCursor([0x00, 0x03])
        do {
            _ = try header.parse(&c)
            Issue.record("expected failure")
        } catch {
            #expect(error.offset == 1)
            #expect(error.rule == "bitDepth")
            #expect(error.path == ["IHDR"])
        }
    }

    @Test func oneOfIsOrderedChoiceWithoutConsumingOnFailure() throws {
        let png = Grammar.literal("png", [0x89, 0x50]).map { "png" }
        let gif = Grammar.literal("gif", [0x47, 0x49]).map { "gif" }
        let any = Grammar.oneOf("magic", [png, gif])
        var c = ByteCursor([0x47, 0x49, 0x46])
        #expect(try any.parse(&c) == "gif")
        #expect(c.position == 2)
    }

    @Test func repeatedRejectsHostileCountsBeforeAllocating() {
        var c = ByteCursor([])
        #expect(throws: ParseFailure.self) { try Grammar.u8.repeated(count: 1 << 40, maxCount: 1024).parse(&c) }
    }

    @Test func repeatedToEndDetectsNonProgress() {
        let nothing = Parser<Int>("nothing") { (_: inout ByteCursor) throws(ParseFailure) in 0 }
        var c = ByteCursor([1])
        #expect(throws: ParseFailure.self) { try nothing.repeatedToEnd(maxCount: 10).parse(&c) }
    }
}

@Suite struct ChecksumTests {
    @Test func crc32CheckValue() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func adler32KnownValue() {
        #expect(Adler32.checksum(Array("Wikipedia".utf8)) == 0x11E6_0398)
    }

    @Test func adler32LargeInputDoesNotOverflow() {
        let big = [UInt8](repeating: 0xFF, count: 100_000)
        // Reference value computed with Python zlib.adler32.
        #expect(Adler32.checksum(big) == 0x149A_302C)
    }
}
