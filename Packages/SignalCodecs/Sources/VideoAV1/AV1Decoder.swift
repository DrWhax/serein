// The AV1 decoder for still images (AVIF items): one shown key frame from a low-overhead
// OBU stream, with its tiles decoded in parallel, then the in-loop filters, film grain
// synthesis (7.18.3) and output cropped to UpscaledWidth × FrameHeight.
//
// Supported: Main (8/10-bit 4:2:0 and monochrome) and High (8/10-bit 4:4:4) profiles; all
// intra tools (directional / smooth / Paeth / filter intra, CfL, palette, intra block copy),
// every transform, quantiser matrices, segmentation, delta q / lf, the loop filter, CDEF,
// loop restoration, superres and film grain. Refused: inter frames, show_existing_frame,
// scalable operating points, 12-bit and 4:2:2 (Professional profile).

public import CodecCore
import Dispatch
import Synchronization

public struct AV1Frame: Sendable {
    public var width: Int, height: Int
    public var bitDepth: Int
    public var monochrome: Bool
    public var subsamplingX: Bool, subsamplingY: Bool
    public var y: [UInt16], u: [UInt16], v: [UInt16]
    public var colourPrimaries: Int, transferCharacteristics: Int, matrixCoefficients: Int
    public var fullRange: Bool
    public var chromaWidth: Int { monochrome ? 0 : (width + (subsamplingX ? 1 : 0)) >> (subsamplingX ? 1 : 0) }
    public var chromaHeight: Int { monochrome ? 0 : (height + (subsamplingY ? 1 : 0)) >> (subsamplingY ? 1 : 0) }
}

public enum AV1Decoder {
    public static let maxDimension = 16_384
    public static let maxPixels = 64 * 1024 * 1024

    /// Decodes the first shown key frame of `data` (an AVIF item). `configOBUs` (av1C's) is
    /// used when the item itself carries no sequence header.
    public static func decodeStill(_ data: ByteSlice, configOBUs: ByteSlice = .empty) throws(AV1DecodeError) -> AV1Frame {
        try decodeStillWithStats(data, configOBUs: configOBUs).frame
    }

    /// decodeStill, with how often each tool was used (AV1Tool order).
    static func decodeStillWithStats(_ data: ByteSlice, configOBUs: ByteSlice = .empty) throws(AV1DecodeError) -> (frame: AV1Frame, stats: [Int]) {
        let bytes = data.copyBytes()
        var seq: AV1SequenceHeader? = nil
        if !configOBUs.isEmpty {
            let cfg = configOBUs.copyBytes()
            for o in try AV1OBU.split(cfg) where o.type == AV1OBUType.sequenceHeader {
                var r = AV1BitReader(cfg, start: o.payloadStart, end: o.payloadEnd)
                seq = try AV1SequenceHeader.parse(&r)
            }
        }
        var frame: FrameState? = nil
        for o in try AV1OBU.split(bytes) {
            switch o.type {
            case AV1OBUType.sequenceHeader:
                var r = AV1BitReader(bytes, start: o.payloadStart, end: o.payloadEnd)
                let s = try AV1SequenceHeader.parse(&r)
                if frame != nil, s != seq { throw .unsupported("a new sequence header inside the frame") }
                seq = s
            case AV1OBUType.frameHeader, AV1OBUType.frame:
                guard let s = seq else { throw .malformed("frame before a sequence header") }
                guard s.operatingPointIdc.first ?? 0 == 0 else { throw .unsupported("scalable operating points") }
                guard s.bitDepth <= 10 else { throw .unsupported("\(s.bitDepth)-bit AV1") }
                guard s.monochrome || (s.subsamplingX == s.subsamplingY) else { throw .unsupported("4:2:2 AV1") }
                if frame != nil {
                    if o.type == AV1OBUType.frameHeader { continue }   // a redundant copy
                    throw .unsupported("more than one frame")
                }
                var r = AV1BitReader(bytes, start: o.payloadStart, end: o.payloadEnd)
                let h = try AV1FrameHeader.parse(&r, s, temporalId: o.temporalId, spatialId: o.spatialId)
                guard h.upscaledWidth <= maxDimension, h.frameHeight <= maxDimension, h.upscaledWidth * h.frameHeight <= maxPixels else {
                    throw .limitExceeded("\(h.upscaledWidth)x\(h.frameHeight)")
                }
                var st = FrameState(info: AV1FrameInfo(seq: s, hdr: h))
                if o.type == AV1OBUType.frame {
                    r.byteAlign()
                    try st.tileGroup(bytes, start: r.bytePosition, end: o.payloadEnd)
                }
                frame = st
            case AV1OBUType.tileGroup:
                guard frame != nil else { throw .malformed("tile group before a frame header") }
                try frame!.tileGroup(bytes, start: o.payloadStart, end: o.payloadEnd)
            case AV1OBUType.redundantFrameHeader, AV1OBUType.temporalDelimiter, AV1OBUType.metadata, AV1OBUType.padding:
                continue
            case AV1OBUType.tileList:
                throw .unsupported("large scale tile lists")
            default:
                continue
            }
            if let st = frame, st.complete { return try st.decode() }
        }
        throw .malformed(frame == nil ? "no frame" : "frame without all its tiles")
    }

    struct FrameState {
        let info: AV1FrameInfo
        var tiles: [(row: Int, col: Int, start: Int, size: Int)] = []
        var data: [UInt8] = []
        var complete = false

        init(info: AV1FrameInfo) { self.info = info }

        mutating func tileGroup(_ bytes: [UInt8], start: Int, end: Int) throws(AV1DecodeError) {
            let h = info.hdr
            if data.isEmpty { data = bytes }
            var r = AV1BitReader(bytes, start: start, end: end)
            let numTiles = h.tileCols * h.tileRows
            var tgStart = 0, tgEnd = numTiles - 1
            if numTiles > 1, try r.flag("tile_start_and_end_present_flag") {
                let bits = h.tileColsLog2 + h.tileRowsLog2
                tgStart = try r.f(bits)
                tgEnd = try r.f(bits)
            }
            guard tgStart == tiles.count, tgEnd >= tgStart, tgEnd < numTiles else { throw .malformed("tile group \(tgStart)…\(tgEnd)") }
            r.byteAlign()
            var pos = r.bytePosition
            for tileNum in tgStart...tgEnd {
                let size: Int
                if tileNum == tgEnd {
                    size = end - pos
                } else {
                    var sr = AV1BitReader(bytes, start: pos, end: end)
                    size = try sr.le(h.tileSizeBytes, "tile_size_minus_1") + 1
                    pos += h.tileSizeBytes
                }
                guard size >= 1, pos + size <= end else { throw .malformed("tile \(tileNum) size \(size)") }
                tiles.append((tileNum / h.tileCols, tileNum % h.tileCols, pos, size))
                pos += size
            }
            if tgEnd == numTiles - 1 { complete = true }
        }

        func decode() throws(AV1DecodeError) -> (frame: AV1Frame, stats: [Int]) {
            let f = info
            let h = f.hdr
            // Tiles in parallel, each into its own buffers.
            let results = Mutex<[Result<AV1TileDecoder, AV1DecodeError>?]>(Array(repeating: nil, count: tiles.count))
            let data = self.data
            let tiles = self.tiles
            DispatchQueue.concurrentPerform(iterations: tiles.count) { i in
                let t = tiles[i]
                let r: Result<AV1TileDecoder, AV1DecodeError>
                do throws(AV1DecodeError) {
                    var d = try AV1TileDecoder(f, data: data, start: t.start, size: t.size, tileRow: t.row, tileCol: t.col)
                    try d.decodeTile()
                    r = .success(d)
                } catch {
                    r = .failure(error)
                }
                results.withLock { $0[i] = r }
            }
            var decoded: [AV1TileDecoder] = []
            var stats = [Int](repeating: 0, count: AV1Tool.allCases.count)
            for r in results.withLock({ $0 }) {
                switch r {
                case .success(let d):
                    decoded.append(d)
                    for (i, v) in d.stats.enumerated() { stats[i] += v }
                case .failure(let e): throw e
                case nil: throw .malformed("tile not decoded")
                }
            }
            // Assemble the frame.
            var planes: [AV1PlaneBuffer] = []
            for p in 0..<f.numPlanes {
                let sx = p == 0 ? 0 : f.subX, sy = p == 0 ? 0 : f.subY
                planes.append(AV1PlaneBuffer(x0: 0, y0: 0, width: (h.miCols * 4) >> sx, height: (h.miRows * 4) >> sy))
            }
            let n = h.miRows * h.miCols
            var lfStride: [Int] = [], lf: [[UInt8]] = []
            for p in 0..<f.numPlanes {
                let sx = p == 0 ? 0 : f.subX, sy = p == 0 ? 0 : f.subY
                let w = (h.miCols >> sx) + 1, hh = (h.miRows >> sy) + 1
                lfStride.append(w)
                lf.append([UInt8](repeating: 0, count: w * hh))
            }
            let cdefCols = (h.miCols + 15) / 16
            var mode = AV1FrameModeInfo(miRows: h.miRows, miCols: h.miCols, miSize: [UInt8](repeating: 0, count: n), skip: [UInt8](repeating: 0, count: n),
                                        segmentId: [UInt8](repeating: 0, count: n), lfTxSize: lf, lfStride: lfStride,
                                        deltaLF: h.deltaLfPresent ? [Int8](repeating: 0, count: 4 * n) : [],
                                        cdefIdx: [Int8](repeating: -1, count: cdefCols * ((h.miRows + 15) / 16)), cdefCols: cdefCols,
                                        lrUnits: (0..<3).map { [AV1LRUnit](repeating: AV1LRUnit(), count: f.lrUnitRows[$0] * f.lrUnitCols[$0]) })
            for t in decoded {
                for p in 0..<f.numPlanes {
                    let src = t.planes[p]
                    let x1 = min(src.x0 + src.width, planes[p].width), y1 = min(src.y0 + src.height, planes[p].height)
                    guard x1 > src.x0 else { continue }
                    for y in src.y0..<y1 {
                        let s = (y - src.y0) * src.width
                        let d = y * planes[p].width + src.x0
                        planes[p].px.replaceSubrange(d..<(d + x1 - src.x0), with: src.px[s..<(s + x1 - src.x0)])
                    }
                    let sx = p == 0 ? 0 : f.subX, sy = p == 0 ? 0 : f.subY
                    let ox = t.miColStart >> sx, oy = t.miRowStart >> sy
                    let tw = t.lfStride[p], th = t.lfTxSizes[p].count / tw
                    for y in 0..<th where oy + y < (h.miRows >> sy) + 1 {
                        for x in 0..<tw where ox + x < lfStride[p] {
                            mode.lfTxSize[p][(oy + y) * lfStride[p] + ox + x] = t.lfTxSizes[p][y * tw + x]
                        }
                    }
                }
                for r in t.miRowStart..<t.miRowEnd {
                    for c in t.miColStart..<t.miColEnd {
                        let s = t.mi(r, c), d = r * h.miCols + c
                        mode.miSize[d] = t.miSizes[s]
                        mode.skip[d] = t.skips[s]
                        mode.segmentId[d] = t.segmentIds[s]
                        if !mode.deltaLF.isEmpty { for k in 0..<4 { mode.deltaLF[4 * d + k] = t.deltaLFs[4 * s + k] } }
                    }
                }
                for r in stride(from: t.miRowStart, to: t.miRowEnd, by: 16) {
                    for c in stride(from: t.miColStart, to: t.miColEnd, by: 16) {
                        mode.cdefIdx[(r >> 4) * cdefCols + (c >> 4)] = t.cdefIdx[((r - t.miRowStart) >> 4) * t.cdefCols + ((c - t.miColStart) >> 4)]
                    }
                }
                for u in t.lrUnits where u.index < mode.lrUnits[u.plane].count { mode.lrUnits[u.plane][u.index] = u.unit }
            }
            // decode_frame_wrapup: loop filter, CDEF, upscaling, loop restoration.
            let filters = AV1Filters(f: f, m: mode)
            if h.loopFilterLevel[0] != 0 || h.loopFilterLevel[1] != 0 { stats[AV1Tool.deblock.rawValue] += 1 }
            if h.useSuperres { stats[AV1Tool.superres.rawValue] += 1 }
            if f.seq.use128 { stats[AV1Tool.sb128.rawValue] += 1 }
            if tiles.count > 1 { stats[AV1Tool.multiTile.rawValue] += 1 }
            if mode.cdefIdx.contains(where: { $0 >= 0 }) && (0..<(1 << h.cdefBits)).contains(where: { h.cdefYPri[$0] + h.cdefYSec[$0] + h.cdefUVPri[$0] + h.cdefUVSec[$0] > 0 }) {
                stats[AV1Tool.cdef.rawValue] += 1
            }
            filters.loopFilter(&planes)
            let cdef = filters.cdef(planes)
            let upCdef = filters.upscale(cdef)
            let upCur = h.usesLr ? filters.upscale(planes) : upCdef
            let lr = filters.loopRestoration(cur: upCur, cdef: upCdef)
            // Output: UpscaledWidth × FrameHeight.
            let w = h.upscaledWidth, hh = h.frameHeight
            func crop(_ p: AV1PlaneBuffer, _ cw: Int, _ ch: Int) -> [UInt16] {
                var out = [UInt16](repeating: 0, count: cw * ch)
                for y in 0..<ch {
                    out.replaceSubrange((y * cw)..<((y + 1) * cw), with: p.px[(y * p.width)..<(y * p.width + cw)])
                }
                return out
            }
            let s = f.seq
            var out = AV1Frame(width: w, height: hh, bitDepth: f.bitDepth, monochrome: s.monochrome, subsamplingX: f.subX == 1, subsamplingY: f.subY == 1,
                               y: crop(lr[0], w, hh), u: [], v: [], colourPrimaries: s.colorPrimaries,
                               transferCharacteristics: s.transferCharacteristics, matrixCoefficients: s.matrixCoefficients, fullRange: s.colorRange)
            if !s.monochrome {
                out.u = crop(lr[1], out.chromaWidth, out.chromaHeight)
                out.v = crop(lr[2], out.chromaWidth, out.chromaHeight)
            }
            if s.filmGrainParamsPresent && h.filmGrain.applyGrain {
                AV1FilmGrain(params: h.filmGrain, bitDepth: f.bitDepth, monochrome: s.monochrome, subX: f.subX, subY: f.subY,
                             matrixCoefficients: s.matrixCoefficients).apply(&out)
                stats[AV1Tool.filmGrain.rawValue] += 1
            }
            return (out, stats)
        }
    }
}
