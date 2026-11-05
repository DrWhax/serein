// Canonical Huffman decoding tables for Deflate (RFC 1951 §3.2.2).
//
// Construction is part of the *grammar*: a code-length vector is only accepted
// if it describes a valid prefix code (not over-subscribed; complete, except for
// the single-code case zlib also accepts). Decoding is a 9-bit direct lookup
// with a canonical bit-by-bit fallback for longer codes.

public struct HuffmanTable: Sendable {
    public enum Kind: Sendable { case codeLengths, literalLength, distance }

    @usableFromInline static let fastBits = 9
    @usableFromInline static let maxBits = 15

    /// (length << 9) | symbol for codes of length ≤ fastBits, 0 for "slow path".
    @usableFromInline var fast: [UInt16]
    /// counts[len] = number of codes of that length.
    @usableFromInline var counts: [Int]
    /// Symbols ordered by (length, symbol).
    @usableFromInline var symbols: [UInt16]
    public let isEmpty: Bool

    /// Validates `lengths` (one per symbol, 0 = unused) and builds the table.
    public init(lengths: [UInt8], kind: Kind, rule: String, offset: Int) throws(ParseFailure) {
        var counts = [Int](repeating: 0, count: HuffmanTable.maxBits + 1)
        for l in lengths {
            guard Int(l) <= HuffmanTable.maxBits else {
                throw ParseFailure(offset: offset, rule: rule, reason: .invalid("code length \(l) > 15"))
            }
            counts[Int(l)] += 1
        }
        counts[0] = 0
        let maxLen = (1...HuffmanTable.maxBits).last { counts[$0] > 0 } ?? 0

        // Kraft inequality: detect over-subscribed and incomplete codes.
        var left = 1
        for len in 1...HuffmanTable.maxBits {
            left <<= 1
            left -= counts[len]
            if left < 0 {
                throw ParseFailure(offset: offset, rule: rule, reason: .invalid("over-subscribed Huffman code"))
            }
        }
        if maxLen > 0 && left > 0 {
            // Same rule as zlib's inflate_table: incomplete only for a single 1-bit code
            // in literal/length or distance tables; never for the code-length code.
            if kind == .codeLengths || maxLen != 1 {
                throw ParseFailure(offset: offset, rule: rule, reason: .invalid("incomplete Huffman code"))
            }
        }

        // Canonical ordering.
        var offs = [Int](repeating: 0, count: HuffmanTable.maxBits + 2)
        for len in 1...HuffmanTable.maxBits { offs[len + 1] = offs[len] + counts[len] }
        var symbols = [UInt16](repeating: 0, count: offs[HuffmanTable.maxBits + 1])
        for (sym, l) in lengths.enumerated() where l != 0 {
            symbols[offs[Int(l)]] = UInt16(sym)
            offs[Int(l)] += 1
        }

        // Fast table from canonical codes (bit-reversed, since Deflate packs LSB first).
        var fast = [UInt16](repeating: 0, count: 1 << HuffmanTable.fastBits)
        var code = 0
        var idx = 0
        for len in 1...HuffmanTable.maxBits {
            for _ in 0..<counts[len] {
                if len <= HuffmanTable.fastBits {
                    var rev = 0
                    var c = code
                    for _ in 0..<len { rev = rev << 1 | (c & 1); c >>= 1 }
                    let entry = UInt16(len << 9) | symbols[idx]
                    var i = rev
                    while i < (1 << HuffmanTable.fastBits) {
                        fast[i] = entry
                        i += 1 << len
                    }
                }
                code += 1
                idx += 1
            }
            code <<= 1
        }

        self.fast = fast
        self.counts = counts
        self.symbols = symbols
        self.isEmpty = maxLen == 0
    }

    /// Decodes one symbol.
    @inlinable
    public func decode(_ r: inout LSBBitReader, _ rule: String) throws(ParseFailure) -> Int {
        let (bits, available) = r.peek(HuffmanTable.fastBits)
        let entry = fast[Int(bits)]
        if entry != 0 {
            let len = Int(entry >> 9)
            guard len <= available else {
                throw ParseFailure(offset: r.byteOffset, rule: rule, reason: .unexpectedEnd(needed: len, available: available))
            }
            r.consume(len)
            return Int(entry & 0x1FF)
        }
        // Canonical decode, one bit at a time (codes longer than fastBits, or unused patterns).
        var code = 0, first = 0, index = 0
        for len in 1...HuffmanTable.maxBits {
            code |= Int(try r.bit(rule))
            let count = counts[len]
            if code - count < first { return Int(symbols[index + (code - first)]) }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw ParseFailure(offset: r.byteOffset, rule: rule, reason: .invalid("invalid Huffman code"))
    }
}
