// ICO / CUR container grammar.
//
//   ico     := reserved:u16le{0} type:u16le{1,2} count:u16le{1..} entry{count}
//   entry   := width:u8 height:u8 colours:u8 reserved:u8 planes/hotX:u16le bpp/hotY:u16le
//              size:u32le offset:u32le { offset < file }   (size is advisory, see below)
//   image   := PNG | DIB (height doubled: XOR bitmap then 1-bpp AND mask)
//
// The decoder chooses the largest entry (then highest bit depth), as Chromium does
// when no size is requested.

public import CodecCore
import ImagePNG

public struct ICOEntry: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var bitCount: Int
    public var data: ByteSlice
    public var isPNG: Bool
}

public enum ICOGrammar {
    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public static func file(_ input: ByteSlice, limits: DecodeLimits = .default) throws(ParseFailure) -> [ICOEntry] {
        guard input.count <= limits.maxInputBytes else {
            throw ParseFailure(offset: 0, rule: "ico", reason: .limitExceeded("input \(input.count) bytes"))
        }
        var c = input.cursor()
        guard try c.u16le("ico.reserved") == 0 else { throw ParseFailure(offset: 0, rule: "ico.reserved", reason: .invalid("not 0")) }
        let type = try c.u16le("ico.type")
        guard type == 1 || type == 2 else { throw ParseFailure(offset: 2, rule: "ico.type", reason: .invalid("type \(type)")) }
        let count = Int(try c.u16le("ico.count"))
        guard count >= 1 else { throw ParseFailure(offset: 4, rule: "ico.count", reason: .invalid("no images")) }

        var entries: [ICOEntry] = []
        for i in 0..<count {
            let at = c.position
            let w = Int(try c.u8("entry.width")), h = Int(try c.u8("entry.height"))
            _ = try c.u8("entry.colours"); _ = try c.u8("entry.reserved")
            _ = try c.u16le("entry.planes"); let bpp = Int(try c.u16le("entry.bitCount"))
            let size = Int(try c.u32le("entry.size")), offset = Int(try c.u32le("entry.offset"))
            guard offset >= 6 + 16 * count, size > 0, offset < input.count else {
                throw ParseFailure(offset: at, rule: "entry[\(i)]", reason: .invalid("image at \(offset)+\(size) outside file"))
            }
            // The size field is advisory (often wrong in cursors); the embedded PNG or DIB
            // is self-delimiting, so its region runs from `offset` to the end of the file.
            var dc = input.cursor()
            try dc.skip(offset)
            let data = dc.rest()
            let isPNG = data.peekPrefix(8) == pngSignature
            // In cursors the bit-count field holds the hotspot.
            entries.append(ICOEntry(width: w == 0 ? 256 : w, height: h == 0 ? 256 : h, bitCount: type == 2 ? 0 : bpp, data: data, isPNG: isPNG))
        }
        return entries
    }
}

extension ByteSlice {
    func peekPrefix(_ n: Int) -> [UInt8]? { cursor().peek(n)?.copyBytes() }
}

public enum ICODecoder {
    public static func decode(_ bytes: [UInt8], limits: DecodeLimits = .default) throws(ParseFailure) -> PixelBuffer {
        let entries = try ICOGrammar.file(ByteSlice(bytes), limits: limits)
        let best = entries.max { a, b in (a.width * a.height, a.bitCount) < (b.width * b.height, b.bitCount) }!
        return try decode(best, limits: limits)
    }

    public static func decode(_ e: ICOEntry, limits: DecodeLimits = .default) throws(ParseFailure) -> PixelBuffer {
        if e.isPNG { return try PNGDecoder.decode(e.data.copyBytes(), limits: limits).stillImage }

        var c = e.data.cursor()
        let dib = try DIBGrammar.dib(&c, input: e.data, pixelOffset: nil, heightIsDoubled: true, limits: limits)
        guard dib.compression == .rgb || dib.compression == .bitfields else {
            throw ParseFailure(offset: e.data.lowerBound, rule: "ICO.DIB", reason: .invalid("compressed icon bitmap"))
        }
        // XOR bitmap, then the AND mask (1 bpp, rows padded to 32 bits).
        let xorStride = ((dib.width * dib.bitsPerPixel + 31) / 32) * 4
        var pc = dib.pixels.cursor()
        let xorSlice = try pc.bytes(xorStride * dib.height, "ICO.xor")
        var xorDIB = dib
        xorDIB.pixels = xorSlice
        var img = try DIBDecoder.decode(xorDIB)

        // 32-bit icons carry alpha in the fourth byte; use it if any pixel is non-zero.
        if dib.bitsPerPixel == 32 && dib.compression == .rgb {
            var xc = xorSlice.cursor()
            var alpha = [UInt8](repeating: 0, count: dib.width * dib.height)
            var any = false
            for fileRow in 0..<dib.height {
                let y = DIBDecoder.row(dib, fileRow)
                for x in 0..<dib.width {
                    _ = try xc.u8(); _ = try xc.u8(); _ = try xc.u8()
                    let a = try xc.u8()
                    alpha[y * dib.width + x] = a
                    any = any || a != 0
                }
            }
            if any {
                for i in 0..<alpha.count { img.rgba[i * 4 + 3] = alpha[i] }
                return img
            }
        }

        // AND mask: 1 = transparent. A missing mask (truncated entry) means opaque.
        let andStride = ((dib.width + 31) / 32) * 4
        guard pc.remaining >= andStride * dib.height else { return img }
        for fileRow in 0..<dib.height {
            var r = try pc.bytes(andStride, "ICO.and").cursor()
            let y = DIBDecoder.row(dib, fileRow)
            var byte: UInt8 = 0
            for x in 0..<dib.width {
                if x % 8 == 0 { byte = try r.u8() }
                if (byte >> UInt8(7 - x % 8)) & 1 == 1 {
                    let i = (y * dib.width + x) * 4
                    img.rgba[i] = 0; img.rgba[i + 1] = 0; img.rgba[i + 2] = 0; img.rgba[i + 3] = 0
                }
            }
        }
        return img
    }
}
