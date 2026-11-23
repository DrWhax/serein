// Prediction and interpolation from VP9 Bitstream Specification §8.5 and §8.6.
// The interpolation tables are from libvpx vp9/common/vp9_filter.c (WebM BSD license).
struct VP9Plane: Sendable {
    let width: Int
    let height: Int
    let stride: Int
    private let codedWidth: Int
    private let codedHeight: Int
    /// The first sample column stored: 0 for a whole plane; a tile column's strip stores only
    /// its own columns but is addressed in frame coordinates.
    let originX: Int
    var bytes: [UInt8]

    init(width: Int, height: Int, chroma: Bool = false) {
        self.init(width: width, height: height, chroma: chroma, columns: 0..<((width+63) / 64 * 64))
    }

    /// Sample columns `columns` of a frame plane of this size.
    init(width: Int, height: Int, chroma: Bool, columns: Range<Int>) {
        self.width = width
        self.height = height
        let miSize = chroma ? 4 : 8
        codedWidth = (width+miSize-1)/miSize*miSize
        codedHeight = (height+miSize-1)/miSize*miSize
        originX = columns.lowerBound
        stride = columns.count
        bytes = [UInt8](repeating: 0, count: stride * ((height+63)/64*64))
    }

    /// A whole plane from its tile columns' strips, left to right, row by row (no zero fill).
    init(strips: [Self]) {
        let first = strips[0]
        self.width = first.width; self.height = first.height
        codedWidth = first.codedWidth; codedHeight = first.codedHeight
        originX = 0
        stride = strips.reduce(0) { $0 + $1.stride }
        var bytes = [UInt8]()
        bytes.reserveCapacity(stride * ((height+63)/64*64))
        for row in 0..<((height+63)/64*64) {
            for strip in strips where strip.stride > 0 {
                bytes.append(contentsOf: strip.bytes[(row*strip.stride)..<((row+1)*strip.stride)])
            }
        }
        self.bytes = bytes
    }

    /// The decoder reconstructs complete transform blocks at the coded frame edge.
    /// For intra prediction the border is the final coded MI, including the decoded
    /// samples outside a partially visible MI. Inter prediction extends visible pixels.
    mutating func predictIntra(mode: Int, x: Int, y: Int, size: Int, tileLeft: Int, tileTop: Int, haveRight: Bool) {
        let hasTop = y > tileTop, hasLeft = x > tileLeft
        var top = [Int](repeating: 127, count: size*2+2)
        var left = [Int](repeating: 129, count: size+2)
        func neighbour(_ x: Int, _ y: Int) -> Int {
            Int(bytes[min(codedHeight-1,y)*stride+min(codedWidth-1,x)-originX])
        }
        let corner = !hasTop ? 127 : !hasLeft ? 129 : neighbour(x-1, y-1)
        if hasTop {
            let available = haveRight && size == 4 ? size*2 : size
            for i in top.indices { top[i] = neighbour(x+min(i,available-1), y-1) }
        }
        if hasLeft {
            for i in left.indices { left[i] = neighbour(x-1, y+min(i,size-1)) }
        }
        let sides = (hasLeft ? 1 : 0) + (hasTop ? 1 : 0)
        let sum = (hasLeft ? left.prefix(size).reduce(0,+) : 0) + (hasTop ? top.prefix(size).reduce(0,+) : 0)
        let dc = sides == 0 ? 128 : (sum + size*sides/2) / (size*sides)
        func boundary(_ i: Int) -> Int {
            if i == 0 { return corner }
            return i < 0 ? left[-i-1] : top[i-1]
        }
        func avg2(_ a: Int, _ b: Int) -> Int { (a+b+1)>>1 }
        func avg3(_ a: Int, _ b: Int, _ c: Int) -> Int { (a+2*b+c+2)>>2 }
        // Project onto a half-pixel diagonal for D117; D153 is its transpose.
        func shallow(_ projection: Int, transposed: Bool) -> Int {
            let direction = transposed ? -1 : 1
            if projection >= 0 && projection.isMultiple(of: 2) {
                let i = projection/2
                return avg2(boundary(direction*i),boundary(direction*(i+1)))
            }
            let i = direction * (projection >= -1 ? (projection+1)/2 : projection+1)
            return avg3(boundary(i-1),boundary(i),boundary(i+1))
        }
        for row in 0..<size {
            for col in 0..<size {
                let result: Int
                switch mode {
                case 0: result = dc
                case 1: result = top[col]
                case 2: result = left[row]
                case 3:
                    let i = row+col
                    result = size == 4 && i == 6 ? top[7] : avg3(top[i],top[i+1],top[i+2])
                case 4:
                    let i = col-row
                    result = avg3(boundary(i-1),boundary(i),boundary(i+1))
                case 5: result = shallow(2*col-row, transposed: false)
                case 6: result = shallow(2*row-col, transposed: true)
                case 7:
                    let i = min(row+col/2, size-1)
                    result = col.isMultiple(of: 2) ? avg2(left[i],left[i+1]) : avg3(left[i],left[i+1],left[i+2])
                case 8:
                    let i = col+row/2
                    result = row.isMultiple(of: 2) ? avg2(top[i],top[i+1]) : avg3(top[i],top[i+1],top[i+2])
                default: result = top[col]+left[row]-corner
                }
                bytes[(y+row)*stride+x-originX+col] = UInt8(clamping: result)
            }
        }
    }

    /// Add one residual value to a whole transform block, clamped.
    mutating func addConstant(_ value: Int, x: Int, y: Int, size: Int) {
        let stride = self.stride, x = x - originX
        var out = bytes.mutableSpan
        for dy in 0..<size {
            let row = (y+dy)*stride + x
            for dx in 0..<size { out[row+dx] = UInt8(clamping: Int(out[row+dx]) + value) }
        }
    }

    /// Add a transform block's residual, clamped, and zero those values for the next block.
    mutating func addResidual(_ values: inout [Int], x: Int, y: Int, size: Int) {
        let stride = self.stride, x = x - originX
        var out = bytes.mutableSpan, residual = values.mutableSpan
        for dy in 0..<size {
            let row = (y+dy)*stride + x, base = dy*size
            for dx in 0..<size {
                out[row+dx] = UInt8(clamping: Int(out[row+dx]) + residual[base+dx])
                residual[base+dx] = 0
            }
        }
    }

    private func sample(_ x: Int, _ y: Int) -> Int {
        Int(bytes[min(height-1,max(0,y))*stride + min(width-1,max(0,x))])
    }

    /// Source coordinates and steps are in sixteenths of a plane sample, including
    /// any per-reference frame scaling. Average a second prediction for compound modes.
    mutating func predictInter(reference: Self, x: Int, y: Int, width: Int, height: Int,
                               sourceX16: Int, sourceY16: Int, stepX16: Int = 16, stepY16: Int = 16,
                               filter: Int, average: Bool = false) {
        if stepX16 == 16 && stepY16 == 16 && width <= 64 && height <= 64 {
            return predictUnscaled(reference: reference, x: x, y: y, width: width, height: height,
                                   sourceX16: sourceX16, sourceY16: sourceY16, filter: filter, average: average)
        }
        let kernels = Self.filters[filter]
        let firstRow = (sourceY16>>4)-3, lastRow = ((sourceY16+(height-1)*stepY16)>>4)+4
        var intermediate = [UInt8](repeating: 0, count: (lastRow-firstRow+1)*width)
        for row in firstRow...lastRow {
            for col in 0..<width {
                let sx = sourceX16+col*stepX16, base = sx>>4, fraction = sx&15
                let value: Int
                if fraction == 0 { value = reference.sample(base, row) }
                else {
                    var sum = 0
                    let taps = kernels[fraction]
                    for tap in 0..<8 { sum += taps[tap]*reference.sample(base+tap-3,row) }
                    value = (sum+64)>>7
                }
                intermediate[(row-firstRow)*width+col] = UInt8(clamping: value)
            }
        }
        for row in 0..<height {
            let sy = sourceY16+row*stepY16, base = (sy>>4)-firstRow, fraction = sy&15
            for col in 0..<width {
                let prediction: UInt8
                if fraction == 0 { prediction = intermediate[base*width+col] }
                else {
                    var sum = 0
                    let taps = kernels[fraction]
                    for tap in 0..<8 { sum += taps[tap]*Int(intermediate[(base+tap-3)*width+col]) }
                    prediction = UInt8(clamping: (sum+64)>>7)
                }
                let i = (y+row)*stride+x-originX+col
                bytes[i] = average ? UInt8((Int(bytes[i])+Int(prediction)+1)>>1) : prediction
            }
        }
    }

    /// The unscaled case of predictInter, with the same arithmetic: a horizontal 8-tap pass
    /// rounded to bytes, then a vertical one; a zero fraction is the identity. Reads go to the
    /// reference itself when the window lies inside it, else to an edge-extended copy.
    private mutating func predictUnscaled(reference: Self, x: Int, y: Int, width: Int, height: Int,
                                          sourceX16: Int, sourceY16: Int, filter: Int, average: Bool) {
        let fractionX = sourceX16 & 15, fractionY = sourceY16 & 15
        let sourceX = sourceX16 >> 4, sourceY = sourceY16 >> 4
        let kx = (filter*16 + fractionX)*8, ky = (filter*16 + fractionY)*8
        let inside = sourceX-3 >= 0 && sourceX+width+4 <= reference.width
            && sourceY-3 >= 0 && sourceY+height+4 <= reference.height
        let src = inside ? reference.bytes : reference.window(x: sourceX-3, y: sourceY-3, width: width+7, height: height+7)
        let srcStride = inside ? reference.stride : width+7
        let srcOrigin = inside ? sourceY*srcStride + sourceX : 3*srcStride+3
        let dstStride = stride, dstOrigin = y*stride + x - originX
        var dst = bytes.mutableSpan
        Self.convolve(src.span, srcOrigin, srcStride, &dst, dstOrigin, dstStride, width: width, height: height,
                      kx: kx, ky: ky, fractionX: fractionX, fractionY: fractionY, average: average)
    }

    /// The samples sample(_:_:) reads for a window, clamped once per position.
    private func window(x: Int, y: Int, width w: Int, height h: Int) -> [UInt8] {
        var window = [UInt8](repeating: 0, count: w*h)
        let ref = bytes.span
        var out = window.mutableSpan
        for r in 0..<h {
            let row = min(height-1,max(0,y+r))*stride
            for c in 0..<w { out[r*w+c] = ref[row + min(width-1,max(0,x+c))] }
        }
        return window
    }

    @inline(__always)
    private static func put(_ dst: inout MutableSpan<UInt8>, _ i: Int, _ value: Int, _ average: Bool) {
        dst[i] = average ? UInt8(truncatingIfNeeded: (Int(dst[i]) + value + 1) >> 1) : UInt8(truncatingIfNeeded: value)
    }

    private typealias Lanes = SIMD8<Int32>
    private typealias Kernel = (Lanes, Lanes, Lanes, Lanes, Lanes, Lanes, Lanes, Lanes)

    @inline(__always)
    private static func kernel(_ k: Int) -> Kernel {
        let taps = flatFilters
        return (Lanes(repeating: Int32(taps[k])), Lanes(repeating: Int32(taps[k+1])), Lanes(repeating: Int32(taps[k+2])),
                Lanes(repeating: Int32(taps[k+3])), Lanes(repeating: Int32(taps[k+4])), Lanes(repeating: Int32(taps[k+5])),
                Lanes(repeating: Int32(taps[k+6])), Lanes(repeating: Int32(taps[k+7])))
    }

    @inline(__always)
    private static func load8(_ s: borrowing Span<UInt8>, _ i: Int) -> Lanes {
        _ = s[i + 7]
        return Lanes(Int32(s[i]), Int32(s[i+1]), Int32(s[i+2]), Int32(s[i+3]),
                     Int32(s[i+4]), Int32(s[i+5]), Int32(s[i+6]), Int32(s[i+7]))
    }

    /// Eight outputs of one 8-tap pass: tap t of output j reads s[i + j + t*step].
    @inline(__always)
    private static func taps8(_ s: borrowing Span<UInt8>, _ i: Int, _ step: Int, _ k: Kernel) -> Lanes {
        var sum = k.0 &* load8(s, i)
        sum &+= k.1 &* load8(s, i + step)
        sum &+= k.2 &* load8(s, i + 2*step)
        sum &+= k.3 &* load8(s, i + 3*step)
        sum &+= k.4 &* load8(s, i + 4*step)
        sum &+= k.5 &* load8(s, i + 5*step)
        sum &+= k.6 &* load8(s, i + 6*step)
        sum &+= k.7 &* load8(s, i + 7*step)
        return ((sum &+ Lanes(repeating: 64)) &>> Lanes(repeating: 7))
            .clamped(lowerBound: Lanes(repeating: 0), upperBound: Lanes(repeating: 255))
    }

    @inline(__always)
    private static func put8(_ d: inout MutableSpan<UInt8>, _ i: Int, _ v: Lanes, _ average: Bool) {
        _ = d[i + 7]
        if average {
            var old = Lanes()
            for j in 0..<8 { old[j] = Int32(d[i+j]) }
            let mean = (old &+ v &+ Lanes(repeating: 1)) &>> Lanes(repeating: 1)
            for j in 0..<8 { d[i+j] = UInt8(truncatingIfNeeded: mean[j]) }
        } else {
            for j in 0..<8 { d[i+j] = UInt8(truncatingIfNeeded: v[j]) }
        }
    }

    private static func convolve(_ source: borrowing Span<UInt8>, _ srcOrigin: Int, _ srcStride: Int,
                                 _ dst: inout MutableSpan<UInt8>, _ dstOrigin: Int, _ dstStride: Int,
                                 width: Int, height: Int, kx: Int, ky: Int, fractionX: Int, fractionY: Int,
                                 average: Bool) {
        if fractionX != 0 && fractionY != 0 {
            // Rows -3 ... height+3 through the horizontal filter first, into a buffer sized
            // for the block (zeroing the largest for every small block costs more than it).
            if (height+7)*width <= 368 {
                var buffer = InlineArray<368, UInt8>(repeating: 0)
                var temp = buffer.mutableSpan
                twoPass(source, srcOrigin, srcStride, &temp, &dst, dstOrigin, dstStride,
                        width: width, height: height, kx: kx, ky: ky, average: average)
            } else {
                var buffer = InlineArray<4544, UInt8>(repeating: 0)
                var temp = buffer.mutableSpan
                twoPass(source, srcOrigin, srcStride, &temp, &dst, dstOrigin, dstStride,
                        width: width, height: height, kx: kx, ky: ky, average: average)
            }
            return
        }
        onePass(source, srcOrigin, srcStride, &dst, dstOrigin, dstStride, width: width, height: height,
                k: fractionX != 0 ? kx : fractionY != 0 ? ky : nil, step: fractionX != 0 ? 1 : srcStride, average: average)
    }

    /// A copy (k nil) or one 8-tap pass along step (1: horizontal, the stride: vertical).
    @inline(__always)
    private static func onePass(_ source: borrowing Span<UInt8>, _ srcOrigin: Int, _ srcStride: Int,
                                _ dst: inout MutableSpan<UInt8>, _ dstOrigin: Int, _ dstStride: Int,
                                width: Int, height: Int, k: Int?, step: Int, average: Bool) {
        guard let k else {
            for row in 0..<height {
                let s = srcOrigin + row*srcStride, d = dstOrigin + row*dstStride
                if width.isMultiple(of: 8) {
                    for col in Swift.stride(from: 0, to: width, by: 8) { put8(&dst, d+col, load8(source, s+col), average) }
                } else {
                    for col in 0..<width { put(&dst, d+col, Int(source[s+col]), average) }
                }
            }
            return
        }
        let lanes = kernel(k)
        let taps = flatFilters
        for row in 0..<height {
            let s = srcOrigin + row*srcStride - 3*step, d = dstOrigin + row*dstStride
            if width.isMultiple(of: 8) {
                for col in Swift.stride(from: 0, to: width, by: 8) { put8(&dst, d+col, taps8(source, s+col, step, lanes), average) }
            } else {
                for col in 0..<width {
                    var sum = 0
                    for t in 0..<8 { sum += taps[k+t]*Int(source[s+col+t*step]) }
                    put(&dst, d+col, min(255,max(0,(sum+64) >> 7)), average)
                }
            }
        }
    }

    @inline(__always)
    private static func twoPass(_ source: borrowing Span<UInt8>, _ srcOrigin: Int, _ srcStride: Int,
                                _ temp: inout MutableSpan<UInt8>,
                                _ dst: inout MutableSpan<UInt8>, _ dstOrigin: Int, _ dstStride: Int,
                                width: Int, height: Int, kx: Int, ky: Int, average: Bool) {
        onePass(source, srcOrigin - 3*srcStride, srcStride, &temp, 0, width, width: width, height: height+7,
                k: kx, step: 1, average: false)
        onePass(temp.span, 3*width, width, &dst, dstOrigin, dstStride, width: width, height: height,
                k: ky, step: width, average: average)
    }

    /// filters flattened: [(filter*16 + fraction)*8 + tap].
    private static let flatFilters: [Int] = filters.flatMap { $0.flatMap { $0 } }

    private static let filters: [[[Int]]] = [
        [
            [0, 0, 0, 128, 0, 0, 0, 0],
            [0, 1, -5, 126, 8, -3, 1, 0],
            [-1, 3, -10, 122, 18, -6, 2, 0],
            [-1, 4, -13, 118, 27, -9, 3, -1],
            [-1, 4, -16, 112, 37, -11, 4, -1],
            [-1, 5, -18, 105, 48, -14, 4, -1],
            [-1, 5, -19, 97, 58, -16, 5, -1],
            [-1, 6, -19, 88, 68, -18, 5, -1],
            [-1, 6, -19, 78, 78, -19, 6, -1],
            [-1, 5, -18, 68, 88, -19, 6, -1],
            [-1, 5, -16, 58, 97, -19, 5, -1],
            [-1, 4, -14, 48, 105, -18, 5, -1],
            [-1, 4, -11, 37, 112, -16, 4, -1],
            [-1, 3, -9, 27, 118, -13, 4, -1],
            [0, 2, -6, 18, 122, -10, 3, -1],
            [0, 1, -3, 8, 126, -5, 1, 0],
        ],
        [
            [0, 0, 0, 128, 0, 0, 0, 0],
            [-3, -1, 32, 64, 38, 1, -3, 0],
            [-2, -2, 29, 63, 41, 2, -3, 0],
            [-2, -2, 26, 63, 43, 4, -4, 0],
            [-2, -3, 24, 62, 46, 5, -4, 0],
            [-2, -3, 21, 60, 49, 7, -4, 0],
            [-1, -4, 18, 59, 51, 9, -4, 0],
            [-1, -4, 16, 57, 53, 12, -4, -1],
            [-1, -4, 14, 55, 55, 14, -4, -1],
            [-1, -4, 12, 53, 57, 16, -4, -1],
            [0, -4, 9, 51, 59, 18, -4, -1],
            [0, -4, 7, 49, 60, 21, -3, -2],
            [0, -4, 5, 46, 62, 24, -3, -2],
            [0, -4, 4, 43, 63, 26, -2, -2],
            [0, -3, 2, 41, 63, 29, -2, -2],
            [0, -3, 1, 38, 64, 32, -1, -3],
        ],
        [
            [0, 0, 0, 128, 0, 0, 0, 0],
            [-1, 3, -7, 127, 8, -3, 1, 0],
            [-2, 5, -13, 125, 17, -6, 3, -1],
            [-3, 7, -17, 121, 27, -10, 5, -2],
            [-4, 9, -20, 115, 37, -13, 6, -2],
            [-4, 10, -23, 108, 48, -16, 8, -3],
            [-4, 10, -24, 100, 59, -19, 9, -3],
            [-4, 11, -24, 90, 70, -21, 10, -4],
            [-4, 11, -23, 80, 80, -23, 11, -4],
            [-4, 10, -21, 70, 90, -24, 11, -4],
            [-3, 9, -19, 59, 100, -24, 10, -4],
            [-3, 8, -16, 48, 108, -23, 10, -4],
            [-2, 6, -13, 37, 115, -20, 9, -4],
            [-2, 5, -10, 27, 121, -17, 7, -3],
            [-1, 3, -6, 17, 125, -13, 5, -2],
            [0, 1, -3, 8, 127, -7, 3, -1],
        ],
        [
            [0, 0, 0, 128, 0, 0, 0, 0],
            [0, 0, 0, 120, 8, 0, 0, 0],
            [0, 0, 0, 112, 16, 0, 0, 0],
            [0, 0, 0, 104, 24, 0, 0, 0],
            [0, 0, 0, 96, 32, 0, 0, 0],
            [0, 0, 0, 88, 40, 0, 0, 0],
            [0, 0, 0, 80, 48, 0, 0, 0],
            [0, 0, 0, 72, 56, 0, 0, 0],
            [0, 0, 0, 64, 64, 0, 0, 0],
            [0, 0, 0, 56, 72, 0, 0, 0],
            [0, 0, 0, 48, 80, 0, 0, 0],
            [0, 0, 0, 40, 88, 0, 0, 0],
            [0, 0, 0, 32, 96, 0, 0, 0],
            [0, 0, 0, 24, 104, 0, 0, 0],
            [0, 0, 0, 16, 112, 0, 0, 0],
            [0, 0, 0, 8, 120, 0, 0, 0],
        ],
    ]
}
