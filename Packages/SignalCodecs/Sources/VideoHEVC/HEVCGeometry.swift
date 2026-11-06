// Picture geometry (H.265 6.5): CTB raster ↔ tile scan (6.5.1), tile ids, the z-scan order
// of minimum transform blocks (6.5.2) behind neighbour availability (6.4.1), and the
// up-right diagonal / horizontal / vertical scan orders (6.5.3 – 6.5.5).

/// Per-PPS layout of a picture's CTBs and minimum transform blocks.
struct HEVCGeometry: Sendable {
    let widthCtbs: Int, heightCtbs: Int
    let log2Ctb: Int, log2MinTb: Int
    /// CtbAddrRsToTs / CtbAddrTsToRs / TileId (by tile-scan address).
    let rsToTs: [Int]
    let tsToRs: [Int]
    let tileId: [Int]
    /// First CTB column / row of each tile column / row.
    let colBd: [Int], rowBd: [Int]
    /// MinTbAddrZs[x][y] as a flat array (x + y * widthMinTbs).
    let minTbAddrZs: [Int32]
    let widthMinTbs: Int, heightMinTbs: Int

    init(sps: HEVCSPS, pps: HEVCPPS) {
        widthCtbs = sps.widthCtbs
        heightCtbs = sps.heightCtbs
        log2Ctb = sps.log2CtbSize
        log2MinTb = sps.log2MinTbSize
        var colBd = [0], rowBd = [0]
        for w in pps.tileColumnWidths { colBd.append(colBd.last! + w) }
        for h in pps.tileRowHeights { rowBd.append(rowBd.last! + h) }
        self.colBd = colBd
        self.rowBd = rowBd
        let n = widthCtbs * heightCtbs
        var rsToTs = [Int](repeating: 0, count: n)
        for rs in 0..<n {
            let tbX = rs % widthCtbs, tbY = rs / widthCtbs
            var tileX = 0, tileY = 0
            for i in 0..<pps.tileColumnWidths.count where tbX >= colBd[i] { tileX = i }
            for j in 0..<pps.tileRowHeights.count where tbY >= rowBd[j] { tileY = j }
            var v = 0
            for i in 0..<tileX { v += pps.tileRowHeights[tileY] * pps.tileColumnWidths[i] }
            for j in 0..<tileY { v += widthCtbs * pps.tileRowHeights[j] }
            v += (tbY - rowBd[tileY]) * pps.tileColumnWidths[tileX] + tbX - colBd[tileX]
            rsToTs[rs] = v
        }
        var tsToRs = [Int](repeating: 0, count: n)
        for rs in 0..<n { tsToRs[rsToTs[rs]] = rs }
        var tileId = [Int](repeating: 0, count: n)
        var t = 0
        for j in 0..<pps.tileRowHeights.count {
            for i in 0..<pps.tileColumnWidths.count {
                for y in rowBd[j]..<rowBd[j + 1] { for x in colBd[i]..<colBd[i + 1] { tileId[rsToTs[y * widthCtbs + x]] = t } }
                t += 1
            }
        }
        self.rsToTs = rsToTs
        self.tsToRs = tsToRs
        self.tileId = tileId
        let shift = log2Ctb - log2MinTb
        widthMinTbs = widthCtbs << shift
        heightMinTbs = heightCtbs << shift
        var zs = [Int32](repeating: 0, count: widthMinTbs * heightMinTbs)
        for y in 0..<heightMinTbs {
            for x in 0..<widthMinTbs {
                let ctbRs = (x >> shift) + (y >> shift) * widthCtbs
                var v = rsToTs[ctbRs] << (shift * 2)
                for i in 0..<shift {
                    let m = 1 << i
                    v += ((m & x) != 0 ? m * m : 0) + ((m & y) != 0 ? 2 * m * m : 0)
                }
                zs[x + y * widthMinTbs] = Int32(v)
            }
        }
        minTbAddrZs = zs
    }

    @inline(__always) func zOrder(_ x: Int, _ y: Int) -> Int32 { minTbAddrZs[(x >> log2MinTb) + (y >> log2MinTb) * widthMinTbs] }
    @inline(__always) func ctbAddrRs(_ x: Int, _ y: Int) -> Int { (x >> log2Ctb) + (y >> log2Ctb) * widthCtbs }
}

/// ScanOrder[log2BlockSize][scanIdx][sPos] (6.5.3 – 6.5.5) for block sizes 1, 2, 4, 8.
enum HEVCScan {
    /// The same orders flattened: x and y of entry (log2·3 + scanIdx)·64 + sPos.
    static let flatX: [UInt8] = flat { $0.x }
    static let flatY: [UInt8] = flat { $0.y }
    static func flat(_ f: ((x: UInt8, y: UInt8)) -> UInt8) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 4 * 3 * 64)
        for l in 0..<4 { for k in 0..<3 { for (i, p) in order[l][k].enumerated() { out[(l * 3 + k) * 64 + i] = f(p) } } }
        return out
    }

    /// [log2Size 0…3][scanIdx 0 diag, 1 horizontal, 2 vertical] → positions (x, y).
    static let order: [[[(x: UInt8, y: UInt8)]]] = (0...3).map { log2 in
        let n = 1 << log2
        var diag: [(x: UInt8, y: UInt8)] = []
        var x = 0, y = 0
        while diag.count < n * n {
            while y >= 0 {
                if x < n && y < n { diag.append((UInt8(x), UInt8(y))) }
                y -= 1
                x += 1
            }
            y = x
            x = 0
        }
        var hor: [(x: UInt8, y: UInt8)] = [], ver: [(x: UInt8, y: UInt8)] = []
        for j in 0..<n { for i in 0..<n { hor.append((UInt8(i), UInt8(j))) } }
        for i in 0..<n { for j in 0..<n { ver.append((UInt8(i), UInt8(j))) } }
        return [diag, hor, ver]
    }
}
