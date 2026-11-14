// Streaming gzip (RFC 1952, one member; the grammar in Gzip.swift): the compressed bytes come
// in pieces and the output is handed out as it is produced, so neither is ever held whole (a
// link-and-sync history is hundreds of megabytes). What is held: the 32 KiB window, the input
// not yet decoded (at most one Deflate block beyond what was handed out) and the output of the
// blocks decoded by one `read`.
//
// Blocks are decoded whole: a block cut off by the end of the input so far is decoded again from
// its start once more input has come (its partial output dropped). So one block may need at
// most `maxBlockInput` bytes of input and give at most `maxBlockOutput` bytes. zlib's blocks
// hold at most 16 Ki symbols (≈ 100 KB in, 4 MB out); a stream no common encoder writes is
// refused rather than buffered.

public struct GzipStream: Sendable {
    public static let defaultMaxBlockInput = 16 << 20
    public static let defaultMaxBlockOutput = 64 << 20
    static let window = 32_768

    enum Stage: Sendable { case header, blocks, trailer, done }
    var stage = Stage.header
    /// The input not decoded yet: `input[start...]`, of which the first `bit` bits are used.
    var input: [UInt8] = []
    var start = 0
    var bit = 0
    /// The last (up to) 32 KiB of output: what back-references reach.
    var history: [UInt8] = []
    var crc = CRC32()
    /// Bytes handed out so far.
    public private(set) var outputCount = 0
    let maxOutput: Int, maxBlockInput: Int, maxBlockOutput: Int

    /// - Parameter maxOutput: the whole member's output; more is `limitExceeded`.
    public init(maxOutput: Int = .max, maxBlockInput: Int = defaultMaxBlockInput, maxBlockOutput: Int = defaultMaxBlockOutput) {
        self.maxOutput = maxOutput
        self.maxBlockInput = maxBlockInput
        self.maxBlockOutput = maxBlockOutput
    }

    /// The member and its trailer have been read (and checked).
    public var isFinished: Bool { stage == .done }

    /// More of the stream.
    public mutating func append(_ bytes: [UInt8]) throws(ParseFailure) {
        guard !bytes.isEmpty else { return }
        guard stage != .done else { throw ParseFailure(offset: outputCount, rule: "gzip", reason: .trailingBytes(bytes.count)) }
        if start > 0 {
            input.removeFirst(start)
            start = 0
        }
        input.append(contentsOf: bytes)
    }

    /// Decodes whole blocks until at least `atLeast` bytes have come out or the input so far is
    /// used up. Empty: more input is needed (or the member is complete).
    public mutating func read(atLeast: Int = 1 << 20) throws(ParseFailure) -> [UInt8] {
        if stage == .header {
            guard try header() else { return [] }
        }
        var out = history
        let base = out.count
        var n = base
        while stage == .blocks, n - base < atLeast {
            guard try block(&out, &n, produced: n - base) else { break }
        }
        let produced = Array(out[base..<n])
        crc.update(produced)
        outputCount += produced.count
        history = Array(out[max(0, n - Self.window)..<n])
        if stage == .trailer { try trailer() }
        if stage == .done, start < input.count {
            throw ParseFailure(offset: outputCount, rule: "gzip", reason: .trailingBytes(input.count - start))
        }
        return produced
    }

    /// The end of the input: the member must be complete, with nothing after it.
    public func finish() throws(ParseFailure) {
        guard stage == .done else {
            throw ParseFailure(offset: outputCount, rule: "gzip", reason: .unexpectedEnd(needed: 1, available: 0))
        }
        guard start == input.count else { throw ParseFailure(offset: outputCount, rule: "gzip", reason: .trailingBytes(input.count - start)) }
    }

    /// The input not decoded yet, as a reader positioned at its first unused bit.
    func reader() throws(ParseFailure) -> LSBBitReader {
        var r = LSBBitReader(ByteSlice(storage: input, lowerBound: start, upperBound: input.count))
        _ = try r.bits(bit, "deflate")
        return r
    }

    /// Input that is not enough yet: fine, unless one block would need more than allowed.
    func needMore(_ e: ParseFailure) throws(ParseFailure) {
        guard case .unexpectedEnd = e.reason else { throw e }
        guard input.count - start <= maxBlockInput else {
            throw ParseFailure(offset: outputCount, rule: "deflate", reason: .limitExceeded("a block of more than \(maxBlockInput) bytes"))
        }
    }

    mutating func header() throws(ParseFailure) -> Bool {
        var c = ByteSlice(storage: input, lowerBound: start, upperBound: input.count).cursor()
        do throws(ParseFailure) {
            try Gzip.memberHeader(&c)
        } catch {
            try needMore(error)
            return false
        }
        start = c.rest().lowerBound
        stage = .blocks
        return true
    }

    /// One whole block onto `out` (n bytes used); false when it is not all here yet.
    mutating func block(_ out: inout [UInt8], _ n: inout Int, produced: Int) throws(ParseFailure) -> Bool {
        if out.count > n { out.removeLast(out.count - n) }
        var r = try reader()
        let before = r.bitsRemaining + bit
        let mark = n
        // This block's output may reach `cap` (absolute, in `out`).
        let cap = n + min(maxBlockOutput, maxOutput - outputCount - produced)
        let isFinal: Bool
        do throws(ParseFailure) {
            let header = try DeflateGrammar.blockHeader(&r)
            isFinal = header.isFinal
            switch header.body {
            case .stored(let data):
                guard n + data.count <= cap else {
                    throw ParseFailure(offset: outputCount, rule: "stored", reason: .limitExceeded("output > \(maxOutput)"))
                }
                data.append(to: &out)
                n = out.count
            case .huffman(let lit, let dist):
                try Inflate.decodeHuffmanBlock(&r, lit, dist, &out, &n, cap, Self.window)
            }
        } catch {
            n = mark
            try needMore(error)
            return false
        }
        let used = before - r.bitsRemaining
        start += used / 8
        bit = used % 8
        if isFinal { stage = .trailer }
        return true
    }

    /// CRC32 and ISIZE, from the next byte boundary.
    mutating func trailer() throws(ParseFailure) {
        if bit > 0 {
            start += 1
            bit = 0
        }
        guard input.count - start >= 8 else { return }
        var c = ByteSlice(storage: input, lowerBound: start, upperBound: start + 8).cursor()
        let crcValue = try c.u32le("gzip.CRC32"), size = try c.u32le("gzip.ISIZE")
        guard crcValue == crc.value else {
            throw ParseFailure(offset: outputCount, rule: "gzip.CRC32", reason: .checksum(expected: crcValue, computed: crc.value))
        }
        guard size == UInt32(truncatingIfNeeded: outputCount) else {
            throw ParseFailure(offset: outputCount, rule: "gzip.ISIZE", reason: .invalid("\(size), decompressed \(outputCount)"))
        }
        start += 8
        stage = .done
    }
}

extension Gzip {
    /// The member header, up to the Deflate stream.
    static func memberHeader(_ c: inout ByteCursor) throws(ParseFailure) {
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
    }
}
