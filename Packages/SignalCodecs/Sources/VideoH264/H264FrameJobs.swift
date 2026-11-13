// Frame-level parallelism. The decode thread keeps what must happen in decode order: slice
// headers, picture order count, the decoded picture buffer and reference lists. Each
// picture's slice data is parsed, concealed and reconstructed by a job of its own, which
// waits only for what it reads: a B slice for its co-located picture's motion (that
// picture's parse), reconstruction for its references' samples (their reconstruction).
// Jobs only ever wait for pictures earlier in decode order.

import CodecCore
import Dispatch
import Synchronization

/// A picture's motion, published when its job has parsed (and concealed) it.
final class MotionPromise: Sendable {
    private let finished = DispatchGroup()
    private let value = Mutex<PictureMotion?>(nil)

    init() { finished.enter() }

    /// Called once, by the picture's job.
    func fulfil(_ motion: PictureMotion) {
        value.withLock { $0 = motion }
        finished.leave()
    }

    var motion: PictureMotion {
        finished.wait()
        return value.withLock { $0 ?? PictureMotion(mbs: 0) }
    }
}

/// What a job's parse failed on (the decoder's errorCount includes it).
final class ParseReport: Sendable {
    private let state = Mutex<(count: Int, last: ParseFailure?)>((0, nil))

    func record(_ e: ParseFailure) { state.withLock { $0.count += 1; $0.last = e } }
    var count: Int { state.withLock { $0.count } }
    var last: ParseFailure? { state.withLock { $0.last } }
}

/// The co-located picture of a B slice (RefPicList1[0]) with its parsed motion, for direct
/// prediction; one per slice, so its count is the slice's own.
final class ColocatedPicture: Sendable {
    let motion: PictureMotion
    let poc: Int
    let longTerm: Bool

    init(motion: PictureMotion, poc: Int, longTerm: Bool) {
        self.motion = motion
        self.poc = poc
        self.longTerm = longTerm
    }
}

/// One slice's data, waiting for its picture's job.
struct PendingSlice: Sendable {
    let header: H264SliceHeader
    let pps: H264PPS
    /// Positioned after the slice header.
    let reader: H264Reader
    let rbsp: [UInt8]
    let index: Int32
    let refs: SliceRefs
}

/// The picture the decode thread is collecting slices for.
struct PictureInProgress: Sendable {
    let sps: H264SPS
    var slices: [SliceInfo] = []
    var dequantCache: [Int: H264Dequant] = [:]
    var work: [PendingSlice] = []
}

/// A picture whose job may still run.
struct PictureJob: Sendable {
    let samples: PictureSamples
    let report: ParseReport
}

/// What concealment needs of the decoder's state when the picture was finished.
struct ConcealInputs: Sendable {
    let last: RefPicture?
    let pps: H264PPS
    let poc: Int
}

extension H264PictureDecoder {
    /// Parses one slice's data into this picture.
    mutating func decodeSlice(_ w: PendingSlice) throws(ParseFailure) {
        colocated = nil
        if w.header.type == .b, w.refs.lists.count > 1, let col = w.refs.lists[1].first ?? nil {
            colocated = ColocatedPicture(motion: col.motion.motion, poc: col.poc, longTerm: col.longTerm)
        }
        if w.pps.cabac {
            try decodeSliceCABAC(w.header, w.pps, w.reader, rbsp: w.rbsp, slice: w.index, refs: w.refs)
        } else {
            var r = w.reader
            try decodeSliceCAVLC(w.header, w.pps, &r, slice: w.index, refs: w.refs)
        }
    }

    /// A picture's job: its slices parsed (failures reported, their macroblocks concealed),
    /// its motion published, then reconstructed.
    static func run(_ picture: PictureInProgress, conceal: ConcealInputs, threads: Int, motion: MotionPromise, samples: PictureSamples, report: ParseReport) {
        var pd = H264PictureDecoder(sps: picture.sps)
        pd.slices = picture.slices
        pd.dequantCache = picture.dequantCache
        for w in picture.work {
            do { try pd.decodeSlice(w) } catch { report.record(error) }
        }
        if pd.st.slice.contains(where: { $0 < 0 }) { H264Decoder.conceal(&pd, conceal) }
        motion.fulfil(pd.st.motion)
        samples.fulfil(pd.reconstructPicture(threads: threads))
    }
}
