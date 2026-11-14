// CRC-32 (ISO-HDLC / IEEE 802.3, reflected, poly 0xEDB88320) as used by PNG and gzip.

public struct CRC32: Sendable {
    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public private(set) var state: UInt32 = 0xFFFF_FFFF
    public init() {}

    /// Slicing-by-8: tables[k][n] is the CRC of byte n followed by k zero bytes.
    static let slices: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 8 * 256)
        for n in 0..<256 { t[n] = table[n] }
        for k in 1..<8 {
            for n in 0..<256 {
                let prev = t[(k - 1) * 256 + n]
                t[k * 256 + n] = table[Int(prev & 0xFF)] ^ (prev >> 8)
            }
        }
        return t
    }()

    public mutating func update(_ slice: ByteSlice) {
        var c = state
        let bytes = slice.storage
        let s = bytes.span
        let t8 = CRC32.slices
        let t = t8.span
        var i = slice.lowerBound
        let end = slice.upperBound
        while i + 8 <= end {
            let lo = c ^ (UInt32(s[i]) | UInt32(s[i + 1]) << 8 | UInt32(s[i + 2]) << 16 | UInt32(s[i + 3]) << 24)
            let hi = UInt32(s[i + 4]) | UInt32(s[i + 5]) << 8 | UInt32(s[i + 6]) << 16 | UInt32(s[i + 7]) << 24
            c = t[7 * 256 + Int(lo & 0xFF)] ^ t[6 * 256 + Int((lo >> 8) & 0xFF)] ^ t[5 * 256 + Int((lo >> 16) & 0xFF)] ^ t[4 * 256 + Int(lo >> 24)]
                ^ t[3 * 256 + Int(hi & 0xFF)] ^ t[2 * 256 + Int((hi >> 8) & 0xFF)] ^ t[256 + Int((hi >> 16) & 0xFF)] ^ t[Int(hi >> 24)]
            i += 8
        }
        while i < end {
            c = t[Int((c ^ UInt32(s[i])) & 0xFF)] ^ (c >> 8)
            i += 1
        }
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
