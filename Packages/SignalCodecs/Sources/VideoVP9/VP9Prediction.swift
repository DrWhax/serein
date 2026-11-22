// Prediction and interpolation from VP9 Bitstream Specification §8.5 and §8.6.
// The interpolation tables are from libvpx vp9/common/vp9_filter.c (WebM BSD license).
struct VP9Plane: Sendable {
    let width: Int
    let height: Int
    let stride: Int
    private let codedWidth: Int
    private let codedHeight: Int
    var bytes: [UInt8]

    init(width: Int, height: Int, chroma: Bool = false) {
        self.width = width
        self.height = height
        let miSize = chroma ? 4 : 8
        codedWidth = (width+miSize-1)/miSize*miSize
        codedHeight = (height+miSize-1)/miSize*miSize
        stride = (width+63) / 64 * 64
        bytes = [UInt8](repeating: 0, count: stride * ((height+63)/64*64))
    }

    /// The decoder reconstructs complete transform blocks at the coded frame edge.
    /// For intra prediction the border is the final coded MI, including the decoded
    /// samples outside a partially visible MI. Inter prediction extends visible pixels.
    mutating func predictIntra(mode: Int, x: Int, y: Int, size: Int, tileLeft: Int, tileTop: Int, haveRight: Bool) {
        let hasTop = y > tileTop, hasLeft = x > tileLeft
        var top = [Int](repeating: 127, count: size*2+2)
        var left = [Int](repeating: 129, count: size+2)
        func neighbour(_ x: Int, _ y: Int) -> Int {
            Int(bytes[min(codedHeight-1,y)*stride+min(codedWidth-1,x)])
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
                bytes[(y+row)*stride+x+col] = UInt8(clamping: result)
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
                let i = (y+row)*stride+x+col
                bytes[i] = average ? UInt8((Int(bytes[i])+Int(prediction)+1)>>1) : prediction
            }
        }
    }

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
