// PNG decoder: consumes only the typed `PNGFile` produced by `PNGGrammar`.
// It never touches the original byte stream.

public import CodecCore

public enum PNGDecoder {
    /// Recognise, then decode. Animated PNGs return every composited frame.
    public static func decode(_ bytes: [UInt8], limits: DecodeLimits = .default) throws(ParseFailure) -> DecodedImage {
        let file = try PNGGrammar.file(ByteSlice(bytes), limits: limits)
        return try decode(file, limits: limits)
    }

    public static func decode(_ file: PNGFile, limits: DecodeLimits = .default) throws(ParseFailure) -> DecodedImage {
        let h = file.header
        let still = try decodeImage(file.imageData, width: h.width, height: h.height, file: file, rule: "IDAT")
        guard let anim = file.animation else { return .still(still) }

        let canvasBytes = h.width * h.height * 4
        guard anim.frames.count <= limits.maxFrames,
              canvasBytes.multipliedReportingOverflow(by: anim.frames.count).overflow == false,
              canvasBytes * anim.frames.count <= limits.maxAnimationBytes else {
            return .still(still)  // too large to animate: show the default image
        }
        return .animated(try composite(anim, still: still, file: file), poster: still)
    }

    // MARK: scanlines

    struct Pass { let x0, y0, dx, dy: Int }
    static let adam7 = [Pass(x0: 0, y0: 0, dx: 8, dy: 8), Pass(x0: 4, y0: 0, dx: 8, dy: 8), Pass(x0: 0, y0: 4, dx: 4, dy: 8),
                        Pass(x0: 2, y0: 0, dx: 4, dy: 4), Pass(x0: 0, y0: 2, dx: 2, dy: 4), Pass(x0: 1, y0: 0, dx: 2, dy: 2),
                        Pass(x0: 0, y0: 1, dx: 1, dy: 2)]
    static let progressive = [Pass(x0: 0, y0: 0, dx: 1, dy: 1)]

    static func passSize(_ p: Pass, _ w: Int, _ h: Int) -> (Int, Int) {
        (w > p.x0 ? (w - p.x0 + p.dx - 1) / p.dx : 0, h > p.y0 ? (h - p.y0 + p.dy - 1) / p.dy : 0)
    }

    static func rowBytes(_ w: Int, _ bpp: Int) -> Int { (w * bpp + 7) / 8 }

    /// Exact size of the filtered, decompressed stream for an image of w×h.
    static func rawSize(_ w: Int, _ h: Int, _ header: PNGHeader) -> Int {
        let passes = header.interlaced ? adam7 : progressive
        var total = 0
        for p in passes {
            let (pw, ph) = passSize(p, w, h)
            if pw > 0 && ph > 0 { total += ph * (1 + rowBytes(pw, header.bitsPerPixel)) }
        }
        return total
    }

    static func decodeImage(_ data: [ByteSlice], width w: Int, height h: Int, file: PNGFile, rule: String) throws(ParseFailure) -> PixelBuffer {
        let header = file.header
        let expected = rawSize(w, h, header)
        let raw = try Zlib.decompress(ByteSlice.concatenate(data), maxOutput: expected, expectedSize: expected, trailing: .ignore)

        var out = PixelBuffer(transparentWidth: w, height: h)
        let bpp = header.bitsPerPixel
        let filterStride = max(1, bpp / 8)
        var pos = 0
        for p in header.interlaced ? adam7 : progressive {
            let (pw, ph) = passSize(p, w, h)
            guard pw > 0 && ph > 0 else { continue }
            let rb = rowBytes(pw, bpp)
            var prior = [UInt8](repeating: 0, count: rb)
            var line = [UInt8](repeating: 0, count: rb)
            var pixels = [UInt8](repeating: 0, count: pw * 4)
            for row in 0..<ph {
                let filter = raw[pos]
                for i in 0..<rb { line[i] = raw[pos + 1 + i] }
                pos += 1 + rb
                try unfilter(filter, &line, prior, filterStride, rule: rule, row: row)
                expand(line, count: pw, header: header, palette: file.palette, transparency: file.transparency, into: &pixels)
                let y = p.y0 + row * p.dy
                for i in 0..<pw {
                    let d = (y * w + p.x0 + i * p.dx) * 4
                    out.rgba[d] = pixels[i * 4]
                    out.rgba[d + 1] = pixels[i * 4 + 1]
                    out.rgba[d + 2] = pixels[i * 4 + 2]
                    out.rgba[d + 3] = pixels[i * 4 + 3]
                }
                swap(&prior, &line)
            }
        }
        return out
    }

    static func unfilter(_ type: UInt8, _ line: inout [UInt8], _ prior: [UInt8], _ bpp: Int, rule: String, row: Int) throws(ParseFailure) {
        let n = line.count
        switch type {
        case 0: break
        case 1: for i in bpp..<max(bpp, n) { line[i] &+= line[i - bpp] }
        case 2: for i in 0..<n { line[i] &+= prior[i] }
        case 3:
            for i in 0..<n {
                let left = i >= bpp ? Int(line[i - bpp]) : 0
                line[i] &+= UInt8((left + Int(prior[i])) >> 1)
            }
        case 4:
            for i in 0..<n {
                let a = i >= bpp ? Int(line[i - bpp]) : 0
                let b = Int(prior[i])
                let c = i >= bpp ? Int(prior[i - bpp]) : 0
                let p = a + b - c
                let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                line[i] &+= UInt8(pa <= pb && pa <= pc ? a : (pb <= pc ? b : c))
            }
        default:
            throw ParseFailure(offset: 0, rule: "\(rule).filter", reason: .invalid("filter type \(type) on row \(row)"))
        }
    }

    /// Converts one unfiltered scanline to RGBA8.
    static func expand(_ line: [UInt8], count: Int, header: PNGHeader, palette: [PNGRGB]?,
                       transparency: PNGTransparency?, into px: inout [UInt8]) {
        let depth = Int(header.bitDepth)

        func sample(_ index: Int) -> Int {  // index-th sample in the line, at full bit depth
            switch depth {
            case 16: return Int(line[index * 2]) << 8 | Int(line[index * 2 + 1])
            case 8: return Int(line[index])
            default:
                let bit = index * depth
                let byte = Int(line[bit >> 3])
                return (byte >> (8 - depth - (bit & 7))) & ((1 << depth) - 1)
            }
        }
        func to8(_ v: Int) -> UInt8 {
            switch depth {
            case 16: UInt8(v >> 8)
            case 8: UInt8(v)
            default: UInt8(v * 255 / ((1 << depth) - 1))
            }
        }

        switch header.colorType {
        case .grayscale:
            var key = -1
            if case .grayKey(let k)? = transparency { key = Int(k) }
            for i in 0..<count {
                let s = sample(i), g = to8(s)
                px[i * 4] = g; px[i * 4 + 1] = g; px[i * 4 + 2] = g
                px[i * 4 + 3] = s == key ? 0 : 255
            }
        case .truecolor:
            var key: (Int, Int, Int)?
            if case .rgbKey(let r, let g, let b)? = transparency { key = (Int(r), Int(g), Int(b)) }
            for i in 0..<count {
                let r = sample(i * 3), g = sample(i * 3 + 1), b = sample(i * 3 + 2)
                px[i * 4] = to8(r); px[i * 4 + 1] = to8(g); px[i * 4 + 2] = to8(b)
                px[i * 4 + 3] = key.map { $0 == (r, g, b) } == true ? 0 : 255
            }
        case .indexed:
            let pal = palette ?? []
            var alpha: [UInt8] = []
            if case .paletteAlpha(let a)? = transparency { alpha = a }
            for i in 0..<count {
                let idx = sample(i)
                // Out-of-range indices are a spec error; render opaque black (as libpng with benign errors).
                let c = idx < pal.count ? pal[idx] : PNGRGB(r: 0, g: 0, b: 0)
                px[i * 4] = c.r; px[i * 4 + 1] = c.g; px[i * 4 + 2] = c.b
                px[i * 4 + 3] = idx < alpha.count ? alpha[idx] : 255
            }
        case .grayscaleAlpha:
            for i in 0..<count {
                let g = to8(sample(i * 2))
                px[i * 4] = g; px[i * 4 + 1] = g; px[i * 4 + 2] = g
                px[i * 4 + 3] = to8(sample(i * 2 + 1))
            }
        case .truecolorAlpha:
            for i in 0..<count {
                px[i * 4] = to8(sample(i * 4)); px[i * 4 + 1] = to8(sample(i * 4 + 1))
                px[i * 4 + 2] = to8(sample(i * 4 + 2)); px[i * 4 + 3] = to8(sample(i * 4 + 3))
            }
        }
    }

    // MARK: APNG compositing (APNG spec §"Frame composition")

    static func composite(_ anim: APNGAnimation, still: PixelBuffer, file: PNGFile) throws(ParseFailure) -> AnimatedImage {
        let W = file.header.width, H = file.header.height
        var canvas = PixelBuffer(transparentWidth: W, height: H)
        var frames: [AnimationFrame] = []
        frames.reserveCapacity(anim.frames.count)

        for (index, frame) in anim.frames.enumerated() {
            let fc = frame.control
            let image: PixelBuffer
            if index == 0 && anim.defaultImageIsFirstFrame {
                image = still
            } else {
                image = try decodeImage(frame.data, width: fc.width, height: fc.height, file: file, rule: "fdAT[\(index)]")
            }

            var dispose = fc.dispose
            if index == 0 && dispose == .previous { dispose = .background }
            let saved: [UInt8]? = dispose == .previous ? region(canvas, fc) : nil

            for y in 0..<fc.height {
                for x in 0..<fc.width {
                    let s = (y * fc.width + x) * 4
                    let d = ((fc.y + y) * W + fc.x + x) * 4
                    if fc.blend == .source || image.rgba[s + 3] == 255 {
                        for k in 0..<4 { canvas.rgba[d + k] = image.rgba[s + k] }
                    } else if image.rgba[s + 3] != 0 {
                        blendOver(image.rgba, s, &canvas.rgba, d)
                    }
                }
            }
            frames.append(AnimationFrame(image: canvas, delayMilliseconds: fc.delayMilliseconds))

            switch dispose {
            case .none: break
            case .background:
                for y in 0..<fc.height {
                    for x in 0..<fc.width {
                        let d = ((fc.y + y) * W + fc.x + x) * 4
                        for k in 0..<4 { canvas.rgba[d + k] = 0 }
                    }
                }
            case .previous:
                if let saved { restore(&canvas, fc, saved) }
            }
        }
        return AnimatedImage(width: W, height: H, frames: frames, loopCount: anim.playCount)
    }

    /// Straight-alpha source-over.
    static func blendOver(_ src: [UInt8], _ s: Int, _ dst: inout [UInt8], _ d: Int) {
        let sa = Int(src[s + 3]), da = Int(dst[d + 3])
        let outA = sa * 255 + da * (255 - sa)  // scaled by 255
        guard outA > 0 else { for k in 0..<4 { dst[d + k] = 0 }; return }
        for k in 0..<3 {
            let num = Int(src[s + k]) * sa * 255 + Int(dst[d + k]) * da * (255 - sa)
            dst[d + k] = UInt8((num + outA / 2) / outA)
        }
        dst[d + 3] = UInt8((outA + 127) / 255)
    }

    static func region(_ canvas: PixelBuffer, _ fc: APNGFrameControl) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(fc.width * fc.height * 4)
        for y in 0..<fc.height {
            let d = ((fc.y + y) * canvas.width + fc.x) * 4
            out.append(contentsOf: canvas.rgba[d..<(d + fc.width * 4)])
        }
        return out
    }

    static func restore(_ canvas: inout PixelBuffer, _ fc: APNGFrameControl, _ saved: [UInt8]) {
        for y in 0..<fc.height {
            let d = ((fc.y + y) * canvas.width + fc.x) * 4
            for i in 0..<(fc.width * 4) { canvas.rgba[d + i] = saved[y * fc.width * 4 + i] }
        }
    }
}
