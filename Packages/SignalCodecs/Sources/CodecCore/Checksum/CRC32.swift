// CRC-32 (ISO-HDLC / IEEE 802.3, reflected, poly 0xEDB88320) as used by PNG and gzip.

public struct CRC32: Sendable {
    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public private(set) var state: UInt32 = 0xFFFF_FFFF
    public init() {}

    public mutating func update(_ slice: ByteSlice) {
        var c = state
        let t = CRC32.table
        slice.forEachByte { b in c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        state = c
    }

    public mutating func update(_ bytes: [UInt8]) { update(ByteSlice(bytes)) }

    public var value: UInt32 { state ^ 0xFFFF_FFFF }

    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var c = CRC32()
        c.update(bytes)
        return c.value
    }
}
