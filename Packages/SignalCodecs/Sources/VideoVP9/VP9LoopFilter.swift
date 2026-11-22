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
        for sbRow in Swift.stride(from: 0, to: rows, by: sb) {
            for sbCol in Swift.stride(from: 0, to: cols, by: sb) {
                let rowEnd = min(rows,sbRow+sb), colEnd = min(cols,sbCol+sb)
                for vertical in [true, false] {
                    let outer = vertical ? sbCol..<colEnd : sbRow..<rowEnd
                    let inner = vertical ? sbRow..<rowEnd : sbCol..<colEnd
                    for edge in outer where edge != 0 {
                        for along in inner {
                            let row = vertical ? along : edge, col = vertical ? edge : along
                            let block = info(row,col)
                            guard block.level > 0, edge.isMultiple(of: 1 << block.tx),
                                  !block.skip || (vertical ? block.left : block.top) else { continue }
                            var taps = min(16, 4 << block.tx)
                            if taps == 4 && edge.isMultiple(of: 8) { taps = 8 }
                            if chroma && edge+1 == (vertical ? cols : rows) { taps = min(8,taps) }
                            let offset = row*4*stride + col*4
                            let step = vertical ? 1 : stride, increment = vertical ? stride : 1
                            for i in 0..<4 {
                                filterSample(at: offset+i*increment, step: step, taps: taps, level: block.level, sharpness: sharpness)
                            }
                        }
                    }
                }
            }
        }
    }

    /// VP9 §8.8.4. Filter a perpendicular sample vector at an eligible edge.
    mutating func filterSample(at index: Int, step: Int, taps: Int, level: Int, sharpness: Int) {
        let shift = (sharpness > 0 ? 1 : 0) + (sharpness > 4 ? 1 : 0)
        let limit = max(1,min(level >> shift, sharpness > 0 ? 9-sharpness : 63))
        let threshold = 2*(level+2)+limit
        func read(_ offset: Int) -> Int { Int(bytes[index+offset*step]) }
        let p0 = read(-1), q0 = read(0), p1 = read(-2), q1 = read(1)
        guard abs(p0-q0)*2+abs(p1-q1)/2 <= threshold else { return }
        for i in 1...3 {
            if abs(read(-i-1)-read(-i)) > limit || abs(read(i)-read(i-1)) > limit { return }
        }
        func flat(_ radii: ClosedRange<Int>) -> Bool {
            radii.allSatisfy { abs(read(-1-$0)-p0) <= 1 && abs(read($0)-q0) <= 1 }
        }
        if taps >= 8 && flat(1...3) {
            let radius = taps == 16 && flat(4...7) ? 7 : 3
            // Symmetric 7- or 15-sample box filter with one extra weight at
            // the centre. Replicate the outermost left and right samples.
            let span = (radius+1)*2
            var original = [Int]()
            original.reserveCapacity(span)
            for i in -(radius+1)...radius { original.append(read(i)) }
            for i in 1..<(span-1) {
                var sum = original[i]
                for tap in -radius...radius { sum += original[max(0,min(i+tap,span-1))] }
                bytes[index+(i-radius-1)*step] = UInt8((sum + span/2)/span)
            }
            return
        }
        let high = max(abs(p1-p0),abs(q1-q0)) > level >> 4
        func signed(_ x: Int) -> Int { min(127,max(-128,x)) }
        let adjustment = signed((high ? signed(p1-q1) : 0) + 3*(q0-p0))
        let innerQ = signed(adjustment+4)>>3, innerP = signed(adjustment+3)>>3
        bytes[index-step] = UInt8(clamping: p0+innerP)
        bytes[index] = UInt8(clamping: q0-innerQ)
        if !high {
            let outer = (innerQ+1)>>1
            bytes[index-2*step] = UInt8(clamping: p1+outer)
            bytes[index+step] = UInt8(clamping: q1-outer)
        }
    }
}
