// Least-significant-bit-first bit reader (Deflate, VP8L, GIF LZW).
//
// Every read is range-checked against the bounding `ByteSlice`; exhaustion is a
// typed `ParseFailure`, never a trap or a silent zero. `peek` may return bits
// beyond the end as zeros (for table-driven Huffman decoding) together with how
// many of them are real, so callers can reject codes that run off the end.

public struct LSBBitReader: Sendable {
    @usableFromInline let storage: [UInt8]
    @usableFromInline var index: Int
    @usableFromInline let end: Int
    @usableFromInline var buffer: UInt64 = 0
    @usableFromInline var count: Int = 0

    public init(_ slice: ByteSlice) {
        storage = slice.storage
        index = slice.lowerBound
        end = slice.upperBound
    }

    /// Absolute byte offset of the next unread bit (for error reporting).
    public var byteOffset: Int { index - count / 8 - (count % 8 == 0 ? 0 : 1) }

    /// Number of unread bits left in the bounded input.
    public var bitsRemaining: Int { (end - index) * 8 + count }

    @inlinable
    mutating func refill() {
        while count <= 56 && index < end {
            buffer |= UInt64(storage[index]) << UInt64(count)
            index += 1
            count += 8
        }
    }

    /// Reads `n` (0...32) bits.
    @inlinable
    public mutating func bits(_ n: Int, _ rule: String) throws(ParseFailure) -> UInt32 {
        precondition(n >= 0 && n <= 32)
        if n == 0 { return 0 }
        if count < n {
            refill()
            if count < n {
                throw ParseFailure(offset: byteOffset, rule: rule, reason: .unexpectedEnd(needed: n, available: count))
            }
        }
        let v = UInt32(truncatingIfNeeded: buffer & ((1 << UInt64(n)) - 1))
        buffer >>= UInt64(n)
        count -= n
        return v
    }

    @inlinable
    public mutating func bit(_ rule: String) throws(ParseFailure) -> UInt32 { try bits(1, rule) }

    /// Returns up to `n` (≤ 32) upcoming bits, zero-padded past the end, and the
    /// number of real bits available.
    @inlinable
    public mutating func peek(_ n: Int) -> (value: UInt32, available: Int) {
        if count < n { refill() }
        return (UInt32(truncatingIfNeeded: buffer & ((1 << UInt64(n)) - 1)), count)
    }

    /// Consumes bits previously inspected with `peek`. Caller guarantees `n <= available`.
    @inlinable
    public mutating func consume(_ n: Int) {
        precondition(n <= count)
        buffer >>= UInt64(n)
        count -= n
    }

    /// Discards bits up to the next byte boundary.
    public mutating func alignToByte() {
        let drop = count % 8
        buffer >>= UInt64(drop)
        count -= drop
    }

    /// After `alignToByte`, takes `n` whole bytes as a slice (Deflate stored blocks).
    public mutating func alignedBytes(_ n: Int, _ rule: String) throws(ParseFailure) -> ByteSlice {
        precondition(count % 8 == 0, "call alignToByte first")
        // Return buffered whole bytes to the input.
        index -= count / 8
        buffer = 0
        count = 0
        guard n >= 0, n <= end - index else {
            throw ParseFailure(offset: index, rule: rule, reason: .unexpectedEnd(needed: n, available: end - index))
        }
        defer { index += n }
        return ByteSlice(storage: storage, lowerBound: index, upperBound: index + n)
    }

    /// After `alignToByte`, the unread remainder as a cursor (e.g. zlib trailer).
    public mutating func remainderCursor() -> ByteCursor {
        precondition(count % 8 == 0, "call alignToByte first")
        index -= count / 8
        buffer = 0
        count = 0
        let slice = ByteSlice(storage: storage, lowerBound: index, upperBound: end)
        index = end
        return slice.cursor()
    }
}
