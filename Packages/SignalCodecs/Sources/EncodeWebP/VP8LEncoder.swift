// WebP lossless (VP8L) writer, for the sticker creator's output: the subtract-green transform,
// LZ77 backward references over pixels (hash chains, linear distances), and one group of five
// canonical prefix codes (green + length prefixes, red, blue, alpha, distance prefixes) with
// their lengths RLE-coded, inside a RIFF/WEBP container. Upstream encodes lossy VP8 at q0.8
// through the browser; lossless keeps stickers exact, at a larger size for photos.

public import CodecCore

public enum WebPEncoder {
    static let lengthPrefixCount = 24
    static let distancePrefixCount = 40
    static let maxLength = 4096
    static let maxDistance = (1 << 20) - 120
    static let codeLengthOrder = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

    enum Token { case literal(UInt32), copy(length: Int, distance: Int) }

    /// Lossless WebP of the image (RGBA8).
    public static func encodeLossless(_ image: PixelBuffer) -> [UInt8] {
        let w = image.width, h = image.height
        precondition(w >= 1 && h >= 1 && w <= 16384 && h <= 16384, "WebP dimensions")
        var argb = [UInt32](repeating: 0, count: w * h)
        var hasAlpha = false
        for i in 0..<(w * h) {
            let r = UInt32(image.rgba[i * 4]), g = UInt32(image.rgba[i * 4 + 1]), b = UInt32(image.rgba[i * 4 + 2]), a = UInt32(image.rgba[i * 4 + 3])
            if a != 255 { hasAlpha = true }
            // subtract green: red and blue minus green (mod 256)
            argb[i] = a << 24 | ((r &- g) & 0xFF) << 16 | g << 8 | ((b &- g) & 0xFF)
        }
        let tokens = lz77(argb)

        var bits = LSBBitWriter(capacity: w * h)
        bits.write(0x2F, 8)
        bits.write(UInt32(w - 1), 14)
        bits.write(UInt32(h - 1), 14)
        bits.write(hasAlpha ? 1 : 0, 1)
        bits.write(0, 3)
        bits.write(1, 1); bits.write(2, 2)     // transform: SUBTRACT_GREEN
        bits.write(0, 1)                        // no more transforms
        bits.write(0, 1)                        // no colour cache
        bits.write(0, 1)                        // no meta prefix codes

        var green = [Int](repeating: 0, count: 256 + lengthPrefixCount), red = [Int](repeating: 0, count: 256)
        var blue = [Int](repeating: 0, count: 256), alpha = [Int](repeating: 0, count: 256)
        var dist = [Int](repeating: 0, count: distancePrefixCount)
        for t in tokens {
            switch t {
            case .literal(let p):
                green[Int(p >> 8 & 0xFF)] += 1; red[Int(p >> 16 & 0xFF)] += 1; blue[Int(p & 0xFF)] += 1; alpha[Int(p >> 24)] += 1
            case .copy(let length, let distance):
                green[256 + prefix(length).code] += 1
                dist[prefix(distance + 120).code] += 1
            }
        }
        if dist.allSatisfy({ $0 == 0 }) { dist[0] = 1 }
        let codes = [green, red, blue, alpha, dist].map { freq in PrefixCode(freq: freq) }
        for c in codes { c.writeHeader(&bits) }
        for t in tokens {
            switch t {
            case .literal(let p):
                codes[0].write(Int(p >> 8 & 0xFF), &bits)
                codes[1].write(Int(p >> 16 & 0xFF), &bits)
                codes[2].write(Int(p & 0xFF), &bits)
                codes[3].write(Int(p >> 24), &bits)
            case .copy(let length, let distance):
                let l = prefix(length)
                codes[0].write(256 + l.code, &bits)
                bits.write(UInt32(l.extra), l.extraBits)
                let d = prefix(distance + 120)
                codes[4].write(d.code, &bits)
                bits.write(UInt32(d.extra), d.extraBits)
            }
        }
        let payload = bits.finish()
        var out: [UInt8] = Array("RIFF".utf8) + le32(UInt32(4 + 8 + payload.count + payload.count % 2)) + Array("WEBPVP8L".utf8) + le32(UInt32(payload.count))
        out += payload
        if payload.count % 2 == 1 { out.append(0) }
        return out
    }

    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }

    /// VP8L prefix coding of a value ≥ 1 (lengths, distance codes): prefix, extra bits, extra value.
    static func prefix(_ value: Int) -> (code: Int, extraBits: Int, extra: Int) {
        let d = value - 1
        if d < 4 { return (d, 0, 0) }
        var high = 0
        while d >> (high + 1) != 0 { high += 1 }
        let second = d >> (high - 1) & 1
        let extraBits = high - 1
        return (2 * high + second, extraBits, d & ((1 << extraBits) - 1))
    }

    /// Greedy LZ77 over pixels with hash chains on pixel pairs.
    static func lz77(_ px: [UInt32]) -> [Token] {
        let n = px.count
        var tokens: [Token] = []
        tokens.reserveCapacity(n)
        let hashBits = 16
        var head = [Int](repeating: -1, count: 1 << hashBits)
        var chain = [Int](repeating: -1, count: n)
        func hash(_ i: Int) -> Int {
            let v = px[i] &* 0x9E37_79B1 ^ (i + 1 < n ? px[i + 1] &* 0x85EB_CA6B : 0)
            return Int(v >> UInt32(32 - hashBits))
        }
        func insert(_ i: Int) {
            guard i + 1 < n else { return }
            let hv = hash(i)
            chain[i] = head[hv]
            head[hv] = i
        }
        var i = 0
        while i < n {
            var bestLength = 0, bestDistance = 0
            if i + 2 < n {
                var candidate = head[hash(i)]
                var tries = 32
                while candidate >= 0 && tries > 0 && i - candidate <= maxDistance {
                    var l = 0
                    let limit = min(maxLength, n - i)
                    while l < limit && px[candidate + l] == px[i + l] { l += 1 }
                    if l > bestLength { bestLength = l; bestDistance = i - candidate; if l == limit { break } }
                    candidate = chain[candidate]
                    tries -= 1
                }
            }
            if bestLength >= 3 {
                tokens.append(.copy(length: bestLength, distance: bestDistance))
                for k in i..<(i + bestLength) { insert(k) }
                i += bestLength
            } else {
                tokens.append(.literal(px[i]))
                insert(i)
                i += 1
            }
        }
        return tokens
    }

    /// One prefix code: simple (≤ 2 symbols below 256) or normal (RLE-coded lengths).
    struct PrefixCode {
        let lengths: [UInt8]
        let codes: [UInt32]
        let used: [Int]

        init(freq: [Int]) {
            used = freq.indices.filter { freq[$0] > 0 }
            lengths = HuffmanCodeBuilder.lengths(freq, maxBits: 15)
            codes = HuffmanCodeBuilder.codes(lengths)
        }

        /// A single-symbol code is read with zero bits.
        func write(_ symbol: Int, _ w: inout LSBBitWriter) {
            if used.count <= 1 { return }
            w.write(codes[symbol], Int(lengths[symbol]))
        }

        func writeHeader(_ w: inout LSBBitWriter) {
            if used.count <= 2 && used.allSatisfy({ $0 < 256 }) {
                let symbols = used.isEmpty ? [0] : used
                w.write(1, 1)                                   // simple code
                w.write(UInt32(symbols.count - 1), 1)
                if symbols[0] <= 1 { w.write(0, 1); w.write(UInt32(symbols[0]), 1) } else { w.write(1, 1); w.write(UInt32(symbols[0]), 8) }
                if symbols.count == 2 { w.write(UInt32(symbols[1]), 8) }
                return
            }
            w.write(0, 1)                                       // normal code
            // RLE of the lengths (16: repeat previous 3–6, 17: zeros 3–10, 18: zeros 11–138).
            var rle: [(symbol: Int, extra: Int, bits: Int)] = []
            var i = 0
            var previous: UInt8 = 8
            while i < lengths.count {
                let l = lengths[i]
                var run = 1
                while i + run < lengths.count && lengths[i + run] == l { run += 1 }
                if l == 0 && run >= 3 {
                    var left = run
                    while left >= 3 {
                        if left >= 11 { let k = min(left, 138); rle.append((18, k - 11, 7)); left -= k } else { let k = min(left, 10); rle.append((17, k - 3, 3)); left -= k }
                    }
                    for _ in 0..<left { rle.append((0, 0, 0)) }
                } else if l != 0 && l == previous && run >= 3 {
                    var left = run
                    while left >= 3 { let k = min(left, 6); rle.append((16, k - 3, 2)); left -= k }
                    for _ in 0..<left { rle.append((Int(l), 0, 0)) }
                } else {
                    rle.append((Int(l), 0, 0))
                    if l != 0 { previous = l }
                    i += 1
                    continue
                }
                if l != 0 { previous = l }
                i += run
            }
            var freq = [Int](repeating: 0, count: 19)
            for r in rle { freq[r.symbol] += 1 }
            // Code-length code: lengths ≤ 7; a single used symbol still needs a 1-bit code here.
            var clLengths = HuffmanCodeBuilder.lengths(freq, maxBits: 7)
            let clUsed = freq.indices.filter { freq[$0] > 0 }
            if clUsed.count == 1 {
                let other = clUsed[0] == 0 ? 1 : 0
                clLengths[other] = 1
            }
            let clCodes = HuffmanCodeBuilder.codes(clLengths)
            var count = 19
            while count > 4 && clLengths[Self.order[count - 1]] == 0 { count -= 1 }
            w.write(UInt32(count - 4), 4)
            for k in 0..<count { w.write(UInt32(clLengths[Self.order[k]]), 3) }
            w.write(0, 1)                                       // max_symbol: all
            for r in rle {
                w.write(clCodes[r.symbol], Int(clLengths[r.symbol]))
                if r.bits > 0 { w.write(UInt32(r.extra), r.bits) }
            }
        }

        static var order: [Int] { WebPEncoder.codeLengthOrder }
    }
}
