// LSB-first bit writer (Deflate). Huffman codes are written MSB-first by the caller
// passing bit-reversed codes.

public struct LSBBitWriter: Sendable {
    public private(set) var bytes: [UInt8] = []
    var buffer: UInt64 = 0
    var count = 0

    public init(capacity: Int = 0) { bytes.reserveCapacity(capacity) }

    public mutating func write(_ value: UInt32, _ n: Int) {
        precondition(n >= 0 && n <= 32)
        buffer |= UInt64(value & (n == 32 ? .max : (1 << UInt32(n)) - 1)) << UInt64(count)
        count += n
        while count >= 8 {
            bytes.append(UInt8(truncatingIfNeeded: buffer))
            buffer >>= 8
            count -= 8
        }
    }

    public mutating func alignToByte() {
        if count > 0 { write(0, 8 - count) }
    }

    public mutating func appendAligned(_ data: ArraySlice<UInt8>) {
        precondition(count == 0)
        bytes.append(contentsOf: data)
    }

    public var bitCount: Int { bytes.count * 8 + count }

    public mutating func finish() -> [UInt8] {
        alignToByte()
        return bytes
    }
}
