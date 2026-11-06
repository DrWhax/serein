// A decoded picture and the per-block state decoding and in-loop filtering read: samples in
// three UInt16 planes (8 … 16 bits), and on a 4x4 grid the prediction mode, intra mode, QP,
// coding-tree depth, skip / PCM / bypass flags, transform and prediction edges, motion.

public struct HEVCPlane: Sendable {
    public let width: Int, height: Int
    public var samples: [UInt16]
    init(width: Int, height: Int, fill: UInt16) {
        self.width = width
        self.height = height
        samples = [UInt16](repeating: fill, count: width * height)
    }
    @inline(__always) subscript(x: Int, y: Int) -> UInt16 {
        get { samples[x + y * width] }
        set { samples[x + y * width] = newValue }
    }
}

/// SAO parameters of one CTB and component (7.4.9.3).
struct HEVCSAO: Sendable, Equatable {
    var type = 0          // 0 off, 1 band, 2 edge
    var offsets = [Int32](repeating: 0, count: 4)
    var bandPosition = 0
    var eoClass = 0
}

/// Motion of a prediction block (8.5.3.2): per list a reference index (−1 unused) and a vector.
public struct HEVCMotion: Sendable, Equatable {
    public var refIdx: (Int8, Int8) = (-1, -1)
    public var mv: (Int16, Int16, Int16, Int16) = (0, 0, 0, 0)    // mvL0 x, y, mvL1 x, y
    public static func == (a: HEVCMotion, b: HEVCMotion) -> Bool {
        a.refIdx == b.refIdx && a.mv == b.mv
    }
    var predFlags: (Bool, Bool) { (refIdx.0 >= 0, refIdx.1 >= 0) }
}

final class HEVCPicture {
    let sps: HEVCSPS
    /// Names the picture to the reconstruction stage, which holds its samples.
    let id: Int
    var poc = 0
    var pts: Int64 = 0
    /// The PPS of its slices (tiles and loop-filter-across-tiles for the in-loop filters).
    var pps: HEVCPPS?
    var isLongTerm = false
    var isReference = true
    var neededForOutput = true
    var latencyCount = 0
    var picOutput = true
    /// 4x4-grid state.
    let w4: Int, h4: Int
    var predMode: [UInt8]       // 0 inter, 1 intra, 2 skip(inter); 255 not yet decoded
    var intraMode: [UInt8]
    var qpY: [Int8]
    var ctDepth: [UInt8]
    var bypass: [Bool]          // cu_transquant_bypass or (pcm && pcm_loop_filter_disabled)
    var tuEdgeV: [UInt8], tuEdgeH: [UInt8]   // 1: transform edge at the block's left / top
    var puEdgeV: [UInt8], puEdgeH: [UInt8]   // 1: prediction edge
    var nonZeroCoeff: [Bool]    // the luma transform block containing it has coefficients
    var motion: [HEVCMotion]
    /// Per CTB (raster): slice address, slice deblocking/loop flags, SAO.
    var ctbSliceAddr: [Int]
    var ctbDeblockDisabled: [Bool], ctbFilterAcrossSlices: [Bool]
    var ctbBetaOffset: [Int8], ctbTcOffset: [Int8]
    var ctbCbQpOffset: [Int8], ctbCrQpOffset: [Int8]
    var sao: [[HEVCSAO]]        // [component][ctbAddrRs]
    var ctbDecoded: [Bool]
    /// Slice type per CTB (for TMVP's collocated picture needs) and the reference POCs per slice.
    var ctbSliceIndex: [Int16]
    var sliceRefPocs: [[[Int]]] = []          // [slice][list][refIdx] → POC
    var sliceRefLongTerm: [[[Bool]]] = []

    init(sps: HEVCSPS, id: Int) {
        self.sps = sps
        self.id = id
        w4 = (sps.width + 3) >> 2
        h4 = (sps.height + 3) >> 2
        let n = w4 * h4
        predMode = [UInt8](repeating: 255, count: n)
        intraMode = [UInt8](repeating: 1, count: n)
        qpY = [Int8](repeating: 0, count: n)
        ctDepth = [UInt8](repeating: 0, count: n)
        bypass = [Bool](repeating: false, count: n)
        tuEdgeV = [UInt8](repeating: 0, count: n)
        tuEdgeH = [UInt8](repeating: 0, count: n)
        puEdgeV = [UInt8](repeating: 0, count: n)
        puEdgeH = [UInt8](repeating: 0, count: n)
        nonZeroCoeff = [Bool](repeating: false, count: n)
        motion = [HEVCMotion](repeating: HEVCMotion(), count: n)
        let nCtb = sps.picSizeInCtbs
        ctbSliceAddr = [Int](repeating: -1, count: nCtb)
        ctbDeblockDisabled = [Bool](repeating: false, count: nCtb)
        ctbFilterAcrossSlices = [Bool](repeating: true, count: nCtb)
        ctbBetaOffset = [Int8](repeating: 0, count: nCtb)
        ctbTcOffset = [Int8](repeating: 0, count: nCtb)
        ctbCbQpOffset = [Int8](repeating: 0, count: nCtb)
        ctbCrQpOffset = [Int8](repeating: 0, count: nCtb)
        sao = [[HEVCSAO]](repeating: [HEVCSAO](repeating: HEVCSAO(), count: nCtb), count: 3)
        ctbDecoded = [Bool](repeating: false, count: nCtb)
        ctbSliceIndex = [Int16](repeating: -1, count: nCtb)
    }

    @inline(__always) func i4(_ x: Int, _ y: Int) -> Int { (x >> 2) + (y >> 2) * w4 }

    /// What reconstruction and the in-loop filters read, once the picture is parsed (the
    /// arrays are shared, not copied: parsing never changes them again).
    func state() -> HEVCPictureState {
        HEVCPictureState(sps: sps, w4: w4, h4: h4, planes: [], predMode: predMode, qpY: qpY, bypass: bypass, tuEdgeV: tuEdgeV, tuEdgeH: tuEdgeH,
                         puEdgeV: puEdgeV, puEdgeH: puEdgeH, nonZeroCoeff: nonZeroCoeff, motion: motion, ctbSliceAddr: ctbSliceAddr,
                         ctbDeblockDisabled: ctbDeblockDisabled, ctbFilterAcrossSlices: ctbFilterAcrossSlices, ctbBetaOffset: ctbBetaOffset,
                         ctbTcOffset: ctbTcOffset, sao: sao, ctbDecoded: ctbDecoded, ctbSliceIndex: ctbSliceIndex, sliceRefPocs: sliceRefPocs)
    }

    /// Fills a rectangle of the 4x4 grid (x, y, w, h in luma samples).
    @inline(__always) func fill<T>(_ a: inout [T], _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ v: T) {
        let x0 = x >> 2, y0 = y >> 2, x1 = min(w4, (x + w + 3) >> 2), y1 = min(h4, (y + h + 3) >> 2)
        for yy in y0..<y1 { for xx in x0..<x1 { a[xx + yy * w4] = v } }
    }
}

/// A parsed picture's samples with the metadata reconstruction and the in-loop filters read
/// (a value: it moves to the reconstruction thread).
struct HEVCPictureState: Sendable {
    let sps: HEVCSPS
    let w4: Int, h4: Int
    var planes: [HEVCPlane]
    let predMode: [UInt8]
    let qpY: [Int8]
    let bypass: [Bool]
    let tuEdgeV: [UInt8], tuEdgeH: [UInt8]
    let puEdgeV: [UInt8], puEdgeH: [UInt8]
    let nonZeroCoeff: [Bool]
    let motion: [HEVCMotion]
    let ctbSliceAddr: [Int]
    let ctbDeblockDisabled: [Bool], ctbFilterAcrossSlices: [Bool]
    let ctbBetaOffset: [Int8], ctbTcOffset: [Int8]
    let sao: [[HEVCSAO]]
    let ctbDecoded: [Bool]
    let ctbSliceIndex: [Int16]
    let sliceRefPocs: [[[Int]]]

    @inline(__always) func i4(_ x: Int, _ y: Int) -> Int { (x >> 2) + (y >> 2) * w4 }

    /// Takes a plane's samples out (unique, so writes need no copy-on-write checks); give them
    /// back with `restore`.
    @inline(__always) mutating func take(_ c: Int) -> [UInt16] {
        let s = planes[c].samples
        planes[c].samples = []
        return s
    }

    @inline(__always) mutating func restore(_ c: Int, _ s: [UInt16]) { planes[c].samples = s }

    /// Mid-grey planes: a picture before reconstruction, or a missing reference (8.3.3).
    static func greyPlanes(_ sps: HEVCSPS) -> [HEVCPlane] {
        var planes = [HEVCPlane(width: sps.width, height: sps.height, fill: UInt16(1 << (sps.bitDepthLuma - 1)))]
        if sps.chromaFormatIdc != 0 {
            let cw = sps.width / sps.subWidthC, ch = sps.height / sps.subHeightC
            planes.append(HEVCPlane(width: cw, height: ch, fill: UInt16(1 << (sps.bitDepthChroma - 1))))
            planes.append(HEVCPlane(width: cw, height: ch, fill: UInt16(1 << (sps.bitDepthChroma - 1))))
        }
        return planes
    }
}
