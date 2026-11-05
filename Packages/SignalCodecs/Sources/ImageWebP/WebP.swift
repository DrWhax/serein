// WebP container grammar (RIFF, VP8X, ALPH, ANIM/ANMF) and decoder front end,
// following libwebp's webp_dec.c / demux.c / anim_decode.c.
//
//   webp   := "RIFF" size:u32le{12 ≤ size, size+8 ≤ file} "WEBP" body      (bytes past size+8 ignored)
//   body   := simple | extended
//   simple := chunk("VP8 ") | chunk("VP8L")
//   extended := chunk("VP8X", 10 bytes: flags rsv:3 cw-1:u24 ch-1:u24)
//             ( anim-flag:  other* chunk("ANIM", ≥6: bg:u32 loop:u16) (chunk("ANMF") | other)*
//             | still:      (chunk("ALPH") | other)* (chunk("VP8 ") | chunk("VP8L")) other* )
//   ANMF   := x/2:u24 y/2:u24 w-1:u24 h-1:u24 duration:u24 flags:u8 (ALPH? (VP8|VP8L) | other)*
//   chunk(t) := t size:u32le byte{size} pad{size odd}
//
// Frames must lie inside the canvas and match their bitstream dimensions; a still
// image with VP8X must match the canvas.

public import CodecCore

public enum WebPBitstream: Sendable, Equatable {
    case lossy(ByteSlice, alpha: ByteSlice?)
    case lossless(ByteSlice)
}

public struct WebPFrameInfo: Sendable, Equatable {
    public var x, y, width, height: Int
    public var duration: Int
    public var disposeToBackground: Bool
    public var blend: Bool
    public var hasAlpha: Bool
    public var bitstream: WebPBitstream
}

public struct WebPFile: Sendable, Equatable {
    public var canvasWidth, canvasHeight: Int
    public var still: WebPBitstream?
    public var frames: [WebPFrameInfo]
    public var loopCount: Int
}

public enum WebPGrammar {
    struct Chunk { var tag: String; var data: ByteSlice; var offset: Int }

    static func chunks(_ body: ByteSlice, maxChunks: Int = 1 << 16) throws(ParseFailure) -> [Chunk] {
        var c = body.cursor()
        var out: [Chunk] = []
        while !c.isAtEnd {
            let at = c.position
            guard c.remaining >= 8 else { throw c.fail("chunk", .unexpectedEnd(needed: 8, available: c.remaining)) }
            let tag = String(decoding: try c.bytes(4, "chunk.tag").copyBytes(), as: UTF8.self)
            let size = Int(try c.u32le("chunk.size"))
            guard size <= c.remaining else { throw ParseFailure(offset: at, rule: "chunk(\(tag))", reason: .unexpectedEnd(needed: size, available: c.remaining)) }
            let data = try c.bytes(size, "chunk.data")
            if size & 1 == 1 && !c.isAtEnd { try c.skip(1, "chunk.pad") }
            guard out.count < maxChunks else { throw c.fail("webp", .limitExceeded("too many chunks")) }
            out.append(Chunk(tag: tag, data: data, offset: at))
        }
        return out
    }

    /// Dimensions and alpha bit from a VP8 / VP8L bitstream header.
    static func bitstreamInfo(_ b: WebPBitstream) throws(ParseFailure) -> (Int, Int, Bool) {
        switch b {
        case .lossy(let s, let alpha):
            var c = s.cursor()
            try c.skip(3, "VP8.frameTag")
            try c.expect([0x9D, 0x01, 0x2A], "VP8.startCode")
            return (Int(try c.u16le()) & 0x3FFF, Int(try c.u16le()) & 0x3FFF, alpha != nil)
        case .lossless(let s):
            var c = s.cursor()
            try c.expect([0x2F], "VP8L.signature")
            let v = try c.u32le("VP8L.header")
            return (Int(v & 0x3FFF) + 1, Int((v >> 14) & 0x3FFF) + 1, (v >> 28) & 1 == 1)
        }
    }

    static func image(_ chunks: ArraySlice<Chunk>) -> WebPBitstream? {
        var alpha: ByteSlice?
        for ch in chunks {
            switch ch.tag {
            case "ALPH": alpha = ch.data
            case "VP8 ": return .lossy(ch.data, alpha: alpha)
            case "VP8L": return .lossless(ch.data)
            default: continue
            }
        }
        return nil
    }

    public static func file(_ input: ByteSlice, limits: DecodeLimits = .default) throws(ParseFailure) -> WebPFile {
        guard input.count <= limits.maxInputBytes else { throw ParseFailure(offset: 0, rule: "webp", reason: .limitExceeded("input \(input.count) bytes")) }
        var c = input.cursor()
        try c.expect(Array("RIFF".utf8), "RIFF")
        let riffSize = Int(try c.u32le("RIFF.size"))
        guard riffSize >= 12 else { throw ParseFailure(offset: 4, rule: "RIFF.size", reason: .invalid("size \(riffSize)")) }
        guard riffSize <= c.remaining else { throw ParseFailure(offset: 4, rule: "RIFF.size", reason: .unexpectedEnd(needed: riffSize, available: c.remaining)) }
        var body = try c.bytes(riffSize, "RIFF.body").cursor()
        try body.expect(Array("WEBP".utf8), "WEBP")
        let list = try chunks(body.rest())
        guard let first = list.first else { throw ParseFailure(offset: 12, rule: "webp", reason: .invalid("no chunks")) }

        switch first.tag {
        case "VP8 ", "VP8L":
            let img = first.tag == "VP8 " ? WebPBitstream.lossy(first.data, alpha: nil) : .lossless(first.data)
            let (w, h, _) = try bitstreamInfo(img)
            try limits.checkDimensions(width: w, height: h, at: first.offset, rule: "webp")
            return WebPFile(canvasWidth: w, canvasHeight: h, still: img, frames: [], loopCount: 1)
        case "VP8X":
            guard first.data.count == 10 else { throw ParseFailure(offset: first.offset, rule: "VP8X", reason: .invalid("size \(first.data.count)")) }
            var v = first.data.cursor()
            let flags = try v.u8("VP8X.flags")
            try v.skip(3, "VP8X.reserved")
            let cw = Int(try v.u24le("VP8X.width")) + 1, ch = Int(try v.u24le("VP8X.height")) + 1
            try limits.checkDimensions(width: cw, height: ch, at: first.offset, rule: "VP8X")
            let rest = list.dropFirst()
            if flags & 0x02 == 0 {
                guard let img = image(rest) else { throw ParseFailure(offset: first.offset, rule: "webp", reason: .invalid("no image chunk")) }
                let (w, h, _) = try bitstreamInfo(img)
                guard w == cw, h == ch else { throw ParseFailure(offset: first.offset, rule: "VP8X", reason: .invalid("canvas \(cw)x\(ch) vs image \(w)x\(h)")) }
                return WebPFile(canvasWidth: cw, canvasHeight: ch, still: img, frames: [], loopCount: 1)
            }
            var loop = 0
            var sawANIM = false
            var frames: [WebPFrameInfo] = []
            for chk in rest {
                switch chk.tag {
                case "ANIM":
                    guard chk.data.count >= 6 else { throw ParseFailure(offset: chk.offset, rule: "ANIM", reason: .invalid("size \(chk.data.count)")) }
                    var a = chk.data.cursor()
                    _ = try a.u32le("ANIM.background")  // a hint; canvas starts transparent
                    loop = Int(try a.u16le("ANIM.loop"))
                    sawANIM = true
                case "ANMF":
                    guard sawANIM else { throw ParseFailure(offset: chk.offset, rule: "ANMF", reason: .invalid("frame before ANIM")) }
                    guard chk.data.count >= 16 else { throw ParseFailure(offset: chk.offset, rule: "ANMF", reason: .invalid("size \(chk.data.count)")) }
                    var f = chk.data.cursor()
                    let x = Int(try f.u24le("ANMF.x")) * 2, y = Int(try f.u24le("ANMF.y")) * 2
                    let w = Int(try f.u24le("ANMF.width")) + 1, h = Int(try f.u24le("ANMF.height")) + 1
                    let duration = Int(try f.u24le("ANMF.duration"))
                    let bits = try f.u8("ANMF.flags")
                    guard x + w <= cw, y + h <= ch else {
                        throw ParseFailure(offset: chk.offset, rule: "ANMF", reason: .invalid("frame \(w)x\(h)+\(x)+\(y) outside canvas \(cw)x\(ch)"))
                    }
                    let sub = try chunks(f.rest())
                    guard let img = image(sub[...]) else { throw ParseFailure(offset: chk.offset, rule: "ANMF", reason: .invalid("frame without image")) }
                    let (bw, bh, alpha) = try bitstreamInfo(img)
                    guard bw == w, bh == h else { throw ParseFailure(offset: chk.offset, rule: "ANMF", reason: .invalid("frame \(w)x\(h) vs bitstream \(bw)x\(bh)")) }
                    guard frames.count < limits.maxFrames else { throw ParseFailure(offset: chk.offset, rule: "webp", reason: .limitExceeded("frames")) }
                    frames.append(WebPFrameInfo(x: x, y: y, width: w, height: h, duration: duration,
                                                disposeToBackground: bits & 1 == 1, blend: bits & 2 == 0, hasAlpha: alpha, bitstream: img))
                default:
                    continue  // ICCP, EXIF, XMP, unknown
                }
            }
            guard !frames.isEmpty else { throw ParseFailure(offset: first.offset, rule: "webp", reason: .invalid("animation without frames")) }
            return WebPFile(canvasWidth: cw, canvasHeight: ch, still: nil, frames: frames, loopCount: loop)
        default:
            throw ParseFailure(offset: first.offset, rule: "webp", reason: .invalid("first chunk \(first.tag)"))
        }
    }
}

public enum WebPDecoder {
    public static func decode(_ bytes: [UInt8], limits: DecodeLimits = .default) throws(ParseFailure) -> DecodedImage {
        let file = try WebPGrammar.file(ByteSlice(bytes), limits: limits)
        if let still = file.still { return .still(try decodeBitstream(still, limits: limits)) }
        let anim = try composite(file, limits: limits)
        if anim.frames.count == 1 { return .still(anim.frames[0].image) }
        return .animated(anim, poster: anim.frames[0].image)
    }

    /// One still image (VP8 + optional ALPH, or VP8L) to straight-alpha RGBA.
    public static func decodeBitstream(_ b: WebPBitstream, limits: DecodeLimits = .default) throws(ParseFailure) -> PixelBuffer {
        switch b {
        case .lossless(let s):
            let (w, h, argb) = try VP8LDecoder.decode(s, limits: limits)
            var out = PixelBuffer(transparentWidth: w, height: h)
            for i in 0..<(w * h) {
                let p = argb[i]
                out.rgba[i * 4] = UInt8(truncatingIfNeeded: p >> 16); out.rgba[i * 4 + 1] = UInt8(truncatingIfNeeded: p >> 8)
                out.rgba[i * 4 + 2] = UInt8(truncatingIfNeeded: p); out.rgba[i * 4 + 3] = UInt8(truncatingIfNeeded: p >> 24)
            }
            return out
        case .lossy(let s, let alphaChunk):
            let frame = try VP8Decoder.decode(s, limits: limits)
            var out = yuvToRGBA(frame)
            if let a = alphaChunk {
                let alpha = try decodeAlpha(a, width: frame.width, height: frame.height, limits: limits)
                for i in 0..<(frame.width * frame.height) { out.rgba[i * 4 + 3] = alpha[i] }
            }
            return out
        }
    }

    // MARK: alpha (alpha_dec.c, dsp/filters.c)

    static func decodeAlpha(_ chunk: ByteSlice, width w: Int, height h: Int, limits: DecodeLimits) throws(ParseFailure) -> [UInt8] {
        var c = chunk.cursor()
        let hdr = try c.u8("ALPH.header")
        let method = hdr & 3, filter = (hdr >> 2) & 3, pre = (hdr >> 4) & 3, rsrv = hdr >> 6
        guard method <= 1, pre <= 1, rsrv == 0 else { throw ParseFailure(offset: chunk.lowerBound, rule: "ALPH", reason: .invalid("header 0x\(String(hdr, radix: 16))")) }
        guard !c.isAtEnd else { throw ParseFailure(offset: chunk.lowerBound, rule: "ALPH", reason: .unexpectedEnd(needed: 1, available: 0)) }
        var plane: [UInt8]
        if method == 0 {
            guard c.remaining >= w * h else { throw ParseFailure(offset: c.position, rule: "ALPH", reason: .unexpectedEnd(needed: w * h, available: c.remaining)) }
            plane = try c.bytes(w * h, "ALPH.raw").copyBytes()
        } else {
            plane = try VP8LDecoder.decodeAlpha(c.rest(), width: w, height: h, limits: limits)
        }
        guard filter != 0 else { return plane }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = y * w
            if y == 0 || filter == 1 {
                var pred: UInt8 = y == 0 ? 0 : out[row - w]
                if y == 0 || filter == 1 {
                    for x in 0..<w { out[row + x] = pred &+ plane[row + x]; pred = out[row + x] }
                }
            } else if filter == 2 {
                for x in 0..<w { out[row + x] = out[row - w + x] &+ plane[row + x] }
            } else {
                var top = out[row - w], topLeft = top, left = top
                for x in 0..<w {
                    top = out[row - w + x]
                    let g = Int(left) + Int(top) - Int(topLeft)
                    left = plane[row + x] &+ UInt8(g & ~0xFF == 0 ? g : g < 0 ? 0 : 255)
                    topLeft = top
                    out[row + x] = left
                }
            }
        }
        return out
    }

    // MARK: YUV → RGB with fancy upsampling (dsp/yuv.h, dsp/upsampling.c)

    @inline(__always) static func multHi(_ v: Int, _ c: Int) -> Int { (v * c) >> 8 }
    @inline(__always) static func clip8(_ v: Int) -> UInt8 { v & ~((256 << 6) - 1) == 0 ? UInt8(v >> 6) : v < 0 ? 0 : 255 }
    @inline(__always) static func put(_ out: inout [UInt8], _ i: Int, _ y: Int, _ u: Int, _ v: Int) {
        out[i] = clip8(multHi(y, 19077) + multHi(v, 26149) - 14234)
        out[i + 1] = clip8(multHi(y, 19077) - multHi(u, 6419) - multHi(v, 13320) + 8708)
        out[i + 2] = clip8(multHi(y, 19077) + multHi(u, 33050) - 17685)
        out[i + 3] = 255
    }

    static func yuvToRGBA(_ f: VP8Frame) -> PixelBuffer {
        let W = f.width, H = f.height
        var out = PixelBuffer(transparentWidth: W, height: H)
        let uvH = (H + 1) / 2
        for y in 0..<H {
            // Near / far chroma rows (libwebp EmitFancyRGB row pairing).
            let near: Int, far: Int
            if y == 0 { near = 0; far = 0 }
            else if y & 1 == 1 { near = (y - 1) / 2; far = min((y + 1) / 2, uvH - 1) }
            else { near = y / 2; far = y / 2 - 1 }
            let nb = near * f.uvStride, fb = far * f.uvStride
            @inline(__always) func uvAt(_ base: Int, _ x: Int) -> (Int, Int) { (Int(f.u[base + x]), Int(f.v[base + x])) }
            let yb = y * f.yStride, ob = y * W * 4
            func emit(_ x: Int, _ u: Int, _ v: Int) { put(&out.rgba, ob + x * 4, Int(f.y[yb + x]), u, v) }
            let (n0u, n0v) = uvAt(nb, 0), (f0u, f0v) = uvAt(fb, 0)
            emit(0, (3 * n0u + f0u + 2) >> 2, (3 * n0v + f0v + 2) >> 2)
            let lastPair = (W - 1) >> 1
            var tl = (n0u, n0v), l = (f0u, f0v)
            if lastPair >= 1 {
                for x in 1...lastPair {
                    let t = uvAt(nb, x), cur = uvAt(fb, x)
                    func ch(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> (Int, Int) {
                        let avg = a + b + c + d + 8
                        let diag12 = (avg + 2 * (b + c)) >> 3, diag03 = (avg + 2 * (a + d)) >> 3
                        return ((diag12 + a) >> 1, (diag03 + b) >> 1)
                    }
                    let (u0, u1) = ch(tl.0, t.0, l.0, cur.0), (v0, v1) = ch(tl.1, t.1, l.1, cur.1)
                    emit(2 * x - 1, u0, v0)
                    if 2 * x < W { emit(2 * x, u1, v1) }
                    tl = t; l = cur
                }
            }
            if W & 1 == 0 { emit(W - 1, (3 * tl.0 + l.0 + 2) >> 2, (3 * tl.1 + l.1 + 2) >> 2) }
        }
        return out
    }

    // MARK: animation (demux/anim_decode.c, non-premultiplied RGBA)

    static func blend(_ src: (UInt8, UInt8, UInt8, UInt8), _ dst: (UInt8, UInt8, UInt8, UInt8)) -> (UInt8, UInt8, UInt8, UInt8) {
        let sa = Int(src.3)
        if sa == 0 { return dst }
        let dstFactorA = (Int(dst.3) * (256 - sa)) >> 8
        let blendA = sa + dstFactorA
        let scale = (1 << 24) / blendA
        func chan(_ s: UInt8, _ d: UInt8) -> UInt8 {
            UInt8(truncatingIfNeeded: (UInt32(Int(s) * sa + Int(d) * dstFactorA) &* UInt32(scale)) >> 24)
        }
        return (chan(src.0, dst.0), chan(src.1, dst.1), chan(src.2, dst.2), UInt8(blendA))
    }

    public static func composite(_ file: WebPFile, limits: DecodeLimits = .default) throws(ParseFailure) -> AnimatedImage {
        let W = file.canvasWidth, H = file.canvasHeight
        let canvasBytes = W * H * 4
        guard canvasBytes.multipliedReportingOverflow(by: file.frames.count).overflow == false,
              canvasBytes * file.frames.count <= limits.maxAnimationBytes else {
            throw ParseFailure(offset: 0, rule: "webp", reason: .limitExceeded("animation memory"))
        }
        var disposed = [UInt8](repeating: 0, count: canvasBytes)  // prev_frame_disposed
        var frames: [AnimationFrame] = []
        var prev: WebPFrameInfo?
        var prevWasKey = false
        for (n, f) in file.frames.enumerated() {
            let full = f.width == W && f.height == H
            let isKey: Bool
            if n == 0 { isKey = true }
            else if (!f.hasAlpha || !f.blend) && full { isKey = true }
            else { isKey = prev!.disposeToBackground && ((prev!.width == W && prev!.height == H) || prevWasKey) }

            var canvas = isKey ? [UInt8](repeating: 0, count: canvasBytes) : disposed
            let img = try decodeBitstream(f.bitstream, limits: limits)
            for y in 0..<f.height {
                for x in 0..<f.width {
                    let s = (y * f.width + x) * 4, d = ((f.y + y) * W + f.x + x) * 4
                    for k in 0..<4 { canvas[d + k] = img.rgba[s + k] }
                }
            }
            if n > 0 && f.blend && !isKey, let p = prev {
                for y in 0..<f.height {
                    let cy = f.y + y
                    var ranges: [(Int, Int)] = []
                    if !p.disposeToBackground {
                        ranges = [(f.x, f.width)]
                    } else {
                        // FindBlendRangeAtRow: skip the previous frame's (now transparent) rectangle.
                        let srcMax = f.x + f.width, dstMax = p.x + p.width
                        if cy < p.y || cy >= p.y + p.height || f.x >= dstMax || srcMax <= p.x {
                            ranges = [(f.x, f.width)]
                        } else {
                            if f.x < p.x { ranges.append((f.x, p.x - f.x)) }
                            if srcMax > dstMax { ranges.append((dstMax, srcMax - dstMax)) }
                        }
                    }
                    for (left, width) in ranges {
                        for x in left..<(left + width) {
                            let i = (cy * W + x) * 4
                            guard canvas[i + 3] != 255 else { continue }
                            let r = blend((canvas[i], canvas[i + 1], canvas[i + 2], canvas[i + 3]),
                                          (disposed[i], disposed[i + 1], disposed[i + 2], disposed[i + 3]))
                            canvas[i] = r.0; canvas[i + 1] = r.1; canvas[i + 2] = r.2; canvas[i + 3] = r.3
                        }
                    }
                }
            }
            frames.append(AnimationFrame(image: PixelBuffer(width: W, height: H, rgba: canvas), delayMilliseconds: f.duration))
            disposed = canvas
            if f.disposeToBackground {
                for y in f.y..<(f.y + f.height) { for x in f.x..<(f.x + f.width) { for k in 0..<4 { disposed[(y * W + x) * 4 + k] = 0 } } }
            }
            prev = f
            prevWasKey = isKey
        }
        return AnimatedImage(width: W, height: H, frames: frames, loopCount: file.loopCount)
    }
}
