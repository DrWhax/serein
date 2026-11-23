// Motion compensation at eighth-pixel resolution (RFC 6386 §18).
enum VP8Prediction {
    private static let sixTap = [
        [0,0,128,0,0,0], [0,-6,123,12,-1,0], [2,-11,108,36,-8,1], [0,-9,93,50,-6,0],
        [3,-16,77,77,-16,3], [0,-6,50,93,-9,0], [1,-8,36,108,-11,2], [0,-1,12,123,-6,0],
    ]
    private static let bilinear = (0..<8).map { [0,0,128 - 16*$0,16*$0,0,0] }

    static func inter(_ motion: VP8Motion, x: Int, y: Int, reference: VP8Frame, version: Int, workspace: inout [UInt8]) {
        let filters = version == 0 ? sixTap : bilinear
        let size = motion.split.isEmpty ? 16 : 4
        for dy in stride(from: 0, to: 16, by: size) {
            for dx in stride(from: 0, to: 16, by: size) {
                predict(reference.y, stride: reference.yStride, rows: reference.mbH * 16, x: x*16+dx, y: y*16+dy,
                        vector: motion.at(dy+dx/4), size: size, filters: filters,
                        output: &workspace, base: VP8Decoder.yOff + dy * VP8Decoder.BPS + dx)
            }
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

    private static func predict(_ plane: [UInt8], stride: Int, rows: Int, x: Int, y: Int,
                                vector: VP8Vector, size: Int, filters: [[Int]], output: inout [UInt8], base: Int) {
        let left = x + (vector.x >> 3), top = y + (vector.y >> 3)
        let fx = vector.x & 7, fy = vector.y & 7
        if fx == 0 && fy == 0 {
            for r in 0..<size {
                let src = min(rows-1,max(0,top+r))*stride
                for c in 0..<size { output[base + r*VP8Decoder.BPS+c] = plane[src + min(stride-1,max(0,left+c))] }
            }
            return
        }
        let horizontal = filters[fx], vertical = filters[fy]
        let halo = fy == 0 ? 0 : 2, count = fy == 0 ? size : size + 5
        var temp = [UInt8](repeating: 0, count: size*count)
        for r in 0..<count {
            let src = min(rows-1,max(0,top+r-halo))*stride
            for c in 0..<size {
                if fx == 0 { temp[r*size+c] = plane[src + min(stride-1,max(0,left+c))]; continue }
                var sum = 64
                for k in 0..<6 { sum += horizontal[k] * Int(plane[src + min(stride-1,max(0,left+c+k-2))]) }
                temp[r*size+c] = UInt8(clamping: sum >> 7)
            }
        }
        for r in 0..<size {
            for c in 0..<size {
                if fy == 0 { output[base + r*VP8Decoder.BPS+c] = temp[r*size+c]; continue }
                var sum = 64
                for k in 0..<6 { sum += vertical[k] * Int(temp[(r+k)*size+c]) }
                output[base + r*VP8Decoder.BPS+c] = UInt8(clamping: sum >> 7)
            }
        }
    }
}
