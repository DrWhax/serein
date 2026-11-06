// A seekable MSB-first bit cursor over decoder-owned bytes. Reads past the end yield zero
// bits (as a decoder reading into zero padding would); callers bound their reads by the
// positions the bitstream declares (e.g. MP3's part2_3_length) and may move back.

public protocol MSBBitSource {
    mutating func peek(_ n: Int) -> UInt32
    mutating func skip(_ n: Int, _ rule: String) throws(ParseFailure)
    var bitPosition: Int { get }
}

extension MSBBitReader: MSBBitSource {}

public struct MSBBitCursor: Sendable, MSBBitSource {
    @usableFromInline let bytes: [UInt8]
    /// Current position in bits; may be set anywhere ≥ 0 (beyond the end reads zeros).
    public var bitPosition: Int

    public init(_ bytes: [UInt8], bitPosition: Int = 0) {
        self.bytes = bytes
        self.bitPosition = max(0, bitPosition)
    }

    public var bitCount: Int { bytes.count * 8 }

    @inlinable
    public func peek(_ n: Int) -> UInt32 {
        precondition(n >= 1 && n <= 32)
        // Five bytes cover any 32-bit window starting mid-byte.
        let byte = bitPosition >> 3, shift = bitPosition & 7
        var acc: UInt64 = 0
        for i in 0 ..< 5 {
            let j = byte + i
            acc = acc << 8 | UInt64(j < bytes.count ? bytes[j] : 0)
        }
        return UInt32(truncatingIfNeeded: (acc << UInt64(24 + shift)) >> UInt64(64 - n))
    }

    @inlinable
    public mutating func bits(_ n: Int) -> UInt32 {
        if n == 0 { return 0 }
        let v = peek(n)
        bitPosition += n
        return v
    }

    @inlinable
    public mutating func bit() -> UInt32 { bits(1) }

    @inlinable
    public mutating func skip(_ n: Int, _ rule: String) { bitPosition += n }
}
