// Adler-32 (RFC 1950 §8.2) over decompressed zlib output.

public struct Adler32: Sendable {
    private var a: UInt32 = 1
    private var b: UInt32 = 0
    public init() {}

    public mutating func update(_ bytes: [UInt8]) {
        let s = bytes.span
        var a = self.a, b = self.b
        var i = 0
        while i < s.count {
            let n = min(5552, s.count - i)  // largest n with no UInt32 overflow
            var j = i
            let end = i + n
            while j + 4 <= end {
                a &+= UInt32(s[j]); b &+= a
                a &+= UInt32(s[j + 1]); b &+= a
                a &+= UInt32(s[j + 2]); b &+= a
                a &+= UInt32(s[j + 3]); b &+= a
                j += 4
            }
            while j < end {
                a &+= UInt32(s[j])
                b &+= a
                j += 1
            }
            a %= 65521
            b %= 65521
            i = end
        }
        self.a = a
        self.b = b
    }

    public var value: UInt32 { b << 16 | a }

    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var c = Adler32()
        c.update(bytes)
        return c.value
    }
}
