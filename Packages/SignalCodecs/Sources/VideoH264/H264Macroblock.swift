// The macroblock layer (H.264 7.3.5) and intra reconstruction (8.3, 8.5) for one picture:
// mb_type, mb_pred / sub_mb_pred, coded_block_pattern, mb_qp_delta, residual() and the
// sample reconstruction of each macroblock as it is parsed.

import CodecCore

/// Golomb code → coded_block_pattern (Table 9-4), intra (Intra_4x4/8x8) and inter.
let golombToIntraCBP: [UInt8] = [47, 31, 15, 0, 23, 27, 29, 30, 7, 11, 13, 14, 39, 43, 45, 46, 16, 3, 5, 10, 12, 19, 21, 26, 28, 35, 37, 42, 44, 1, 2, 4, 8, 17, 18, 20, 24, 6, 9, 22, 25, 32, 33, 34, 36, 40, 38, 41]
let golombToInterCBP: [UInt8] = [0, 16, 1, 2, 4, 8, 32, 3, 5, 10, 12, 15, 47, 7, 11, 13, 14, 6, 9, 31, 35, 37, 42, 44, 33, 34, 36, 40, 39, 43, 45, 46, 17, 18, 20, 24, 19, 21, 26, 28, 23, 27, 29, 30, 22, 25, 38, 41]

/// QPc from qPi (Table 8-15).
let chromaQPTable: [Int] = (0 ... 51).map { q in q < 30 ? q : [29, 30, 31, 32, 32, 33, 34, 34, 35, 35, 36, 36, 37, 37, 37, 38, 38, 38, 39, 39, 39, 39][q - 30] }

/// Per-slice parameters kept for deblocking.
struct SliceDeblock: Sendable {
    var disable: Int
    var alpha: Int, beta: Int
}

/// What reconstruction and deblocking need of a slice. A class: every macroblock of the slice
/// refers to it, from every reconstruction thread, and copying the struct (its arrays) per
/// macroblock cost more than reconstructing.
final class SliceInfo: Sendable {
    let header: H264SliceHeader
    let pps: H264PPS
    let refs: SliceRefs
    let dequant: H264Dequant
    let deblock: SliceDeblock
    /// Which entries of each reference list hold a picture.
    let present: [[Bool]]
    /// The list-1 length, and the prediction weights per pair of reference indices in use
    /// (−1: that list unused): `weights[(refIdx0 + 1) · (count1 + 1) + refIdx1 + 1]`, computed
    /// once here rather than per partition.
    let count1: Int
    let weights: [PartitionWeights?]

    init(header: H264SliceHeader, pps: H264PPS, refs: SliceRefs, dequant: H264Dequant, deblock: SliceDeblock) {
        self.header = header
        self.pps = pps
        self.refs = refs
        self.dequant = dequant
        self.deblock = deblock
        present = refs.lists.map { $0.map { $0 != nil } }
        let n0 = refs.lists.first?.count ?? 0, n1 = refs.lists.count > 1 ? refs.lists[1].count : 0
        count1 = n1
        var table = [PartitionWeights?](repeating: nil, count: (n0 + 1) * (n1 + 1))
        for a in -1 ..< n0 {
            for b in -1 ..< n1 {
                table[(a + 1) * (n1 + 1) + b + 1] = header.type == .b
                    ? H264PictureDecoder.bWeights(header, pps, refIdx: (a, b), refs: refs.lists, currentPOC: refs.currentPOC)
                    : H264PictureDecoder.weights(header, pps, refIdx: (a, -1), refs: refs.lists)
            }
        }
        weights = table
    }

    /// Another object with the same contents (the arrays are shared): one per reconstruction
    /// thread, so the retains each macroblock does are not on a count every thread writes.
    init(copying o: SliceInfo) {
        header = o.header; pps = o.pps; refs = o.refs; dequant = o.dequant; deblock = o.deblock
        present = o.present; count1 = o.count1; weights = o.weights
    }
}

/// Luma, Cb and Cr weights of one partition's prediction.
typealias PartitionWeights = (luma: PredWeights, cb: PredWeights, cr: PredWeights)

struct H264PictureDecoder: Sendable {
    let sps: H264SPS
    var st: MBState
    var slices: [SliceInfo] = []
    var dequantCache: [Int: H264Dequant] = [:]
    /// The slice being parsed's co-located picture (B slices).
    var colocated: ColocatedPicture?
    // Per-macroblock scratch.
    var coeff = [Int32](repeating: 0, count: 16 * 16 + 2 * 16 * 4)  // luma 4x4 blocks (raster blk·16), then Cb, Cr
    var coeff8 = [Int32](repeating: 0, count: 4 * 64)
    var chromaDCLevels = [Int32](repeating: 0, count: 8)
    var lumaDCLevels = [Int32](repeating: 0, count: 16)

    init(sps: H264SPS) {
        self.sps = sps
        st = MBState(widthMbs: sps.widthMbs, heightMbs: sps.heightMbs)
    }

    // MARK: neighbours

    /// The neighbour MB (A left, B above, C above-right, D above-left) if available to `mb` in
    /// slice `slice`.
    @inline(__always) func neighbour(_ mb: Int, _ which: Int, slice: Int32) -> Int? {
        let w = st.widthMbs, x = mb % w, y = mb / w
        let n: Int
        switch which {
        case 0: guard x > 0 else { return nil }; n = mb - 1
        case 1: guard y > 0 else { return nil }; n = mb - w
        case 2: guard y > 0, x + 1 < w else { return nil }; n = mb - w + 1
        default: guard y > 0, x > 0 else { return nil }; n = mb - w - 1
        }
        return st.slice[n] == slice ? n : nil
    }

    /// Neighbouring 4x4 luma block of (mb, blk raster) in direction A (left) or B (above):
    /// (mb, blk) or nil.
    @inline(__always) func neighbourBlock(_ mb: Int, _ blk: Int, left: Bool, slice: Int32) -> (Int, Int)? {
        if left {
            if blk & 3 != 0 { return (mb, blk - 1) }
            guard let a = neighbour(mb, 0, slice: slice) else { return nil }
            return (a, blk + 3)
        }
        if blk >= 4 { return (mb, blk - 4) }
        guard let b = neighbour(mb, 1, slice: slice) else { return nil }
        return (b, blk + 12)
    }

    /// nC for a luma 4x4 block (9.2.1): from TotalCoeff of the left and upper blocks.
    func lumaNC(_ mb: Int, _ blk: Int, slice: Int32) -> Int {
        let a = neighbourBlock(mb, blk, left: true, slice: slice).map { Int(nnzCAVLC($0.0, $0.1)) }
        let b = neighbourBlock(mb, blk, left: false, slice: slice).map { Int(nnzCAVLC($0.0, $0.1)) }
        switch (a, b) {
        case let (x?, y?): return (x + y + 1) >> 1
        case let (x?, nil): return x
        case let (nil, y?): return y
        default: return 0
        }
    }

    @inline(__always) func nnzCAVLC(_ mb: Int, _ i: Int) -> UInt8 {
        if st.kind[mb].contains(.pcm) { return 16 }
        if st.kind[mb].contains(.skip) { return 0 }
        return st.nnz[mb * 24 + i]
    }

    /// nC for a chroma AC block (blk 0…3 raster in the 2x2 of 4x4 blocks).
    func chromaNC(_ mb: Int, _ c: Int, _ blk: Int, slice: Int32) -> Int {
        func at(_ m: Int, _ b: Int) -> Int { Int(st.kind[m].contains(.pcm) ? 16 : st.kind[m].contains(.skip) ? 0 : st.nnz[m * 24 + 16 + c * 4 + b]) }
        var a: Int?, b: Int?
        if blk & 1 == 1 { a = at(mb, blk - 1) } else if let m = neighbour(mb, 0, slice: slice) { a = at(m, blk + 1) }
        if blk >= 2 { b = at(mb, blk - 2) } else if let m = neighbour(mb, 1, slice: slice) { b = at(m, blk + 2) }
        switch (a, b) {
        case let (x?, y?): return (x + y + 1) >> 1
        case let (x?, nil): return x
        case let (nil, y?): return y
        default: return 0
        }
    }

    func dequant(_ pps: H264PPS) -> H264Dequant {
        H264Dequant(lists4: pps.scaling4 ?? sps.scaling4, lists8: pps.scaling8 ?? sps.scaling8)
    }

    // MARK: intra reconstruction

    /// Whether neighbour MB `n` may serve intra prediction (constrained_intra_pred).
    @inline(__always) func intraUsable(_ n: Int?, constrained: Bool) -> Bool {
        guard let n else { return false }
        return !constrained || st.kind[n].isIntra
    }

    /// Availability of the four edges of a luma block of size `n` at (bx, by) in `mb`.
    func lumaEdges(_ mb: Int, bx: Int, by: Int, size n: Int, slice: Int32, constrained: Bool) -> (top: Bool, left: Bool, topLeft: Bool, topRight: Bool) {
        let a = intraUsable(neighbour(mb, 0, slice: slice), constrained: constrained)
        let b = intraUsable(neighbour(mb, 1, slice: slice), constrained: constrained)
        let c = intraUsable(neighbour(mb, 2, slice: slice), constrained: constrained)
        let d = intraUsable(neighbour(mb, 3, slice: slice), constrained: constrained)
        let left = bx > 0 || a
        let top = by > 0 || b
        let topLeft = (bx > 0 && by > 0) || (bx == 0 && by > 0 && a) || (bx > 0 && by == 0 && b) || (bx == 0 && by == 0 && d)
        var topRight: Bool
        if by == 0 {
            topRight = bx + n < 16 ? b : c
        } else if bx + n < 16 {
            // Inside the MB: available if that block is decoded already (zigzag of 8x8s).
            if n == 8 {
                topRight = false   // the upper-right 8x8 of the lower-left one is decoded only for b8 = 2
                if bx == 0 && by == 8 { topRight = true }
            } else {
                let rasterTR = ((by - 4) / 4) * 4 + (bx + 4) / 4
                let cur = blkIdxToRaster.firstIndex(of: (by / 4) * 4 + bx / 4)!
                topRight = blkIdxToRaster.firstIndex(of: rasterTR)! < cur
            }
        } else {
            topRight = false
        }
        return (top, left, topLeft, topRight)
    }

}
