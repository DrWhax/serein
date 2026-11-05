// Decodes a recognised DIB to RGBA8.

public import CodecCore

public enum BMPDecoder {
    public static func decode(_ bytes: [UInt8], limits: DecodeLimits = .default) throws(ParseFailure) -> PixelBuffer {
        try DIBDecoder.decode(try DIBGrammar.bmp(ByteSlice(bytes), limits: limits))
    }
}

enum DIBDecoder {
    static func decode(_ d: DIBImage) throws(ParseFailure) -> PixelBuffer {
        var out = PixelBuffer(transparentWidth: d.width, height: d.height)
        switch d.compression {
        case .rgb, .bitfields: try decodeUncompressed(d, &out)
        case .rle8, .rle4: try decodeRLE(d, &out)
        }
        return out
    }

    static func put(_ out: inout PixelBuffer, _ x: Int, _ y: Int, _ c: RGB8, _ a: UInt8 = 255) {
        let i = (y * out.width + x) * 4
        out.rgba[i] = c.r; out.rgba[i + 1] = c.g; out.rgba[i + 2] = c.b; out.rgba[i + 3] = a
    }

    static func row(_ d: DIBImage, _ fileRow: Int) -> Int { d.topDown ? fileRow : d.height - 1 - fileRow }

    struct Channel {
        let mask: UInt32, shift: Int, max: UInt32
        init(_ mask: UInt32) {
            self.mask = mask
            shift = mask == 0 ? 0 : mask.trailingZeroBitCount
            max = mask == 0 ? 0 : mask >> UInt32(shift)
        }
        /// Rescales an n-bit channel to 8 bits with rounding.
        func value(_ px: UInt32) -> UInt8 {
            guard max > 0 else { return 0 }
            let v = UInt64((px & mask) >> UInt32(shift))
            return UInt8((v * 255 + UInt64(max) / 2) / UInt64(max))
        }
    }

    static func decodeUncompressed(_ d: DIBImage, _ out: inout PixelBuffer) throws(ParseFailure) {
        let stride = ((d.width * d.bitsPerPixel + 31) / 32) * 4
        var c = d.pixels.cursor()
        let masks: DIBMasks? = d.compression == .bitfields ? d.masks
            : d.bitsPerPixel == 16 ? DIBMasks(r: 0x7C00, g: 0x03E0, b: 0x001F, a: 0)
            : d.bitsPerPixel == 32 ? DIBMasks(r: 0x00FF_0000, g: 0x0000_FF00, b: 0x0000_00FF, a: 0) : nil
        let channels = masks.map { [Channel($0.r), Channel($0.g), Channel($0.b), Channel($0.a)] }

        for fileRow in 0..<d.height {
            var r = try c.bytes(stride, "row").cursor()
            let y = row(d, fileRow)
            switch d.bitsPerPixel {
            case 1, 2, 4, 8:
                let bpp = d.bitsPerPixel
                var byte: UInt8 = 0
                var bitsLeft = 0
                for x in 0..<d.width {
                    if bitsLeft == 0 { byte = try r.u8(); bitsLeft = 8 }
                    bitsLeft -= bpp
                    let idx = Int(byte >> UInt8(bitsLeft)) & ((1 << bpp) - 1)
                    guard idx < d.palette.count else {
                        throw ParseFailure(offset: r.position, rule: "pixels", reason: .invalid("palette index \(idx) ≥ \(d.palette.count)"))
                    }
                    put(&out, x, y, d.palette[idx])
                }
            case 24:
                for x in 0..<d.width {
                    let b = try r.u8(), g = try r.u8(), rr = try r.u8()
                    put(&out, x, y, RGB8(r: rr, g: g, b: b))
                }
            case 16, 32:
                let ch = channels!
                for x in 0..<d.width {
                    let px = d.bitsPerPixel == 16 ? UInt32(try r.u16le()) : try r.u32le()
                    let a: UInt8 = ch[3].max > 0 ? ch[3].value(px) : 255
                    put(&out, x, y, RGB8(r: ch[0].value(px), g: ch[1].value(px), b: ch[2].value(px)), a)
                }
            default:
                throw ParseFailure(offset: 0, rule: "pixels", reason: .invalid("bit depth \(d.bitsPerPixel)"))
            }
        }
    }

    /// BI_RLE8 / BI_RLE4. Pixels not written stay transparent. Data ending
    /// before end-of-bitmap is accepted (the remainder stays transparent).
    static func decodeRLE(_ d: DIBImage, _ out: inout PixelBuffer) throws(ParseFailure) {
        var c = d.pixels.cursor()
        let four = d.compression == .rle4
        var x = 0, fileRow = 0

        func paint(_ idx: Int, at pos: Int) throws(ParseFailure) {
            guard idx < d.palette.count else {
                throw ParseFailure(offset: pos, rule: "RLE", reason: .invalid("palette index \(idx) ≥ \(d.palette.count)"))
            }
            if x < d.width && fileRow < d.height { put(&out, x, row(d, fileRow), d.palette[idx]) }
            x += 1
        }

        while fileRow < d.height, c.remaining >= 2 {
            let at = c.position
            let count = Int(try c.u8()), value = try c.u8()
            if count > 0 {
                // Encoded run.
                guard x + count <= d.width else {
                    throw ParseFailure(offset: at, rule: "RLE.run", reason: .invalid("run past end of row"))
                }
                for i in 0..<count {
                    let idx = four ? Int(i % 2 == 0 ? value >> 4 : value & 0x0F) : Int(value)
                    try paint(idx, at: at)
                }
                continue
            }
            switch value {
            case 0:  // end of line
                x = 0
                fileRow += 1
            case 1:  // end of bitmap
                return
            case 2:  // delta
                let dx = Int(try c.u8("RLE.delta")), dy = Int(try c.u8("RLE.delta"))
                x += dx
                fileRow += dy
                guard x <= d.width, fileRow <= d.height else {
                    throw ParseFailure(offset: at, rule: "RLE.delta", reason: .invalid("delta moves outside the image"))
                }
            default:  // absolute run of `value` pixels, padded to 16 bits
                let n = Int(value)
                guard x + n <= d.width else {
                    throw ParseFailure(offset: at, rule: "RLE.absolute", reason: .invalid("absolute run past end of row"))
                }
                let bytes = four ? (n + 1) / 2 : n
                var run = try c.bytes(bytes + (bytes & 1), "RLE.absolute").cursor()
                var byte: UInt8 = 0
                for i in 0..<n {
                    let idx: Int
                    if four {
                        if i % 2 == 0 { byte = try run.u8() }
                        idx = Int(i % 2 == 0 ? byte >> 4 : byte & 0x0F)
                    } else {
                        idx = Int(try run.u8())
                    }
                    try paint(idx, at: at)
                }
            }
        }
    }
}
