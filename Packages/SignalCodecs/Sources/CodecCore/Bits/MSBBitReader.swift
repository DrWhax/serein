// Most-significant-bit-first bit reader over decoder-owned bytes (JPEG entropy
// data after unstuffing, H.264 RBSP after emulation-prevention removal).
//
// Two exhaustion policies:
//   * .fail     — reading past the end throws (bitstreams where truncation is an error);
//   * .zeroFill — reading past the end yields zero bits and sets `exhausted`
//                 (libjpeg's behaviour for truncated scans, which browsers inherit).

public struct MSBBitReader: Sendable {
    public enum Exhaustion: Sendable { case fail, zeroFill }

    @usableFromInline let bytes: [UInt8]
    @usableFromInline var index = 0
    @usableFromInline var buffer: UInt64 = 0
    @usableFromInline var count = 0
    public let policy: Exhaustion
    @usableFromInline var _exhausted = false
    public var exhausted: Bool { _exhausted }

    public init(_ bytes: [UInt8], policy: Exhaustion) {
        self.bytes = bytes
        self.policy = policy
    }

    public var bitsRemaining: Int { (bytes.count - index) * 8 + count }

    @inlinable
    mutating func refill() {
        while count <= 56 && index < bytes.count {
            buffer |= UInt64(bytes[index]) << UInt64(56 - count)
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
                guard policy == .zeroFill else {
                    throw ParseFailure(offset: index, rule: rule, reason: .unexpectedEnd(needed: n, available: count))
                }
                _exhausted = true
                count = n  // missing bits are zeros (buffer is already zero-padded)
            }
        }
        let v = UInt32(truncatingIfNeeded: buffer >> UInt64(64 - n))
        buffer <<= UInt64(n)
        count -= n
        return v
    }

    @inlinable
    public mutating func bit(_ rule: String) throws(ParseFailure) -> UInt32 { try bits(1, rule) }

    /// Discards bits to the next byte boundary.
    public mutating func alignToByte() {
        let drop = count % 8
        buffer <<= UInt64(drop)
        count -= drop
    }

    /// Bit position (for error offsets).
    public var bitPosition: Int { index * 8 - count }
}
