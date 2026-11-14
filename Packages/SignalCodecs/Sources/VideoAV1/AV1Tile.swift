// decode_tile( ) (5.11): the partition tree, intra frame mode info, palettes, transform sizes
// and coefficients of one tile of a key frame, and the reconstruction calls of 5.11.35.
// A tile only ever reads samples and mode info inside itself (is_inside, 5.11.51), so each
// tile decodes into its own buffers and tiles run in parallel; the frame is assembled after.

import CodecCore

/// What every tile of the frame shares (read-only).
struct AV1FrameInfo: Sendable {
    let seq: AV1SequenceHeader
    let hdr: AV1FrameHeader
    let subX: Int, subY: Int
    let numPlanes: Int
    let bitDepth: Int
    let sbSize: Int, sbSize4: Int, sbMask: Int
    let cdfIndex: Int
    /// Loop restoration units per plane (rows, cols).
    let lrUnitRows: [Int], lrUnitCols: [Int]
    /// Inter frames: the pictures of LAST_FRAME … ALTREF_FRAME (index 1 … 7), the projected
    /// motion field per reference (MotionFieldMvs: (row, col) per 8x8, `AV1Inter.invalidMv`
    /// where none), and the previous frame's segment ids (MiRows × MiCols; empty: all 0).
    var refPictures: [AV1RefPicture?] = Array(repeating: nil, count: 8)
    var motionField = AV1MotionFieldMvs()
    var prevSegmentIds: [UInt8] = []
    var prevSegmentStride = 0
    /// The CDFs the frame starts from (loaded from a reference); empty: the defaults.
    var initialCdf: [UInt16] = []

    init(seq: AV1SequenceHeader, hdr: AV1FrameHeader) {
        self.seq = seq
        self.hdr = hdr
        subX = seq.subsamplingX
        subY = seq.subsamplingY
        numPlanes = seq.numPlanes
        bitDepth = seq.bitDepth
        sbSize = seq.use128 ? AV1C.block128x128 : AV1C.block64x64
        sbSize4 = seq.use128 ? 32 : 16
        sbMask = seq.use128 ? 31 : 15
        let q = hdr.baseQIdx
        cdfIndex = q <= 20 ? 0 : (q <= 60 ? 1 : (q <= 120 ? 2 : 3))
        var rows: [Int] = [], cols: [Int] = []
        for p in 0..<3 {
            let sx = p == 0 ? 0 : seq.subsamplingX, sy = p == 0 ? 0 : seq.subsamplingY
            let unit = hdr.loopRestorationSize[p]
            rows.append(max((round2(hdr.frameHeight, sy) + (unit >> 1)) / unit, 1))
            cols.append(max((round2(hdr.upscaledWidth, sx) + (unit >> 1)) / unit, 1))
        }
        lrUnitRows = rows
        lrUnitCols = cols
    }
}

/// A reference frame as inter prediction reads it: its samples (upscaled width × height) and
/// size. Parsing reads only the size; the samples are filled in for reconstruction.
struct AV1RefPicture: Sendable {
    var planes: [AV1PlaneBuffer]
    let upscaledWidth: Int, frameWidth: Int, frameHeight: Int
}

/// Samples of one plane over a region (a tile, or the frame).
struct AV1PlaneBuffer: Sendable {
    let x0: Int, y0: Int
    let width: Int, height: Int
    var px: [UInt16]

    /// `allocate` false: no samples yet (px empty).
    init(x0: Int, y0: Int, width: Int, height: Int, fill: UInt16 = 0, allocate: Bool = true) {
        self.x0 = x0
        self.y0 = y0
        self.width = width
        self.height = height
        px = allocate ? [UInt16](repeating: fill, count: width * height) : []
    }

    @inline(__always) func at(_ x: Int, _ y: Int) -> Int { Int(px[(y - y0) * width + (x - x0)]) }
    @inline(__always) mutating func set(_ x: Int, _ y: Int, _ v: Int) { px[(y - y0) * width + (x - x0)] = UInt16(truncatingIfNeeded: v) }
    /// A sample with its coordinates clamped into the buffer (intra block copy reads).
    @inline(__always) func clamped(_ x: Int, _ y: Int) -> Int {
        let cx = min(max(x - x0, 0), width - 1), cy = min(max(y - y0, 0), height - 1)
        return Int(px[cy * width + cx])
    }
}

struct AV1LRUnit: Sendable {
    var type = 0
    var wiener: [Int] = [0, 0, 0, 0, 0, 0]   // [pass][3]
    var sgrSet = 0
    var xqd = [0, 0]
}

/// Mode info that outlives the tile (loop filter, CDEF), in tile-local mi coordinates.
struct AV1TileModeInfo: Sendable {
    let miRow0: Int, miCol0: Int, rows: Int, cols: Int
    var miSize: [UInt8], skip: [UInt8], segmentId: [UInt8], isInter: [UInt8]
    /// LoopfilterTxSizes per plane, in that plane's 4x4 units relative to the tile origin.
    var lfTxSize: [[UInt8]]
    var deltaLF: [Int8]
    /// cdef_idx per 64x64 luma block, relative to the tile origin.
    var cdefIdx: [Int8]
    let cdefCols: Int
}

struct AV1TileDecoder {
    /// Read-only while decoding; a replay fills in the reference samples.
    var f: AV1FrameInfo
    let lay = AV1CDFLayout.shared
    var sd: AV1SymbolDecoder
    let miRowStart: Int, miRowEnd: Int, miColStart: Int, miColEnd: Int
    // Tile-local mode info (origin miRowStart / miColStart, stride miStride).
    let miStride: Int, miRowsAlloc: Int
    var miSizes: [UInt8], yModes: [UInt8], uvModes: [UInt8], isInters: [UInt8], skips: [UInt8], segmentIds: [UInt8]
    var interTxSizes: [UInt8], written: [UInt8], txTypes: [UInt8]
    /// Mvs: (row, col) for list 0 then list 1, four per mode info unit.
    var mvs: [Int32]
    /// RefFrames (two per unit), InterpFilters (two per unit), CompGroupIdxs, CompoundIdxs, SkipModes.
    var refFrames: [Int8], interpFilters: [UInt8], compGroupIdxs: [UInt8], compoundIdxs: [UInt8], skipModes: [UInt8]
    /// AboveSegPredContext / LeftSegPredContext (absolute mode info columns / rows).
    var aboveSegPred: [UInt8], leftSegPred: [UInt8]
    var deltaLFs: [Int8]
    var lfTxSizes: [[UInt8]]
    var lfStride: [Int]
    var cdefIdx: [Int8]
    let cdefCols: Int
    // Samples.
    var planes: [AV1PlaneBuffer]
    // Above / left contexts in each plane's 4x4 units (absolute indices).
    var aboveLevel: [[UInt8]], aboveDc: [[UInt8]], leftLevel: [[UInt8]], leftDc: [[UInt8]]
    // Palettes of the latest block above (per column) / left (per row): size and 8 colours.
    var abovePalSize: [[UInt8]], abovePal: [[UInt16]], leftPalSize: [[UInt8]], leftPal: [[UInt16]]
    var blockDecoded: [[UInt8]]
    let bdStride: Int
    // Loop restoration.
    var lrUnits: [(plane: Int, index: Int, unit: AV1LRUnit)] = []
    var refLrWiener: [[Int]] = []
    var refSgrXqd: [[Int]] = []
    var error: AV1DecodeError? = nil
    var stats = [Int](repeating: 0, count: AV1Tool.allCases.count)
    @inline(__always) mutating func used(_ t: AV1Tool) { stats[t.rawValue] += 1 }
    var interStats = [Int](repeating: 0, count: AV1InterTool.allCases.count)
    @inline(__always) mutating func used(_ t: AV1InterTool) { interStats[t.rawValue] += 1 }

    // The current block (5.11.5 … 5.11.33).
    var miRow = 0, miCol = 0, miSize = 0
    var hasChroma = false
    var availU = false, availL = false, availUChroma = false, availLChroma = false
    var skip = 0, segmentId = 0, lossless = false
    var isInter = false, useIntrabc = false
    var yMode = 0, uvMode = 0, angleDeltaY = 0, angleDeltaUV = 0
    var useFilterIntra = false, filterIntraMode = 0
    var cflAlphaU = 0, cflAlphaV = 0
    var paletteSizeY = 0, paletteSizeUV = 0
    var paletteY = [Int](repeating: 0, count: 8), paletteU = [Int](repeating: 0, count: 8), paletteV = [Int](repeating: 0, count: 8)
    var colorMapY = [UInt8](repeating: 0, count: 64 * 64), colorMapUV = [UInt8](repeating: 0, count: 64 * 64)
    var txSize = 0
    var readDeltas = false
    var currentQIndex = 0
    var deltaLF = [0, 0, 0, 0]
    /// Mv[0] and Mv[1].
    var mv = (row: 0, col: 0), mv1 = (row: 0, col: 0)
    // Inter blocks (5.11.23 – 5.11.29) and the motion vector stack (7.10.2).
    var refFrame = (0, -1)
    var leftRef = (0, -1), aboveRef = (0, -1)
    var skipMode = 0
    var interintra = false, interintraMode = 0, wedgeInterintra = false
    var wedgeIndex = 0, wedgeSign = 0, maskType = 0
    var compoundType = AV1Inter.compoundAverage, compGroupIdx = 0, compoundIdx = 1
    var motionMode = 0
    var interpFilter = [0, 0]
    var refMvIdx = 0
    var numMvFound = 0, newMvCount = 0, foundMatch = false
    var refStackMv = [Int](repeating: 0, count: 8 * 4)
    var weightStack = [Int](repeating: 0, count: 8)
    var globalMvs = [0, 0, 0, 0]
    var drlCtxStack = [Int](repeating: 0, count: 8)
    var newMvContext = 0, refMvContext = 0, zeroMvContext = 0
    var numSamples = 0, numSamplesScanned = 0
    var candList = [Int](repeating: 0, count: 8 * 4)
    var localWarpParams = [0, 0, 1 << 16, 0, 0, 1 << 16], localValid = false
    /// Inter prediction scratch: the two predictions, the filter's intermediate rows, the mask.
    var predBuf0: [Int] = [], predBuf1: [Int] = [], interBuf: [Int] = [], interMask: [Int] = []
    var maskStride = 0
    var maxLumaW = 0, maxLumaH = 0
    // Coefficients of the current transform block.
    var quant = [Int32](repeating: 0, count: 1024)
    var planeTxType = 0
    var tx = AV1InverseTransform()
    // Video frames are parsed first, recording what reconstruction then replays
    // (AV1TileReplay.swift): a record per block, per transform block, the coefficients.
    var recording = false, replaying = false
    var blockRecords: [AV1BlockRecord] = []
    var txRecords: [AV1TxRecord] = []
    /// (position, value) of each nonzero coefficient.
    var coefData: [Int32] = []
    /// Palettes with their colour maps, and warp samples.
    var sideData: [Int32] = []
    var txCursor = 0
    /// Interintra blocks: per plane, whether the above-right (bit 2p) and below-left (2p + 1) are decoded.
    var iiEdges: UInt8 = 0

    /// `recording`: parse only (AV1TileReplay.swift); the samples are allocated by the replay.
    init(_ f: AV1FrameInfo, data: [UInt8], start: Int, size: Int, tileRow: Int, tileCol: Int, recording: Bool = false) throws(AV1DecodeError) {
        self.f = f
        self.recording = recording
        miRowStart = f.hdr.miRowStarts[tileRow]
        miRowEnd = f.hdr.miRowStarts[tileRow + 1]
        miColStart = f.hdr.miColStarts[tileCol]
        miColEnd = f.hdr.miColStarts[tileCol + 1]
        let sb4 = f.sbSize4
        let colsAlloc = ((miColEnd - miColStart + sb4 - 1) / sb4) * sb4
        let rowsAlloc = ((miRowEnd - miRowStart + sb4 - 1) / sb4) * sb4
        miStride = colsAlloc
        miRowsAlloc = rowsAlloc
        let n = colsAlloc * rowsAlloc
        miSizes = [UInt8](repeating: 0, count: n)
        yModes = miSizes; uvModes = miSizes; isInters = miSizes; skips = miSizes; segmentIds = miSizes
        interTxSizes = miSizes; written = miSizes; txTypes = miSizes
        mvs = f.hdr.allowIntrabc || !f.hdr.frameIsIntra ? [Int32](repeating: 0, count: 4 * n) : []
        refFrames = [Int8](repeating: 0, count: 2 * n)
        interpFilters = [UInt8](repeating: 0, count: 2 * n)
        compGroupIdxs = miSizes
        compoundIdxs = miSizes
        skipModes = miSizes
        deltaLFs = f.hdr.deltaLfPresent ? [Int8](repeating: 0, count: 4 * n) : []
        var lfs: [[UInt8]] = [], strides: [Int] = []
        for p in 0..<f.numPlanes {
            let sx = p == 0 ? 0 : f.subX, sy = p == 0 ? 0 : f.subY
            let w = (colsAlloc >> sx) + 1, hh = (rowsAlloc >> sy) + 1
            lfs.append([UInt8](repeating: 0, count: w * hh))
            strides.append(w)
        }
        lfTxSizes = lfs
        lfStride = strides
        cdefCols = (colsAlloc + 15) / 16
        cdefIdx = [Int8](repeating: -1, count: cdefCols * ((rowsAlloc + 15) / 16))
        var pls: [AV1PlaneBuffer] = []
        for p in 0..<f.numPlanes {
            let sx = p == 0 ? 0 : f.subX, sy = p == 0 ? 0 : f.subY
            pls.append(AV1PlaneBuffer(x0: (miColStart * 4) >> sx, y0: (miRowStart * 4) >> sy, width: (colsAlloc * 4) >> sx, height: (rowsAlloc * 4) >> sy,
                                      allocate: !recording))
        }
        planes = pls
        let frameCols4 = ((f.hdr.miColStarts.last ?? 0) + 2 * sb4), frameRows4 = ((f.hdr.miRowStarts.last ?? 0) + 2 * sb4)
        aboveLevel = Array(repeating: [UInt8](repeating: 0, count: frameCols4), count: 3)
        aboveDc = aboveLevel
        leftLevel = Array(repeating: [UInt8](repeating: 0, count: frameRows4), count: 3)
        leftDc = leftLevel
        abovePalSize = Array(repeating: [UInt8](repeating: 0, count: frameCols4), count: 2)
        abovePal = Array(repeating: [UInt16](repeating: 0, count: frameCols4 * 8), count: 2)
        leftPalSize = Array(repeating: [UInt8](repeating: 0, count: frameRows4), count: 2)
        leftPal = Array(repeating: [UInt16](repeating: 0, count: frameRows4 * 8), count: 2)
        aboveSegPred = [UInt8](repeating: 0, count: frameCols4)
        leftSegPred = [UInt8](repeating: 0, count: frameRows4)
        bdStride = sb4 + 3
        blockDecoded = Array(repeating: [UInt8](repeating: 0, count: bdStride * bdStride), count: 3)
        sd = try AV1SymbolDecoder(data, start: start, size: size, cdf: f.initialCdf.isEmpty ? lay.defaults[f.cdfIndex] : f.initialCdf,
                                  disableUpdate: f.hdr.disableCdfUpdate)
        currentQIndex = f.hdr.baseQIdx
    }

    @inline(__always) func mi(_ r: Int, _ c: Int) -> Int { (r - miRowStart) * miStride + (c - miColStart) }
    @inline(__always) func isInside(_ r: Int, _ c: Int) -> Bool { c >= miColStart && c < miColEnd && r >= miRowStart && r < miRowEnd }

    mutating func fail(_ e: AV1DecodeError) { if error == nil { error = e } }

    // MARK: decode_tile

    mutating func decodeTile() throws(AV1DecodeError) {
        refLrWiener = Array(repeating: [3, -7, 15], count: 6)
        refSgrXqd = Array(repeating: [-32, 31], count: 3)
        var r = miRowStart
        while r < miRowEnd {
            for p in 0..<3 {
                for i in leftLevel[p].indices { leftLevel[p][i] = 0; leftDc[p][i] = 0 }
            }
            for p in 0..<2 { for i in leftPalSize[p].indices { leftPalSize[p][i] = 0 } }
            var c = miColStart
            while c < miColEnd {
                readDeltas = f.hdr.deltaQPresent
                clearBlockDecoded(r, c)
                readLr(r, c)
                decodePartition(r, c, f.sbSize)
                if let e = error { throw e }
                c += f.sbSize4
            }
            r += f.sbSize4
        }
        guard sd.paddingValid else { throw .malformed("tile data overrun") }
    }

    mutating func clearBlockDecoded(_ r: Int, _ c: Int) {
        let sb4 = f.sbSize4
        for plane in 0..<f.numPlanes {
            let sx = plane > 0 ? f.subX : 0, sy = plane > 0 ? f.subY : 0
            Self.clearDecoded(&blockDecoded[plane], bdStride, sb4 >> sx, sb4 >> sy, (miColEnd - c) >> sx, (miRowEnd - r) >> sy)
        }
    }

    static func clearDecoded(_ a: inout [UInt8], _ stride: Int, _ w4: Int, _ h4: Int, _ sbW4: Int, _ sbH4: Int) {
        var s = a.mutableSpan
        for y in -1...h4 {
            for x in -1...w4 {
                let v: UInt8 = (y < 0 && x < sbW4) || (x < 0 && y < sbH4) ? 1 : 0
                s[(y + 1) * stride + x + 1] = v
            }
        }
        s[(h4 + 1) * stride] = 0
    }

    /// a[y · stride + x] = v over a w × h rectangle at (x0, y0), clipped to stride × rows.
    @inline(__always) static func fillRect(_ a: inout [UInt8], stride: Int, rows: Int, x0: Int, y0: Int, w: Int, h: Int, _ v: UInt8) {
        let x1 = min(stride, x0 + w), y1 = min(rows, y0 + h)
        guard x0 >= 0, y0 >= 0, x1 > x0, y1 > y0 else { return }
        var s = a.mutableSpan
        for y in y0..<y1 {
            let row = y * stride
            for x in x0..<x1 { s[row + x] = v }
        }
    }

    @inline(__always) func decoded(_ plane: Int, _ y: Int, _ x: Int) -> Bool { blockDecoded[plane][(y + 1) * bdStride + x + 1] != 0 }

    // MARK: decode_partition

    mutating func decodePartition(_ r: Int, _ c: Int, _ bSize: Int) {
        if r >= f.hdr.miRows || c >= f.hdr.miCols || error != nil { return }
        availU = isInside(r - 1, c)
        availL = isInside(r, c - 1)
        let num4x4 = AV1C.num4x4W[bSize]
        let half = num4x4 >> 1, quarter = half >> 1
        let hasRows = r + half < f.hdr.miRows, hasCols = c + half < f.hdr.miCols
        var partition: Int
        if bSize < AV1C.block8x8 {
            partition = AV1C.partitionNone
        } else {
            let bsl = AV1C.miWidthLog2[bSize]
            let above = availU && AV1C.miWidthLog2[Int(miSizes[mi(r - 1, c)])] < bsl ? 1 : 0
            let left = availL && AV1C.miHeightLog2[Int(miSizes[mi(r, c - 1)])] < bsl ? 1 : 0
            let ctx = left * 2 + above
            let n = bsl == 1 ? 4 : (bsl == 5 ? 8 : 10)
            let base = lay.partition[bsl - 1] + ctx * (n + 1)
            if hasRows && hasCols {
                partition = sd.symbol(base, n)
            } else if hasCols {
                func p(_ i: Int) -> Int { Int(sd.cdf[base + i]) - (i > 0 ? Int(sd.cdf[base + i - 1]) : 0) }
                var psum = p(AV1C.partitionVert) + p(AV1C.partitionSplit) + p(AV1C.partitionHorzA) + p(AV1C.partitionVertA) + p(AV1C.partitionVertB)
                if bSize != AV1C.block128x128 { psum += p(AV1C.partitionVert4) }
                partition = sd.symbolFixed((1 << 15) - psum) == 1 ? AV1C.partitionSplit : AV1C.partitionHorz
            } else if hasRows {
                func p(_ i: Int) -> Int { Int(sd.cdf[base + i]) - (i > 0 ? Int(sd.cdf[base + i - 1]) : 0) }
                var psum = p(AV1C.partitionHorz) + p(AV1C.partitionSplit) + p(AV1C.partitionHorzA) + p(AV1C.partitionHorzB) + p(AV1C.partitionVertA)
                if bSize != AV1C.block128x128 { psum += p(AV1C.partitionHorz4) }
                partition = sd.symbolFixed((1 << 15) - psum) == 1 ? AV1C.partitionSplit : AV1C.partitionVert
            } else {
                partition = AV1C.partitionSplit
            }
        }
        let subSize = AV1C.partitionSubsize[partition * 22 + bSize]
        let splitSize = AV1C.partitionSubsize[AV1C.partitionSplit * 22 + bSize]
        guard subSize < 22 else { fail(.malformed("partition \(partition) of block size \(bSize)")); return }
        switch partition {
        case AV1C.partitionNone: decodeBlock(r, c, subSize)
        case AV1C.partitionHorz:
            decodeBlock(r, c, subSize)
            if hasRows { decodeBlock(r + half, c, subSize) }
        case AV1C.partitionVert:
            decodeBlock(r, c, subSize)
            if hasCols { decodeBlock(r, c + half, subSize) }
        case AV1C.partitionSplit:
            decodePartition(r, c, subSize)
            decodePartition(r, c + half, subSize)
            decodePartition(r + half, c, subSize)
            decodePartition(r + half, c + half, subSize)
        case AV1C.partitionHorzA:
            decodeBlock(r, c, splitSize)
            decodeBlock(r, c + half, splitSize)
            decodeBlock(r + half, c, subSize)
        case AV1C.partitionHorzB:
            decodeBlock(r, c, subSize)
            decodeBlock(r + half, c, splitSize)
            decodeBlock(r + half, c + half, splitSize)
        case AV1C.partitionVertA:
            decodeBlock(r, c, splitSize)
            decodeBlock(r + half, c, splitSize)
            decodeBlock(r, c + half, subSize)
        case AV1C.partitionVertB:
            decodeBlock(r, c, subSize)
            decodeBlock(r, c + half, splitSize)
            decodeBlock(r + half, c + half, splitSize)
        case AV1C.partitionHorz4:
            for k in 0..<4 where k < 3 || r + quarter * 3 < f.hdr.miRows { decodeBlock(r + quarter * k, c, subSize) }
        default:
            for k in 0..<4 where k < 3 || c + quarter * 3 < f.hdr.miCols { decodeBlock(r, c + quarter * k, subSize) }
        }
    }

    // MARK: decode_block

    mutating func decodeBlock(_ r: Int, _ c: Int, _ bSize: Int) {
        if error != nil { return }
        miRow = r
        miCol = c
        miSize = bSize
        let bw4 = AV1C.num4x4W[bSize], bh4 = AV1C.num4x4H[bSize]
        if bh4 == 1 && f.subY == 1 && (miRow & 1) == 0 {
            hasChroma = false
        } else if bw4 == 1 && f.subX == 1 && (miCol & 1) == 0 {
            hasChroma = false
        } else {
            hasChroma = f.numPlanes > 1
        }
        availU = isInside(r - 1, c)
        availL = isInside(r, c - 1)
        availUChroma = availU
        availLChroma = availL
        if hasChroma {
            if f.subY == 1 && bh4 == 1 { availUChroma = isInside(r - 2, c) }
            if f.subX == 1 && bw4 == 1 { availLChroma = isInside(r, c - 2) }
        } else {
            availUChroma = false
            availLChroma = false
        }
        if f.hdr.frameIsIntra { intraFrameModeInfo() } else { interFrameModeInfo() }
        paletteTokens()
        readBlockTxSize()
        if skip != 0 { resetBlockContext(bw4, bh4) }
        // The block's mode info, row by row (a span per array: no per-element checks).
        let base = mi(r, c), stride = miStride
        Self.fill(&yModes, base, stride, 1, bw4, bh4, UInt8(yMode))
        Self.fill(&written, base, stride, 1, bw4, bh4, UInt8(1))
        Self.fill(&refFrames, 2 * base, 2 * stride, 2, bw4, bh4, Int8(refFrame.0))
        Self.fill(&refFrames, 2 * base + 1, 2 * stride, 2, bw4, bh4, Int8(refFrame.1))
        if hasChroma { Self.fill(&uvModes, base, stride, 1, bw4, bh4, UInt8(uvMode)) }
        if isInter {
            if !useIntrabc {
                Self.fill(&compGroupIdxs, base, stride, 1, bw4, bh4, UInt8(compGroupIdx))
                Self.fill(&compoundIdxs, base, stride, 1, bw4, bh4, UInt8(compoundIdx))
            }
            Self.fill(&interpFilters, 2 * base, 2 * stride, 2, bw4, bh4, UInt8(interpFilter[0]))
            Self.fill(&interpFilters, 2 * base + 1, 2 * stride, 2, bw4, bh4, UInt8(interpFilter[1]))
            Self.fill(&mvs, 4 * base, 4 * stride, 4, bw4, bh4, Int32(mv.row))
            Self.fill(&mvs, 4 * base + 1, 4 * stride, 4, bw4, bh4, Int32(mv.col))
            if refFrame.1 > AV1Ref.intra {
                Self.fill(&mvs, 4 * base + 2, 4 * stride, 4, bw4, bh4, Int32(mv1.row))
                Self.fill(&mvs, 4 * base + 3, 4 * stride, 4, bw4, bh4, Int32(mv1.col))
            }
        }
        if recording { recordBlock() } else { computePrediction() }
        residual()
        Self.fill(&isInters, base, stride, 1, bw4, bh4, UInt8(isInter ? 1 : 0))
        Self.fill(&skipModes, base, stride, 1, bw4, bh4, UInt8(skipMode))
        Self.fill(&skips, base, stride, 1, bw4, bh4, UInt8(skip))
        Self.fill(&miSizes, base, stride, 1, bw4, bh4, UInt8(bSize))
        Self.fill(&segmentIds, base, stride, 1, bw4, bh4, UInt8(segmentId))
        if !deltaLFs.isEmpty {
            for k in 0..<4 { Self.fill(&deltaLFs, 4 * base + k, 4 * stride, 4, bw4, bh4, Int8(deltaLF[k])) }
        }
        // Palette colours of this block, for later blocks' palette caches.
        for x in 0..<bw4 {
            abovePalSize[0][c + x] = UInt8(paletteSizeY)
            abovePalSize[1][c + x] = UInt8(paletteSizeUV)
            for k in 0..<paletteSizeY { abovePal[0][(c + x) * 8 + k] = UInt16(paletteY[k]) }
            for k in 0..<paletteSizeUV { abovePal[1][(c + x) * 8 + k] = UInt16(paletteU[k]) }
        }
        for y in 0..<bh4 {
            leftPalSize[0][r + y] = UInt8(paletteSizeY)
            leftPalSize[1][r + y] = UInt8(paletteSizeUV)
            for k in 0..<paletteSizeY { leftPal[0][(r + y) * 8 + k] = UInt16(paletteY[k]) }
            for k in 0..<paletteSizeUV { leftPal[1][(r + y) * 8 + k] = UInt16(paletteU[k]) }
        }
    }

    mutating func resetBlockContext(_ bw4: Int, _ bh4: Int) {
        for plane in 0..<(hasChroma ? 3 : 1) {
            let sx = plane > 0 ? f.subX : 0, sy = plane > 0 ? f.subY : 0
            let c0 = miCol >> sx, c1 = (miCol + bw4) >> sx, r0 = miRow >> sy, r1 = (miRow + bh4) >> sy
            Self.zero(&aboveLevel[plane], c0, c1)
            Self.zero(&aboveDc[plane], c0, c1)
            Self.zero(&leftLevel[plane], r0, r1)
            Self.zero(&leftDc[plane], r0, r1)
        }
    }

    /// a[start + y · rowStride + x · step] = v for x < w, y < h.
    @inline(__always) static func fill<T>(_ a: inout [T], _ start: Int, _ rowStride: Int, _ step: Int, _ w: Int, _ h: Int, _ v: T) {
        var s = a.mutableSpan
        for y in 0..<h {
            var i = start + y * rowStride
            for _ in 0..<w {
                s[i] = v
                i += step
            }
        }
    }

    @inline(__always) static func zero(_ a: inout [UInt8], _ lo: Int, _ hi: Int) {
        var s = a.mutableSpan
        var i = lo
        while i < hi { s[i] = 0; i += 1 }
    }

    // MARK: intra_frame_mode_info

    mutating func intraFrameModeInfo() {
        skip = 0
        skipMode = 0
        refFrame = (AV1Ref.intra, AV1Ref.none)
        interintra = false
        motionMode = AV1Inter.simple
        compoundType = AV1Inter.compoundAverage
        if f.hdr.segIdPreSkip { intraSegmentId() }
        if f.hdr.segIdPreSkip && f.hdr.segFeatureActive(segmentId, 6) {
            skip = 1
        } else {
            var ctx = 0
            if availU { ctx += Int(skips[mi(miRow - 1, miCol)]) }
            if availL { ctx += Int(skips[mi(miRow, miCol - 1)]) }
            skip = sd.symbol(lay.skip + ctx * 3, 2)
        }
        if !f.hdr.segIdPreSkip { intraSegmentId() }
        readCdef()
        readDeltaQIndex()
        readDeltaLf()
        readDeltas = false
        useIntrabc = f.hdr.allowIntrabc ? sd.symbol(lay.intrabc, 2) == 1 : false
        useFilterIntra = false
        paletteSizeY = 0
        paletteSizeUV = 0
        angleDeltaY = 0
        angleDeltaUV = 0
        if useIntrabc {
            isInter = true
            yMode = AV1C.dcPred
            uvMode = AV1C.dcPred
            used(.intrabc)
            interpFilter = [3, 3]   // BILINEAR
            findMvStack(false)
            assignIntrabcMv()
        } else {
            isInter = false
            let above = AV1C.intraModeContext[availU ? Int(yModes[mi(miRow - 1, miCol)]) : 0]
            let left = AV1C.intraModeContext[availL ? Int(yModes[mi(miRow, miCol - 1)]) : 0]
            yMode = sd.symbol(lay.intraFrameYMode + (above * 5 + left) * 14, 13)
            if miSize >= AV1C.block8x8 && isDirectional(yMode) {
                angleDeltaY = sd.symbol(lay.angleDelta + (yMode - AV1C.vPred) * 8, 7) - 3
            }
            if hasChroma {
                let cflAllowed: Bool
                if lossless && AV1C.planeResidualSize(miSize, f.subX, f.subY) == AV1C.block4x4 {
                    cflAllowed = true
                } else {
                    cflAllowed = !lossless && max(AV1C.blockWidth[miSize], AV1C.blockHeight[miSize]) <= 32
                }
                uvMode = cflAllowed ? sd.symbol(lay.uvModeCflAllowed + yMode * 15, 14) : sd.symbol(lay.uvModeCflNotAllowed + yMode * 14, 13)
                if uvMode == AV1C.uvCflPred { readCflAlphas(); used(.cfl) }
                if miSize >= AV1C.block8x8 && isDirectional(uvMode) {
                    angleDeltaUV = sd.symbol(lay.angleDelta + (uvMode - AV1C.vPred) * 8, 7) - 3
                }
            } else {
                uvMode = AV1C.dcPred
            }
            if miSize >= AV1C.block8x8 && AV1C.blockWidth[miSize] <= 64 && AV1C.blockHeight[miSize] <= 64 && f.hdr.allowScreenContentTools {
                paletteModeInfo()
            }
            if f.seq.enableFilterIntra && yMode == AV1C.dcPred && paletteSizeY == 0 && max(AV1C.blockWidth[miSize], AV1C.blockHeight[miSize]) <= 32 {
                useFilterIntra = sd.symbol(lay.filterIntra + miSize * 3, 2) == 1
                if useFilterIntra { filterIntraMode = sd.symbol(lay.filterIntraMode, 5); used(.filterIntra) }
            }
        }
    }

    @inline(__always) func isDirectional(_ m: Int) -> Bool { m >= AV1C.vPred && m <= AV1C.d67Pred }

    mutating func intraSegmentId() {
        if f.hdr.segmentationEnabled {
            readSegmentId()
        } else {
            segmentId = 0
        }
        lossless = f.hdr.losslessArray[segmentId]
        if lossless { used(.lossless) }
        if f.hdr.segmentationEnabled && segmentId != 0 { used(.segmentation) }
    }

    /// read_segment_id (5.11.9).
    mutating func readSegmentId() {
        do {
            let prevUL = availU && availL ? Int(segmentIds[mi(miRow - 1, miCol - 1)]) : -1
            let prevU = availU ? Int(segmentIds[mi(miRow - 1, miCol)]) : -1
            let prevL = availL ? Int(segmentIds[mi(miRow, miCol - 1)]) : -1
            let pred: Int
            if prevU == -1 { pred = prevL == -1 ? 0 : prevL } else if prevL == -1 { pred = prevU } else { pred = prevUL == prevU ? prevU : prevL }
            if skip != 0 {
                segmentId = pred
            } else {
                let ctx: Int
                if prevUL < 0 { ctx = 0 } else if prevUL == prevU && prevUL == prevL { ctx = 2 } else if prevUL == prevU || prevUL == prevL || prevU == prevL { ctx = 1 } else { ctx = 0 }
                let diff = sd.symbol(lay.segmentId + ctx * 9, 8)
                segmentId = Self.negDeinterleave(diff, pred, f.hdr.lastActiveSegId + 1)
                if segmentId < 0 || segmentId > 7 { fail(.malformed("segment_id")); segmentId = 0 }
            }
        }
    }

    static func negDeinterleave(_ diff: Int, _ ref: Int, _ max: Int) -> Int {
        if ref == 0 { return diff }
        if ref >= max - 1 { return max - diff - 1 }
        if 2 * ref < max {
            if diff <= 2 * ref { return diff & 1 != 0 ? ref + ((diff + 1) >> 1) : ref - (diff >> 1) }
            return diff
        }
        if diff <= 2 * (max - ref - 1) { return diff & 1 != 0 ? ref + ((diff + 1) >> 1) : ref - (diff >> 1) }
        return max - (diff + 1)
    }

    mutating func readCdef() {
        if skip != 0 || f.hdr.codedLossless || !f.seq.enableCdef || f.hdr.allowIntrabc { return }
        let r = miRow & ~15, c = miCol & ~15
        let idx = ((r - miRowStart) / 16) * cdefCols + (c - miColStart) / 16
        if cdefIdx[idx] == -1 {
            cdefIdx[idx] = Int8(sd.literal(f.hdr.cdefBits))
            let w4 = AV1C.num4x4W[miSize], h4 = AV1C.num4x4H[miSize]
            var i = r
            while i < r + h4 {
                var j = c
                while j < c + w4 {
                    cdefIdx[((i - miRowStart) / 16) * cdefCols + (j - miColStart) / 16] = cdefIdx[idx]
                    j += 16
                }
                i += 16
            }
        }
    }

    mutating func readDeltaQIndex() {
        if miSize == f.sbSize && skip != 0 { return }
        guard readDeltas else { return }
        var abs = sd.symbol(lay.deltaQ, 4)
        if abs == 3 {
            let remBits = sd.literal(3) + 1
            abs = sd.literal(remBits) + (1 << remBits) + 1
        }
        used(.deltaQ)
        if abs != 0 {
            let sign = sd.literal(1)
            let reduced = sign != 0 ? -abs : abs
            currentQIndex = clip3(1, 255, currentQIndex + (reduced << f.hdr.deltaQRes))
        }
    }

    mutating func readDeltaLf() {
        if miSize == f.sbSize && skip != 0 { return }
        guard readDeltas && f.hdr.deltaLfPresent else { return }
        let count = f.hdr.deltaLfMulti ? (f.numPlanes > 1 ? 4 : 2) : 1
        used(.deltaLF)
        for i in 0..<count {
            let base = f.hdr.deltaLfMulti ? lay.deltaLFMulti + i * 5 : lay.deltaLF
            var abs = sd.symbol(base, 4)
            if abs == 3 {
                let n = sd.literal(3) + 1
                abs = sd.literal(n) + (1 << n) + 1
            }
            if abs != 0 {
                let sign = sd.literal(1)
                let reduced = sign != 0 ? -abs : abs
                deltaLF[i] = clip3(-63, 63, deltaLF[i] + (reduced << f.hdr.deltaLfRes))
            }
        }
    }

    mutating func readCflAlphas() {
        let signs = sd.symbol(lay.cflSign, 8)
        let signU = (signs + 1) / 3, signV = (signs + 1) % 3
        if signU != 0 {
            let ctx = (signU - 1) * 3 + signV
            cflAlphaU = 1 + sd.symbol(lay.cflAlpha + ctx * 17, 16)
            if signU == 1 { cflAlphaU = -cflAlphaU }
        } else {
            cflAlphaU = 0
        }
        if signV != 0 {
            let ctx = (signV - 1) * 3 + signU
            cflAlphaV = 1 + sd.symbol(lay.cflAlpha + ctx * 17, 16)
            if signV == 1 { cflAlphaV = -cflAlphaV }
        } else {
            cflAlphaV = 0
        }
    }

    // MARK: Palette (5.11.46, 5.11.49, 5.11.50)

    mutating func paletteModeInfo() {
        let bd = f.bitDepth
        let bsizeCtx = AV1C.miWidthLog2[miSize] + AV1C.miHeightLog2[miSize] - 2
        func clip1(_ v: Int) -> Int { clip3(0, (1 << bd) - 1, v) }
        func ceilLog2(_ x: Int) -> Int {
            if x < 2 { return 0 }
            var i = 1, p = 2
            while p < x { i += 1; p <<= 1 }
            return i
        }
        if yMode == AV1C.dcPred {
            var ctx = 0
            if availU && abovePalSize[0][miCol] > 0 { ctx += 1 }
            if availL && leftPalSize[0][miRow] > 0 { ctx += 1 }
            if sd.symbol(lay.paletteYMode + (bsizeCtx * 3 + ctx) * 3, 2) == 1 {
                paletteSizeY = sd.symbol(lay.paletteYSize + bsizeCtx * 8, 7) + 2
                used(.paletteY)
                let cache = paletteCache(0)
                var idx = 0
                var i = 0
                while i < cache.count && idx < paletteSizeY {
                    if sd.literal(1) == 1 { paletteY[idx] = cache[i]; idx += 1 }
                    i += 1
                }
                if idx < paletteSizeY {
                    paletteY[idx] = sd.literal(bd)
                    idx += 1
                }
                var paletteBits = 0
                if idx < paletteSizeY { paletteBits = bd - 3 + sd.literal(2) }
                while idx < paletteSizeY {
                    let delta = sd.literal(paletteBits) + 1
                    paletteY[idx] = clip1(paletteY[idx - 1] + delta)
                    let range = (1 << bd) - paletteY[idx] - 1
                    paletteBits = min(paletteBits, ceilLog2(range))
                    idx += 1
                }
                paletteY[0..<paletteSizeY].sort()
            }
        }
        if hasChroma && uvMode == AV1C.dcPred {
            let ctx = paletteSizeY > 0 ? 1 : 0
            if sd.symbol(lay.paletteUVMode + ctx * 3, 2) == 1 {
                paletteSizeUV = sd.symbol(lay.paletteUVSize + bsizeCtx * 8, 7) + 2
                used(.paletteUV)
                let cache = paletteCache(1)
                var idx = 0
                var i = 0
                while i < cache.count && idx < paletteSizeUV {
                    if sd.literal(1) == 1 { paletteU[idx] = cache[i]; idx += 1 }
                    i += 1
                }
                if idx < paletteSizeUV {
                    paletteU[idx] = sd.literal(bd)
                    idx += 1
                }
                var paletteBits = 0
                if idx < paletteSizeUV { paletteBits = bd - 3 + sd.literal(2) }
                while idx < paletteSizeUV {
                    let delta = sd.literal(paletteBits)
                    paletteU[idx] = clip1(paletteU[idx - 1] + delta)
                    let range = (1 << bd) - paletteU[idx]
                    paletteBits = min(paletteBits, ceilLog2(range))
                    idx += 1
                }
                paletteU[0..<paletteSizeUV].sort()
                if sd.literal(1) == 1 {
                    let minBits = bd - 4, maxVal = 1 << bd
                    let bits = minBits + sd.literal(2)
                    paletteV[0] = sd.literal(bd)
                    for k in 1..<paletteSizeUV {
                        var delta = sd.literal(bits)
                        if delta != 0 && sd.literal(1) == 1 { delta = -delta }
                        var val = paletteV[k - 1] + delta
                        if val < 0 { val += maxVal }
                        if val >= maxVal { val -= maxVal }
                        paletteV[k] = clip1(val)
                    }
                } else {
                    for k in 0..<paletteSizeUV { paletteV[k] = sd.literal(bd) }
                }
            }
        }
    }

    func paletteCache(_ plane: Int) -> [Int] {
        let aboveN = (miRow * 4) % 64 != 0 ? Int(abovePalSize[plane][miCol]) : 0
        let leftN = availL ? Int(leftPalSize[plane][miRow]) : 0
        var out: [Int] = []
        var ai = 0, li = 0
        func above(_ i: Int) -> Int { Int(abovePal[plane][miCol * 8 + i]) }
        func left(_ i: Int) -> Int { Int(leftPal[plane][miRow * 8 + i]) }
        while ai < aboveN && li < leftN {
            let a = above(ai), l = left(li)
            if l < a {
                if out.last != l { out.append(l) }
                li += 1
            } else {
                if out.last != a { out.append(a) }
                ai += 1
                if l == a { li += 1 }
            }
        }
        while ai < aboveN { let v = above(ai); ai += 1; if out.last != v { out.append(v) } }
        while li < leftN { let v = left(li); li += 1; if out.last != v { out.append(v) } }
        return out
    }

    mutating func paletteTokens() {
        var blockHeight = AV1C.blockHeight[miSize], blockWidth = AV1C.blockWidth[miSize]
        var onscreenHeight = min(blockHeight, (f.hdr.miRows - miRow) * 4)
        var onscreenWidth = min(blockWidth, (f.hdr.miCols - miCol) * 4)
        if paletteSizeY > 0 {
            var map = colorMapY
            readColorMap(&map, n: paletteSizeY, cdfs: lay.paletteYColor, blockWidth: blockWidth, blockHeight: blockHeight,
                         onscreenWidth: onscreenWidth, onscreenHeight: onscreenHeight)
            colorMapY = map
        }
        if paletteSizeUV > 0 {
            blockHeight >>= f.subY
            blockWidth >>= f.subX
            onscreenHeight >>= f.subY
            onscreenWidth >>= f.subX
            if blockWidth < 4 { blockWidth += 2; onscreenWidth += 2 }
            if blockHeight < 4 { blockHeight += 2; onscreenHeight += 2 }
            var map = colorMapUV
            readColorMap(&map, n: paletteSizeUV, cdfs: lay.paletteUVColor, blockWidth: blockWidth, blockHeight: blockHeight,
                         onscreenWidth: onscreenWidth, onscreenHeight: onscreenHeight)
            colorMapUV = map
        }
    }

    mutating func readColorMap(_ map: inout [UInt8], n: Int, cdfs: [Int], blockWidth: Int, blockHeight: Int, onscreenWidth: Int, onscreenHeight: Int) {
        let stride = 64
        map[0] = UInt8(sd.ns(n))
        if onscreenHeight + onscreenWidth > 1 {
            for i in 1..<(onscreenHeight + onscreenWidth - 1) {
                var j = min(i, onscreenWidth - 1)
                while j >= max(0, i - onscreenHeight + 1) {
                    let r = i - j, c = j
                    // get_palette_color_context
                    var scores = [0, 0, 0, 0, 0, 0, 0, 0]
                    var order = [0, 1, 2, 3, 4, 5, 6, 7]
                    if c > 0 { scores[Int(map[r * stride + c - 1])] += 2 }
                    if r > 0 && c > 0 { scores[Int(map[(r - 1) * stride + c - 1])] += 1 }
                    if r > 0 { scores[Int(map[(r - 1) * stride + c])] += 2 }
                    for k in 0..<3 {
                        var maxScore = scores[k], maxIdx = k
                        for l in (k + 1)..<max(k + 1, n) where scores[l] > maxScore { maxScore = scores[l]; maxIdx = l }
                        if maxIdx != k {
                            let ms = scores[maxIdx], mo = order[maxIdx]
                            var q = maxIdx
                            while q > k { scores[q] = scores[q - 1]; order[q] = order[q - 1]; q -= 1 }
                            scores[k] = ms
                            order[k] = mo
                        }
                    }
                    let hash = scores[0] * 1 + scores[1] * 2 + scores[2] * 2
                    let ctx = max(0, AV1C.paletteColorContext[min(hash, 8)])
                    let sym = sd.symbol(cdfs[n - 2] + ctx * (n + 1), n)
                    map[r * stride + c] = UInt8(order[sym])
                    j -= 1
                }
            }
        }
        for i in 0..<onscreenHeight {
            for j in onscreenWidth..<max(onscreenWidth, blockWidth) { map[i * stride + j] = map[i * stride + onscreenWidth - 1] }
        }
        for i in onscreenHeight..<max(onscreenHeight, blockHeight) {
            for j in 0..<blockWidth { map[i * stride + j] = map[(onscreenHeight - 1) * stride + j] }
        }
    }

    // MARK: Transform size (5.11.15 – 5.11.17)

    mutating func readBlockTxSize() {
        let bw4 = AV1C.num4x4W[miSize], bh4 = AV1C.num4x4H[miSize]
        if f.hdr.txMode == AV1C.txModeSelect && miSize > AV1C.block4x4 && isInter && skip == 0 && !lossless {
            let maxTx = AV1C.maxTxSizeRect[miSize]
            let txW4 = AV1C.txWidth[maxTx] / 4, txH4 = AV1C.txHeight[maxTx] / 4
            var row = miRow
            while row < miRow + bh4 {
                var col = miCol
                while col < miCol + bw4 {
                    readVarTxSize(row, col, maxTx, 0)
                    col += txW4
                }
                row += txH4
            }
        } else {
            readTxSize(skip == 0 || !isInter)
            for row in miRow..<(miRow + bh4) { for col in miCol..<(miCol + bw4) { interTxSizes[mi(row, col)] = UInt8(txSize) } }
        }
    }

    func aboveTxWidth(_ row: Int, _ col: Int) -> Int {
        if row == miRow {
            if !availU { return 64 }
            let i = mi(row - 1, col)
            if skips[i] != 0 && isInters[i] != 0 { return AV1C.blockWidth[Int(miSizes[i])] }
        }
        return AV1C.txWidth[Int(interTxSizes[mi(row - 1, col)])]
    }

    func leftTxHeight(_ row: Int, _ col: Int) -> Int {
        if col == miCol {
            if !availL { return 64 }
            let i = mi(row, col - 1)
            if skips[i] != 0 && isInters[i] != 0 { return AV1C.blockHeight[Int(miSizes[i])] }
        }
        return AV1C.txHeight[Int(interTxSizes[mi(row, col - 1)])]
    }

    mutating func readTxSize(_ allowSelect: Bool) {
        if lossless { txSize = AV1C.tx4x4; return }
        let maxRect = AV1C.maxTxSizeRect[miSize], maxDepth = AV1C.maxTxDepth[miSize]
        txSize = maxRect
        if miSize > AV1C.block4x4 && allowSelect && f.hdr.txMode == AV1C.txModeSelect {
            let maxW = AV1C.txWidth[maxRect], maxH = AV1C.txHeight[maxRect]
            var aboveW = 0, leftH = 0
            if availU {
                let i = mi(miRow - 1, miCol)
                aboveW = isInters[i] != 0 ? AV1C.blockWidth[Int(miSizes[i])] : aboveTxWidth(miRow, miCol)
            }
            if availL {
                let i = mi(miRow, miCol - 1)
                leftH = isInters[i] != 0 ? AV1C.blockHeight[Int(miSizes[i])] : leftTxHeight(miRow, miCol)
            }
            let ctx = (aboveW >= maxW ? 1 : 0) + (leftH >= maxH ? 1 : 0)
            let depth: Int
            switch maxDepth {
            case 4: depth = sd.symbol(lay.txDepth[3] + ctx * 4, 3)
            case 3: depth = sd.symbol(lay.txDepth[2] + ctx * 4, 3)
            case 2: depth = sd.symbol(lay.txDepth[1] + ctx * 4, 3)
            default: depth = sd.symbol(lay.txDepth[0] + ctx * 3, 2)
            }
            for _ in 0..<depth { txSize = AV1C.splitTxSize[txSize] }
        }
    }

    mutating func readVarTxSize(_ row: Int, _ col: Int, _ txSz: Int, _ depth: Int) {
        if row >= f.hdr.miRows || col >= f.hdr.miCols { return }
        var split = 0
        if txSz != AV1C.tx4x4 && depth != 2 {
            let above = aboveTxWidth(row, col) < AV1C.txWidth[txSz] ? 1 : 0
            let left = leftTxHeight(row, col) < AV1C.txHeight[txSz] ? 1 : 0
            let size = min(64, max(AV1C.blockWidth[miSize], AV1C.blockHeight[miSize]))
            let maxTxSz = AV1C.findTxSize(size, size)
            let ctx = (AV1C.txSizeSqrUp[txSz] != maxTxSz ? 3 : 0) + (5 - 1 - maxTxSz) * 6 + above + left
            split = sd.symbol(lay.txfmSplit + ctx * 3, 2)
        }
        let w4 = AV1C.txWidth[txSz] / 4, h4 = AV1C.txHeight[txSz] / 4
        if split == 1 {
            used(.varTxSplit)
            let sub = AV1C.splitTxSize[txSz]
            let stepW = AV1C.txWidth[sub] / 4, stepH = AV1C.txHeight[sub] / 4
            var i = 0
            while i < h4 {
                var j = 0
                while j < w4 { readVarTxSize(row + i, col + j, sub, depth + 1); j += stepW }
                i += stepH
            }
        } else {
            for i in 0..<h4 {
                for j in 0..<w4 where row + i - miRowStart < miRowsAlloc && col + j - miColStart < miStride { interTxSizes[mi(row + i, col + j)] = UInt8(txSz) }
            }
            txSize = txSz
        }
    }

    // MARK: Intra block copy motion vector (assign_mv with use_intrabc, 5.11.26)

    mutating func assignIntrabcMv() {
        var pred = (stackMv(0, 0, 0), stackMv(0, 0, 1))
        if pred.0 == 0 && pred.1 == 0 { pred = (stackMv(1, 0, 0), stackMv(1, 0, 1)) }
        if pred.0 == 0 && pred.1 == 0 {
            let sb4 = f.sbSize4
            if miRow - sb4 < miRowStart {
                pred = (0, -(sb4 * 4 + 256) * 8)
            } else {
                pred = (-(sb4 * 4 * 8), 0)
            }
        }
        let (diffRow, diffCol) = readMv(ctx: 1)
        mv = (pred.0 + diffRow, pred.1 + diffCol)
        if mv.row & 7 != 0 || mv.col & 7 != 0 { fail(.malformed("fractional intra block copy vector")) }
    }

    /// read_mv_component (5.11.32).
    mutating func readMvComponent(_ ctx: Int, _ comp: Int) -> Int {
        let k = ctx * 2 + comp
        let sign = sd.symbol(lay.mvSign + k * 3, 2)
        let mvClass = sd.symbol(lay.mvClass + k * 12, 11)
        var mag: Int
        if mvClass == 0 {
            let class0Bit = sd.symbol(lay.mvClass0Bit + k * 3, 2)
            let fr = f.hdr.forceIntegerMv ? 3 : sd.symbol(lay.mvClass0Fr + (k * 2 + class0Bit) * 5, 4)
            let hp = f.hdr.allowHighPrecisionMv ? sd.symbol(lay.mvClass0Hp + k * 3, 2) : 1
            mag = ((class0Bit << 3) | (fr << 1) | hp) + 1
        } else {
            var d = 0
            for i in 0..<mvClass { d |= sd.symbol(lay.mvBit + (k * 10 + i) * 3, 2) << i }
            mag = 2 << (mvClass + 2)
            let fr = f.hdr.forceIntegerMv ? 3 : sd.symbol(lay.mvFr + k * 5, 4)
            let hp = f.hdr.allowHighPrecisionMv ? sd.symbol(lay.mvHp + k * 3, 2) : 1
            mag += ((d << 3) | (fr << 1) | hp) + 1
        }
        return sign != 0 ? -mag : mag
    }

    // MARK: Loop restoration coefficients (5.11.57, 5.11.58)

    mutating func readLr(_ r: Int, _ c: Int) {
        if f.hdr.allowIntrabc { return }
        let w = f.sbSize4, hh = f.sbSize4
        for plane in 0..<f.numPlanes where f.hdr.frameRestorationType[plane] != AV1C.restoreNone {
            let sx = plane == 0 ? 0 : f.subX, sy = plane == 0 ? 0 : f.subY
            let unitSize = f.hdr.loopRestorationSize[plane]
            let unitRows = f.lrUnitRows[plane], unitCols = f.lrUnitCols[plane]
            let rowStart = (r * (4 >> sy) + unitSize - 1) / unitSize
            let rowEnd = min(unitRows, ((r + hh) * (4 >> sy) + unitSize - 1) / unitSize)
            let numerator: Int, denominator: Int
            if f.hdr.useSuperres {
                numerator = (4 >> sx) * f.hdr.superresDenom
                denominator = unitSize * 8
            } else {
                numerator = 4 >> sx
                denominator = unitSize
            }
            let colStart = (c * numerator + denominator - 1) / denominator
            let colEnd = min(unitCols, ((c + w) * numerator + denominator - 1) / denominator)
            if rowStart < rowEnd && colStart < colEnd {
                for unitRow in rowStart..<rowEnd { for unitCol in colStart..<colEnd { readLrUnit(plane, unitRow, unitCol) } }
            }
        }
    }

    mutating func readLrUnit(_ plane: Int, _ unitRow: Int, _ unitCol: Int) {
        var u = AV1LRUnit()
        switch f.hdr.frameRestorationType[plane] {
        case AV1C.restoreWiener: u.type = sd.symbol(lay.useWiener, 2) == 1 ? AV1C.restoreWiener : AV1C.restoreNone
        case AV1C.restoreSgrproj: u.type = sd.symbol(lay.useSgrproj, 2) == 1 ? AV1C.restoreSgrproj : AV1C.restoreNone
        default: u.type = sd.symbol(lay.restorationType, 3)
        }
        if u.type == AV1C.restoreWiener { used(.wiener) }
        if u.type == AV1C.restoreSgrproj { used(.sgrproj) }
        let wMin = [-5, -23, -17], wMax = [10, 8, 46], wK = [1, 2, 3]
        if u.type == AV1C.restoreWiener {
            for pass in 0..<2 {
                let first = plane > 0 ? 1 : 0
                if plane > 0 { u.wiener[pass * 3] = 0 }
                for j in first..<3 {
                    let v = decodeSignedSubexpBool(wMin[j], wMax[j] + 1, wK[j], refLrWiener[plane * 2 + pass][j])
                    u.wiener[pass * 3 + j] = v
                    refLrWiener[plane * 2 + pass][j] = v
                }
            }
        } else if u.type == AV1C.restoreSgrproj {
            u.sgrSet = sd.literal(4)
            let xMin = [-96, -32], xMax = [31, 95]
            for i in 0..<2 {
                let radius = AV1C.sgrParams[u.sgrSet * 4 + i * 2]
                var v: Int
                if radius != 0 {
                    v = decodeSignedSubexpBool(xMin[i], xMax[i] + 1, 4, refSgrXqd[plane][i])
                } else {
                    v = 0
                    if i == 1 { v = clip3(xMin[i], xMax[i], (1 << 7) - refSgrXqd[plane][0]) }
                }
                u.xqd[i] = v
                refSgrXqd[plane][i] = v
            }
        }
        lrUnits.append((plane, unitRow * f.lrUnitCols[plane] + unitCol, u))
    }

    mutating func decodeSignedSubexpBool(_ low: Int, _ high: Int, _ k: Int, _ r: Int) -> Int {
        let mx = high - low, rr = r - low
        // decode_subexp_bool
        var i = 0, mk = 0
        var v = 0
        while true {
            let b2 = i != 0 ? k + i - 1 : k
            let a = 1 << b2
            if mx <= mk + 3 * a {
                v = sd.ns(mx - mk) + mk
                break
            } else if sd.literal(1) == 1 {
                i += 1
                mk += a
            } else {
                v = sd.literal(b2) + mk
                break
            }
        }
        func inverseRecenter(_ r: Int, _ v: Int) -> Int {
            if v > 2 * r { return v }
            if v & 1 != 0 { return r - ((v + 1) >> 1) }
            return r + (v >> 1)
        }
        let x = (rr << 1) <= mx ? inverseRecenter(rr, v) : mx - 1 - inverseRecenter(mx - 1 - rr, v)
        return x + low
    }

    /// The mode info the frame keeps after the tile.
    func modeInfo() -> AV1TileModeInfo {
        AV1TileModeInfo(miRow0: miRowStart, miCol0: miColStart, rows: miRowsAlloc, cols: miStride, miSize: miSizes, skip: skips, segmentId: segmentIds,
                        isInter: isInters, lfTxSize: lfTxSizes, deltaLF: deltaLFs, cdefIdx: cdefIdx, cdefCols: cdefCols)
    }
}
