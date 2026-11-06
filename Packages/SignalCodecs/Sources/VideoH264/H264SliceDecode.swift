// Slice data (H.264 7.3.4) and macroblock parsing + reconstruction, CAVLC entropy coding.
// Intra macroblocks are reconstructed block by block as they are parsed (each 4x4 / 8x8
// prediction depends on the previous block's reconstruction).

import CodecCore

/// What residual() delivers for one macroblock.
struct MBResidual {
    var cbp = 0
    var transform8x8 = false
    var qp = 0
}

extension H264PictureDecoder {
    /// predIntra4x4PredMode / predIntra8x8PredMode (8.3.1.1, 8.3.2.1) for the 4x4 block at
    /// raster `blk` (for 8x8 blocks, its top-left 4x4).
    func predictedIntraMode(_ mb: Int, _ blk: Int, slice: Int32, constrained: Bool) -> Int {
        func mode(_ n: (Int, Int)?) -> Int? {
            guard let (m, b) = n else { return nil }
            let k = st.kind[m]
            if constrained && !k.isIntra { return nil }
            if !k.contains(.intra4x4) && !k.contains(.intra8x8) { return 2 }
            if m == mb { return Int(st.intraModes[m * 16 + b]) }
            return Int(st.intraModes[m * 16 + b])
        }
        let a = mode(neighbourBlock(mb, blk, left: true, slice: slice))
        let b = mode(neighbourBlock(mb, blk, left: false, slice: slice))
        guard let a, let b else { return 2 }
        return min(a, b)
    }
}
