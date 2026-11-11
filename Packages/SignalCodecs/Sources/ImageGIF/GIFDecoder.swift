// GIF decoder: LZW expansion of each recognised image and browser-style
// compositing (transparent initial canvas; background colour ignored).

public import CodecCore

public enum GIFDecoder {
    public static func decode(_ bytes: [UInt8], limits: DecodeLimits = .default) throws(ParseFailure) -> DecodedImage {
        try decode(try GIFGrammar.file(ByteSlice(bytes), limits: limits), limits: limits)
    }

    /// A parsed file's image (for callers that also read the file's own fields, such as its
    /// loop count as stored).
    public static func decode(_ file: GIFFile, limits: DecodeLimits = .default) throws(ParseFailure) -> DecodedImage {
        let anim = try composite(file, limits: limits)
        if anim.frames.count == 1 { return .still(anim.frames[0].image) }
        let bytesNeeded = anim.width * anim.height * 4
        if bytesNeeded.multipliedReportingOverflow(by: anim.frames.count).overflow || bytesNeeded * anim.frames.count > limits.maxAnimationBytes {
            return .still(anim.frames[0].image)
        }
        return .animated(anim, poster: anim.frames[0].image)
    }

    /// All composited frames, in order (one frame for still GIFs).
    public static func composite(_ file: GIFFile, limits: DecodeLimits = .default) throws(ParseFailure) -> AnimatedImage {
        let W = file.width, H = file.height
        var canvas = PixelBuffer(transparentWidth: W, height: H)
        let loop = file.loopCount.map { $0 == 0 ? 0 : $0 } ?? 1
        guard !file.images.isEmpty else {
            return AnimatedImage(width: W, height: H, frames: [AnimationFrame(image: canvas, delayMilliseconds: 0)], loopCount: loop)
        }
        // Compositing memory: cap the number of retained canvases.
        let canvasBytes = W * H * 4
        let maxRetained = max(1, limits.maxAnimationBytes / max(1, canvasBytes))

        var frames: [AnimationFrame] = []
        for (n, image) in file.images.enumerated() {
            // No colour table at all: the image draws nothing (Chromium behaviour).
            let palette = image.localPalette ?? file.globalPalette ?? []
            let drawable = !palette.isEmpty
            let indices = drawable ? try lzw(image, rule: "image[\(n)].lzw") : []
            let transparent = image.control?.transparentIndex.map(Int.init) ?? -1
            let disposal = image.control?.disposal ?? 0
            let saved: [UInt8]? = disposal == 3 ? canvas.rgba : nil

            let order = rowOrder(height: image.height, interlaced: image.interlaced)
            for (srcRow, dstRow) in order.enumerated() {
                let y = image.top + dstRow
                guard y < H else { continue }
                for x in 0..<image.width {
                    let i = srcRow * image.width + x
                    guard i < indices.count else { break }  // missing pixels stay as they are
                    let idx = Int(indices[i])
                    if idx == transparent { continue }
                    guard idx < palette.count else {
                        throw ParseFailure(offset: 0, rule: "image[\(n)]", reason: .invalid("colour index \(idx) outside table of \(palette.count)"))
                    }
                    let cx = image.left + x
                    guard cx < W else { continue }
                    let d = (y * W + cx) * 4
                    let c = palette[idx]
                    canvas.rgba[d] = c.r; canvas.rgba[d + 1] = c.g; canvas.rgba[d + 2] = c.b; canvas.rgba[d + 3] = 255
                }
            }
            if frames.count < maxRetained {
                frames.append(AnimationFrame(image: canvas, delayMilliseconds: Int(image.control?.delayCentiseconds ?? 0) * 10))
            }

            switch disposal {
            case 2:
                for y in image.top..<min(H, image.top + image.height) {
                    for x in image.left..<min(W, image.left + image.width) {
                        let d = (y * W + x) * 4
                        for k in 0..<4 { canvas.rgba[d + k] = 0 }
                    }
                }
            case 3:
                if let saved { canvas.rgba = saved }
            default:
                break
            }
        }
        return AnimatedImage(width: W, height: H, frames: frames, loopCount: loop)
    }

    /// Destination row for each source row.
    static func rowOrder(height h: Int, interlaced: Bool) -> [Int] {
        guard interlaced else { return Array(0..<h) }
        var rows: [Int] = []
        rows.reserveCapacity(h)
        for (start, step) in [(0, 8), (4, 8), (2, 4), (1, 2)] {
            var y = start
            while y < h { rows.append(y); y += step }
        }
        return rows
    }

    /// Variable-width LZW (GIF89a Appendix F). Produces at most width*height
    /// indices; extra codes are ignored, a missing EOI is accepted.
    static func lzw(_ image: GIFImage, rule: String) throws(ParseFailure) -> [UInt8] {
        let total = image.width * image.height
        var out = [UInt8]()
        out.reserveCapacity(total)
        guard total > 0 else { return out }

        let minSize = image.minCodeSize
        let clear = 1 << minSize, eoi = clear + 1
        var prefix = [UInt16](repeating: 0, count: 4096)
        var suffix = [UInt8](repeating: 0, count: 4096)
        var length = [UInt16](repeating: 0, count: 4096)
        var firstByte = [UInt8](repeating: 0, count: 4096)
        for i in 0..<min(clear, 4096) {
            suffix[i] = UInt8(truncatingIfNeeded: i)
            firstByte[i] = suffix[i]
            length[i] = 1
        }

        var r = LSBBitReader(ByteSlice.concatenate(image.data))
        var width = minSize + 1
        var next = clear + 2
        var prev = -1
        var scratch = [UInt8](repeating: 0, count: 4096)

        func emit(_ code: Int) {
            let n = Int(length[code])
            var c = code
            var i = n - 1
            while i >= 0 {
                scratch[i] = suffix[c]
                c = Int(prefix[c])
                i -= 1
            }
            let take = min(n, total - out.count)
            out.append(contentsOf: scratch[0..<take])
        }

        while out.count < total {
            guard r.bitsRemaining >= width else { break }  // data ended without EOI
            let code = Int(try r.bits(width, rule))
            if code == clear {
                width = minSize + 1
                next = clear + 2
                prev = -1
                continue
            }
            if code == eoi { break }
            if prev < 0 {
                guard code < clear else {
                    throw ParseFailure(offset: r.byteOffset, rule: rule, reason: .invalid("code \(code) after clear"))
                }
                emit(code)
                prev = code
                continue
            }
            let k: UInt8
            if code < next {
                k = firstByte[code]
                emit(code)
            } else if code == next && next < 4096 {
                k = firstByte[prev]
                emit(prev)
                if out.count < total { out.append(k) }
            } else {
                throw ParseFailure(offset: r.byteOffset, rule: rule, reason: .invalid("code \(code) beyond table (\(next))"))
            }
            if next < 4096 {
                prefix[next] = UInt16(prev)
                suffix[next] = k
                length[next] = length[prev] + 1
                firstByte[next] = firstByte[prev]
                next += 1
                if next == 1 << width && width < 12 { width += 1 }
            }
            prev = code
        }
        return out
    }
}
