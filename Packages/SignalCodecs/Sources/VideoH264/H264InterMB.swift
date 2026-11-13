// Inter macroblocks (H.264 7.3.5.1, 7.3.5.2): P_Skip, the P partitions and sub-macroblock
// partitions with their reference indices and vector differences (CAVLC), motion vector
// derivation in partition order, prediction (with explicit weights) and the inter residual.

import CodecCore

/// (width, height) of the partitions of P mb_type 0…3 and P sub_mb_type 0…3.
let pPartitions: [[(x: Int, y: Int, w: Int, h: Int)]] = [
    [(0, 0, 16, 16)], [(0, 0, 16, 8), (0, 8, 16, 8)], [(0, 0, 8, 16), (8, 0, 8, 16)],
]
let pSubPartitions: [[(x: Int, y: Int, w: Int, h: Int)]] = [
    [(0, 0, 8, 8)], [(0, 0, 8, 4), (0, 4, 8, 4)], [(0, 0, 4, 8), (4, 0, 4, 8)], [(0, 0, 4, 4), (4, 0, 4, 4), (0, 4, 4, 4), (4, 4, 4, 4)],
]

extension H264PictureDecoder {
    mutating func clearMotion(_ mb: Int) {
        for l in 0 ..< 2 {
            for b in 0 ..< 4 { st.motion.refIdx[(l) * st.motion.n4 + mb * 4 + b] = -1; st.motion.refID[(l) * st.motion.n4 + mb * 4 + b] = -1 }
            for b in 0 ..< 16 { st.motion.mvX[(l) * st.motion.n16 + mb * 16 + b] = 0; st.motion.mvY[(l) * st.motion.n16 + mb * 16 + b] = 0 }
        }
    }

    /// The explicit (P) weights for a partition, nil for default prediction.
    static func weights(_ h: H264SliceHeader, _ pps: H264PPS, refIdx: (Int, Int), refs: [[RefPicture?]]) -> PartitionWeights? {
        guard let ws = h.weights else { return nil }
        let w0 = refIdx.0 >= 0 && refIdx.0 < ws[0].count ? ws[0][refIdx.0] : nil
        let w1 = ws.count > 1 && refIdx.1 >= 0 && refIdx.1 < ws[1].count ? ws[1][refIdx.1] : nil
        func make(_ get: (H264Weight) -> (Int, Int), _ logWD: Int) -> PredWeights {
            let a = w0.map(get) ?? (1 << logWD, 0), b = w1.map(get) ?? (1 << logWD, 0)
            return PredWeights(logWD: logWD, w0: a.0, w1: b.0, o0: a.1, o1: b.1)
        }
        return (make({ ($0.lumaWeight, $0.lumaOffset) }, h.lumaLog2Denom),
                make({ ($0.chromaWeight.0, $0.chromaOffset.0) }, h.chromaLog2Denom),
                make({ ($0.chromaWeight.1, $0.chromaOffset.1) }, h.chromaLog2Denom))
    }

}
