// Decoded pictures and the per-picture macroblock state the decoder keeps for neighbour
// derivation (intra modes, CAVLC/CABAC contexts), deblocking, and later as a reference
// (motion for direct prediction). Everything is flat arrays indexed by macroblock, 4x4
// block (16 per MB, raster within the MB) or 8x8 block (4 per MB).

/// An 8-bit 4:2:0 picture, planes without padding (stride = width).
public struct YUVPicture: Sendable, Equatable {
    public var width: Int, height: Int
    public var y: [UInt8], u: [UInt8], v: [UInt8]

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        y = Array(repeating: 0, count: width * height)
        u = Array(repeating: 128, count: (width / 2) * (height / 2))
        v = Array(repeating: 128, count: (width / 2) * (height / 2))
    }

    public var chromaWidth: Int { width / 2 }
    public var chromaHeight: Int { height / 2 }

    /// The cropped picture (display window).
    public func cropped(left: Int, top: Int, width w: Int, height h: Int) -> YUVPicture {
        if left == 0 && top == 0 && w == width && h == height { return self }
        var out = YUVPicture(width: 0, height: 0)
        out.width = w
        out.height = h
        out.y.reserveCapacity(w * h)
        for row in 0 ..< h { out.y += y[(top + row) * width + left ..< (top + row) * width + left + w] }
        let cw = w / 2, ch = h / 2, l2 = left / 2, t2 = top / 2
        out.u.reserveCapacity(cw * ch)
        out.v.reserveCapacity(cw * ch)
        for row in 0 ..< ch {
            out.u += u[(t2 + row) * chromaWidth + l2 ..< (t2 + row) * chromaWidth + l2 + cw]
            out.v += v[(t2 + row) * chromaWidth + l2 ..< (t2 + row) * chromaWidth + l2 + cw]
        }
        return out
    }
}

/// Macroblock kinds (flags).
struct MBKind: OptionSet, Sendable {
    let rawValue: UInt16
    static let intra4x4 = MBKind(rawValue: 1)
    static let intra8x8 = MBKind(rawValue: 2)
    static let intra16x16 = MBKind(rawValue: 4)
    static let pcm = MBKind(rawValue: 8)
    static let inter = MBKind(rawValue: 16)
    static let skip = MBKind(rawValue: 32)
    static let direct16x16 = MBKind(rawValue: 64)
    static let transform8x8 = MBKind(rawValue: 128)
    static let p8x8 = MBKind(rawValue: 256)
    static let decoded = MBKind(rawValue: 512)

    var isIntra: Bool { !isDisjoint(with: [.intra4x4, .intra8x8, .intra16x16, .pcm]) }
}

/// The motion of a decoded picture, kept with it while it is a reference (for temporal and
/// spatial direct prediction of later B pictures and for nothing else).
struct PictureMotion: Sendable {
    /// Per-list arrays are flat: list l's entries start at l · n16 (per 4x4) or l · n4 (per 8x8).
    let n16: Int, n4: Int
    /// mv per (list, mb·16 + blk).
    var mvX: [Int16], mvY: [Int16]
    /// refIdx per (list, mb·4 + b8), −1 = not used.
    var refIdx: [Int8]
    /// The referenced picture's POC and long-term flag per (list, mb·4 + b8).
    var refPOC: [Int32]
    var refLongTerm: [Bool]
    /// The referenced picture's identity (decode index) per (list, mb·4 + b8), for deblocking.
    var refID: [Int32]
    var intra: [Bool]

    init(mbs: Int) {
        n16 = mbs * 16
        n4 = mbs * 4
        mvX = Array(repeating: 0, count: 2 * mbs * 16)
        mvY = mvX
        refIdx = Array(repeating: -1, count: 2 * mbs * 4)
        refPOC = Array(repeating: 0, count: 2 * mbs * 4)
        refLongTerm = Array(repeating: false, count: 2 * mbs * 4)
        refID = Array(repeating: -1, count: 2 * mbs * 4)
        intra = Array(repeating: false, count: mbs)
    }
}

/// A picture in the decoded picture buffer.
struct DecodedPicture: Sendable {
    var picture: YUVPicture
    var motion: PictureMotion
    var poc: Int
    var frameNum: Int
    var frameNumWrap = 0
    var longTermFrameIdx = -1
    var shortTerm = false
    var longTerm: Bool { longTermFrameIdx >= 0 }
    var isReference: Bool { shortTerm || longTerm }
    var neededForOutput = true
    /// Decode order, for stable output among equal POCs across IDRs.
    var decodeIndex: Int
    /// An IDR / MMCO-5 "epoch": output sorts by (epoch, POC).
    var epoch: Int
    var pts: Int64?
}

/// The state of the picture being decoded.
struct MBState: Sendable {
    let widthMbs: Int, heightMbs: Int
    var mbs: Int { widthMbs * heightMbs }
    var kind: [MBKind]
    var slice: [Int32]          // slice number per MB, −1 = not yet decoded
    var qp: [Int8]
    var qpc: [Int8]             // chroma QP per (Cb/Cr, MB): c · mbs + mb
    var cbp: [UInt8]
    /// TotalCoeff per 4x4 block: luma 16, then Cb 4, Cr 4 (24 per MB). For deblocking a block
    /// counts as coded if this is non-zero.
    var nnz: [UInt8]
    /// Intra 4x4 / 8x8 prediction modes per 4x4 block (8x8 modes repeated), −1 = n/a.
    var intraModes: [Int8]
    var chromaPredMode: [UInt8]
    // CABAC contexts.
    let n16: Int
    var mvdX: [UInt8], mvdY: [UInt8]       // |mvd| per (list, mb·16 + blk), clipped
    var codedDC: [UInt8]                     // coded_block_flag bits: 1 luma DC, 2 Cb DC, 4 Cr DC
    var directSub: [UInt8]                   // per 8x8: B_Direct_8x8 / direct 16x16 (CABAC ref_idx ctx)
    var motion: PictureMotion
    // What reconstruction needs, written by the parser.
    var i16Mode: [UInt8]
    /// Per MB (`levelStride` entries): luma levels (16 × 4x4 raster, or 4 × 8x8 raster),
    /// chroma AC (2 × 4 × 16), luma DC (16, raster of block positions), chroma DC (2 × 4);
    /// for I_PCM the 384 samples. Only the coded parts are meaningful.
    var levels: [Int32]
    static let levelStride = 408
    /// Inter partitions per MB: up to 16, packed x/4 | y/4 << 2 | wCode << 4 | hCode << 6.
    var parts: [UInt8]
    var partCount: [UInt8]

    init(widthMbs: Int, heightMbs: Int) {
        self.widthMbs = widthMbs
        self.heightMbs = heightMbs
        let n = widthMbs * heightMbs
        kind = Array(repeating: [], count: n)
        slice = Array(repeating: -1, count: n)
        qp = Array(repeating: 0, count: n)
        qpc = Array(repeating: 0, count: 2 * n)
        cbp = Array(repeating: 0, count: n)
        nnz = Array(repeating: 0, count: n * 24)
        intraModes = Array(repeating: -1, count: n * 16)
        chromaPredMode = Array(repeating: 0, count: n)
        n16 = n * 16
        mvdX = Array(repeating: 0, count: 2 * n * 16)
        mvdY = mvdX
        codedDC = Array(repeating: 0, count: n)
        directSub = Array(repeating: 0, count: n * 4)
        motion = PictureMotion(mbs: n)
        i16Mode = Array(repeating: 0, count: n)
        levels = Array(repeating: 0, count: n * MBState.levelStride)
        parts = Array(repeating: 0, count: n * 16)
        partCount = Array(repeating: 0, count: n)
    }
}

/// 4x4 block index (raster within the MB, 0…15) ↔ position.
@inline(__always) func blkX(_ b: Int) -> Int { (b & 3) * 4 }
@inline(__always) func blkY(_ b: Int) -> Int { (b >> 2) * 4 }
/// The spec's luma4x4BlkIdx (zigzag of 8x8 quadrants) → raster index.
let blkIdxToRaster: [Int] = [0, 1, 4, 5, 2, 3, 6, 7, 8, 9, 12, 13, 10, 11, 14, 15]
