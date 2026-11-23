// Motion compensation at eighth-pixel resolution (RFC 6386 §18).
enum VP8Prediction {
    private static let sixTap = [
        [0,0,128,0,0,0], [0,-6,123,12,-1,0], [2,-11,108,36,-8,1], [0,-9,93,50,-6,0],
        [3,-16,77,77,-16,3], [0,-6,50,93,-9,0], [1,-8,36,108,-11,2], [0,-1,12,123,-6,0],
    ]
    private static let bilinear = (0..<8).map { [0,0,128 - 16*$0,16*$0,0,0] }

    /// luma false leaves the luma workspace as it is (the encoder already holds that prediction).
    static func inter(_ motion: VP8Motion, x: Int, y: Int, reference: VP8Frame, version: Int, workspace: inout [UInt8],
                      luma: Bool = true) {
        let filters = version == 0 ? sixTap : bilinear
        let size = motion.split.isEmpty ? 16 : 4
        for dy in stride(from: 0, to: luma ? 16 : 0, by: size) {
            for dx in stride(from: 0, to: 16, by: size) {
                predict(reference.y, stride: reference.yStride, rows: reference.mbH * 16, x: x*16+dx, y: y*16+dy,
                        vector: motion.at(dy+dx/4), size: size, filters: filters,
                        output: &workspace, base: VP8Decoder.yOff + dy * VP8Decoder.BPS + dx)
            }
        }
        if motion.split.isEmpty {
            // One vector for the macroblock: each chroma plane as one 8x8 (the same samples as
            // four 4x4 blocks with the same vector).
            let v = motion.vector, mask = version == 3 ? ~7 : ~0
            let uv = VP8Vector(x: ((4*v.x + (v.x < 0 ? -4 : 4)) / 8) & mask, y: ((4*v.y + (v.y < 0 ? -4 : 4)) / 8) & mask)
            predict(reference.u, stride: reference.uvStride, rows: reference.mbH*8, x: x*8, y: y*8,
                    vector: uv, size: 8, filters: filters, output: &workspace, base: VP8Decoder.uOff)
            predict(reference.v, stride: reference.uvStride, rows: reference.mbH*8, x: x*8, y: y*8,
                    vector: uv, size: 8, filters: filters, output: &workspace, base: VP8Decoder.vOff)
            return
        }
        for dy in [0,4] {
            for dx in [0,4] {
                var sx = 0, sy = 0
                for i in [0,1,4,5] {
                    let v = motion.at(dy*2 + dx/2 + i)
                    sx += v.x; sy += v.y
                }
                let mask = version == 3 ? ~7 : ~0
                let uv = VP8Vector(x: ((sx + (sx < 0 ? -4 : 4)) / 8) & mask, y: ((sy + (sy < 0 ? -4 : 4)) / 8) & mask)
                for (plane,base) in [(reference.u,VP8Decoder.uOff),(reference.v,VP8Decoder.vOff)] {
                    predict(plane, stride: reference.uvStride, rows: reference.mbH*8, x: x*8+dx, y: y*8+dy,
                            vector: uv, size: 4, filters: filters, output: &workspace, base: base + dy * VP8Decoder.BPS + dx)
                }
            }
        }
    }

    /// The 16x16 luma prediction of a whole-block vector at sample (x, y), as `inter` makes it,
    /// into `output` (`VP8Decoder.BPS` per row): the encoder's exact measure.
    static func luma(_ reference: VP8Frame, x: Int, y: Int, vector: VP8Vector, version: Int, into output: inout [UInt8]) {
        predict(reference.y, stride: reference.yStride, rows: reference.mbH * 16, x: x, y: y, vector: vector, size: 16,
                filters: version == 0 ? sixTap : bilinear, output: &output, base: 0)
    }

    /// The filters flattened: [fraction*6 + tap].
    private static let sixTapFlat = sixTap.flatMap { $0 }, bilinearFlat = bilinear.flatMap { $0 }

    /// Six-tap (or bilinear) prediction of a size x size block, horizontal pass first, each
    /// rounded to bytes; reference samples outside the plane repeat its edge.
    private static func predict(_ plane: [UInt8], stride: Int, rows: Int, x: Int, y: Int,
                                vector: VP8Vector, size: Int, filters: [[Int]], output: inout [UInt8], base: Int) {
        let left = x + (vector.x >> 3), top = y + (vector.y >> 3)
        let fx = vector.x & 7, fy = vector.y & 7
        let taps = filters == bilinear ? bilinearFlat : sixTapFlat
        let BPS = VP8Decoder.BPS
        let src = plane.span
        var out = output.mutableSpan
        // Every sample a tap reads lies inside the plane: no clamping.
        let inside = left - 2 >= 0 && left + size + 3 <= stride && top - 2 >= 0 && top + size + 3 <= rows
        @inline(__always) func sample(_ r: Int, _ c: Int) -> Int {
            inside ? Int(src[r*stride + c]) : Int(src[min(rows-1,max(0,r))*stride + min(stride-1,max(0,c))])
        }
        if fx == 0 && fy == 0 {
            if inside && size == 16 {
                for r in 0..<16 { storeWide16(&out, base + r*BPS, loadWide16(src, (top + r)*stride + left)) }
                return
            }
            if inside && size == 8 {
                for r in 0..<8 { storeWide8(&out, base + r*BPS, loadWide8(src, (top + r)*stride + left)) }
                return
            }
            for r in 0..<size {
                for c in 0..<size { out[base + r*BPS+c] = UInt8(truncatingIfNeeded: sample(top+r, left+c)) }
            }
            return
        }
        let h = fx*6, v = fy*6
        if inside && size == 16 {
            return predictWide16(src, stride: stride, left: left, top: top, fx: fx, fy: fy, h: h, v: v, taps: taps, output: &out, base: base)
        }
        if inside && size == 8 {
            return predictWide8(src, stride: stride, left: left, top: top, fx: fx, fy: fy, h: h, v: v, taps: taps, output: &out, base: base)
        }
        let h0 = taps[h], h1 = taps[h+1], h2 = taps[h+2], h3 = taps[h+3], h4 = taps[h+4], h5 = taps[h+5]
        let v0 = taps[v], v1 = taps[v+1], v2 = taps[v+2], v3 = taps[v+3], v4 = taps[v+4], v5 = taps[v+5]
        let halo = fy == 0 ? 0 : 2, count = fy == 0 ? size : size + 5
        var temp = InlineArray<336, UInt8>(repeating: 0)
        for r in 0..<count {
            let row = top + r - halo
            for c in 0..<size {
                if fx == 0 { temp[r*size+c] = UInt8(truncatingIfNeeded: sample(row, left+c)); continue }
                let at = left + c - 2
                let sum = 64 + h0*sample(row, at) + h1*sample(row, at+1) + h2*sample(row, at+2)
                    + h3*sample(row, at+3) + h4*sample(row, at+4) + h5*sample(row, at+5)
                temp[r*size+c] = UInt8(clamping: sum >> 7)
            }
        }
        for r in 0..<size {
            for c in 0..<size {
                if fy == 0 { out[base + r*BPS+c] = temp[r*size+c]; continue }
                let i = r*size + c
                let sum = 64 + v0*Int(temp[i]) + v1*Int(temp[i+size]) + v2*Int(temp[i+2*size])
                    + v3*Int(temp[i+3*size]) + v4*Int(temp[i+4*size]) + v5*Int(temp[i+5*size])
                out[base + r*BPS+c] = UInt8(clamping: sum >> 7)
            }
        }
    }

    // 16-bit lanes. For every six-tap (and bilinear) filter the negative taps add up to at most
    // 32 and the positive ones to at most 160, so a sum of taps times bytes lies in
    // [-8 160, 40 800]. Biased by 64 + 64*128 it lies in [96, 49 056]: wrapping 16-bit lanes hold
    // it exactly, and (biased >> 7) - 64 is (64 + sum) >> 7, clamped to bytes without branches.

    @inline(__always)
    private static func loadWide16(_ s: borrowing Span<UInt8>, _ i: Int) -> SIMD16<Int16> {
        let w = s.extracting(i..<(i &+ 16))
        return SIMD16<Int16>(Int16(w[0]), Int16(w[1]), Int16(w[2]), Int16(w[3]), Int16(w[4]), Int16(w[5]), Int16(w[6]), Int16(w[7]), Int16(w[8]), Int16(w[9]), Int16(w[10]), Int16(w[11]), Int16(w[12]), Int16(w[13]), Int16(w[14]), Int16(w[15]))
    }

    @inline(__always)
    private static func kernelWide16(_ taps: [Int], _ k: Int) -> (SIMD16<Int16>, SIMD16<Int16>, SIMD16<Int16>, SIMD16<Int16>, SIMD16<Int16>, SIMD16<Int16>) {
        (SIMD16<Int16>(repeating: Int16(taps[k+0])), SIMD16<Int16>(repeating: Int16(taps[k+1])), SIMD16<Int16>(repeating: Int16(taps[k+2])), SIMD16<Int16>(repeating: Int16(taps[k+3])), SIMD16<Int16>(repeating: Int16(taps[k+4])), SIMD16<Int16>(repeating: Int16(taps[k+5])))
    }

    /// clamp((64 + sum) >> 7, 0, 255) of six taps, exactly (see predictWide).
    @inline(__always)
    private static func filterWide16(_ k: (SIMD16<Int16>, SIMD16<Int16>, SIMD16<Int16>, SIMD16<Int16>, SIMD16<Int16>, SIMD16<Int16>), _ r0: SIMD16<Int16>, _ r1: SIMD16<Int16>, _ r2: SIMD16<Int16>, _ r3: SIMD16<Int16>, _ r4: SIMD16<Int16>, _ r5: SIMD16<Int16>) -> SIMD16<Int16> {
        var sum = SIMD16<Int16>(repeating: 64 + 64*128) &+ k.0 &* r0 &+ k.1 &* r1 &+ k.2 &* r2
        sum &+= k.3 &* r3 &+ k.4 &* r4 &+ k.5 &* r5
        // The biased sum is below 2^16: its unsigned >> 7 is the arithmetic shift's low 9 bits.
        var value = ((sum &>> SIMD16<Int16>(repeating: 7)) & SIMD16<Int16>(repeating: 511)) &- SIMD16<Int16>(repeating: 64)
        value &= ~(value &>> SIMD16<Int16>(repeating: 15))
        let over = (SIMD16<Int16>(repeating: 255) &- value) &>> SIMD16<Int16>(repeating: 15)
        return (value & ~over) | (SIMD16<Int16>(repeating: 255) & over)
    }

    @inline(__always)
    private static func horizontalWide16(_ s: borrowing Span<UInt8>, _ at: Int, _ k: (SIMD16<Int16>, SIMD16<Int16>, SIMD16<Int16>, SIMD16<Int16>, SIMD16<Int16>, SIMD16<Int16>)) -> SIMD16<Int16> {
        filterWide16(k, loadWide16(s, at), loadWide16(s, at &+ 1), loadWide16(s, at &+ 2),
                      loadWide16(s, at &+ 3), loadWide16(s, at &+ 4), loadWide16(s, at &+ 5))
    }

    @inline(__always)
    private static func storeWide16(_ out: inout MutableSpan<UInt8>, _ i: Int, _ v: SIMD16<Int16>) {
        _ = out[i]; _ = out[i &+ 15]
        for j in 0..<16 { out[i &+ j] = UInt8(truncatingIfNeeded: v[j]) }
    }

    /// predictWide for a 16x16 block: 16 outputs per lane vector; two-dimensional filtering
    /// keeps the horizontally filtered rows in a ring (row m: source row top - 2 + m).
    private static func predictWide16(_ src: borrowing Span<UInt8>, stride: Int, left: Int, top: Int, fx: Int, fy: Int,
                                      h: Int, v: Int, taps: [Int], output out: inout MutableSpan<UInt8>, base: Int) {
        let BPS = VP8Decoder.BPS, hk = kernelWide16(taps, h), vk = kernelWide16(taps, v)
        if fy == 0 {
            for r in 0..<16 { storeWide16(&out, base + r*BPS, horizontalWide16(src, (top + r)*stride + left - 2, hk)) }
            return
        }
        if fx == 0 {
            for r in 0..<16 {
                let at = (top + r - 2)*stride + left
                let value = filterWide16(vk, loadWide16(src, at), loadWide16(src, at + stride), loadWide16(src, at + 2*stride),
                                          loadWide16(src, at + 3*stride), loadWide16(src, at + 4*stride), loadWide16(src, at + 5*stride))
                storeWide16(&out, base + r*BPS, value)
            }
            return
        }
        var ring = InlineArray<8, SIMD16<Int16>>(repeating: SIMD16<Int16>())
        for m in 0..<5 { ring[m] = horizontalWide16(src, (top + m - 2)*stride + left - 2, hk) }
        for r in 0..<16 {
            ring[(r + 5) & 7] = horizontalWide16(src, (top + r + 3)*stride + left - 2, hk)
            let value = filterWide16(vk, ring[r & 7], ring[(r + 1) & 7], ring[(r + 2) & 7], ring[(r + 3) & 7],
                                      ring[(r + 4) & 7], ring[(r + 5) & 7])
            storeWide16(&out, base + r*BPS, value)
        }
    }

    @inline(__always)
    private static func loadWide8(_ s: borrowing Span<UInt8>, _ i: Int) -> SIMD8<Int16> {
        let w = s.extracting(i..<(i &+ 8))
        return SIMD8<Int16>(Int16(w[0]), Int16(w[1]), Int16(w[2]), Int16(w[3]), Int16(w[4]), Int16(w[5]), Int16(w[6]), Int16(w[7]))
    }

    @inline(__always)
    private static func kernelWide8(_ taps: [Int], _ k: Int) -> (SIMD8<Int16>, SIMD8<Int16>, SIMD8<Int16>, SIMD8<Int16>, SIMD8<Int16>, SIMD8<Int16>) {
        (SIMD8<Int16>(repeating: Int16(taps[k+0])), SIMD8<Int16>(repeating: Int16(taps[k+1])), SIMD8<Int16>(repeating: Int16(taps[k+2])), SIMD8<Int16>(repeating: Int16(taps[k+3])), SIMD8<Int16>(repeating: Int16(taps[k+4])), SIMD8<Int16>(repeating: Int16(taps[k+5])))
    }

    /// clamp((64 + sum) >> 7, 0, 255) of six taps, exactly (see predictWide).
    @inline(__always)
    private static func filterWide8(_ k: (SIMD8<Int16>, SIMD8<Int16>, SIMD8<Int16>, SIMD8<Int16>, SIMD8<Int16>, SIMD8<Int16>), _ r0: SIMD8<Int16>, _ r1: SIMD8<Int16>, _ r2: SIMD8<Int16>, _ r3: SIMD8<Int16>, _ r4: SIMD8<Int16>, _ r5: SIMD8<Int16>) -> SIMD8<Int16> {
        var sum = SIMD8<Int16>(repeating: 64 + 64*128) &+ k.0 &* r0 &+ k.1 &* r1 &+ k.2 &* r2
        sum &+= k.3 &* r3 &+ k.4 &* r4 &+ k.5 &* r5
        // The biased sum is below 2^16: its unsigned >> 7 is the arithmetic shift's low 9 bits.
        var value = ((sum &>> SIMD8<Int16>(repeating: 7)) & SIMD8<Int16>(repeating: 511)) &- SIMD8<Int16>(repeating: 64)
        value &= ~(value &>> SIMD8<Int16>(repeating: 15))
        let over = (SIMD8<Int16>(repeating: 255) &- value) &>> SIMD8<Int16>(repeating: 15)
        return (value & ~over) | (SIMD8<Int16>(repeating: 255) & over)
    }

    @inline(__always)
    private static func horizontalWide8(_ s: borrowing Span<UInt8>, _ at: Int, _ k: (SIMD8<Int16>, SIMD8<Int16>, SIMD8<Int16>, SIMD8<Int16>, SIMD8<Int16>, SIMD8<Int16>)) -> SIMD8<Int16> {
        filterWide8(k, loadWide8(s, at), loadWide8(s, at &+ 1), loadWide8(s, at &+ 2),
                      loadWide8(s, at &+ 3), loadWide8(s, at &+ 4), loadWide8(s, at &+ 5))
    }

    @inline(__always)
    private static func storeWide8(_ out: inout MutableSpan<UInt8>, _ i: Int, _ v: SIMD8<Int16>) {
        _ = out[i]; _ = out[i &+ 7]
        for j in 0..<8 { out[i &+ j] = UInt8(truncatingIfNeeded: v[j]) }
    }

    /// predictWide for a 8x8 block: 8 outputs per lane vector; two-dimensional filtering
    /// keeps the horizontally filtered rows in a ring (row m: source row top - 2 + m).
    private static func predictWide8(_ src: borrowing Span<UInt8>, stride: Int, left: Int, top: Int, fx: Int, fy: Int,
                                      h: Int, v: Int, taps: [Int], output out: inout MutableSpan<UInt8>, base: Int) {
        let BPS = VP8Decoder.BPS, hk = kernelWide8(taps, h), vk = kernelWide8(taps, v)
        if fy == 0 {
            for r in 0..<8 { storeWide8(&out, base + r*BPS, horizontalWide8(src, (top + r)*stride + left - 2, hk)) }
            return
        }
        if fx == 0 {
            for r in 0..<8 {
                let at = (top + r - 2)*stride + left
                let value = filterWide8(vk, loadWide8(src, at), loadWide8(src, at + stride), loadWide8(src, at + 2*stride),
                                          loadWide8(src, at + 3*stride), loadWide8(src, at + 4*stride), loadWide8(src, at + 5*stride))
                storeWide8(&out, base + r*BPS, value)
            }
            return
        }
        var ring = InlineArray<8, SIMD8<Int16>>(repeating: SIMD8<Int16>())
        for m in 0..<5 { ring[m] = horizontalWide8(src, (top + m - 2)*stride + left - 2, hk) }
        for r in 0..<8 {
            ring[(r + 5) & 7] = horizontalWide8(src, (top + r + 3)*stride + left - 2, hk)
            let value = filterWide8(vk, ring[r & 7], ring[(r + 1) & 7], ring[(r + 2) & 7], ring[(r + 3) & 7],
                                      ring[(r + 4) & 7], ring[(r + 5) & 7])
            storeWide8(&out, base + r*BPS, value)
        }
    }

}

