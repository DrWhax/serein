// A decoded picture and the per-block state decoding and in-loop filtering read: samples in
// three UInt16 planes (8 … 16 bits), and on a 4x4 grid the prediction mode, intra mode, QP,
// coding-tree depth, skip / PCM / bypass flags, transform and prediction edges, motion.

/// One plane's samples in bands of a CTB row each (the last one shorter): a band is what one
/// worker reconstructs or filters, so no step copies a picture whole, and a reader takes a row
/// from its band (`bands.span[y >> log2Rows]` borrows it, without retaining).
public struct HEVCPlane: Sendable {
    public let width: Int, height: Int
    /// Rows per band, 1 << log2Rows.
    let log2Rows: Int
    var bands: [[UInt16]]

    init(width: Int, height: Int, log2Rows: Int, fill: UInt16) {
        self.width = width
        self.height = height
        self.log2Rows = log2Rows
        let n = (height + (1 << log2Rows) - 1) >> log2Rows
        bands = (0..<n).map { k in [UInt16](repeating: fill, count: width * (min(height, (k + 1) << log2Rows) - (k << log2Rows))) }
    }

    init(width: Int, height: Int, log2Rows: Int, bands: [[UInt16]]) {
        self.width = width
        self.height = height
        self.log2Rows = log2Rows
        self.bands = bands
    }

    /// The rows of band `k`.
    @inline(__always) func rows(_ k: Int) -> Range<Int> { (k << log2Rows) ..< min(height, (k + 1) << log2Rows) }

    @inline(__always) subscript(x: Int, y: Int) -> UInt16 {
        get { bands[y >> log2Rows][x + (y & ((1 << log2Rows) - 1)) * width] }
        set { bands[y >> log2Rows][x + (y & ((1 << log2Rows) - 1)) * width] = newValue }
    }
}

/// SAO parameters of one CTB and component (7.4.9.3). Plain values (the offsets inline): the
/// per-CTB tables copy them without reference counting.
struct HEVCSAO: Sendable, Equatable {
    var type = 0          // 0 off, 1 band, 2 edge
    var offsets = InlineArray<4, Int32>(repeating: 0)
    var bandPosition = 0
    var eoClass = 0

    static func == (a: HEVCSAO, b: HEVCSAO) -> Bool {
        a.type == b.type && a.bandPosition == b.bandPosition && a.eoClass == b.eoClass
            && a.offsets[0] == b.offsets[0] && a.offsets[1] == b.offsets[1] && a.offsets[2] == b.offsets[2] && a.offsets[3] == b.offsets[3]
    }
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
    var sps: HEVCSPS
    /// Names the picture to the reconstruction stage, which holds its samples.
    var id: Int
    var poc = 0
    var pts: Int64 = 0
    /// The PPS of its slices (tiles and loop-filter-across-tiles for the in-loop filters).
    var pps: HEVCPPS?
    var isLongTerm = false
    var isReference = true
    var neededForOutput = true
    var latencyCount = 0
    var picOutput = true
    /// 4x4-grid state, of the grid rows `y4Origin ..< y4Origin + rows4`: all of them, except in
    /// a wavefront row's band (HEVCDecoder.decodeRowsInParallel), which holds its CTB row and
    /// the grid row above it.
    let w4: Int, h4: Int
    let y4Origin: Int, rows4: Int
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

    /// `band`: the grid rows to hold (all of them by default).
    init(sps: HEVCSPS, id: Int, band: Range<Int>? = nil) {
        self.sps = sps
        self.id = id
        w4 = (sps.width + 3) >> 2
        h4 = (sps.height + 3) >> 2
        let rows = band ?? 0..<h4
        y4Origin = rows.lowerBound
        rows4 = rows.count
        let n = w4 * rows4
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

    @inline(__always) func i4(_ x: Int, _ y: Int) -> Int { (x >> 2) + ((y >> 2) - y4Origin) * w4 }

    /// Whether a fresh picture's grid serves a picture of `s` (its sizes are all it depends on).
    func fits(_ s: HEVCSPS) -> Bool {
        y4Origin == 0 && rows4 == h4 && sps.width == s.width && sps.height == s.height && sps.log2CtbSize == s.log2CtbSize
    }

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
        let x0 = x >> 2, y0 = max(y4Origin, y >> 2), x1 = min(w4, (x + w + 3) >> 2), y1 = min(y4Origin + rows4, (y + h + 3) >> 2)
        for yy in y0..<y1 { for xx in x0..<x1 { a[xx + (yy - y4Origin) * w4] = v } }
    }
}

/// What TMVP reads of the collocated picture (8.5.3.2.8, 8.5.3.2.9): a finished picture's
/// motion field and its slices' reference POCs, as values.
struct HEVCColocated: Sendable {
    let poc: Int
    let w4: Int
    let log2CtbSize: Int, widthCtbs: Int
    let predMode: [UInt8]
    let motion: [HEVCMotion]
    let ctbSliceIndex: [Int16]
    let sliceRefPocs: [[[Int]]]
    let sliceRefLongTerm: [[[Bool]]]

    init(_ p: HEVCPicture) {
        poc = p.poc
        w4 = p.w4
        log2CtbSize = p.sps.log2CtbSize
        widthCtbs = p.sps.widthCtbs
        predMode = p.predMode
        motion = p.motion
        ctbSliceIndex = p.ctbSliceIndex
        sliceRefPocs = p.sliceRefPocs
        sliceRefLongTerm = p.sliceRefLongTerm
    }

    @inline(__always) func i4(_ x: Int, _ y: Int) -> Int { (x >> 2) + (y >> 2) * w4 }
}

/// The contexts a wavefront row stores after its second CTB (9.3.2.4), for the row below.
struct HEVCWppState: Sendable {
    var state: InlineArray<157, UInt8>
    var stat: [Int]
}

/// What the row below may read of a decoded CTB (HEVCDecoder.decodeRowsInParallel): its last
/// grid row (the neighbours above of the row below: availability, contexts, merge and AMVP
/// candidates, MPM), whether it is decoded and in which slice, and its SAO (merge-up). Parsing
/// reads nothing else outside its CTB row; the transform and prediction edges, bypass and
/// coefficient flags only matter to deblocking.
struct HEVCCtbEdge: Sendable {
    var rs: Int
    /// The grid row and its columns.
    var y4: Int, x4: Range<Int>
    var predMode = InlineArray<16, UInt8>(repeating: 255)
    var intraMode = InlineArray<16, UInt8>(repeating: 1)
    var ctDepth = InlineArray<16, UInt8>(repeating: 0)
    var qpY = InlineArray<16, Int8>(repeating: 0)
    var motion = InlineArray<16, HEVCMotion>(repeating: HEVCMotion())
    var decoded: Bool
    var sliceAddr: Int
    var sao: InlineArray<3, HEVCSAO>
    /// Set on the CTB after which the row stored its contexts.
    var wpp: HEVCWppState?
}

extension HEVCPicture {
    /// CTB `rs`'s edge for the row below (its last grid row in the picture).
    func edge(_ rs: Int, wpp: HEVCWppState? = nil) -> HEVCCtbEdge {
        let ctb = sps.ctbSize, wc = sps.widthCtbs
        let x0 = (rs % wc) * ctb, y0 = (rs / wc) * ctb
        let y4 = min(h4, (y0 + ctb) >> 2) - 1
        let x4 = (x0 >> 2) ..< min(w4, (x0 + ctb) >> 2)
        var e = HEVCCtbEdge(rs: rs, y4: y4, x4: x4, decoded: ctbDecoded[rs], sliceAddr: ctbSliceAddr[rs],
                            sao: InlineArray<3, HEVCSAO>(repeating: HEVCSAO()), wpp: wpp)
        for c in 0..<sao.count { e.sao[c] = sao[c][rs] }
        let row = (y4 - y4Origin) * w4
        for (k, x) in x4.enumerated() {
            e.predMode[k] = predMode[row + x]
            e.intraMode[k] = intraMode[row + x]
            e.ctDepth[k] = ctDepth[row + x]
            e.qpY[k] = qpY[row + x]
            e.motion[k] = motion[row + x]
        }
        return e
    }

    /// Takes in the edge of a CTB above (a band's first grid row is the row above's last).
    func putAbove(_ e: HEVCCtbEdge) {
        ctbDecoded[e.rs] = e.decoded
        ctbSliceAddr[e.rs] = e.sliceAddr
        for c in 0..<sao.count { sao[c][e.rs] = e.sao[c] }
        let row = (e.y4 - y4Origin) * w4
        for (k, x) in e.x4.enumerated() {
            predMode[row + x] = e.predMode[k]
            intraMode[row + x] = e.intraMode[k]
            ctDepth[row + x] = e.ctDepth[k]
            qpY[row + x] = e.qpY[k]
            motion[row + x] = e.motion[k]
        }
    }
}

/// One wavefront row's parse (HEVCDecoder.decodeRowsInParallel): its band's state, the CTBs
/// it decoded (a prefix of the row), its recorded reconstruction and its contexts at the end.
struct HEVCRowParse: Sendable {
    let row: Int, decodedCtbs: Int
    let y4Origin: Int
    var predMode: [UInt8], intraMode: [UInt8], qpY: [Int8], ctDepth: [UInt8], bypass: [Bool]
    var tuEdgeV: [UInt8], tuEdgeH: [UInt8], puEdgeV: [UInt8], puEdgeH: [UInt8], nonZeroCoeff: [Bool], motion: [HEVCMotion]
    var ctbSliceAddr: [Int], ctbSliceIndex: [Int16], ctbDeblockDisabled: [Bool], ctbFilterAcrossSlices: [Bool]
    var ctbBetaOffset: [Int8], ctbTcOffset: [Int8], ctbCbQpOffset: [Int8], ctbCrQpOffset: [Int8]
    var sao: [[HEVCSAO]]
    var work: HEVCSliceWork
    var endState: InlineArray<157, UInt8>
    var endStat: [Int]
    var wppState: InlineArray<157, UInt8>?

    init(_ p: HEVCPicture, row: Int, work: HEVCSliceWork, endState: InlineArray<157, UInt8>, endStat: [Int], wppState: InlineArray<157, UInt8>?) {
        self.row = row
        let wc = p.sps.widthCtbs
        var n = 0
        while n < wc && p.ctbDecoded[row * wc + n] { n += 1 }
        decodedCtbs = n
        y4Origin = p.y4Origin
        predMode = p.predMode; intraMode = p.intraMode; qpY = p.qpY; ctDepth = p.ctDepth; bypass = p.bypass
        tuEdgeV = p.tuEdgeV; tuEdgeH = p.tuEdgeH; puEdgeV = p.puEdgeV; puEdgeH = p.puEdgeH; nonZeroCoeff = p.nonZeroCoeff; motion = p.motion
        ctbSliceAddr = p.ctbSliceAddr; ctbSliceIndex = p.ctbSliceIndex; ctbDeblockDisabled = p.ctbDeblockDisabled
        ctbFilterAcrossSlices = p.ctbFilterAcrossSlices; ctbBetaOffset = p.ctbBetaOffset; ctbTcOffset = p.ctbTcOffset
        ctbCbQpOffset = p.ctbCbQpOffset; ctbCrQpOffset = p.ctbCrQpOffset; sao = p.sao
        self.work = work
        self.endState = endState
        self.endStat = endStat
        self.wppState = wppState
    }
}

extension HEVCPicture {
    /// Copies a wavefront row's decoded CTBs from its band: whole grid rows when the row is
    /// complete, else the decoded columns of each.
    func merge(_ t: HEVCRowParse) {
        let ctb = sps.ctbSize, wc = sps.widthCtbs
        guard t.decodedCtbs > 0 else { return }
        for x in 0..<t.decodedCtbs {
            let rs = t.row * wc + x
            ctbDecoded[rs] = true
            ctbSliceAddr[rs] = t.ctbSliceAddr[rs]
            ctbSliceIndex[rs] = t.ctbSliceIndex[rs]
            ctbDeblockDisabled[rs] = t.ctbDeblockDisabled[rs]
            ctbFilterAcrossSlices[rs] = t.ctbFilterAcrossSlices[rs]
            ctbBetaOffset[rs] = t.ctbBetaOffset[rs]
            ctbTcOffset[rs] = t.ctbTcOffset[rs]
            ctbCbQpOffset[rs] = t.ctbCbQpOffset[rs]
            ctbCrQpOffset[rs] = t.ctbCrQpOffset[rs]
            for c in 0..<sao.count { sao[c][rs] = t.sao[c][rs] }
        }
        let first4 = (t.row * ctb) >> 2, end4 = min(h4, ((t.row + 1) * ctb) >> 2)
        let cols = t.decodedCtbs == wc ? w4 : min(w4, (t.decodedCtbs * ctb) >> 2)
        func copy<T>(_ dst: inout [T], _ src: [T]) {
            if cols == w4 {
                let s = (first4 - t.y4Origin) * w4
                dst.replaceSubrange((first4 * w4) ..< (end4 * w4), with: src[s ..< s + (end4 - first4) * w4])
            } else {
                for y4 in first4..<end4 {
                    let s = (y4 - t.y4Origin) * w4
                    dst.replaceSubrange((y4 * w4) ..< (y4 * w4 + cols), with: src[s ..< s + cols])
                }
            }
        }
        copy(&predMode, t.predMode); copy(&intraMode, t.intraMode); copy(&qpY, t.qpY); copy(&ctDepth, t.ctDepth); copy(&bypass, t.bypass)
        copy(&tuEdgeV, t.tuEdgeV); copy(&tuEdgeH, t.tuEdgeH); copy(&puEdgeV, t.puEdgeV); copy(&puEdgeH, t.puEdgeH)
        copy(&nonZeroCoeff, t.nonZeroCoeff); copy(&motion, t.motion)
    }
}

/// One tile's parse (HEVCDecoder.decodeTilesInParallel): the shadow picture's metadata, its
/// recorded reconstruction, and the contexts it ended with.
struct HEVCTileParse: Sendable {
    let w4: Int
    var ctbs: [Int]
    var predMode: [UInt8], intraMode: [UInt8], qpY: [Int8], ctDepth: [UInt8], bypass: [Bool]
    var tuEdgeV: [UInt8], tuEdgeH: [UInt8], puEdgeV: [UInt8], puEdgeH: [UInt8], nonZeroCoeff: [Bool], motion: [HEVCMotion]
    var ctbSliceAddr: [Int], ctbSliceIndex: [Int16], ctbDeblockDisabled: [Bool], ctbFilterAcrossSlices: [Bool]
    var ctbBetaOffset: [Int8], ctbTcOffset: [Int8], ctbCbQpOffset: [Int8], ctbCrQpOffset: [Int8]
    var sao: [[HEVCSAO]]
    var work: HEVCSliceWork
    var endState: InlineArray<157, UInt8>
    var endStat: [Int]

    init(_ p: HEVCPicture, work: HEVCSliceWork, endState: InlineArray<157, UInt8>, endStat: [Int]) {
        w4 = p.w4
        ctbs = p.ctbDecoded.indices.filter { p.ctbDecoded[$0] }
        predMode = p.predMode; intraMode = p.intraMode; qpY = p.qpY; ctDepth = p.ctDepth; bypass = p.bypass
        tuEdgeV = p.tuEdgeV; tuEdgeH = p.tuEdgeH; puEdgeV = p.puEdgeV; puEdgeH = p.puEdgeH; nonZeroCoeff = p.nonZeroCoeff; motion = p.motion
        ctbSliceAddr = p.ctbSliceAddr; ctbSliceIndex = p.ctbSliceIndex; ctbDeblockDisabled = p.ctbDeblockDisabled
        ctbFilterAcrossSlices = p.ctbFilterAcrossSlices; ctbBetaOffset = p.ctbBetaOffset; ctbTcOffset = p.ctbTcOffset
        ctbCbQpOffset = p.ctbCbQpOffset; ctbCrQpOffset = p.ctbCrQpOffset; sao = p.sao
        self.work = work
        self.endState = endState
        self.endStat = endStat
    }
}

extension HEVCPicture {
    /// Copies a tile's decoded CTBs (their per-CTB state and 4x4 grid) from its shadow picture.
    func merge(_ t: HEVCTileParse, geometry g: HEVCGeometry) {
        let ctb = sps.ctbSize
        for rs in t.ctbs {
            ctbDecoded[rs] = true
            ctbSliceAddr[rs] = t.ctbSliceAddr[rs]
            ctbSliceIndex[rs] = t.ctbSliceIndex[rs]
            ctbDeblockDisabled[rs] = t.ctbDeblockDisabled[rs]
            ctbFilterAcrossSlices[rs] = t.ctbFilterAcrossSlices[rs]
            ctbBetaOffset[rs] = t.ctbBetaOffset[rs]
            ctbTcOffset[rs] = t.ctbTcOffset[rs]
            ctbCbQpOffset[rs] = t.ctbCbQpOffset[rs]
            ctbCrQpOffset[rs] = t.ctbCrQpOffset[rs]
            for c in 0..<sao.count { sao[c][rs] = t.sao[c][rs] }
            let x0 = (rs % g.widthCtbs) * ctb, y0 = (rs / g.widthCtbs) * ctb
            for y4 in (y0 >> 2)..<min(h4, (y0 + ctb) >> 2) {
                for x4 in (x0 >> 2)..<min(w4, (x0 + ctb) >> 2) {
                    let i = x4 + y4 * w4
                    predMode[i] = t.predMode[i]; intraMode[i] = t.intraMode[i]; qpY[i] = t.qpY[i]; ctDepth[i] = t.ctDepth[i]; bypass[i] = t.bypass[i]
                    tuEdgeV[i] = t.tuEdgeV[i]; tuEdgeH[i] = t.tuEdgeH[i]; puEdgeV[i] = t.puEdgeV[i]; puEdgeH[i] = t.puEdgeH[i]
                    nonZeroCoeff[i] = t.nonZeroCoeff[i]; motion[i] = t.motion[i]
                }
            }
        }
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

    /// The planes' sizes: luma, then (unless 4:0:0) Cb and Cr.
    static func planeSizes(_ sps: HEVCSPS) -> [(width: Int, height: Int)] {
        sps.chromaFormatIdc == 0 ? [(sps.width, sps.height)]
            : [(sps.width, sps.height), (sps.width / sps.subWidthC, sps.height / sps.subHeightC), (sps.width / sps.subWidthC, sps.height / sps.subHeightC)]
    }

    /// log2 of plane `c`'s rows per band: a CTB row.
    static func bandLog2(_ sps: HEVCSPS, _ c: Int) -> Int { c == 0 || sps.subHeightC == 1 ? sps.log2CtbSize : sps.log2CtbSize - 1 }

    /// Mid-grey planes: a picture before reconstruction, or a missing reference (8.3.3).
    static func greyPlanes(_ sps: HEVCSPS) -> [HEVCPlane] {
        planeSizes(sps).enumerated().map { c, size in
            HEVCPlane(width: size.width, height: size.height, log2Rows: bandLog2(sps, c),
                      fill: UInt16(1 << ((c == 0 ? sps.bitDepthLuma : sps.bitDepthChroma) - 1)))
        }
    }
}
