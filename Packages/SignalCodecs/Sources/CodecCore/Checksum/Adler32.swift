// Adler-32 (RFC 1950 §8.2) over decompressed zlib output.

public struct Adler32: Sendable {
    private var a: UInt32 = 1
    private var b: UInt32 = 0
    public init() {}

    public mutating func update(_ bytes: [UInt8]) {
        var i = 0
        while i < bytes.count {
            let n = min(5552, bytes.count - i)  // largest n with no UInt32 overflow
            for j in i..<(i + n) {
                a &+= UInt32(bytes[j])
                b &+= a
            }
            a %= 65521
            b %= 65521
            i += n
        }
    }

    public var value: UInt32 { b << 16 | a }

    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var c = Adler32()
        c.update(bytes)
        return c.value
    }
}
