// Windows/OS2 device-independent bitmap grammar (BMP files and ICO/CUR entries).
//
//   bmp      := "BM" fileSize:u32le reserved:u32le pixelOffset:u32le dib
//   dib      := headerSize:u32le header(headerSize) masks? palette pixels
//   header(12)            := width:u16le height:u16le planes:u16le{1} bpp:u16le           (OS/2 1.x)
//   header(40|52|56|108|124) := width:i32le height:i32le planes:u16le{1} bpp:u16le
//                            compression:u32le imageSize xppm yppm clrUsed clrImportant
//                            [rgbMask:u32le{3} (52+)] [aMask (56+)] [colour space, profile (108+)]
//   header(16..64, other) := OS/2 2.x: same leading fields, OS/2 compression codes
//   masks    := r:u32le g:u32le b:u32le [a:u32le]  after a 40-byte header with BITFIELDS / ALPHABITFIELDS
//   palette  := (b g r [x])^{n}                   3-byte entries for OS/2 1.x, else 4-byte
//
// Policy: embedded JPEG/PNG, OS/2 Huffman-1D and RLE24, and 64-bit BMPs are
// rejected (Chromium does not render them either). Missing RLE pixels are
// transparent. 32-bit BI_RGB ignores the fourth byte (it is not alpha).

public import CodecCore

public enum DIBCompression: Sendable, Equatable {
    case rgb, rle8, rle4, bitfields
}

public struct DIBMasks: Sendable, Equatable {
    public var r, g, b, a: UInt32
    public init(r: UInt32, g: UInt32, b: UInt32, a: UInt32) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

public struct DIBImage: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var topDown: Bool
    public var bitsPerPixel: Int
    public var compression: DIBCompression
    public var masks: DIBMasks?
    public var palette: [RGB8]
    /// Pixel data region (the decoder never reads outside it).
    public var pixels: ByteSlice
}

public enum DIBGrammar {
    static let infoSizes: Set<Int> = [40, 52, 56, 108, 124]

    /// Parses a DIB header + optional masks + palette starting at `c`.
    /// - Parameters:
    ///   - pixelData: for BMP files, the slice from `pixelOffset` to EOF; for ICO
    ///     entries, nil (pixels follow the palette directly).
    ///   - heightIsDoubled: ICO/CUR entries store XOR+AND heights.
    static func dib(_ c: inout ByteCursor, input: ByteSlice, pixelOffset: Int?, heightIsDoubled: Bool,
                    limits: DecodeLimits) throws(ParseFailure) -> DIBImage {
        let at = c.position
        let headerSize = Int(try c.u32le("DIB.headerSize"))
        let isCore = headerSize == 12
        let isInfo = infoSizes.contains(headerSize)
        let isOS2v2 = !isCore && !isInfo && (16...64).contains(headerSize)
        guard isCore || isInfo || isOS2v2 else {
            throw ParseFailure(offset: at, rule: "DIB.headerSize", reason: .invalid("header size \(headerSize)"))
        }
        var h = try c.bytes(headerSize - 4, "DIB.header").cursor()

        let width: Int, rawHeight: Int
        if isCore {
            width = Int(try h.u16le("DIB.width"))
            rawHeight = Int(try h.u16le("DIB.height"))
        } else {
            width = Int(Int32(bitPattern: try h.u32le("DIB.width")))
            rawHeight = Int(Int32(bitPattern: try h.u32le("DIB.height")))
        }
        _ = try h.u16le("DIB.planes", require: "planes must be 1") { $0 == 1 }
        let bpp = Int(try h.u16le("DIB.bitCount"))

        var compressionCode: UInt32 = 0
        var clrUsed = 0
        if !isCore && h.remaining >= 4 { compressionCode = try h.u32le("DIB.compression") }
        if !isCore && h.remaining >= 12 { try h.skip(12) }  // imageSize, xppm, yppm
        if !isCore && h.remaining >= 4 { clrUsed = Int(try h.u32le("DIB.clrUsed")) }
        if !isCore && h.remaining >= 4 { _ = try h.u32le("DIB.clrImportant") }

        // Masks inside V2+ headers.
        var masks: DIBMasks?
        if isInfo && headerSize >= 52 {
            masks = DIBMasks(r: try h.u32le("DIB.redMask"), g: try h.u32le("DIB.greenMask"), b: try h.u32le("DIB.blueMask"),
                             a: headerSize >= 56 ? try h.u32le("DIB.alphaMask") : 0)
        }

        // Width/height.
        guard width > 0 else { throw ParseFailure(offset: at + 4, rule: "DIB.width", reason: .invalid("width \(width)")) }
        guard rawHeight != 0, rawHeight != Int(Int32.min) else {
            throw ParseFailure(offset: at + 8, rule: "DIB.height", reason: .invalid("height \(rawHeight)"))
        }
        let topDown = rawHeight < 0
        var height = abs(rawHeight)
        if heightIsDoubled { height /= 2 }
        try limits.checkDimensions(width: width, height: height, at: at, rule: "DIB")

        // Compression.
        let compression: DIBCompression
        switch (compressionCode, isOS2v2) {
        case (0, _): compression = .rgb
        case (1, _): compression = .rle8
        case (2, _): compression = .rle4
        case (3, false), (6, false): compression = .bitfields
        default:
            throw ParseFailure(offset: at + 16, rule: "DIB.compression", reason: .invalid("unsupported compression \(compressionCode)\(isOS2v2 ? " (OS/2)" : "")"))
        }

        // Bit depth vs compression.
        let validDepth: Bool
        switch compression {
        case .rgb: validDepth = [1, 2, 4, 8, 16, 24, 32].contains(bpp)
        case .rle8: validDepth = bpp == 8
        case .rle4: validDepth = bpp == 4
        case .bitfields: validDepth = bpp == 16 || bpp == 32
        }
        guard validDepth else {
            throw ParseFailure(offset: at + 14, rule: "DIB.bitCount", reason: .invalid("\(bpp) bpp with \(compression)"))
        }
        guard !(topDown && (compression == .rle4 || compression == .rle8)) else {
            throw ParseFailure(offset: at + 8, rule: "DIB.height", reason: .invalid("top-down RLE bitmap"))
        }

        // Masks following a 40-byte header.
        if compression == .bitfields && masks == nil {
            masks = DIBMasks(r: try c.u32le("masks.red"), g: try c.u32le("masks.green"), b: try c.u32le("masks.blue"),
                             a: compressionCode == 6 ? try c.u32le("masks.alpha") : 0)
        }
        if compression != .bitfields { masks = nil }  // masks in V4/V5 headers only apply to BITFIELDS
        if let m = masks { try validate(m, bpp: bpp, at: at) }

        // Palette.
        let entrySize = isCore ? 3 : 4
        var palette: [RGB8] = []
        if bpp <= 8 {
            let maxEntries = 1 << bpp
            var count = clrUsed == 0 ? maxEntries : clrUsed
            guard count <= 1 << 16 else {
                throw ParseFailure(offset: at, rule: "DIB.clrUsed", reason: .invalid("palette of \(count) entries"))
            }
            // The palette may not run into the pixel data.
            if let off = pixelOffset, off > c.position {
                count = min(count, (off - c.position) / entrySize)
            }
            guard c.remaining >= count * entrySize else {
                throw ParseFailure(offset: c.position, rule: "palette", reason: .unexpectedEnd(needed: count * entrySize, available: c.remaining))
            }
            for i in 0..<count {
                let b = try c.u8(), g = try c.u8(), r = try c.u8()
                if entrySize == 4 { _ = try c.u8() }
                if i < maxEntries { palette.append(RGB8(r: r, g: g, b: b)) }
            }
            guard !palette.isEmpty else { throw c.fail("palette", .invalid("empty palette")) }
        } else if clrUsed > 0, pixelOffset == nil {
            // Optional palette for >8bpp images in ICO entries: skip it.
            try c.skip(min(clrUsed, 1 << 16) * entrySize, "palette")
        }

        // Pixel data region.
        let pixels: ByteSlice
        if let off = pixelOffset, off >= c.position - input.lowerBound + input.lowerBound, off <= input.upperBound, off != 0 {
            var pc = input.cursor()
            try pc.skip(off - input.lowerBound)
            pixels = pc.rest()
        } else {
            pixels = c.rest()
        }

        // Uncompressed images must contain every row (padding included).
        if compression == .rgb || compression == .bitfields {
            let stride = ((width * bpp + 31) / 32) * 4
            let needed = stride * height
            guard pixels.count >= needed else {
                throw ParseFailure(offset: pixels.lowerBound, rule: "pixels", reason: .unexpectedEnd(needed: needed, available: pixels.count))
            }
        }
        return DIBImage(width: width, height: height, topDown: topDown, bitsPerPixel: bpp, compression: compression,
                        masks: masks, palette: palette, pixels: pixels)
    }

    static func validate(_ m: DIBMasks, bpp: Int, at: Int) throws(ParseFailure) {
        let limit: UInt64 = bpp == 16 ? 0xFFFF : 0xFFFF_FFFF
        for v in [m.r, m.g, m.b, m.a] {
            guard UInt64(v) <= limit else { throw ParseFailure(offset: at, rule: "masks", reason: .invalid("mask exceeds \(bpp) bits")) }
            // Contiguous run of ones (or empty).
            if v != 0 {
                let shifted = v >> v.trailingZeroBitCount
                guard shifted & (shifted &+ 1) == 0 else {
                    throw ParseFailure(offset: at, rule: "masks", reason: .invalid("non-contiguous mask 0x\(String(v, radix: 16))"))
                }
            }
        }
        guard m.r & m.g == 0, m.r & m.b == 0, m.g & m.b == 0, (m.r | m.g | m.b) & m.a == 0 else {
            throw ParseFailure(offset: at, rule: "masks", reason: .invalid("overlapping masks"))
        }
    }

    /// bmp := "BM" fileSize reserved pixelOffset dib
    public static func bmp(_ input: ByteSlice, limits: DecodeLimits = .default) throws(ParseFailure) -> DIBImage {
        guard input.count <= limits.maxInputBytes else {
            throw ParseFailure(offset: 0, rule: "bmp", reason: .limitExceeded("input \(input.count) bytes"))
        }
        var c = input.cursor()
        try c.expect([0x42, 0x4D], "bmp.signature")
        _ = try c.u32le("bmp.fileSize")  // frequently wrong in the wild; not used
        _ = try c.u32le("bmp.reserved")
        let offset = Int(try c.u32le("bmp.pixelOffset"))
        guard offset == 0 || offset <= input.count else {
            throw ParseFailure(offset: 10, rule: "bmp.pixelOffset", reason: .invalid("offset \(offset) beyond end of file"))
        }
        return try dib(&c, input: input, pixelOffset: offset == 0 ? nil : input.lowerBound + offset, heightIsDoubled: false, limits: limits)
    }
}
