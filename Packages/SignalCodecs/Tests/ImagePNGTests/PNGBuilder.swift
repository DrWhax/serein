// Minimal PNG writer for tests: stored (uncompressed) zlib, filter type 0, RGBA8.
@testable import CodecCore

struct PNGBuilder {
    var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }

    mutating func chunk(_ type: String, _ data: [UInt8], corruptCRC: Bool = false) {
        let t = Array(type.utf8)
        bytes += Self.be32(UInt32(data.count)) + t + data
        var crc = CRC32()
        crc.update(t + data)
        bytes += Self.be32(crc.value ^ (corruptCRC ? 1 : 0))
    }

    mutating func ihdr(_ w: Int, _ h: Int, depth: UInt8 = 8, colorType: UInt8 = 6, interlace: UInt8 = 0) {
        chunk("IHDR", Self.be32(UInt32(w)) + Self.be32(UInt32(h)) + [depth, colorType, 0, 0, interlace])
    }

    static func zlibStored(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var i = 0
        repeat {
            let n = min(65_535, data.count - i)
            let final: UInt8 = i + n == data.count ? 1 : 0
            out += [final, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            out += data[i..<(i + n)]
            i += n
        } while i < data.count
        return out + be32(Adler32.checksum(data))
    }

    /// Unfiltered RGBA8 scanlines for a solid or per-pixel image.
    static func rgbaScanlines(_ w: Int, _ h: Int, _ px: (Int, Int) -> [UInt8]) -> [UInt8] {
        var raw: [UInt8] = []
        for y in 0..<h {
            raw.append(0)
            for x in 0..<w { raw += px(x, y) }
        }
        return raw
    }

    mutating func idat(_ w: Int, _ h: Int, _ px: (Int, Int) -> [UInt8]) {
        chunk("IDAT", Self.zlibStored(Self.rgbaScanlines(w, h, px)))
    }

    mutating func actl(frames: UInt32, plays: UInt32) { chunk("acTL", Self.be32(frames) + Self.be32(plays)) }

    mutating func fctl(seq: UInt32, w: Int, h: Int, x: Int = 0, y: Int = 0, delay: (UInt16, UInt16) = (1, 10), dispose: UInt8 = 0, blend: UInt8 = 0) {
        chunk("fcTL", Self.be32(seq) + Self.be32(UInt32(w)) + Self.be32(UInt32(h)) + Self.be32(UInt32(x)) + Self.be32(UInt32(y))
              + Self.be16(delay.0) + Self.be16(delay.1) + [dispose, blend])
    }

    mutating func fdat(seq: UInt32, _ w: Int, _ h: Int, _ px: (Int, Int) -> [UInt8]) {
        chunk("fdAT", Self.be32(seq) + Self.zlibStored(Self.rgbaScanlines(w, h, px)))
    }

    mutating func iend() { chunk("IEND", []) }
}
