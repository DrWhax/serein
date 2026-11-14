// Video frames: parsing and reconstruction apart. A tile is parsed first (symbols, mode info,
// coefficients; no samples), recording per block what prediction and reconstruction read of
// the block's state, per transform block its type, edges and coefficients. Reconstruction then
// replays the records in two passes:
//
//  1. Inter blocks (not interintra) read only reference frames and write only their own
//     area, so they run by superblock rows in parallel, each row into its own buffer.
//  2. Every other block (intra, interintra, intra block copy) reads the samples of blocks
//     decoded before it, so these run after, in decoding order, on the assembled tile.
//
// Mode info is final once the tile is parsed (every position is written once, by its own
// block), so what a block reads of its neighbours is the same as when decoding in one pass;
// the availability of above-right / below-left samples, which depends on decoding order, is
// recorded while parsing.

import CodecCore
import Dispatch
import Synchronization

struct AV1BlockRecord: Sendable {
    var miRow: Int32, miCol: Int32
    var mvRow: Int32, mvCol: Int32, mv1Row: Int32, mv1Col: Int32
    /// The block's first transform block record.
    var txStart: Int32
    /// Its palette (colours, then colour maps) and warp samples in sideData; -1: none.
    var side: Int32
    var flags: UInt16
    var miSize: UInt8, segmentId: UInt8, yMode: UInt8, uvMode: UInt8
    var angleDeltaY: Int8, angleDeltaUV: Int8, filterIntraMode: UInt8, cflAlphaU: Int8, cflAlphaV: Int8
    var paletteSizeY: UInt8, paletteSizeUV: UInt8, txSize: UInt8, currentQIndex: UInt8
    var refFrame0: Int8, refFrame1: Int8
    var interintraMode: UInt8, wedgeIndex: UInt8, wedgeSign: UInt8, maskType: UInt8, compoundType: UInt8, motionMode: UInt8
    var numSamples: UInt8, iiEdges: UInt8

    static let hasChroma: UInt16 = 1, availU: UInt16 = 2, availL: UInt16 = 4, availUChroma: UInt16 = 8, availLChroma: UInt16 = 16
    static let skip: UInt16 = 32, lossless: UInt16 = 64, isInter: UInt16 = 128, useIntrabc: UInt16 = 256, useFilterIntra: UInt16 = 512
    static let interintra: UInt16 = 1024, wedgeInterintra: UInt16 = 2048

    /// Pass 1: an inter block whose prediction reads no samples of the current frame.
    var independent: Bool { flags & (Self.isInter | Self.useIntrabc) == Self.isInter && refFrame1 != Int8(AV1Ref.intra) }
}

struct AV1TxRecord: Sendable {
    var coefStart: Int32
    /// Nonzero coefficients ((position, value) pairs from coefStart); 0: nothing to add.
    var coefCount: Int16
    var txType: UInt8
    /// Intra prediction: bit 0 the above-right samples are decoded, bit 1 the below-left.
    var edges: UInt8
}

extension AV1TileDecoder {
    /// While parsing: the current block, before its transform blocks.
    mutating func recordBlock() {
        var flags: UInt16 = 0
        func set(_ b: Bool, _ v: UInt16) { if b { flags |= v } }
        set(hasChroma, AV1BlockRecord.hasChroma); set(availU, AV1BlockRecord.availU); set(availL, AV1BlockRecord.availL)
        set(availUChroma, AV1BlockRecord.availUChroma); set(availLChroma, AV1BlockRecord.availLChroma)
        set(skip != 0, AV1BlockRecord.skip); set(lossless, AV1BlockRecord.lossless); set(isInter, AV1BlockRecord.isInter)
        set(useIntrabc, AV1BlockRecord.useIntrabc); set(useFilterIntra, AV1BlockRecord.useFilterIntra)
        set(interintra, AV1BlockRecord.interintra); set(wedgeInterintra, AV1BlockRecord.wedgeInterintra)
        var side: Int32 = -1
        if paletteSizeY > 0 || paletteSizeUV > 0 || (isInter && motionMode == AV1Inter.localWarp) {
            side = Int32(sideData.count)
            if paletteSizeY > 0 || paletteSizeUV > 0 {
                for k in 0..<8 { sideData.append(Int32(paletteY[k])) }
                for k in 0..<8 { sideData.append(Int32(paletteU[k])) }
                for k in 0..<8 { sideData.append(Int32(paletteV[k])) }
                if paletteSizeY > 0 { for i in 0..<(AV1C.blockHeight[miSize] * 64) { sideData.append(Int32(colorMapY[i])) } }
                if paletteSizeUV > 0 { for i in 0..<(min(64, (AV1C.blockHeight[miSize] >> f.subY) + 2) * 64) { sideData.append(Int32(colorMapUV[i])) } }
            }
            if isInter && motionMode == AV1Inter.localWarp {
                for i in 0..<(4 * numSamples) { sideData.append(Int32(candList[i])) }
            }
        }
        var edges: UInt8 = 0
        if isInter && refFrame.1 == AV1Ref.intra {
            let sbMask = f.sbMask
            let subBlockMiRow = miRow & sbMask, subBlockMiCol = miCol & sbMask
            for plane in 0..<(hasChroma ? 3 : 1) {
                let sx = plane > 0 ? f.subX : 0, sy = plane > 0 ? f.subY : 0
                let planeSz = AV1C.planeResidualSize(miSize, sx, sy)
                let num4x4W = AV1C.num4x4W[planeSz], num4x4H = AV1C.num4x4H[planeSz]
                if decoded(plane, (subBlockMiRow >> sy) - 1, (subBlockMiCol >> sx) + num4x4W) { edges |= 1 << (2 * plane) }
                if decoded(plane, (subBlockMiRow >> sy) + num4x4H, (subBlockMiCol >> sx) - 1) { edges |= 2 << (2 * plane) }
            }
        }
        blockRecords.append(AV1BlockRecord(
            miRow: Int32(miRow), miCol: Int32(miCol), mvRow: Int32(mv.row), mvCol: Int32(mv.col), mv1Row: Int32(mv1.row), mv1Col: Int32(mv1.col),
            txStart: Int32(txRecords.count), side: side, flags: flags,
            miSize: UInt8(miSize), segmentId: UInt8(segmentId), yMode: UInt8(yMode), uvMode: UInt8(uvMode),
            angleDeltaY: Int8(angleDeltaY), angleDeltaUV: Int8(angleDeltaUV), filterIntraMode: UInt8(filterIntraMode),
            cflAlphaU: Int8(cflAlphaU), cflAlphaV: Int8(cflAlphaV),
            paletteSizeY: UInt8(paletteSizeY), paletteSizeUV: UInt8(paletteSizeUV), txSize: UInt8(txSize), currentQIndex: UInt8(currentQIndex),
            refFrame0: Int8(refFrame.0), refFrame1: Int8(refFrame.1),
            interintraMode: UInt8(interintraMode), wedgeIndex: UInt8(wedgeIndex), wedgeSign: UInt8(wedgeSign), maskType: UInt8(maskType),
            compoundType: UInt8(compoundType), motionMode: UInt8(motionMode), numSamples: UInt8(numSamples), iiEdges: edges))
    }

    /// The block state of record `k`, then its prediction and reconstruction.
    mutating func replay(_ k: Int) {
        let r = blockRecords[k]
        miRow = Int(r.miRow); miCol = Int(r.miCol); miSize = Int(r.miSize)
        let fl = r.flags
        hasChroma = fl & AV1BlockRecord.hasChroma != 0
        availU = fl & AV1BlockRecord.availU != 0; availL = fl & AV1BlockRecord.availL != 0
        availUChroma = fl & AV1BlockRecord.availUChroma != 0; availLChroma = fl & AV1BlockRecord.availLChroma != 0
        skip = fl & AV1BlockRecord.skip != 0 ? 1 : 0
        lossless = fl & AV1BlockRecord.lossless != 0
        isInter = fl & AV1BlockRecord.isInter != 0
        useIntrabc = fl & AV1BlockRecord.useIntrabc != 0
        useFilterIntra = fl & AV1BlockRecord.useFilterIntra != 0
        interintra = fl & AV1BlockRecord.interintra != 0
        wedgeInterintra = fl & AV1BlockRecord.wedgeInterintra != 0
        segmentId = Int(r.segmentId); yMode = Int(r.yMode); uvMode = Int(r.uvMode)
        angleDeltaY = Int(r.angleDeltaY); angleDeltaUV = Int(r.angleDeltaUV); filterIntraMode = Int(r.filterIntraMode)
        cflAlphaU = Int(r.cflAlphaU); cflAlphaV = Int(r.cflAlphaV)
        paletteSizeY = Int(r.paletteSizeY); paletteSizeUV = Int(r.paletteSizeUV)
        txSize = Int(r.txSize); currentQIndex = Int(r.currentQIndex)
        mv = (Int(r.mvRow), Int(r.mvCol)); mv1 = (Int(r.mv1Row), Int(r.mv1Col))
        refFrame = (Int(r.refFrame0), Int(r.refFrame1))
        interintraMode = Int(r.interintraMode); wedgeIndex = Int(r.wedgeIndex); wedgeSign = Int(r.wedgeSign); maskType = Int(r.maskType)
        compoundType = Int(r.compoundType); motionMode = Int(r.motionMode)
        numSamples = Int(r.numSamples)
        iiEdges = r.iiEdges
        if r.side >= 0 {
            var o = Int(r.side)
            if paletteSizeY > 0 || paletteSizeUV > 0 {
                for k in 0..<8 { paletteY[k] = Int(sideData[o + k]); paletteU[k] = Int(sideData[o + 8 + k]); paletteV[k] = Int(sideData[o + 16 + k]) }
                o += 24
                if paletteSizeY > 0 {
                    let n = AV1C.blockHeight[miSize] * 64
                    for i in 0..<n { colorMapY[i] = UInt8(truncatingIfNeeded: sideData[o + i]) }
                    o += n
                }
                if paletteSizeUV > 0 {
                    let n = min(64, (AV1C.blockHeight[miSize] >> f.subY) + 2) * 64
                    for i in 0..<n { colorMapUV[i] = UInt8(truncatingIfNeeded: sideData[o + i]) }
                    o += n
                }
            }
            if isInter && motionMode == AV1Inter.localWarp {
                for i in 0..<(4 * numSamples) { candList[i] = Int(sideData[o + i]) }
            }
        }
        txCursor = Int(r.txStart)
        computePrediction()
        residual()
    }

    /// transform_block while replaying: intra prediction with the recorded edges, then the
    /// recorded coefficients.
    mutating func replayTransformBlock(_ plane: Int, _ startX: Int, _ startY: Int, _ txSz: Int, _ x: Int, _ y: Int) {
        let t = txRecords[txCursor]
        txCursor += 1
        if !isInter {
            let stepX = AV1C.txWidth[txSz] >> 2, stepY = AV1C.txHeight[txSz] >> 2
            if (plane == 0 && paletteSizeY > 0) || (plane != 0 && paletteSizeUV > 0) {
                predictPalette(plane, startX, startY, x, y, txSz)
            } else {
                let isCfl = plane > 0 && uvMode == AV1C.uvCflPred
                let mode = plane == 0 ? yMode : (isCfl ? AV1C.dcPred : uvMode)
                predictIntra(plane, startX, startY, haveLeft: (plane == 0 ? availL : availLChroma) || x > 0,
                             haveAbove: (plane == 0 ? availU : availUChroma) || y > 0, haveAboveRight: t.edges & 1 != 0,
                             haveBelowLeft: t.edges & 2 != 0, mode: mode, log2W: AV1C.txWidthLog2[txSz], log2H: AV1C.txHeightLog2[txSz])
                if isCfl { predictCfl(plane, startX, startY, txSz) }
            }
            if plane == 0 {
                maxLumaW = startX + stepX * 4
                maxLumaH = startY + stepY * 4
            }
        }
        guard t.coefCount > 0 else { return }
        let s = Int(t.coefStart), n = Int(t.coefCount)
        for i in 0..<n { quant[Int(coefData[s + 2 * i])] = coefData[s + 2 * i + 1] }
        planeTxType = Int(t.txType)
        reconstruct(plane, startX, startY, txSz)
        for i in 0..<n { quant[Int(coefData[s + 2 * i])] = 0 }
    }

    /// Ready to replay into `planes` (zeroed coefficients, fresh tool counts).
    mutating func beginReplay() {
        recording = false
        replaying = true
        quant = [Int32](repeating: 0, count: 1024)
        stats = [Int](repeating: 0, count: AV1Tool.allCases.count)
        interStats = [Int](repeating: 0, count: AV1InterTool.allCases.count)
        error = nil
    }
}

/// A band's bottom sample rows as the band below reads them (its halo), and how many of the
/// band's superblocks are final.
final class AV1BandEdge: Sendable {
    let rows: Mutex<[[UInt16]]>
    /// Superblocks of the band whose samples are final; -1 until the band has published its
    /// rows after pass 1.
    let done = Atomic<Int>(-1)

    init(planes: Int) { rows = Mutex(Array(repeating: [], count: planes)) }

    func wait(for count: Int) {
        while done.load(ordering: .acquiring) < count {}
    }
}

enum AV1Replay {
    /// Reconstructs parsed tiles by superblock rows ("bands") of every tile in parallel, each
    /// into its own buffer: first its inter blocks (pass 1), then the rest in decoding order
    /// (pass 2) as a wavefront — a band's superblock waits for the band above to have
    /// finished up to the superblock above-right of it, whose bottom row it copies into the
    /// row above its buffer (intra prediction reads one row above a block). Frames with
    /// intra block copy, which reads anywhere above, run pass 2 on the whole tile instead.
    static func reconstruct(_ parsed: [AV1TileDecoder]) throws(AV1DecodeError) -> [AV1TileDecoder] {
        struct Band: Sendable { let tile: Int, row: Int, lo: Int, hi: Int, above: Int? }
        var bands: [Band] = []
        var bandsOf = [[Int]](repeating: [], count: parsed.count)
        for (ti, t) in parsed.enumerated() where !t.f.hdr.allowIntrabc {
            let sb4 = t.f.sbSize4
            let rows = (t.miRowEnd - t.miRowStart + sb4 - 1) / sb4
            var k = 0
            for row in 0..<rows {
                let lo = k
                let end = Int32(t.miRowStart + (row + 1) * sb4)
                while k < t.blockRecords.count && t.blockRecords[k].miRow < end { k += 1 }
                let above = row > 0 ? bands.count - 1 : nil
                bandsOf[ti].append(bands.count)
                bands.append(Band(tile: ti, row: row, lo: lo, hi: k, above: above))
            }
        }
        var tiles = parsed
        if !bands.isEmpty {
            typealias Output = (planes: [[UInt16]], stats: [Int], interStats: [Int], error: AV1DecodeError?)
            let edges = bands.map { AV1BandEdge(planes: parsed[$0.tile].planes.count) }
            let results = Mutex<[Output?]>(Array(repeating: nil, count: bands.count))
            let jobs = bands
            DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
                let b = jobs[i]
                var w = parsed[b.tile]
                w.beginReplay()
                let f = w.f
                let sb4 = f.sbSize4
                // The band's rows, with one row above it.
                var pls: [AV1PlaneBuffer] = []
                for p in 0..<f.numPlanes {
                    let sy = p == 0 ? 0 : f.subY
                    let src = w.planes[p]
                    let y0 = ((w.miRowStart + b.row * sb4) * 4) >> sy
                    let y1 = min(src.y0 + src.height, ((w.miRowStart + (b.row + 1) * sb4) * 4) >> sy)
                    pls.append(AV1PlaneBuffer(x0: src.x0, y0: y0 - 1, width: src.width, height: y1 - y0 + 1))
                }
                w.planes = pls
                for k in b.lo..<b.hi where w.blockRecords[k].independent { w.replay(k) }
                let edge = edges[i]
                edge.rows.withLock { rows in
                    for p in 0..<pls.count {
                        let pl = w.planes[p]
                        let last = (pl.height - 1) * pl.width
                        rows[p] = Array(pl.px[last..<(last + pl.width)])
                    }
                }
                edge.done.store(0, ordering: .releasing)
                // Pass 2, superblock by superblock.
                let sbCols = (w.miColEnd - w.miColStart + sb4 - 1) / sb4
                var k = b.lo
                var halo = 0   // superblocks of the row above copied
                for sb in 0..<sbCols {
                    let end = Int32(w.miColStart + (sb + 1) * sb4)
                    let start = k
                    var dependent = false
                    while k < b.hi && w.blockRecords[k].miCol < end {
                        if !w.blockRecords[k].independent { dependent = true }
                        k += 1
                    }
                    if dependent {
                        if let a = b.above {
                            let need = min(sbCols, sb + 2)
                            if halo < need {
                                edges[a].wait(for: need)
                                edges[a].rows.withLock { rows in
                                    for p in 0..<w.planes.count {
                                        let sx = p == 0 ? 0 : f.subX
                                        let x0 = (halo * sb4 * 4) >> sx, x1 = min(w.planes[p].width, (need * sb4 * 4) >> sx)
                                        guard x1 > x0, rows[p].count >= x1 else { continue }
                                        let row = rows[p]
                                        let src = row.span
                                        var px = w.planes[p].px.mutableSpan
                                        for x in x0..<x1 { px[x] = src[x] }
                                    }
                                }
                                halo = need
                            }
                        }
                        for kk in start..<k where !w.blockRecords[kk].independent { w.replay(kk) }
                        edge.rows.withLock { rows in
                            for p in 0..<w.planes.count {
                                let sx = p == 0 ? 0 : f.subX
                                let pl = w.planes[p]
                                let x0 = (sb * sb4 * 4) >> sx, x1 = min(pl.width, ((sb + 1) * sb4 * 4) >> sx)
                                let last = (pl.height - 1) * pl.width
                                guard x1 > x0, rows[p].count >= x1 else { continue }
                                for x in x0..<x1 { rows[p][x] = pl.px[last + x] }
                            }
                        }
                    }
                    edge.done.store(sb + 1, ordering: .releasing)
                }
                let out: Output = (w.planes.map { Array($0.px[$0.width...]) }, w.stats, w.interStats, w.error)
                results.withLock { $0[i] = out }
            }
            let all = results.withLock { $0 }
            for ti in tiles.indices where !bandsOf[ti].isEmpty {
                for p in 0..<tiles[ti].planes.count {
                    let n = tiles[ti].planes[p].width * tiles[ti].planes[p].height
                    var px: [UInt16] = []
                    px.reserveCapacity(n)
                    for bi in bandsOf[ti] { if let o = all[bi] { px += o.planes[p] } }
                    guard px.count == n else { throw .malformed("tile reconstruction") }
                    tiles[ti].planes[p].px = px
                }
                for bi in bandsOf[ti] {
                    guard let o = all[bi] else { throw .malformed("tile reconstruction") }
                    if let e = o.error { throw e }
                    for (k, v) in o.stats.enumerated() { tiles[ti].stats[k] += v }
                    for (k, v) in o.interStats.enumerated() { tiles[ti].interStats[k] += v }
                }
            }
        }
        // Intra block copy: every block in decoding order, on the whole tile.
        let serial = tiles.indices.filter { bandsOf[$0].isEmpty }
        guard !serial.isEmpty else { return tiles }
        let base = tiles
        let results = Mutex<[AV1TileDecoder?]>(Array(repeating: nil, count: serial.count))
        DispatchQueue.concurrentPerform(iterations: serial.count) { i in
            var t = base[serial[i]]
            let parseStats = t.stats, parseInter = t.interStats
            t.beginReplay()
            for p in t.planes.indices {
                let b = t.planes[p]
                t.planes[p] = AV1PlaneBuffer(x0: b.x0, y0: b.y0, width: b.width, height: b.height)
            }
            for k in t.blockRecords.indices { t.replay(k) }
            for (k, v) in parseStats.enumerated() { t.stats[k] += v }
            for (k, v) in parseInter.enumerated() { t.interStats[k] += v }
            let done = t
            results.withLock { $0[i] = done }
        }
        let done = results.withLock { $0 }
        for (i, ti) in serial.enumerated() {
            guard let t = done[i] else { throw .malformed("tile reconstruction") }
            if let e = t.error { throw e }
            tiles[ti] = t
        }
        return tiles
    }
}
