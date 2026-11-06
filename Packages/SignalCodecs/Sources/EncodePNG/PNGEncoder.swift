// PNG writer: smallest lossless colour type (grey / grey+alpha / RGB / RGBA, 8-bit),
// per-row adaptive filtering (minimum sum of absolute differences, as libpng),
// zlib via CodecCore's Deflate.

public import CodecCore

public enum PNGEncoder {
    /// - Parameter dotsPerInch: written as a pHYs chunk (`changeDpiBlob`), when given.
    public static func encode(_ image: PixelBuffer, options: Deflate.Options = Deflate.Options(), dotsPerInch: Int? = nil) -> [UInt8] {
        let w = image.width, h = image.height
        var opaque = true, grey = true
        for i in stride(from: 0, to: image.rgba.count, by: 4) {
            if image.rgba[i + 3] != 255 { opaque = false }
            if image.rgba[i] != image.rgba[i + 1] || image.rgba[i] != image.rgba[i + 2] { grey = false }
            if !opaque && !grey { break }
        }
        let (colorType, channels): (UInt8, Int) = grey ? (opaque ? (0, 1) : (4, 2)) : (opaque ? (2, 3) : (6, 4))
        let pick: [Int] = grey ? (opaque ? [0] : [0, 3]) : (opaque ? [0, 1, 2] : [0, 1, 2, 3])
        let stride = w * channels

        var raw: [UInt8] = []
        raw.reserveCapacity((stride + 1) * h)
        var prior = [UInt8](repeating: 0, count: stride)
        var line = [UInt8](repeating: 0, count: stride)
        var candidate = [UInt8](repeating: 0, count: stride)
        var best = [UInt8](repeating: 0, count: stride)
        for y in 0..<h {
            for x in 0..<w { for (k, c) in pick.enumerated() { line[x * channels + k] = image.rgba[(y * w + x) * 4 + c] } }
            var bestType: UInt8 = 0
            var bestScore = Int.max
            for t: UInt8 in 0...4 {
                var score = 0
                for i in 0..<stride {
                    let a = i >= channels ? Int(line[i - channels]) : 0
                    let b = Int(prior[i])
                    let c = i >= channels ? Int(prior[i - channels]) : 0
                    let x = Int(line[i])
                    let pred: Int
                    switch t {
                    case 0: pred = 0
                    case 1: pred = a
                    case 2: pred = b
                    case 3: pred = (a + b) >> 1
                    default:
                        let p = a + b - c
                        let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                        pred = pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
                    }
                    let v = UInt8(truncatingIfNeeded: x - pred)
                    candidate[i] = v
                    score += v < 128 ? Int(v) : 256 - Int(v)
                }
                if score < bestScore { bestScore = score; bestType = t; swap(&best, &candidate) }
            }
            raw.append(bestType)
            raw += best
            swap(&prior, &line)
        }

        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        func chunk(_ type: String, _ data: [UInt8]) {
            let t = Array(type.utf8)
            out += be32(UInt32(data.count)) + t + data
            var crc = CRC32()
            crc.update(t)
            crc.update(data)
            out += be32(crc.value)
        }
        chunk("IHDR", be32(UInt32(w)) + be32(UInt32(h)) + [8, colorType, 0, 0, 0])
        if let dpi = dotsPerInch, dpi > 0 {
            // Pixels per metre (unit 1), as changeDpiBlob: round(dpi / 0.0254).
            let ppm = UInt32((Double(dpi) / 0.0254).rounded())
            chunk("pHYs", be32(ppm) + be32(ppm) + [1])
        }
        let z = ZlibWriter.compress(raw, options: options)
        var off = 0
        repeat {
            let n = min(1 << 20, z.count - off)
            chunk("IDAT", Array(z[off..<(off + n)]))
            off += n
        } while off < z.count
        chunk("IEND", [])
        return out
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
}
