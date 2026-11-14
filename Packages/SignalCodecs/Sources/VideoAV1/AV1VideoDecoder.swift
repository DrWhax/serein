// The AV1 video decoder: temporal units (MP4 samples or IVF frames) of OBUs, every frame type,
// the eight reference slots and what they carry between frames (7.20, 7.21), and output of
// shown frames (show_existing_frame included) with film grain.
//
// Two stages. The caller's thread parses: headers, the motion field, every tile's symbols
// and what a reference slot keeps of them (CDFs, motion, segment ids) — parsing a frame needs
// nothing of its references' samples. Reconstruction, the in-loop filters and output then run
// as a job on a serial queue, so the next frame parses meanwhile; a job reads the samples of
// earlier jobs only, which the queue has finished. Frames come out in decoding order, a few
// calls late (flush returns the rest).

public import CodecCore
import Dispatch
import Synchronization

/// A frame's samples after the in-loop filters, filled in by its reconstruction job (empty if
/// that failed).
final class AV1Pixels: Sendable {
    private let value = Mutex<[AV1PlaneBuffer]>([])

    func fill(_ planes: [AV1PlaneBuffer]) { value.withLock { $0 = planes } }
    var planes: [AV1PlaneBuffer] { value.withLock { $0 } }
}

/// One reconstruction job: whether it is done, and what it gives.
final class AV1Job: Sendable {
    struct Result: Sendable {
        var frame: AV1Frame?
        var failed = false
        var interStats: [Int] = []
    }
    private let finished = DispatchGroup()
    private let value = Mutex<Result>(Result())

    init() { finished.enter() }

    func finish(_ r: Result) {
        value.withLock { $0 = r }
        finished.leave()
    }

    var isDone: Bool { finished.wait(timeout: .now()) == .success }

    var result: Result {
        finished.wait()
        return value.withLock { $0 }
    }
}

public final class AV1VideoDecoder {
    var seq: AV1SequenceHeader?
    var slots = [AV1RefSlot](repeating: AV1RefSlot(), count: 8)
    public private(set) var errorCount = 0
    /// Frames decoded (shown or not).
    public private(set) var framesDecoded = 0
    /// How often each inter tool was used (AV1InterTool order), as of the frames returned.
    var interStats = [Int](repeating: 0, count: AV1InterTool.allCases.count)
    /// Reconstruction jobs not yet returned, in decoding order.
    var jobs: [AV1Job] = []
    let queue = DispatchQueue(label: "org.signalsafe.av1.reconstruct", qos: .utility)
    /// Jobs in flight before decode waits for the oldest.
    static let maxJobs = 3

    /// `configOBUs`: av1C's configOBUs (a sequence header), or empty when the stream carries it.
    public init(configOBUs: ByteSlice = .empty) throws(AV1DecodeError) {
        if !configOBUs.isEmpty {
            let cfg = configOBUs.copyBytes()
            for o in try AV1OBU.split(cfg) where o.type == AV1OBUType.sequenceHeader {
                var r = AV1BitReader(cfg, start: o.payloadStart, end: o.payloadEnd)
                seq = try Self.checked(try AV1SequenceHeader.parse(&r))
            }
        }
    }

    static func checked(_ s: AV1SequenceHeader) throws(AV1DecodeError) -> AV1SequenceHeader {
        guard s.operatingPointIdc.first ?? 0 == 0 else { throw .unsupported("scalable operating points") }
        guard s.bitDepth <= 10 else { throw .unsupported("\(s.bitDepth)-bit AV1") }
        guard s.monochrome || (s.subsamplingX == s.subsamplingY) else { throw .unsupported("4:2:2 AV1") }
        return s
    }

    /// One temporal unit; the frames finished since the last call, in order. A frame that
    /// fails to parse is counted and skipped (its reference slots keep what they had).
    public func decode(sample: ByteSlice, pts: Int64) -> [AV1Frame] {
        do { try decodeUnit(sample.copyBytes(), pts: pts) } catch { errorCount += 1 }
        return collect(waitingFor: max(0, jobs.count - Self.maxJobs))
    }

    /// Every frame still being reconstructed.
    public func flush() -> [AV1Frame] { collect(waitingFor: jobs.count) }

    /// Finished jobs from the oldest, waiting for the first `count` of them.
    func collect(waitingFor count: Int) -> [AV1Frame] {
        var out: [AV1Frame] = []
        var taken = 0
        while let job = jobs.first, taken < count || job.isDone {
            jobs.removeFirst()
            taken += 1
            let r = job.result
            if r.failed { errorCount += 1 }
            for (k, v) in r.interStats.enumerated() { interStats[k] += v }
            if let f = r.frame { out.append(f) }
        }
        return out
    }

    func decodeUnit(_ bytes: [UInt8], pts: Int64) throws(AV1DecodeError) {
        var pending: AV1Decoder.FrameState? = nil
        for o in try AV1OBU.split(bytes, limit: 1 << 16) {
            switch o.type {
            case AV1OBUType.sequenceHeader:
                var r = AV1BitReader(bytes, start: o.payloadStart, end: o.payloadEnd)
                seq = try Self.checked(try AV1SequenceHeader.parse(&r))
            case AV1OBUType.frameHeader, AV1OBUType.frame:
                guard let s = seq else { throw .malformed("frame before a sequence header") }
                if pending != nil {
                    if o.type == AV1OBUType.frameHeader { continue }   // a redundant copy
                    throw .malformed("a frame before the last one had all its tiles")
                }
                var r = AV1BitReader(bytes, start: o.payloadStart, end: o.payloadEnd)
                let h = try AV1FrameHeader.parse(&r, s, temporalId: o.temporalId, spatialId: o.spatialId, refs: slots)
                if h.showExistingFrame {
                    try showExisting(h, s, pts: pts)
                    continue
                }
                guard h.upscaledWidth <= AV1Decoder.maxDimension, h.frameHeight <= AV1Decoder.maxDimension,
                      h.upscaledWidth * h.frameHeight <= AV1Decoder.maxPixels else { throw .limitExceeded("\(h.upscaledWidth)x\(h.frameHeight)") }
                var st = AV1Decoder.FrameState(info: try frameInfo(s, h))
                if o.type == AV1OBUType.frame {
                    r.byteAlign()
                    try st.tileGroup(bytes, start: r.bytePosition, end: o.payloadEnd)
                }
                pending = st
            case AV1OBUType.tileGroup:
                guard pending != nil else { throw .malformed("tile group before a frame header") }
                try pending!.tileGroup(bytes, start: o.payloadStart, end: o.payloadEnd)
            case AV1OBUType.tileList:
                throw .unsupported("large scale tile lists")
            default:
                continue
            }
            if let st = pending, st.complete {
                pending = nil
                try finish(st, pts: pts)
            }
        }
        if pending != nil { throw .malformed("frame without all its tiles") }
    }

    /// The frame's shared inputs: reference sizes, starting CDFs, motion field, previous
    /// segment ids. (The references' samples are the job's.)
    func frameInfo(_ s: AV1SequenceHeader, _ h: AV1FrameHeader) throws(AV1DecodeError) -> AV1FrameInfo {
        var f = AV1FrameInfo(seq: s, hdr: h)
        if !h.frameIsIntra {
            for ref in AV1Ref.last...AV1Ref.altref {
                let slot = slots[h.refFrameIdx[ref - 1]]
                guard slot.valid, slot.pixels != nil else { throw .malformed("reference \(ref) is missing") }
                guard slot.bitDepth == s.bitDepth, slot.subX == s.subsamplingX, slot.subY == s.subsamplingY else { throw .unsupported("a reference of another format") }
                guard 2 * h.frameWidth >= slot.upscaledWidth, 2 * h.frameHeight >= slot.frameHeight,
                      h.frameWidth <= 16 * slot.upscaledWidth, h.frameHeight <= 16 * slot.frameHeight else { throw .malformed("reference scale") }
                f.refPictures[ref] = AV1RefPicture(planes: [], upscaledWidth: slot.upscaledWidth, frameWidth: slot.frameWidth,
                                                   frameHeight: slot.frameHeight)
            }
            if h.useRefFrameMvs { f.motionField = AV1MotionField.estimate(hdr: h, seq: s, slots: slots) }
        }
        if h.primaryRefFrame != AV1Ref.primaryRefNone {
            let prev = slots[h.refFrameIdx[h.primaryRefFrame]]
            guard !prev.cdf.isEmpty else { throw .malformed("primary reference without saved CDFs") }
            f.initialCdf = AV1CDFLayout.shared.loaded(prev.cdf)
            if h.segmentationEnabled && prev.miRows == h.miRows && prev.miCols == h.miCols && prev.segmentStride >= h.miCols
                && prev.segmentIds.count >= (h.miRows - 1) * prev.segmentStride + h.miCols {
                f.prevSegmentIds = prev.segmentIds
                f.prevSegmentStride = prev.segmentStride
            }
        }
        return f
    }

    /// Parses the frame, updates the slots it refreshes, and queues its reconstruction.
    func finish(_ st: AV1Decoder.FrameState, pts: Int64) throws(AV1DecodeError) {
        let f = st.info, h = f.hdr, s = f.seq
        let tiles = try st.decodeTiles(replay: true)
        let parsed = AV1Decoder.FrameState.parsed(tiles, f)
        framesDecoded += 1
        if !h.showFrame { interStats[AV1InterTool.hiddenFrame.rawValue] += 1 }
        if h.primaryRefFrame != AV1Ref.primaryRefNone { interStats[AV1InterTool.primaryRefCdf.rawValue] += 1 }
        let mf = AV1MotionField.store(refFrames: parsed.mode.refFrames, mvs: parsed.mvs, stride: parsed.mode.stride, miRows: h.miRows, miCols: h.miCols,
                                      hdr: h, seq: s, refOrderHint: { self.slots[$0].orderHint })
        let cdf = h.disableFrameEndUpdateCdf ? (f.initialCdf.isEmpty ? AV1CDFLayout.shared.defaults[f.cdfIndex] : f.initialCdf) : parsed.cdf
        var refs = [AV1Pixels?](repeating: nil, count: 8)
        if !h.frameIsIntra { for ref in AV1Ref.last...AV1Ref.altref { refs[ref] = slots[h.refFrameIdx[ref - 1]].pixels } }
        let refPixels = refs
        let pixels = AV1Pixels()
        var slot = AV1RefSlot()
        slot.valid = true
        slot.frameId = h.currentFrameId
        slot.upscaledWidth = h.upscaledWidth
        slot.frameWidth = h.frameWidth
        slot.frameHeight = h.frameHeight
        slot.renderWidth = h.renderWidth
        slot.renderHeight = h.renderHeight
        slot.miCols = h.miCols
        slot.miRows = h.miRows
        slot.frameType = h.frameType
        slot.subX = s.subsamplingX
        slot.subY = s.subsamplingY
        slot.bitDepth = s.bitDepth
        slot.orderHint = h.orderHint
        slot.savedOrderHints = h.orderHints
        slot.pixels = pixels
        slot.savedRefFrames = mf.refs
        slot.savedMvs = mf.mvs
        slot.gmParams = h.gmParams
        slot.segmentIds = parsed.mode.segmentId
        slot.segmentStride = parsed.mode.stride
        slot.cdf = cdf
        slot.filmGrain = h.filmGrain
        slot.lfRefDeltas = h.loopFilterRefDeltas
        slot.lfModeDeltas = h.loopFilterModeDeltas
        slot.featureEnabled = h.featureEnabled
        slot.featureData = h.featureData
        slot.showableFrame = h.showableFrame
        for i in 0..<8 where (h.refreshFrameFlags >> i) & 1 == 1 { slots[i] = slot }
        let job = AV1Job()
        jobs.append(job)
        let show = h.showFrame
        queue.async {
            var r = AV1Job.Result()
            do throws(AV1DecodeError) {
                var tiles = tiles
                for ref in AV1Ref.last...AV1Ref.altref {
                    guard let p = refPixels[ref] else { continue }
                    let planes = p.planes
                    guard !planes.isEmpty else { throw .malformed("reference \(ref) was not reconstructed") }
                    for t in tiles.indices { tiles[t].f.refPictures[ref]?.planes = planes }
                }
                tiles = try AV1Replay.reconstruct(tiles)
                var stats = parsed.stats
                let planes = AV1Decoder.FrameState.wrapup(AV1Decoder.FrameState.samples(tiles, f), parsed.mode, f, tiles: tiles.count, stats: &stats)
                pixels.fill(planes)
                var inter = [Int](repeating: 0, count: AV1InterTool.allCases.count)
                for t in tiles { for (k, v) in t.interStats.enumerated() { inter[k] += v } }
                r.interStats = inter
                if show {
                    var frame = AV1Decoder.FrameState.output(planes, f)
                    frame.pts = pts
                    r.frame = frame
                }
            } catch {
                r.failed = true
            }
            job.finish(r)
        }
    }

    /// show_existing_frame: the slot's frame, with its film grain; a key frame shown this way
    /// also becomes every slot (7.21 then 7.20 with all frames refreshed).
    func showExisting(_ h: AV1FrameHeader, _ s: AV1SequenceHeader, pts: Int64) throws(AV1DecodeError) {
        let slot = slots[h.frameToShowMapIdx]
        guard slot.valid, let pixels = slot.pixels else { throw .malformed("show_existing_frame of an empty slot") }
        interStats[AV1InterTool.showExisting.rawValue] += 1
        var oh = AV1FrameHeader()
        oh.upscaledWidth = slot.upscaledWidth
        oh.frameWidth = slot.frameWidth
        oh.frameHeight = slot.frameHeight
        oh.miCols = slot.miCols
        oh.miRows = slot.miRows
        oh.filmGrain = h.filmGrain
        let info = AV1FrameInfo(seq: s, hdr: oh)
        let job = AV1Job()
        jobs.append(job)
        queue.async {
            var r = AV1Job.Result()
            let planes = pixels.planes
            if planes.isEmpty {
                r.failed = true
            } else {
                var frame = AV1Decoder.FrameState.output(planes, info)
                frame.pts = pts
                r.frame = frame
            }
            job.finish(r)
        }
        if slot.frameType == AV1FrameType.key {
            var copy = slot
            copy.showableFrame = false
            for i in 0..<8 { slots[i] = copy }
        }
    }
}
