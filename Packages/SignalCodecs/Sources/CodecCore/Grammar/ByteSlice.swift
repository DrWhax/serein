// Bounded, copy-free views of untrusted input.
//
// `ByteSlice` is an immutable window into shared storage. Decoders never index
// raw storage directly; they open a `ByteCursor` (for grammars) or a bit reader
// (for entropy-coded payloads) over a slice. Every read is range-checked against
// the slice bounds, so a sub-grammar can never read outside the region its
// enclosing length field delimited.

public struct ByteSlice: Sendable, Equatable {
    @usableFromInline let storage: [UInt8]
    /// Absolute offsets into `storage`.
    public let lowerBound: Int
    public let upperBound: Int

    public init(_ bytes: [UInt8]) {
        storage = bytes
        lowerBound = 0
        upperBound = bytes.count
    }

    @usableFromInline
    init(storage: [UInt8], lowerBound: Int, upperBound: Int) {
        precondition(0 <= lowerBound && lowerBound <= upperBound && upperBound <= storage.count)
        self.storage = storage
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public static let empty = ByteSlice([])

    public var count: Int { upperBound - lowerBound }
    public var isEmpty: Bool { lowerBound == upperBound }

    public func cursor() -> ByteCursor { ByteCursor(self) }

    /// Copies the bytes out. Use for payloads that a decoder must own
    /// (e.g. concatenating IDAT chunks before inflating).
    public func copyBytes() -> [UInt8] { Array(storage[lowerBound..<upperBound]) }

    /// Appends the bytes to `buffer` without exposing indices.
    public func append(to buffer: inout [UInt8]) {
        buffer.append(contentsOf: storage[lowerBound..<upperBound])
    }

    /// Feeds the bytes to a checksum/hash accumulator.
    public func forEachByte(_ body: (UInt8) -> Void) {
        for i in lowerBound..<upperBound { body(storage[i]) }
    }

    /// Concatenates slices into one owned slice.
    public static func concatenate(_ slices: [ByteSlice]) -> ByteSlice {
        if slices.count == 1 { return slices[0] }
        var out: [UInt8] = []
        out.reserveCapacity(slices.reduce(0) { $0 + $1.count })
        for s in slices { s.append(to: &out) }
        return ByteSlice(out)
    }

    public static func == (a: ByteSlice, b: ByteSlice) -> Bool {
        a.count == b.count && a.storage[a.lowerBound..<a.upperBound].elementsEqual(b.storage[b.lowerBound..<b.upperBound])
    }
}

/// Sequential, bounds-checked reader over a `ByteSlice`. All primitive grammar
/// rules are methods on the cursor; failures carry absolute offsets.
public struct ByteCursor: Sendable {
    @usableFromInline let storage: [UInt8]
    public private(set) var position: Int
    public let end: Int
    public let start: Int

    public init(_ slice: ByteSlice) {
        storage = slice.storage
        position = slice.lowerBound
        start = slice.lowerBound
        end = slice.upperBound
    }

    public init(_ bytes: [UInt8]) { self.init(ByteSlice(bytes)) }

    public var remaining: Int { end - position }
    public var isAtEnd: Bool { position == end }
    /// Bytes consumed since this cursor was opened.
    public var consumed: Int { position - start }

    @inlinable
    func need(_ n: Int, _ rule: String) throws(ParseFailure) {
        if n < 0 || n > end - position {
            throw ParseFailure(offset: position, rule: rule, reason: .unexpectedEnd(needed: n, available: end - position))
        }
    }

    public mutating func u8(_ rule: String = "u8") throws(ParseFailure) -> UInt8 {
        try need(1, rule)
        defer { position += 1 }
        return storage[position]
    }

    /// Reads a byte and validates it; a violation is reported at the field's own offset.
    public mutating func u8(_ rule: String, require what: String, _ valid: (UInt8) -> Bool) throws(ParseFailure) -> UInt8 {
        let at = position
        let v = try u8(rule)
        guard valid(v) else { throw ParseFailure(offset: at, rule: rule, reason: .invalid("\(what): \(v)")) }
        return v
    }

    public mutating func u16le(_ rule: String, require what: String, _ valid: (UInt16) -> Bool) throws(ParseFailure) -> UInt16 {
        let at = position
        let v = try u16le(rule)
        guard valid(v) else { throw ParseFailure(offset: at, rule: rule, reason: .invalid("\(what): \(v)")) }
        return v
    }

    public mutating func u16be(_ rule: String = "u16be") throws(ParseFailure) -> UInt16 {
        try need(2, rule)
        defer { position += 2 }
        return UInt16(storage[position]) << 8 | UInt16(storage[position + 1])
    }

    public mutating func u16le(_ rule: String = "u16le") throws(ParseFailure) -> UInt16 {
        try need(2, rule)
        defer { position += 2 }
        return UInt16(storage[position + 1]) << 8 | UInt16(storage[position])
    }

    public mutating func u24be(_ rule: String = "u24be") throws(ParseFailure) -> UInt32 {
        try need(3, rule)
        defer { position += 3 }
        return UInt32(storage[position]) << 16 | UInt32(storage[position + 1]) << 8 | UInt32(storage[position + 2])
    }

    public mutating func u24le(_ rule: String = "u24le") throws(ParseFailure) -> UInt32 {
        try need(3, rule)
        defer { position += 3 }
        return UInt32(storage[position + 2]) << 16 | UInt32(storage[position + 1]) << 8 | UInt32(storage[position])
    }

    public mutating func u32be(_ rule: String = "u32be") throws(ParseFailure) -> UInt32 {
        try need(4, rule)
        defer { position += 4 }
        return UInt32(storage[position]) << 24 | UInt32(storage[position + 1]) << 16
            | UInt32(storage[position + 2]) << 8 | UInt32(storage[position + 3])
    }

    public mutating func u32le(_ rule: String = "u32le") throws(ParseFailure) -> UInt32 {
        try need(4, rule)
        defer { position += 4 }
        return UInt32(storage[position + 3]) << 24 | UInt32(storage[position + 2]) << 16
            | UInt32(storage[position + 1]) << 8 | UInt32(storage[position])
    }

    public mutating func u64be(_ rule: String = "u64be") throws(ParseFailure) -> UInt64 {
        let hi = try u32be(rule)
        let lo = try u32be(rule)
        return UInt64(hi) << 32 | UInt64(lo)
    }

    /// Takes `count` bytes as a bounded slice (no copy).
    public mutating func bytes(_ count: Int, _ rule: String = "bytes") throws(ParseFailure) -> ByteSlice {
        try need(count, rule)
        defer { position += count }
        return ByteSlice(storage: storage, lowerBound: position, upperBound: position + count)
    }

    /// Takes everything that is left.
    public mutating func rest() -> ByteSlice {
        defer { position = end }
        return ByteSlice(storage: storage, lowerBound: position, upperBound: end)
    }

    public mutating func skip(_ count: Int, _ rule: String = "skip") throws(ParseFailure) {
        try need(count, rule)
        position += count
    }

    /// Matches a literal byte string (magic numbers, tags).
    public mutating func expect(_ literal: [UInt8], _ rule: String) throws(ParseFailure) {
        try need(literal.count, rule)
        for (i, b) in literal.enumerated() where storage[position + i] != b {
            throw ParseFailure(offset: position, rule: rule, reason: .mismatch(expected: literal.map { String($0, radix: 16) }.joined(separator: " ")))
        }
        position += literal.count
    }

    /// Lookahead without consuming. Returns nil if fewer than `count` bytes remain.
    public func peek(_ count: Int) -> ByteSlice? {
        guard count >= 0, count <= remaining else { return nil }
        return ByteSlice(storage: storage, lowerBound: position, upperBound: position + count)
    }

    public func peekU8() -> UInt8? { position < end ? storage[position] : nil }

    /// Builds a failure at the current position (for semantic checks inside rules).
    public func fail(_ rule: String, _ reason: ParseFailure.Reason) -> ParseFailure {
        ParseFailure(offset: position, rule: rule, reason: reason)
    }

    /// Requires that the cursor is exhausted (the grammar consumed its whole region).
    public func expectEnd(_ rule: String) throws(ParseFailure) {
        if position != end {
            throw ParseFailure(offset: position, rule: rule, reason: .trailingBytes(end - position))
        }
    }
}
