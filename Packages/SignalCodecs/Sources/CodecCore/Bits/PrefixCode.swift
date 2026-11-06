// Table-driven decoding of MSB-first prefix codes (the static Huffman codebooks of AAC and
// MP3). A root table indexed by the next `rootBits` bits gives either a symbol and its code
// length or a second-level table for the longer codes sharing that prefix. Tables are built
// from trusted constants; construction checks that the code is prefix-free.

public struct PrefixCodeTable: Sendable {
    @usableFromInline struct Entry: Sendable {
        /// Leaf: the symbol. Link: the subtable's offset.
        @usableFromInline var value: Int32
        /// > 0: leaf with this code length; < 0: link to a subtable indexed by −length bits; 0: no code.
        @usableFromInline var length: Int8
    }

    @usableFromInline let rootBits: Int
    @usableFromInline let entries: [Entry]
    public let maxLength: Int

    /// `codes[i]` is the `lengths[i]`-bit code of `symbols[i]` (default: i); length 0 = unused.
    public init(codes: [UInt32], lengths: [UInt8], symbols: [Int]? = nil, rootBits: Int = 9) {
        precondition(codes.count == lengths.count && (symbols?.count ?? codes.count) == codes.count)
        let maxLen = Int(lengths.max() ?? 0)
        precondition(maxLen <= 32)
        let root = min(rootBits, max(maxLen, 1))
        var table = Array(repeating: Entry(value: 0, length: 0), count: 1 << root)
        // Group the long codes by their root prefix to size the subtables.
        var subBits: [Int: Int] = [:]
        for (code, len) in zip(codes, lengths) where Int(len) > root {
            let prefix = Int(code >> UInt32(Int(len) - root))
            subBits[prefix] = max(subBits[prefix] ?? 0, Int(len) - root)
        }
        for (prefix, bits) in subBits.sorted(by: { $0.key < $1.key }) {
            precondition(table[prefix].length == 0, "prefix code: overlapping codes")
            table[prefix] = Entry(value: Int32(table.count), length: Int8(-bits))
            table += Array(repeating: Entry(value: 0, length: 0), count: 1 << bits)
        }
        for i in codes.indices where lengths[i] > 0 {
            let len = Int(lengths[i]), code = Int(codes[i])
            precondition(code >> len == 0, "prefix code: code wider than its length")
            let symbol = Int32(symbols?[i] ?? i)
            if len <= root {
                let first = code << (root - len)
                for j in first ..< first + (1 << (root - len)) {
                    precondition(table[j].length == 0, "prefix code: not prefix-free")
                    table[j] = Entry(value: symbol, length: Int8(len))
                }
            } else {
                let link = table[code >> (len - root)]
                let bits = -Int(link.length)
                let rest = code & ((1 << (len - root)) - 1)
                let first = Int(link.value) + (rest << (bits - (len - root)))
                for j in first ..< first + (1 << (bits - (len - root))) {
                    precondition(table[j].length == 0, "prefix code: not prefix-free")
                    table[j] = Entry(value: symbol, length: Int8(len))
                }
            }
        }
        self.rootBits = root
        self.entries = table
        self.maxLength = maxLen
    }

    /// Decodes one symbol; bits that match no code are an error.
    @inlinable
    public func decode<R: MSBBitSource>(_ r: inout R, _ rule: String) throws(ParseFailure) -> Int {
        var e = entries[Int(r.peek(rootBits))]
        if e.length < 0 {
            let bits = -Int(e.length)
            let w = r.peek(rootBits + bits) & ((1 << UInt32(bits)) - 1)
            e = entries[Int(e.value) + Int(w)]
        }
        guard e.length > 0 else {
            throw ParseFailure(offset: r.bitPosition / 8, rule: rule, reason: .invalid("no prefix code matches"))
        }
        try r.skip(Int(e.length), rule)
        return Int(e.value)
    }
}
