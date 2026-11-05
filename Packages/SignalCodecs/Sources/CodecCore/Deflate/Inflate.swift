// Deflate decoder: consumes block headers recognised by `DeflateGrammar` and
// expands Huffman-coded symbols. Output is capped *before* growth, and every
// back-reference is checked against data already produced and the window size.

public enum Inflate {
    static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    /// Decodes a raw Deflate stream from `r`, stopping after the final block.
    /// - Parameters:
    ///   - maxOutput: hard cap; exceeding it is `limitExceeded`.
    ///   - windowSize: maximum back-reference distance (32768, or less if a zlib header says so).
    public static func decode(_ r: inout LSBBitReader, maxOutput: Int, windowSize: Int = 32_768, sizeHint: Int = 0) throws(ParseFailure) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(min(max(sizeHint, 0), maxOutput))

        while true {
            let header = try DeflateGrammar.blockHeader(&r)
            switch header.body {
            case .stored(let data):
                guard out.count + data.count <= maxOutput else {
                    throw ParseFailure(offset: r.byteOffset, rule: "stored", reason: .limitExceeded("output > \(maxOutput)"))
                }
                data.append(to: &out)
            case .huffman(let lit, let dist):
                try decodeHuffmanBlock(&r, lit, dist, &out, maxOutput, windowSize)
            }
            if header.isFinal { return out }
        }
    }

    static func decodeHuffmanBlock(
        _ r: inout LSBBitReader, _ lit: HuffmanTable, _ dist: HuffmanTable,
        _ out: inout [UInt8], _ maxOutput: Int, _ windowSize: Int
    ) throws(ParseFailure) {
        while true {
            let sym = try lit.decode(&r, "literal/length")
            if sym < 256 {
                guard out.count < maxOutput else {
                    throw ParseFailure(offset: r.byteOffset, rule: "literal", reason: .limitExceeded("output > \(maxOutput)"))
                }
                out.append(UInt8(sym))
                continue
            }
            if sym == 256 { return }
            let li = sym - 257
            guard li < 29 else {
                throw ParseFailure(offset: r.byteOffset, rule: "length", reason: .invalid("length symbol \(sym)"))
            }
            let length = lengthBase[li] + Int(try r.bits(lengthExtra[li], "length.extra"))

            guard !dist.isEmpty else {
                throw ParseFailure(offset: r.byteOffset, rule: "distance", reason: .invalid("back-reference without distance code"))
            }
            let ds = try dist.decode(&r, "distance")
            guard ds < 30 else {
                throw ParseFailure(offset: r.byteOffset, rule: "distance", reason: .invalid("distance symbol \(ds)"))
            }
            let distance = distBase[ds] + Int(try r.bits(distExtra[ds], "distance.extra"))
            guard distance <= out.count, distance <= windowSize else {
                throw ParseFailure(offset: r.byteOffset, rule: "distance", reason: .invalid("distance \(distance) too far back (have \(out.count))"))
            }
            guard out.count + length <= maxOutput else {
                throw ParseFailure(offset: r.byteOffset, rule: "match", reason: .limitExceeded("output > \(maxOutput)"))
            }
            var from = out.count - distance
            for _ in 0..<length {
                out.append(out[from])
                from += 1
            }
        }
    }
}
