/// Edge metadata in plane-local 4x4 units. The decoder supplies the segment and
/// mode-adjusted filter level and the transform size (0=4x4 through 3=32x32).
struct VP9FilterBlock {
    var level: Int
    var tx: Int
    var skip: Bool
    var left: Bool
    var top: Bool
}

extension VP9Plane {
    /// Filter one plane in superblock order. Both passes over a superblock
    /// finish before the vertical pass on the adjacent superblock starts.
    mutating func filter(sharpness: Int, chroma: Bool, info: (Int, Int) -> VP9FilterBlock) {
        let sb = chroma ? 8 : 16
        let rows = chroma ? (height+3)/4 : (height+7)/8*2
        let cols = chroma ? (width+3)/4 : (width+7)/8*2
        let stride = self.stride
        // Each 4x4's filter decisions for its left (vertical pass) and top edges, packed as
        // level | vertical taps << 8 | horizontal taps << 16; zero taps: not filtered.
        // Filtering never changes block info, so this is the same as asking per edge.
        var edges = [Int32](repeating: 0, count: rows*cols)
        do {
            var out = edges.mutableSpan
            for row in 0..<rows {
                for col in 0..<cols {
                    let block = info(row,col)
                    guard block.level > 0 else { continue }
                    func taps(_ edge: Int, _ count: Int, _ boundary: Bool) -> Int {
                        guard edge != 0, edge.isMultiple(of: 1 << block.tx), !block.skip || boundary else { return 0 }
                        var taps = min(16, 4 << block.tx)
                        if taps == 4 && edge.isMultiple(of: 8) { taps = 8 }
                        if chroma && edge+1 == count { taps = min(8,taps) }
                        return taps
                    }
                    out[row*cols+col] = Int32(block.level | taps(col,cols,block.left) << 8 | taps(row,rows,block.top) << 16)
                }
            }
        }
        var samples = bytes.mutableSpan
        for sbRow in Swift.stride(from: 0, to: rows, by: sb) {
            for sbCol in Swift.stride(from: 0, to: cols, by: sb) {
                let rowEnd = min(rows,sbRow+sb), colEnd = min(cols,sbCol+sb)
                for pass in 0..<2 {
                    let vertical = pass == 0
                    let outer = vertical ? sbCol..<colEnd : sbRow..<rowEnd
                    let inner = vertical ? sbRow..<rowEnd : sbCol..<colEnd
                    let step = vertical ? 1 : stride, increment = vertical ? stride : 1
                    let tapShift = vertical ? 8 : 16
                    for edge in outer where edge != 0 {
                        // Units along one edge filter separate sample lines, so two at a time
                        // (8 lanes) give the same result as one after the other.
                        var along = inner.lowerBound
                        while along < inner.upperBound {
                            let row = vertical ? along : edge, col = vertical ? edge : along
                            let code = Int(edges[row*cols+col])
                            let offset = row*4*stride + col*4
                            if along+1 < inner.upperBound {
                                let next = Int(edges[vertical ? (row+1)*cols+col : row*cols+col+1])
                                if (code | next) >> tapShift & 255 != 0 {
                                    func lanes(_ f: (Int) -> Int) -> SIMD8<Int16> {
                                        SIMD8(lowHalf: SIMD4(repeating: Int16(f(code))), highHalf: SIMD4(repeating: Int16(f(next))))
                                    }
                                    Self.filterLanes(&samples, at: offset, step: step, increment: increment,
                                                     taps: lanes { $0 >> tapShift & 255 }, hev: lanes { ($0 & 255) >> 4 },
                                                     limit: lanes { Self.limits(level: $0 & 255, sharpness: sharpness).limit },
                                                     threshold: lanes { Self.limits(level: $0 & 255, sharpness: sharpness).threshold })
                                }
                                along += 2
                                continue
                            }
                            along += 1
                            let taps = (code >> tapShift) & 255
                            guard taps != 0 else { continue }
                            let level = code & 255
                            let (limit, threshold) = Self.limits(level: level, sharpness: sharpness)
                            for i in 0..<4 {
                                Self.filterSample(&samples, at: offset+i*increment, step: step, taps: taps,
                                                  level: level, limit: limit, threshold: threshold)
                            }
                        }
                    }
                }
            }
        }
    }

    /// §8.8.1: the limit and the edge threshold for a filter level.
    static func limits(level: Int, sharpness: Int) -> (limit: Int, threshold: Int) {
        let shift = (sharpness > 0 ? 1 : 0) + (sharpness > 4 ? 1 : 0)
        let limit = max(1,min(level >> shift, sharpness > 0 ? 9-sharpness : 63))
        return (limit, 2*(level+2)+limit)
    }

    /// One sample line, as the scalar kernel filters it.
    mutating func filterSample(at index: Int, step: Int, taps: Int, level: Int, sharpness: Int) {
        let (limit, threshold) = Self.limits(level: level, sharpness: sharpness)
        var samples = bytes.mutableSpan
        Self.filterSample(&samples, at: index, step: step, taps: taps, level: level, limit: limit, threshold: threshold)
    }

    /// Two adjacent 4-sample units along one edge (taps 0: unit not filtered), as the plane
    /// filter runs them: 8 lanes at once.
    mutating func filterPair(at index: Int, step: Int, increment: Int, taps: (Int, Int), levels: (Int, Int), sharpness: Int) {
        let first = Self.limits(level: levels.0, sharpness: sharpness), second = Self.limits(level: levels.1, sharpness: sharpness)
        func lanes(_ a: Int, _ b: Int) -> SIMD8<Int16> { SIMD8(lowHalf: SIMD4(repeating: Int16(a)), highHalf: SIMD4(repeating: Int16(b))) }
        var samples = bytes.mutableSpan
        Self.filterLanes(&samples, at: index, step: step, increment: increment, taps: lanes(taps.0, taps.1),
                         hev: lanes(levels.0 >> 4, levels.1 >> 4), limit: lanes(first.limit, second.limit),
                         threshold: lanes(first.threshold, second.threshold))
    }

    /// VP9 §8.8.4. Filter a perpendicular sample vector at an eligible edge.
    @inline(__always)
    private static func filterSample(_ s: inout MutableSpan<UInt8>, at index: Int, step: Int, taps: Int,
                                     level: Int, limit: Int, threshold: Int) {
        let p0 = Int(s[index-step]), q0 = Int(s[index]), p1 = Int(s[index-2*step]), q1 = Int(s[index+step])
        guard abs(p0-q0)*2+abs(p1-q1)/2 <= threshold else { return }
        let p2 = Int(s[index-3*step]), q2 = Int(s[index+2*step])
        let p3 = Int(s[index-4*step]), q3 = Int(s[index+3*step])
        guard abs(p1-p0) <= limit, abs(q1-q0) <= limit, abs(p2-p1) <= limit, abs(q2-q1) <= limit,
              abs(p3-p2) <= limit, abs(q3-q2) <= limit else { return }
        if taps >= 8 && abs(p1-p0) <= 1 && abs(q1-q0) <= 1 && abs(p2-p0) <= 1 && abs(q2-q0) <= 1
            && abs(p3-p0) <= 1 && abs(q3-q0) <= 1 {
            if taps == 16 && abs(Int(s[index-5*step])-p0) <= 1 && abs(Int(s[index+4*step])-q0) <= 1
                && abs(Int(s[index-6*step])-p0) <= 1 && abs(Int(s[index+5*step])-q0) <= 1
                && abs(Int(s[index-7*step])-p0) <= 1 && abs(Int(s[index+6*step])-q0) <= 1
                && abs(Int(s[index-8*step])-p0) <= 1 && abs(Int(s[index+7*step])-q0) <= 1 {
                smooth(&s, at: index, step: step, radius: 7)
            } else {
                smooth(&s, at: index, step: step, radius: 3)
            }
            return
        }
        let high = max(abs(p1-p0),abs(q1-q0)) > level >> 4
        func signed(_ x: Int) -> Int { min(127,max(-128,x)) }
        let adjustment = signed((high ? signed(p1-q1) : 0) + 3*(q0-p0))
        let innerQ = signed(adjustment+4)>>3, innerP = signed(adjustment+3)>>3
        s[index-step] = UInt8(clamping: p0+innerP)
        s[index] = UInt8(clamping: q0-innerQ)
        if !high {
            let outer = (innerQ+1)>>1
            s[index-2*step] = UInt8(clamping: p1+outer)
            s[index+step] = UInt8(clamping: q1-outer)
        }
    }

    /// filterSample for 8 sample lines at once (lane j at index + j*increment), each lane with
    /// its own taps (0: leave it), hev threshold (level >> 4), limit and threshold. Every
    /// variant is computed and selected per lane; unselected lanes are written back unchanged.
    @inline(__always)
    private static func filterLanes(_ s: inout MutableSpan<UInt8>, at index: Int, step: Int, increment: Int,
                                    taps: SIMD8<Int16>, hev: SIMD8<Int16>, limit: SIMD8<Int16>, threshold: SIMD8<Int16>) {
        // Horizontal edges (step: the stride): a lane vector is 8 adjacent samples of one row.
        // Vertical edges (step 1): lane j is row j, read as one contiguous run per row.
        let across = step == 1
        @inline(__always) func load(_ k: Int) -> SIMD8<Int16> {
            let i = index + k*step
            _ = s[i]; _ = s[i + 7]
            return SIMD8(Int16(s[i]), Int16(s[i+1]), Int16(s[i+2]), Int16(s[i+3]),
                         Int16(s[i+4]), Int16(s[i+5]), Int16(s[i+6]), Int16(s[i+7]))
        }
        /// Samples first ..< first+count of every row, as count lane vectors (vertical edges).
        @inline(__always) func rows(_ first: Int) -> (V, V, V, V, V, V, V, V) {
            var a = V(), b = V(), c = V(), d = V(), e = V(), f = V(), g = V(), h = V()
            for j in 0..<8 {
                let i = index + j*increment + first
                _ = s[i]; _ = s[i + 7]
                a[j] = Int16(s[i]); b[j] = Int16(s[i+1]); c[j] = Int16(s[i+2]); d[j] = Int16(s[i+3])
                e[j] = Int16(s[i+4]); f[j] = Int16(s[i+5]); g[j] = Int16(s[i+6]); h[j] = Int16(s[i+7])
            }
            return (a, b, c, d, e, f, g, h)
        }
        typealias V = SIMD8<Int16>
        let zero = V(repeating: 0), one = V(repeating: 1), two = V(repeating: 2), three = V(repeating: 3)
        let four = V(repeating: 4), seven = V(repeating: 7), eight = V(repeating: 8), sixteen = V(repeating: 16)
        @inline(__always) func abs(_ v: V) -> V { pointwiseMax(v, zero &- v) }
        let p3, p2, p1, p0, q0, q1, q2, q3: V
        if across { (p3, p2, p1, p0, q0, q1, q2, q3) = rows(-4) }
        else { p3 = load(-4); p2 = load(-3); p1 = load(-2); p0 = load(-1); q0 = load(0); q1 = load(1); q2 = load(2); q3 = load(3) }
        let d10 = abs(p1 &- p0), e10 = abs(q1 &- q0)
        var mask = (taps .!= zero) .& ((abs(p0 &- q0) &* two &+ abs(p1 &- q1) &>> one) .<= threshold)
        mask = mask .& (d10 .<= limit) .& (e10 .<= limit) .& (abs(p2 &- p1) .<= limit) .& (abs(q2 &- q1) .<= limit)
            .& (abs(p3 &- p2) .<= limit) .& (abs(q3 &- q2) .<= limit)
        guard any(mask) else { return }
        let flat = mask .& (taps .>= eight) .& (d10 .<= one) .& (e10 .<= one) .& (abs(p2 &- p0) .<= one) .& (abs(q2 &- q0) .<= one)
            .& (abs(p3 &- p0) .<= one) .& (abs(q3 &- q0) .<= one)
        // Normal filter (lanes in mask, not flat).
        let high = pointwiseMax(d10, e10) .> hev
        @inline(__always) func signed(_ v: SIMD8<Int16>) -> SIMD8<Int16> { v.clamped(lowerBound: SIMD8(repeating: -128), upperBound: SIMD8(repeating: 127)) }
        @inline(__always) func pixel(_ v: SIMD8<Int16>) -> SIMD8<Int16> { v.clamped(lowerBound: SIMD8(repeating: 0), upperBound: SIMD8(repeating: 255)) }
        let adjustment = signed(zero.replacing(with: signed(p1 &- q1), where: high) &+ three &* (q0 &- p0))
        let innerQ = signed(adjustment &+ four) &>> three, innerP = signed(adjustment &+ three) &>> three
        let outer = (innerQ &+ one) &>> one
        let normal = mask .& .!flat, outerToo = normal .& .!high
        var op0 = p0.replacing(with: pixel(p0 &+ innerP), where: normal)
        var oq0 = q0.replacing(with: pixel(q0 &- innerQ), where: normal)
        var op1 = p1.replacing(with: pixel(p1 &+ outer), where: outerToo)
        var oq1 = q1.replacing(with: pixel(q1 &- outer), where: outerToo)
        var op2 = p2, oq2 = q2
        var wide = false
        if any(flat) {
            // 7-tap: (p3 p3 p3 2p2 p1 p0 q0) ... running sums as in smooth(radius: 3).
            op2.replace(with: (p3 &* three &+ p2 &* two &+ p1 &+ p0 &+ q0 &+ four) &>> three, where: flat)
            op1.replace(with: (p3 &* two &+ p2 &+ p1 &* two &+ p0 &+ q0 &+ q1 &+ four) &>> three, where: flat)
            op0.replace(with: (p3 &+ p2 &+ p1 &+ p0 &* two &+ q0 &+ q1 &+ q2 &+ four) &>> three, where: flat)
            oq0.replace(with: (p2 &+ p1 &+ p0 &+ q0 &* two &+ q1 &+ q2 &+ q3 &+ four) &>> three, where: flat)
            oq1.replace(with: (p1 &+ p0 &+ q0 &+ q1 &* two &+ q2 &+ q3 &* two &+ four) &>> three, where: flat)
            oq2.replace(with: (p0 &+ q0 &+ q1 &+ q2 &* two &+ q3 &* three &+ four) &>> three, where: flat)
            let flat16 = flat .& (taps .== sixteen)
            if any(flat16) {
                let p7, p6, p5, p4, q4, q5, q6, q7: V
                if across {
                    let outer = rows(-8), inner = rows(0)
                    (p7, p6, p5, p4) = (outer.0, outer.1, outer.2, outer.3)
                    (q4, q5, q6, q7) = (inner.4, inner.5, inner.6, inner.7)
                } else {
                    p7 = load(-8); p6 = load(-7); p5 = load(-6); p4 = load(-5); q4 = load(4); q5 = load(5); q6 = load(6); q7 = load(7)
                }
                let flat2 = flat16 .& (abs(p4 &- p0) .<= one) .& (abs(q4 &- q0) .<= one) .& (abs(p5 &- p0) .<= one)
                    .& (abs(q5 &- q0) .<= one) .& (abs(p6 &- p0) .<= one) .& (abs(q6 &- q0) .<= one)
                    .& (abs(p7 &- p0) .<= one) .& (abs(q7 &- q0) .<= one)
                if any(flat2) {
                    wide = true
                    // 15-tap box with the centre doubled and p7/q7 replicated (smooth(radius: 7)).
                    var x = InlineArray<16, SIMD8<Int16>>(repeating: p7)
                    x[1] = p6; x[2] = p5; x[3] = p4; x[4] = p3; x[5] = p2; x[6] = p1; x[7] = p0
                    x[8] = q0; x[9] = q1; x[10] = q2; x[11] = q3; x[12] = q4; x[13] = q5; x[14] = q6; x[15] = q7
                    var window = p7 &* seven &+ p6 &+ p5 &+ p4 &+ p3 &+ p2 &+ p1 &+ p0 &+ q0
                    var out = InlineArray<14, SIMD8<Int16>>(repeating: SIMD8())
                    for i in 1..<15 {
                        out[i-1] = (x[i] &+ window &+ eight) &>> four
                        window = window &+ x[min(i+8,15)] &- x[max(0,i-7)]
                    }
                    for i in 1..<15 {
                        let original = x[i]
                        var v: SIMD8<Int16>
                        switch i {
                        case 5: v = op2
                        case 6: v = op1
                        case 7: v = op0
                        case 8: v = oq0
                        case 9: v = oq1
                        case 10: v = oq2
                        default: v = original
                        }
                        v.replace(with: out[i-1], where: flat2)
                        store(i-8, v)
                    }
                }
            }
        }
        @inline(__always) func store(_ k: Int, _ v: SIMD8<Int16>) {
            let i = index + k*step
            for j in 0..<8 { s[i + j*increment] = UInt8(truncatingIfNeeded: v[j]) }
        }
        guard !wide else { return }
        store(-2, op1); store(-1, op0); store(0, oq0); store(1, oq1)
        if any(flat) { store(-3, op2); store(2, oq2) }
    }

    /// Symmetric 7- or 15-sample box filter with one extra weight at the centre,
    /// replicating the outermost samples; a running window sum per output.
    @inline(__always)
    private static func smooth(_ s: inout MutableSpan<UInt8>, at index: Int, step: Int, radius: Int) {
        let span = (radius+1)*2, last = span-1, shift = radius == 7 ? 4 : 3
        var original = InlineArray<16, Int>(repeating: 0)
        for i in 0..<span { original[i] = Int(s[index+(i-radius-1)*step]) }
        var window = 0
        for tap in -radius...radius { window += original[max(0,min(1+tap,last))] }
        for i in 1..<last {
            s[index+(i-radius-1)*step] = UInt8(truncatingIfNeeded: (original[i] + window + span/2) >> shift)
            window += original[min(i+radius+1,last)] - original[max(0,i-radius)]
        }
    }
}
