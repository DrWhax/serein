// WebP lossless (VP8L, RFC 9649) decoder, a port of libwebp's vp8l_dec.c /
// lossless.c semantics. Bitstream grammar (per RFC 9649 §3-§6):
//
//   vp8l    := 0x2F width-1:14 height-1:14 alpha:1 version:3{0} image(level0)
//   image   := [level0: (1 transform)* 0] cache? huffcodes pixels
//   transform := 00 predictor(bits:3+2, subimage) | 01 cross-colour(bits, subimage)
//              | 10 subtract-green | 11 colour-indexing(n:8+1, palette subimage)   (each at most once)
//   cache   := 1 bits:4{1..11} | 0
//   huffcodes := [level0: 1 meta(bits:3+2, subimage) | 0] group{num_groups}
//   group   := code(256+24+cache) code(256) code(256) code(256) code(40)
//   code    := 1 simple(n:1, symbols) | 0 lengths(code-length code, RLE 16/17/18)  { complete prefix code, or one symbol }
//
// The decoder checks every distance and length against the pixels decoded so far.

public import CodecCore

struct VP8LHuffman {
    // fast[bits] = (len << 16) | symbol, len 0 = slow path; single-symbol codes use len 0 & zeroBit.
    static let fastBits = 8
    var fast: [UInt32]
    var counts: [Int]
    var symbols: [UInt16]
    var single: Int?   // one symbol: consumes 0 bits

    /// libwebp BuildHuffmanTable validity: lengths ≤ 15, not all zero, and either a
    /// single symbol or a complete prefix code.
    init?(_ lengths: [Int]) {
        var counts = [Int](repeating: 0, count: 16)
        for l in lengths {
            guard l <= 15 else { return nil }
            counts[l] += 1
        }
        let used = lengths.count - counts[0]
        guard used > 0 else { return nil }
        if used == 1 {
            single = lengths.firstIndex { $0 > 0 }!
            fast = []; self.counts = []; symbols = []
            return
        }
        single = nil
        counts[0] = 0
        var left = 1
        for len in 1...15 {
            left <<= 1
            left -= counts[len]
            if left < 0 { return nil }
        }
        guard left == 0 else { return nil }  // incomplete
        var offs = [Int](repeating: 0, count: 17)
        for len in 1...15 { offs[len + 1] = offs[len] + counts[len] }
        var syms = [UInt16](repeating: 0, count: offs[16])
        for (s, l) in lengths.enumerated() where l > 0 { syms[offs[l]] = UInt16(s); offs[l] += 1 }
        var fast = [UInt32](repeating: 0, count: 1 << Self.fastBits)
        var code = 0, idx = 0
        for len in 1...15 {
            for _ in 0..<counts[len] {
                if len <= Self.fastBits {
                    var rev = 0, c = code
                    for _ in 0..<len { rev = rev << 1 | (c & 1); c >>= 1 }
                    var i = rev
                    while i < (1 << Self.fastBits) { fast[i] = UInt32(len << 16) | UInt32(syms[idx]); i += 1 << len }
                }
                code += 1; idx += 1
            }
            code <<= 1
        }
        self.fast = fast
        self.counts = counts
        symbols = syms
    }

    @inline(__always)
    func read(_ r: inout LSBBitReader) throws(ParseFailure) -> Int {
        if let s = single { return s }
        let (bits, available) = r.peek(Self.fastBits)
        let e = fast[Int(bits)]
        if e != 0 {
            let len = Int(e >> 16)
            guard len <= available else { throw ParseFailure(offset: r.byteOffset, rule: "VP8L.symbol", reason: .unexpectedEnd(needed: len, available: available)) }
            r.consume(len)
            return Int(e & 0xFFFF)
        }
        var code = 0, first = 0, index = 0
        for len in 1...15 {
            code |= Int(try r.bit("VP8L.symbol"))
            let count = counts[len]
            if code - count < first { return Int(symbols[index + (code - first)]) }
            index += count; first += count; first <<= 1; code <<= 1
        }
        throw ParseFailure(offset: r.byteOffset, rule: "VP8L.symbol", reason: .invalid("invalid code"))
    }
}

struct VP8LGroup { var trees: [VP8LHuffman] }  // green, red, blue, alpha, distance

enum VP8LTransform {
    case predictor(bits: Int, data: [UInt32], xsize: Int)
    case crossColor(bits: Int, data: [UInt32], xsize: Int)
    case subtractGreen
    case colorIndexing(bits: Int, palette: [UInt32], xsize: Int)
}

public enum VP8LDecoder {
    static let codeLengthOrder = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
    static let codeToPlane: [Int] = [
        0x18, 0x07, 0x17, 0x19, 0x28, 0x06, 0x27, 0x29, 0x16, 0x1a, 0x26, 0x2a, 0x38, 0x05, 0x37, 0x39, 0x15, 0x1b, 0x36, 0x3a, 0x25, 0x2b, 0x48, 0x04,
        0x47, 0x49, 0x14, 0x1c, 0x35, 0x3b, 0x46, 0x4a, 0x24, 0x2c, 0x58, 0x45, 0x4b, 0x34, 0x3c, 0x03, 0x57, 0x59, 0x13, 0x1d, 0x56, 0x5a, 0x23, 0x2d,
        0x44, 0x4c, 0x55, 0x5b, 0x33, 0x3d, 0x68, 0x02, 0x67, 0x69, 0x12, 0x1e, 0x66, 0x6a, 0x22, 0x2e, 0x54, 0x5c, 0x43, 0x4d, 0x65, 0x6b, 0x32, 0x3e,
        0x78, 0x01, 0x77, 0x79, 0x53, 0x5d, 0x11, 0x1f, 0x64, 0x6c, 0x42, 0x4e, 0x76, 0x7a, 0x21, 0x2f, 0x75, 0x7b, 0x31, 0x3f, 0x63, 0x6d, 0x52, 0x5e,
        0x00, 0x74, 0x7c, 0x41, 0x4f, 0x10, 0x20, 0x62, 0x6e, 0x30, 0x73, 0x7d, 0x51, 0x5f, 0x40, 0x72, 0x7e, 0x61, 0x6f, 0x50, 0x71, 0x7f, 0x60, 0x70,
    ]
    static let alphabetSizes = [256 + 24, 256, 256, 256, 40]

    /// Decodes a "VP8L" chunk payload to ARGB pixels.
    public static func decode(_ payload: ByteSlice, limits: DecodeLimits = .default) throws(ParseFailure) -> (width: Int, height: Int, argb: [UInt32]) {
        var c = payload.cursor()
        try c.expect([0x2F], "VP8L.signature")
        var r = LSBBitReader(c.rest())
        let w = Int(try r.bits(14, "VP8L.width")) + 1
        let h = Int(try r.bits(14, "VP8L.height")) + 1
        _ = try r.bit("VP8L.alpha")
        guard try r.bits(3, "VP8L.version") == 0 else { throw ParseFailure(offset: payload.lowerBound, rule: "VP8L.version", reason: .invalid("version ≠ 0")) }
        try limits.checkDimensions(width: w, height: h, at: payload.lowerBound, rule: "VP8L")
        return (w, h, try decodeLevel0(&r, w, h, limits: limits))
    }

    /// ALPH chunk with compression 1: a headerless VP8L stream of the given size;
    /// the green channel is the alpha plane.
    static func decodeAlpha(_ data: ByteSlice, width: Int, height: Int, limits: DecodeLimits) throws(ParseFailure) -> [UInt8] {
        var r = LSBBitReader(data)
        return try decodeLevel0(&r, width, height, limits: limits).map { UInt8(truncatingIfNeeded: $0 >> 8) }
    }

    static func subsample(_ size: Int, _ bits: Int) -> Int { (size + (1 << bits) - 1) >> bits }

    static func decodeLevel0(_ r: inout LSBBitReader, _ width: Int, _ height: Int, limits: DecodeLimits) throws(ParseFailure) -> [UInt32] {
        var transforms: [VP8LTransform] = []
        var seen = 0
        var xsize = width
        while try r.bit("VP8L.transform") == 1 {
            let type = Int(try r.bits(2, "VP8L.transform.type"))
            guard seen & (1 << type) == 0 else { throw ParseFailure(offset: r.byteOffset, rule: "VP8L.transform", reason: .invalid("transform \(type) repeated")) }
            seen |= 1 << type
            switch type {
            case 0, 1:
                let bits = Int(try r.bits(3, "VP8L.transform.bits")) + 2
                let data = try decodeSubImage(&r, subsample(xsize, bits), subsample(height, bits), limits: limits)
                transforms.append(type == 0 ? .predictor(bits: bits, data: data, xsize: xsize) : .crossColor(bits: bits, data: data, xsize: xsize))
            case 2:
                transforms.append(.subtractGreen)
            default:
                let n = Int(try r.bits(8, "VP8L.palette.size")) + 1
                let bits = n > 16 ? 0 : n > 4 ? 1 : n > 2 ? 2 : 3
                let raw = try decodeSubImage(&r, n, 1, limits: limits)
                // Delta-coded palette, padded with transparent black.
                var pal = [UInt32](repeating: 0, count: 1 << (8 >> bits))
                pal[0] = raw[0]
                for i in 1..<n { pal[i] = addPixels(raw[i], pal[i - 1]) }
                transforms.append(.colorIndexing(bits: bits, palette: pal, xsize: xsize))
                xsize = subsample(xsize, bits)
            }
        }
        var pixels = try decodeImageData(&r, xsize, height, isLevel0: true, limits: limits)
        // Inverse transforms in reverse order.
        for t in transforms.reversed() { pixels = inverse(t, pixels, height) }
        return pixels
    }

    static func decodeSubImage(_ r: inout LSBBitReader, _ w: Int, _ h: Int, limits: DecodeLimits) throws(ParseFailure) -> [UInt32] {
        try decodeImageData(&r, w, h, isLevel0: false, limits: limits)
    }

    static func readCode(_ r: inout LSBBitReader, alphabet: Int) throws(ParseFailure) -> VP8LHuffman {
        var lengths = [Int](repeating: 0, count: alphabet)
        let at = r.byteOffset
        if try r.bit("code.simple") == 1 {
            let n = Int(try r.bit("code.simple.count")) + 1
            let firstIs8 = try r.bit("code.simple.width") == 1
            let s0 = Int(try r.bits(firstIs8 ? 8 : 1, "code.simple.symbol"))
            if s0 < alphabet { lengths[s0] = 1 }
            if n == 2 {
                let s1 = Int(try r.bits(8, "code.simple.symbol"))
                if s1 < alphabet { lengths[s1] = 1 }
            }
        } else {
            var clLengths = [Int](repeating: 0, count: 19)
            let numCodes = Int(try r.bits(4, "code.numCodes")) + 4
            for i in 0..<numCodes { clLengths[codeLengthOrder[i]] = Int(try r.bits(3, "code.clLength")) }
            guard let cl = VP8LHuffman(clLengths) else { throw ParseFailure(offset: at, rule: "VP8L.code", reason: .invalid("invalid code-length code")) }
            var maxSymbol = alphabet
            if try r.bit("code.useLength") == 1 {
                let nbits = 2 + 2 * Int(try r.bits(3, "code.lengthBits"))
                maxSymbol = 2 + Int(try r.bits(nbits, "code.maxSymbol"))
                guard maxSymbol <= alphabet else { throw ParseFailure(offset: at, rule: "VP8L.code", reason: .invalid("max_symbol \(maxSymbol) > \(alphabet)")) }
            }
            var symbol = 0, prev = 8
            while symbol < alphabet {
                if maxSymbol == 0 { break }
                maxSymbol -= 1
                let len = try cl.read(&r)
                if len < 16 {
                    lengths[symbol] = len
                    symbol += 1
                    if len != 0 { prev = len }
                } else {
                    let slot = len - 16
                    let extra = [2, 3, 7][slot], offset = [3, 3, 11][slot]
                    let repeatCount = Int(try r.bits(extra, "code.repeat")) + offset
                    guard symbol + repeatCount <= alphabet else { throw ParseFailure(offset: at, rule: "VP8L.code", reason: .invalid("repeat past alphabet")) }
                    let v = len == 16 ? prev : 0
                    for _ in 0..<repeatCount { lengths[symbol] = v; symbol += 1 }
                }
            }
        }
        guard let t = VP8LHuffman(lengths) else { throw ParseFailure(offset: at, rule: "VP8L.code", reason: .invalid("invalid prefix code")) }
        return t
    }

    static func decodeImageData(_ r: inout LSBBitReader, _ w: Int, _ h: Int, isLevel0: Bool, limits: DecodeLimits) throws(ParseFailure) -> [UInt32] {
        guard w * h <= limits.maxPixels else { throw ParseFailure(offset: r.byteOffset, rule: "VP8L", reason: .limitExceeded("\(w)x\(h)")) }
        var cacheBits = 0
        if try r.bit("VP8L.cache") == 1 {
            cacheBits = Int(try r.bits(4, "VP8L.cache.bits"))
            guard (1...11).contains(cacheBits) else { throw ParseFailure(offset: r.byteOffset, rule: "VP8L.cache", reason: .invalid("cache bits \(cacheBits)")) }
        }
        // Meta Huffman image. Group indices may be sparse: every declared group is read
        // from the stream, only referenced ones are kept (libwebp's remapping).
        var metaBits = 0, metaW = 0
        var meta: [Int] = []
        var totalGroups = 1
        var remap: [Int]?
        if isLevel0, try r.bit("VP8L.meta") == 1 {
            metaBits = Int(try r.bits(3, "VP8L.meta.bits")) + 2
            metaW = subsample(w, metaBits)
            let raw = try decodeSubImage(&r, metaW, subsample(h, metaBits), limits: limits).map { Int(($0 >> 8) & 0xFFFF) }
            totalGroups = (raw.max() ?? 0) + 1
            var map = [Int](repeating: -1, count: totalGroups)
            var n = 0
            meta = raw.map { g in
                if map[g] < 0 { map[g] = n; n += 1 }
                return map[g]
            }
            remap = map
        }
        return try decodeWithGroups(&r, w, h, cacheBits, metaBits, metaW, meta, totalGroups: totalGroups, remap: remap, limits: limits)
    }

    static func decodeWithGroups(_ r: inout LSBBitReader, _ w: Int, _ h: Int, _ cacheBits: Int, _ metaBits: Int, _ metaW: Int,
                                 _ meta: [Int], totalGroups: Int, remap: [Int]?, limits: DecodeLimits) throws(ParseFailure) -> [UInt32] {
        // libwebp: reject streams too short to hold the declared groups (≥ 20 bits each).
        guard r.bitsRemaining + 64 >= totalGroups * 20 else {
            throw ParseFailure(offset: r.byteOffset, rule: "VP8L.groups", reason: .invalid("\(totalGroups) groups in \(r.bitsRemaining) bits"))
        }
        let kept = remap.map { $0.filter { $0 >= 0 }.count } ?? totalGroups
        var groups: [VP8LGroup?] = [VP8LGroup?](repeating: nil, count: kept)
        for g in 0..<totalGroups {
            var trees: [VP8LHuffman] = []
            for j in 0..<5 {
                let size = alphabetSizes[j] + (j == 0 && cacheBits > 0 ? 1 << cacheBits : 0)
                trees.append(try readCode(&r, alphabet: size))
            }
            if let m = remap { if m[g] >= 0 { groups[m[g]] = VP8LGroup(trees: trees) } }
            else { groups[g] = VP8LGroup(trees: trees) }
        }
        let gs = groups.map { $0! }

        let total = w * h
        var px = [UInt32](repeating: 0, count: total)
        let cacheSize = cacheBits > 0 ? 1 << cacheBits : 0
        var cache = [UInt32](repeating: 0, count: cacheSize)
        var cached = 0
        @inline(__always) func insertCache(upTo n: Int) {
            guard cacheSize > 0 else { return }
            while cached < n {
                let v = px[cached]
                cache[Int((0x1e35_a7bd &* v) >> UInt32(32 - cacheBits))] = v
                cached += 1
            }
        }
        var pos = 0
        while pos < total {
            let x = pos % w, y = pos / w
            let group = metaBits == 0 ? gs[0] : gs[meta[(y >> metaBits) * metaW + (x >> metaBits)]]
            let code = try group.trees[0].read(&r)
            if code < 256 {
                let red = try group.trees[1].read(&r)
                let blue = try group.trees[2].read(&r)
                let alpha = try group.trees[3].read(&r)
                px[pos] = UInt32(alpha) << 24 | UInt32(red) << 16 | UInt32(code) << 8 | UInt32(blue)
                pos += 1
            } else if code < 256 + 24 {
                let length = try copyValue(code - 256, &r)
                let distSymbol = try group.trees[4].read(&r)
                let distCode = try copyValue(distSymbol, &r)
                let dist: Int
                if distCode > 120 { dist = distCode - 120 } else {
                    let d = codeToPlane[distCode - 1]
                    dist = max(1, (d >> 4) * w + 8 - (d & 0xF))
                }
                guard dist <= pos, length <= total - pos else {
                    throw ParseFailure(offset: r.byteOffset, rule: "VP8L.backref", reason: .invalid("distance \(dist), length \(length) at pixel \(pos)"))
                }
                for k in 0..<length { px[pos + k] = px[pos + k - dist] }
                pos += length
            } else {
                insertCache(upTo: pos)
                let key = code - 280
                guard key < cacheSize else { throw ParseFailure(offset: r.byteOffset, rule: "VP8L.cache", reason: .invalid("cache index \(key)")) }
                px[pos] = cache[key]
                pos += 1
            }
            insertCache(upTo: pos)
        }
        return px
    }

    @inline(__always)
    static func copyValue(_ symbol: Int, _ r: inout LSBBitReader) throws(ParseFailure) -> Int {
        if symbol < 4 { return symbol + 1 }
        let extra = (symbol - 2) >> 1
        let offset = (2 + (symbol & 1)) << extra
        return offset + Int(try r.bits(extra, "VP8L.extra")) + 1
    }

    // MARK: pixel arithmetic (lossless.c)

    @inline(__always) static func addPixels(_ a: UInt32, _ b: UInt32) -> UInt32 {
        let ag = (a & 0xFF00_FF00) &+ (b & 0xFF00_FF00)
        let rb = (a & 0x00FF_00FF) &+ (b & 0x00FF_00FF)
        return (ag & 0xFF00_FF00) | (rb & 0x00FF_00FF)
    }
    @inline(__always) static func average2(_ a: UInt32, _ b: UInt32) -> UInt32 { (((a ^ b) & 0xFEFE_FEFE) >> 1) &+ (a & b) }
    @inline(__always) static func clip255(_ a: Int) -> UInt32 { UInt32(a < 0 ? 0 : a > 255 ? 255 : a) }
    @inline(__always) static func ch(_ v: UInt32, _ s: UInt32) -> Int { Int((v >> s) & 0xFF) }
    static func clampedFull(_ c0: UInt32, _ c1: UInt32, _ c2: UInt32) -> UInt32 {
        var out: UInt32 = 0
        for s: UInt32 in [24, 16, 8, 0] { out |= clip255(ch(c0, s) + ch(c1, s) - ch(c2, s)) << s }
        return out
    }
    static func clampedHalf(_ c0: UInt32, _ c1: UInt32, _ c2: UInt32) -> UInt32 {
        let ave = average2(c0, c1)
        var out: UInt32 = 0
        for s: UInt32 in [24, 16, 8, 0] {
            let a = ch(ave, s), b = ch(c2, s)
            out |= clip255(a + (a - b) / 2) << s   // C division truncates toward zero, as Swift's
        }
        return out
    }
    static func select(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt32 {
        var d = 0
        for s: UInt32 in [24, 16, 8, 0] { d += abs(ch(b, s) - ch(c, s)) - abs(ch(a, s) - ch(c, s)) }
        return d <= 0 ? a : b
    }

    static func predict(_ mode: Int, _ left: UInt32, _ t: UInt32, _ tr: UInt32, _ tl: UInt32) -> UInt32 {
        switch mode {
        case 1: return left
        case 2: return t
        case 3: return tr
        case 4: return tl
        case 5: return average2(average2(left, tr), t)
        case 6: return average2(left, tl)
        case 7: return average2(left, t)
        case 8: return average2(tl, t)
        case 9: return average2(t, tr)
        case 10: return average2(average2(left, tl), average2(t, tr))
        case 11: return select(t, left, tl)
        case 12: return clampedFull(left, t, tl)
        case 13: return clampedHalf(left, t, tl)
        default: return 0xFF00_0000  // 0, 14, 15
        }
    }

    static func inverse(_ t: VP8LTransform, _ input: [UInt32], _ height: Int) -> [UInt32] {
        switch t {
        case .subtractGreen:
            return input.map { argb in
                let g = (argb >> 8) & 0xFF
                let rb = ((argb & 0x00FF_00FF) &+ (g << 16 | g)) & 0x00FF_00FF
                return (argb & 0xFF00_FF00) | rb
            }
        case .predictor(let bits, let data, let w):
            var out = input
            let tiles = subsample(w, bits)
            for y in 0..<height {
                for x in 0..<w {
                    let i = y * w + x
                    let pred: UInt32
                    if y == 0 { pred = x == 0 ? 0xFF00_0000 : out[i - 1] }
                    else if x == 0 { pred = out[i - w] }
                    else {
                        let mode = Int((data[(y >> bits) * tiles + (x >> bits)] >> 8) & 0xF)
                        // TR of the last column is the first pixel of the current row (memory layout).
                        pred = predict(mode, out[i - 1], out[i - w], out[i - w + 1], out[i - w - 1])
                    }
                    out[i] = addPixels(input[i], pred)
                }
            }
            return out
        case .crossColor(let bits, let data, let w):
            var out = input
            let tiles = subsample(w, bits)
            for y in 0..<height {
                for x in 0..<w {
                    let m = data[(y >> bits) * tiles + (x >> bits)]
                    let g2r = Int8(truncatingIfNeeded: m), g2b = Int8(truncatingIfNeeded: m >> 8), r2b = Int8(truncatingIfNeeded: m >> 16)
                    let argb = input[y * w + x]
                    let green = Int8(truncatingIfNeeded: argb >> 8)
                    var newRed = Int((argb >> 16) & 0xFF)
                    var newBlue = Int(argb & 0xFF)
                    newRed += (Int(g2r) * Int(green)) >> 5
                    newRed &= 0xFF
                    newBlue += (Int(g2b) * Int(green)) >> 5
                    newBlue += (Int(r2b) * Int(Int8(truncatingIfNeeded: newRed))) >> 5
                    newBlue &= 0xFF
                    out[y * w + x] = (argb & 0xFF00_FF00) | UInt32(newRed) << 16 | UInt32(newBlue)
                }
            }
            return out
        case .colorIndexing(let bits, let palette, let w):
            let packedW = subsample(w, bits)
            var out = [UInt32](repeating: 0, count: w * height)
            let bpp = 8 >> bits, mask = (1 << bpp) - 1
            for y in 0..<height {
                for x in 0..<w {
                    let packed = Int((input[y * packedW + (x >> bits)] >> 8) & 0xFF)
                    let idx = (packed >> ((x & ((1 << bits) - 1)) * bpp)) & mask
                    out[y * w + x] = palette[idx]
                }
            }
            return out
        }
    }
}
