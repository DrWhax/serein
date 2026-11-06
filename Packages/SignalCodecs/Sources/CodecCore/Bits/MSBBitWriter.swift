// MSB-first bit writer (MP3 side information and main data, JPEG-style bitstreams).

public struct MSBBitWriter: Sendable {
    public private(set) var bytes: [UInt8] = []
    var buffer: UInt64 = 0
    var count = 0

    public init(capacity: Int = 0) { bytes.reserveCapacity(capacity) }

    /// Writes the low `n` (0…32) bits of `value`, most significant first.
    public mutating func write(_ value: UInt32, _ n: Int) {
        precondition(n >= 0 && n <= 32)
        guard n > 0 else { return }
        let v = UInt64(value) & ((1 << UInt64(n)) - 1)
        buffer = buffer << UInt64(n) | v
        count += n
        while count >= 8 {
            bytes.append(UInt8(truncatingIfNeeded: buffer >> UInt64(count - 8)))
            count -= 8
        }
        buffer &= (1 << UInt64(count)) - 1
    }

    public mutating func write(_ value: Int, _ n: Int) {
        precondition(value >= 0)
        write(UInt32(truncatingIfNeeded: value), n)
    }

    public mutating func alignToByte() {
        if count > 0 { write(0 as UInt32, 8 - count) }
    }

    public var bitCount: Int { bytes.count * 8 + count }

    public mutating func finish() -> [UInt8] {
        alignToByte()
        return bytes
    }
}
