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

/// Samples of one plane over a region (a tile, or the frame).
struct AV1PlaneBuffer: Sendable {
    let x0: Int, y0: Int
    let width: Int, height: Int
    var px: [UInt16]

    init(x0: Int, y0: Int, width: Int, height: Int, fill: UInt16 = 0) {
        self.x0 = x0
        self.y0 = y0
        self.width = width
        self.height = height
        px = [UInt16](repeating: fill, count: width * height)
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
    let f: AV1FrameInfo
    let lay = AV1CDFLayout.shared
    var sd: AV1SymbolDecoder
    let miRowStart: Int, miRowEnd: Int, miColStart: Int, miColEnd: Int
    // Tile-local mode info (origin miRowStart / miColStart, stride miStride).
    let miStride: Int, miRowsAlloc: Int
    var miSizes: [UInt8], yModes: [UInt8], uvModes: [UInt8], isInters: [UInt8], skips: [UInt8], segmentIds: [UInt8]
    var interTxSizes: [UInt8], written: [UInt8], txTypes: [UInt8]
    var mvs: [Int32]
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
    var mv = (row: 0, col: 0)
    var maxLumaW = 0, maxLumaH = 0
    // Coefficients of the current transform block.
    var quant = [Int32](repeating: 0, count: 1024)
    var planeTxType = 0
    var tx = AV1InverseTransform()

    init(_ f: AV1FrameInfo, data: [UInt8], start: Int, size: Int, tileRow: Int, tileCol: Int) throws(AV1DecodeError) {
        self.f = f
        let h = f.hdr
        miRowStart = h.miRowStarts[tileRow]
        miRowEnd = h.miRowStarts[tileRow + 1]
        miColStart = h.miColStarts[tileCol]
        miColEnd = h.miColStarts[tileCol + 1]
        let sb4 = f.sbSize4
        let colsAlloc = ((miColEnd - miColStart + sb4 - 1) / sb4) * sb4
        let rowsAlloc = ((miRowEnd - miRowStart + sb4 - 1) / sb4) * sb4
        miStride = colsAlloc
        miRowsAlloc = rowsAlloc
        let n = colsAlloc * rowsAlloc
        miSizes = [UInt8](repeating: 0, count: n)
        yModes = miSizes; uvModes = miSizes; isInters = miSizes; skips = miSizes; segmentIds = miSizes
        interTxSizes = miSizes; written = miSizes; txTypes = miSizes
        mvs = h.allowIntrabc ? [Int32](repeating: 0, count: 2 * n) : []
        deltaLFs = h.deltaLfPresent ? [Int8](repeating: 0, count: 4 * n) : []
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
            pls.append(AV1PlaneBuffer(x0: (miColStart * 4) >> sx, y0: (miRowStart * 4) >> sy, width: (colsAlloc * 4) >> sx, height: (rowsAlloc * 4) >> sy))
        }
        planes = pls
        let frameCols4 = ((h.miColStarts.last ?? 0) + 2 * sb4), frameRows4 = ((h.miRowStarts.last ?? 0) + 2 * sb4)
        aboveLevel = Array(repeating: [UInt8](repeating: 0, count: frameCols4), count: 3)
        aboveDc = aboveLevel
        leftLevel = Array(repeating: [UInt8](repeating: 0, count: frameRows4), count: 3)
        leftDc = leftLevel
        abovePalSize = Array(repeating: [UInt8](repeating: 0, count: frameCols4), count: 2)
        abovePal = Array(repeating: [UInt16](repeating: 0, count: frameCols4 * 8), count: 2)
        leftPalSize = Array(repeating: [UInt8](repeating: 0, count: frameRows4), count: 2)
        leftPal = Array(repeating: [UInt16](repeating: 0, count: frameRows4 * 8), count: 2)
        bdStride = sb4 + 3
        blockDecoded = Array(repeating: [UInt8](repeating: 0, count: bdStride * bdStride), count: 3)
        sd = try AV1SymbolDecoder(data, start: start, size: size, cdf: lay.defaults[f.cdfIndex], disableUpdate: h.disableCdfUpdate)
        currentQIndex = h.baseQIdx
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
            let sbW4 = (miColEnd - c) >> sx, sbH4 = (miRowEnd - r) >> sy
            for y in -1...(sb4 >> sy) {
                for x in -1...(sb4 >> sx) {
                    let v: UInt8 = (y < 0 && x < sbW4) || (x < 0 && y < sbH4) ? 1 : 0
                    blockDecoded[plane][(y + 1) * bdStride + x + 1] = v
                }
            }
            blockDecoded[plane][((sb4 >> sy) + 1) * bdStride] = 0
        }
    }

    @inline(__always) func decoded(_ plane: Int, _ y: Int, _ x: Int) -> Bool { blockDecoded[plane][(y + 1) * bdStride + x + 1] != 0 }

    // MARK: decode_partition

    mutating func decodePartition(_ r: Int, _ c: Int, _ bSize: Int) {
        let h = f.hdr
        if r >= h.miRows || c >= h.miCols || error != nil { return }
        availU = isInside(r - 1, c)
        availL = isInside(r, c - 1)
        let num4x4 = AV1C.num4x4W[bSize]
        let half = num4x4 >> 1, quarter = half >> 1
        let hasRows = r + half < h.miRows, hasCols = c + half < h.miCols
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
            for k in 0..<4 where k < 3 || r + quarter * 3 < h.miRows { decodeBlock(r + quarter * k, c, subSize) }
        default:
            for k in 0..<4 where k < 3 || c + quarter * 3 < h.miCols { decodeBlock(r, c + quarter * k, subSize) }
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
        intraFrameModeInfo()
        paletteTokens()
        readBlockTxSize()
        if skip != 0 { resetBlockContext(bw4, bh4) }
        for y in 0..<bh4 {
            for x in 0..<bw4 {
                let i = mi(r + y, c + x)
                yModes[i] = UInt8(yMode)
                if hasChroma { uvModes[i] = UInt8(uvMode) }
                written[i] = 1
                if isInter {
                    mvs[2 * i] = Int32(mv.row)
                    mvs[2 * i + 1] = Int32(mv.col)
                }
            }
        }
        computePrediction()
        residual()
        for y in 0..<bh4 {
            for x in 0..<bw4 {
                let i = mi(r + y, c + x)
                isInters[i] = isInter ? 1 : 0
                skips[i] = UInt8(skip)
                miSizes[i] = UInt8(bSize)
                segmentIds[i] = UInt8(segmentId)
                if !deltaLFs.isEmpty { for k in 0..<4 { deltaLFs[4 * i + k] = Int8(deltaLF[k]) } }
            }
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
            for i in (miCol >> sx)..<((miCol + bw4) >> sx) { aboveLevel[plane][i] = 0; aboveDc[plane][i] = 0 }
            for i in (miRow >> sy)..<((miRow + bh4) >> sy) { leftLevel[plane][i] = 0; leftDc[plane][i] = 0 }
        }
    }

    // MARK: intra_frame_mode_info

    mutating func intraFrameModeInfo() {
        let h = f.hdr
        skip = 0
        if h.segIdPreSkip { intraSegmentId() }
        if h.segIdPreSkip && h.segFeatureActive(segmentId, 6) {
            skip = 1
        } else {
            var ctx = 0
            if availU { ctx += Int(skips[mi(miRow - 1, miCol)]) }
            if availL { ctx += Int(skips[mi(miRow, miCol - 1)]) }
            skip = sd.symbol(lay.skip + ctx * 3, 2)
        }
        if !h.segIdPreSkip { intraSegmentId() }
        readCdef()
        readDeltaQIndex()
        readDeltaLf()
        readDeltas = false
        useIntrabc = h.allowIntrabc ? sd.symbol(lay.intrabc, 2) == 1 : false
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
            findMvStackAndAssign()
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
            if miSize >= AV1C.block8x8 && AV1C.blockWidth[miSize] <= 64 && AV1C.blockHeight[miSize] <= 64 && h.allowScreenContentTools {
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
        let h = f.hdr
        if h.segmentationEnabled {
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
                segmentId = Self.negDeinterleave(diff, pred, h.lastActiveSegId + 1)
                if segmentId < 0 || segmentId > 7 { fail(.malformed("segment_id")); segmentId = 0 }
            }
        } else {
            segmentId = 0
        }
        lossless = h.losslessArray[segmentId]
        if lossless { used(.lossless) }
        if h.segmentationEnabled && segmentId != 0 { used(.segmentation) }
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
        let h = f.hdr
        if skip != 0 || h.codedLossless || !f.seq.enableCdef || h.allowIntrabc { return }
        let r = miRow & ~15, c = miCol & ~15
        let idx = ((r - miRowStart) / 16) * cdefCols + (c - miColStart) / 16
        if cdefIdx[idx] == -1 {
            cdefIdx[idx] = Int8(sd.literal(h.cdefBits))
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
        let h = f.hdr
        if miSize == f.sbSize && skip != 0 { return }
        guard readDeltas && h.deltaLfPresent else { return }
        let count = h.deltaLfMulti ? (f.numPlanes > 1 ? 4 : 2) : 1
        used(.deltaLF)
        for i in 0..<count {
            let base = h.deltaLfMulti ? lay.deltaLFMulti + i * 5 : lay.deltaLF
            var abs = sd.symbol(base, 4)
            if abs == 3 {
                let n = sd.literal(3) + 1
                abs = sd.literal(n) + (1 << n) + 1
            }
            if abs != 0 {
                let sign = sd.literal(1)
                let reduced = sign != 0 ? -abs : abs
                deltaLF[i] = clip3(-63, 63, deltaLF[i] + (reduced << h.deltaLfRes))
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
        let h = f.hdr
        var blockHeight = AV1C.blockHeight[miSize], blockWidth = AV1C.blockWidth[miSize]
        var onscreenHeight = min(blockHeight, (h.miRows - miRow) * 4)
        var onscreenWidth = min(blockWidth, (h.miCols - miCol) * 4)
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
        let h = f.hdr
        let bw4 = AV1C.num4x4W[miSize], bh4 = AV1C.num4x4H[miSize]
        if h.txMode == AV1C.txModeSelect && miSize > AV1C.block4x4 && isInter && skip == 0 && !lossless {
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
        let h = f.hdr
        if row >= h.miRows || col >= h.miCols { return }
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

    // MARK: Intra block copy motion vector (7.10.2 for an intra frame, 5.11.26, 5.11.32)

    mutating func findMvStackAndAssign() {
        let bw4 = AV1C.num4x4W[miSize], bh4 = AV1C.num4x4H[miSize]
        var stack: [(row: Int, col: Int, weight: Int)] = []
        func lower(_ v: Int) -> Int {
            // force_integer_mv: whole samples, rounding half away from zero.
            let a = (abs(v) + 3) >> 3
            return v > 0 ? a << 3 : -(a << 3)
        }
        func add(_ mvRow: Int, _ mvCol: Int, _ weight: Int) {
            let i = mi(mvRow, mvCol)
            guard isInters[i] != 0 else { return }
            let cand = (row: lower(Int(mvs[2 * i])), col: lower(Int(mvs[2 * i + 1])))
            if let k = stack.firstIndex(where: { $0.row == cand.row && $0.col == cand.col }) {
                stack[k].weight += weight
            } else if stack.count < 8 {
                stack.append((cand.row, cand.col, weight))
            }
        }
        func scanRow(_ deltaRowIn: Int) {
            var deltaRow = deltaRowIn, deltaCol = 0
            let end4 = min(min(bw4, f.hdr.miCols - miCol), 16)
            let useStep16 = bw4 >= 16
            if abs(deltaRow) > 1 {
                deltaRow += miRow & 1
                deltaCol = 1 - (miCol & 1)
            }
            var i = 0
            while i < end4 {
                let r = miRow + deltaRow, c = miCol + deltaCol + i
                if !isInside(r, c) { break }
                var len = min(bw4, AV1C.num4x4W[Int(miSizes[mi(r, c)])])
                if abs(deltaRow) > 1 { len = max(2, len) }
                if useStep16 { len = max(4, len) }
                add(r, c, len * 2)
                i += len
            }
        }
        func scanCol(_ deltaColIn: Int) {
            var deltaCol = deltaColIn, deltaRow = 0
            let end4 = min(min(bh4, f.hdr.miRows - miRow), 16)
            let useStep16 = bh4 >= 16
            if abs(deltaCol) > 1 {
                deltaRow = 1 - (miRow & 1)
                deltaCol += miCol & 1
            }
            var i = 0
            while i < end4 {
                let r = miRow + deltaRow + i, c = miCol + deltaCol
                if !isInside(r, c) { break }
                var len = min(bh4, AV1C.num4x4H[Int(miSizes[mi(r, c)])])
                if abs(deltaCol) > 1 { len = max(2, len) }
                if useStep16 { len = max(4, len) }
                add(r, c, len * 2)
                i += len
            }
        }
        func scanPoint(_ deltaRow: Int, _ deltaCol: Int) {
            let r = miRow + deltaRow, c = miCol + deltaCol
            if isInside(r, c) && written[mi(r, c)] != 0 { add(r, c, 4) }
        }
        scanRow(-1)
        scanCol(-1)
        if max(bw4, bh4) <= 16 { scanPoint(-1, bw4) }
        let numNearest = stack.count
        for k in 0..<numNearest { stack[k].weight += 640 }
        scanPoint(-1, -1)
        scanRow(-3)
        scanCol(-3)
        if bh4 > 1 { scanRow(-5) }
        if bw4 > 1 { scanCol(-5) }
        func sortRange(_ start: Int, _ endIn: Int) {
            var end = endIn
            while end > start {
                var newEnd = start
                var idx = start + 1
                while idx < end {
                    if stack[idx - 1].weight < stack[idx].weight {
                        stack.swapAt(idx - 1, idx)
                        newEnd = idx
                    }
                    idx += 1
                }
                end = newEnd
            }
        }
        sortRange(0, numNearest)
        sortRange(numNearest, stack.count)
        // Context and clamping (7.10.2.14) for the candidates found.
        let bw = AV1C.blockWidth[miSize], bh = AV1C.blockHeight[miSize]
        func clampRow(_ v: Int) -> Int {
            let top = -((miRow * 4) * 8), bottom = ((f.hdr.miRows - bh4 - miRow) * 4) * 8
            return clip3(top - (128 + bh * 8), bottom + (128 + bh * 8), v)
        }
        func clampCol(_ v: Int) -> Int {
            let left = -((miCol * 4) * 8), right = ((f.hdr.miCols - bw4 - miCol) * 4) * 8
            return clip3(left - (128 + bw * 8), right + (128 + bw * 8), v)
        }
        var ref: [(Int, Int)] = stack.map { (clampRow($0.row), clampCol($0.col)) }
        while ref.count < 2 { ref.append((0, 0)) }   // global motion: zero in an intra frame
        // assign_mv( 0 ) with use_intrabc.
        var pred = ref[0]
        if pred.0 == 0 && pred.1 == 0 { pred = ref[1] }
        if pred.0 == 0 && pred.1 == 0 {
            let sb4 = f.sbSize4
            if miRow - sb4 < miRowStart {
                pred = (0, -(sb4 * 4 + 256) * 8)
            } else {
                pred = (-(sb4 * 4 * 8), 0)
            }
        }
        // read_mv( 0 ), MvCtx = MV_INTRABC_CONTEXT.
        let ctx = 1
        let joint = sd.symbol(lay.mvJoint + ctx * 5, 4)
        var diffRow = 0, diffCol = 0
        if joint == 2 || joint == 3 { diffRow = readMvComponent(ctx, 0) }
        if joint == 1 || joint == 3 { diffCol = readMvComponent(ctx, 1) }
        mv = (pred.0 + diffRow, pred.1 + diffCol)
        if mv.row & 7 != 0 || mv.col & 7 != 0 { fail(.malformed("fractional intra block copy vector")) }
    }

    mutating func readMvComponent(_ ctx: Int, _ comp: Int) -> Int {
        let k = ctx * 2 + comp
        let sign = sd.symbol(lay.mvSign + k * 3, 2)
        let mvClass = sd.symbol(lay.mvClass + k * 12, 11)
        var mag: Int
        if mvClass == 0 {
            let class0Bit = sd.symbol(lay.mvClass0Bit + k * 3, 2)
            // force_integer_mv: fr = 3; allow_high_precision_mv = 0: hp = 1.
            mag = ((class0Bit << 3) | (3 << 1) | 1) + 1
        } else {
            var d = 0
            for i in 0..<mvClass { d |= sd.symbol(lay.mvBit + (k * 10 + i) * 3, 2) << i }
            mag = 2 << (mvClass + 2)
            mag += ((d << 3) | (3 << 1) | 1) + 1
        }
        return sign != 0 ? -mag : mag
    }

    // MARK: Loop restoration coefficients (5.11.57, 5.11.58)

    mutating func readLr(_ r: Int, _ c: Int) {
        let h = f.hdr
        if h.allowIntrabc { return }
        let w = f.sbSize4, hh = f.sbSize4
        for plane in 0..<f.numPlanes where h.frameRestorationType[plane] != AV1C.restoreNone {
            let sx = plane == 0 ? 0 : f.subX, sy = plane == 0 ? 0 : f.subY
            let unitSize = h.loopRestorationSize[plane]
            let unitRows = f.lrUnitRows[plane], unitCols = f.lrUnitCols[plane]
            let rowStart = (r * (4 >> sy) + unitSize - 1) / unitSize
            let rowEnd = min(unitRows, ((r + hh) * (4 >> sy) + unitSize - 1) / unitSize)
            let numerator: Int, denominator: Int
            if h.useSuperres {
                numerator = (4 >> sx) * h.superresDenom
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
