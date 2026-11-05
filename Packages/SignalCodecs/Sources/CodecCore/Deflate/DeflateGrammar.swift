// RFC 1951 block-level grammar.
//
//   stream      := block* final-block
//   block       := BFINAL:1 BTYPE:2 body
//   body(00)    := align LEN:16 NLEN:16 { NLEN == ~LEN } byte{LEN}
//   body(01)    := huffman-data(fixed tables)
//   body(10)    := HLIT:5 HDIST:5 HCLEN:4 cl-lengths:3{HCLEN+4}
//                  lengths(HLIT+257 + HDIST+1) { valid prefix codes; len(256) > 0 }
//                  huffman-data
//   body(11)    := ⊥   (reserved)
//
// `huffman-data` is entropy-coded and therefore decoded by `Inflate`, but all of
// its *parameters* (both tables) are fully recognised and validated here first.

public enum DeflateGrammar {
    public enum BlockBody: Sendable {
        case stored(ByteSlice)
        case huffman(literal: HuffmanTable, distance: HuffmanTable)
    }

    public struct BlockHeader: Sendable {
        public var isFinal: Bool
        public var body: BlockBody
    }

    static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    public static let fixedLiteral: HuffmanTable = {
        var l = [UInt8](repeating: 8, count: 288)
        for i in 144..<256 { l[i] = 9 }
        for i in 256..<280 { l[i] = 7 }
        // Known-valid constant: construction cannot fail.
        return try! HuffmanTable(lengths: l, kind: .literalLength, rule: "fixed", offset: 0)
    }()

    public static let fixedDistance: HuffmanTable = {
        // RFC 1951 §3.2.6: 32 five-bit codes; symbols 30 and 31 are rejected by Inflate.
        try! HuffmanTable(lengths: [UInt8](repeating: 5, count: 32), kind: .distance, rule: "fixed", offset: 0)
    }()

    /// Recognises one block header and its tables.
    public static func blockHeader(_ r: inout LSBBitReader) throws(ParseFailure) -> BlockHeader {
        let at = r.byteOffset
        let isFinal = try r.bit("BFINAL") == 1
        switch try r.bits(2, "BTYPE") {
        case 0:
            r.alignToByte()
            var c = try r.alignedBytes(4, "stored.LEN/NLEN").cursor()
            let len = try c.u16le("stored.LEN")
            let nlen = try c.u16le("stored.NLEN")
            guard len == ~nlen else {
                throw ParseFailure(offset: at, rule: "stored", reason: .invalid("NLEN is not one's complement of LEN"))
            }
            return BlockHeader(isFinal: isFinal, body: .stored(try r.alignedBytes(Int(len), "stored.data")))
        case 1:
            return BlockHeader(isFinal: isFinal, body: .huffman(literal: fixedLiteral, distance: fixedDistance))
        case 2:
            let (lit, dist) = try dynamicTables(&r)
            return BlockHeader(isFinal: isFinal, body: .huffman(literal: lit, distance: dist))
        default:
            throw ParseFailure(offset: at, rule: "BTYPE", reason: .invalid("reserved block type 3"))
        }
    }

    static func dynamicTables(_ r: inout LSBBitReader) throws(ParseFailure) -> (HuffmanTable, HuffmanTable) {
        let at = r.byteOffset
        let hlit = Int(try r.bits(5, "HLIT")) + 257
        let hdist = Int(try r.bits(5, "HDIST")) + 1
        let hclen = Int(try r.bits(4, "HCLEN")) + 4
        guard hlit <= 286, hdist <= 30 else {
            throw ParseFailure(offset: at, rule: "dynamic", reason: .invalid("HLIT \(hlit) / HDIST \(hdist) out of range"))
        }
        var clLengths = [UInt8](repeating: 0, count: 19)
        for i in 0..<hclen { clLengths[codeLengthOrder[i]] = UInt8(try r.bits(3, "HCLEN.length")) }
        let clTable = try HuffmanTable(lengths: clLengths, kind: .codeLengths, rule: "code-length code", offset: at)

        let total = hlit + hdist
        var lengths: [UInt8] = []
        lengths.reserveCapacity(total)
        while lengths.count < total {
            let sym = try clTable.decode(&r, "code-length symbol")
            switch sym {
            case 0...15:
                lengths.append(UInt8(sym))
            case 16:
                guard let prev = lengths.last else {
                    throw ParseFailure(offset: r.byteOffset, rule: "repeat-16", reason: .invalid("repeat with no previous length"))
                }
                let n = 3 + Int(try r.bits(2, "repeat-16"))
                try appendRepeat(&lengths, prev, n, total, r.byteOffset)
            case 17:
                try appendRepeat(&lengths, 0, 3 + Int(try r.bits(3, "repeat-17")), total, r.byteOffset)
            case 18:
                try appendRepeat(&lengths, 0, 11 + Int(try r.bits(7, "repeat-18")), total, r.byteOffset)
            default:
                throw ParseFailure(offset: r.byteOffset, rule: "code-length symbol", reason: .invalid("symbol \(sym)"))
            }
        }
        let litLengths = Array(lengths[0..<hlit])
        guard litLengths[256] != 0 else {
            throw ParseFailure(offset: at, rule: "dynamic", reason: .invalid("no code for end-of-block"))
        }
        let lit = try HuffmanTable(lengths: litLengths, kind: .literalLength, rule: "literal/length code", offset: at)
        let dist = try HuffmanTable(lengths: Array(lengths[hlit...]), kind: .distance, rule: "distance code", offset: at)
        return (lit, dist)
    }

    static func appendRepeat(_ a: inout [UInt8], _ v: UInt8, _ n: Int, _ total: Int, _ at: Int) throws(ParseFailure) {
        guard a.count + n <= total else {
            throw ParseFailure(offset: at, rule: "code lengths", reason: .invalid("repeat overflows HLIT+HDIST"))
        }
        a.append(contentsOf: repeatElement(v, count: n))
    }
}
