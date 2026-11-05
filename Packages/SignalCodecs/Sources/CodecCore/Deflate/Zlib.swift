// RFC 1950 zlib container.
//
//   zlib := CMF:8 FLG:8 { CM == 8; CINFO <= 7; (CMF*256+FLG) % 31 == 0; FDICT == 0 }
//           deflate-stream  ADLER32:32be { == adler32(output) }  trailing?
//
// Preset dictionaries (FDICT=1) are rejected: no format SignalSafe parses uses them.

public enum Zlib {
    public enum TrailingPolicy: Sendable {
        /// Bytes after the Adler-32 are an error.
        case reject
        /// Bytes after the Adler-32 are ignored (PNG: libpng treats them as a benign warning).
        case ignore
    }

    public static func decompress(
        _ input: ByteSlice, maxOutput: Int, expectedSize: Int? = nil, trailing: TrailingPolicy = .reject
    ) throws(ParseFailure) -> [UInt8] {
        var c = input.cursor()
        let at = c.position
        let cmf = try c.u8("zlib.CMF")
        let flg = try c.u8("zlib.FLG")
        guard cmf & 0x0F == 8 else {
            throw ParseFailure(offset: at, rule: "zlib.CMF", reason: .invalid("compression method \(cmf & 0x0F)"))
        }
        let cinfo = Int(cmf >> 4)
        guard cinfo <= 7 else {
            throw ParseFailure(offset: at, rule: "zlib.CMF", reason: .invalid("window size CINFO=\(cinfo)"))
        }
        guard (Int(cmf) << 8 | Int(flg)) % 31 == 0 else {
            throw ParseFailure(offset: at + 1, rule: "zlib.FLG", reason: .invalid("FCHECK"))
        }
        guard flg & 0x20 == 0 else {
            throw ParseFailure(offset: at + 1, rule: "zlib.FLG", reason: .invalid("preset dictionary not allowed"))
        }

        var r = LSBBitReader(c.rest())
        let cap = expectedSize.map { min($0, maxOutput) } ?? maxOutput
        let out = try Inflate.decode(&r, maxOutput: cap, windowSize: 1 << (cinfo + 8), sizeHint: expectedSize ?? 0)
        if let expected = expectedSize, out.count != expected {
            throw ParseFailure(offset: r.byteOffset, rule: "zlib", reason: .invalid("decompressed \(out.count) bytes, expected \(expected)"))
        }

        r.alignToByte()
        var trailer = r.remainderCursor()
        let stored = try trailer.u32be("zlib.ADLER32")
        let computed = Adler32.checksum(out)
        guard stored == computed else {
            throw ParseFailure(offset: trailer.position - 4, rule: "zlib.ADLER32", reason: .checksum(expected: stored, computed: computed))
        }
        if trailing == .reject && !trailer.isAtEnd {
            throw ParseFailure(offset: trailer.position, rule: "zlib", reason: .trailingBytes(trailer.remaining))
        }
        return out
    }
}
