// RFC 1952 gzip: one member.
//
//   member := ID1:8 ID2:8 { == 1F 8B } CM:8 { == 8 } FLG:8 { reserved bits 0 } MTIME:32 XFL:8 OS:8
//             [FEXTRA: XLEN:16le, XLEN bytes] [FNAME: bytes, 0] [FCOMMENT: bytes, 0] [FHCRC: 16]
//             deflate-stream  CRC32:32le { == crc32(output) }  ISIZE:32le { == output size mod 2^32 }
//
// Signal's message backups (and link-and-sync transfer archives) are gzip inside their
// encryption; this is their decompression.

public enum Gzip {
    /// The decompressed member. Anything after it is an error.
    public static func decompress(_ input: ByteSlice, maxOutput: Int) throws(ParseFailure) -> [UInt8] {
        var c = input.cursor()
        _ = try c.u8("gzip.ID1", require: "0x1F") { $0 == 0x1F }
        _ = try c.u8("gzip.ID2", require: "0x8B") { $0 == 0x8B }
        _ = try c.u8("gzip.CM", require: "8 (deflate)") { $0 == 8 }
        let flags = try c.u8("gzip.FLG", require: "no reserved bits") { $0 & 0xE0 == 0 }
        try c.skip(6, "gzip.MTIME/XFL/OS")
        if flags & 0x04 != 0 {
            let xlen = Int(try c.u16le("gzip.XLEN"))
            try c.skip(xlen, "gzip.FEXTRA")
        }
        for (bit, rule) in [(UInt8(0x08), "gzip.FNAME"), (UInt8(0x10), "gzip.FCOMMENT")] where flags & bit != 0 {
            while try c.u8(rule) != 0 {}
        }
        if flags & 0x02 != 0 { try c.skip(2, "gzip.FHCRC") }
        var r = LSBBitReader(c.rest())
        let out = try Inflate.decode(&r, maxOutput: maxOutput)
        r.alignToByte()
        var trailer = r.remainderCursor()
        let at = trailer.position
        let crc = try trailer.u32le("gzip.CRC32")
        let size = try trailer.u32le("gzip.ISIZE")
        let computed = CRC32.checksum(out)
        guard crc == computed else { throw ParseFailure(offset: at, rule: "gzip.CRC32", reason: .checksum(expected: crc, computed: computed)) }
        guard size == UInt32(truncatingIfNeeded: out.count) else {
            throw ParseFailure(offset: at + 4, rule: "gzip.ISIZE", reason: .invalid("\(size), decompressed \(out.count)"))
        }
        guard trailer.isAtEnd else { throw ParseFailure(offset: trailer.position, rule: "gzip", reason: .trailingBytes(trailer.remaining)) }
        return out
    }

    /// A gzip member around a Deflate stream of `data` (no name, MTIME 0).
    public static func compress(_ data: [UInt8], options: Deflate.Options = Deflate.Options()) -> [UInt8] {
        var out: [UInt8] = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF]
        out += Deflate.compress(data, options: options)
        let crc = CRC32.checksum(data), size = UInt32(truncatingIfNeeded: data.count)
        for v in [crc, size] { out += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
        return out
    }
}
