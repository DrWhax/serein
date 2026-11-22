// VP8 decoding on two threads (libwebp's threaded decoding makes the same split): the caller
// parses each row of macroblocks (the entropy decoding, serial by nature) and hands it over by
// value; a second thread reconstructs it (prediction and inverse transforms) and loop-filters it
// a row behind, then appends the rows that are final to the planes. Nothing is shared but the
// queue between them: each row's data moves from one thread to the other, and the filter keeps
// its own window of pixels.
//
// The window: the band of the row being filtered (16 luma, 8 chroma rows) below the last 4 rows
// of the row above, which its top edge reaches into (it changes up to 3 and reads 4). Rows that
// no later edge reaches are written out as soon as their row is filtered.

import CodecCore
import Dispatch
import Synchronization

/// The pixels a row of macroblocks is reconstructed into and filtered in: rows 0…3 the row
/// above's last four, then its band (luma 16 rows, chroma 8).
struct VP8Window: Sendable {
    let mbW: Int, mbH: Int
    var y: [UInt8], u: [UInt8], v: [UInt8]
    var yStride: Int { mbW * 16 }
    var uvStride: Int { mbW * 8 }

    init(mbW: Int, mbH: Int) {
        self.mbW = mbW
        self.mbH = mbH
        y = [UInt8](repeating: 0, count: 20 * mbW * 16)
        u = [UInt8](repeating: 0, count: 12 * mbW * 8)
        v = u
    }

    /// Appends the rows that are final once row `mbY` is filtered (all of the band, unfiltered),
    /// and keeps the rest for the next row's top edge.
    mutating func emit(mbY: Int, filtered: Bool, into py: inout [UInt8], _ pu: inout [UInt8], _ pv: inout [UInt8]) {
        let ys = yStride, uvs = uvStride
        guard filtered else {
            py += y[(4 * ys)...]
            pu += u[(4 * uvs)...]
            pv += v[(4 * uvs)...]
            return
        }
        if mbY > 0 {
            py += y[0..<(4 * ys)]
            pu += u[0..<(4 * uvs)]
            pv += v[0..<(4 * uvs)]
        }
        py += y[(4 * ys)..<(16 * ys)]
        pu += u[(4 * uvs)..<(8 * uvs)]
        pv += v[(4 * uvs)..<(8 * uvs)]
        if mbY == mbH - 1 {
            py += y[(16 * ys)...]
            pu += u[(8 * uvs)...]
            pv += v[(8 * uvs)...]
        } else {
            y.replaceSubrange(0..<(4 * ys), with: y[(16 * ys)...])
            u.replaceSubrange(0..<(4 * uvs), with: u[(8 * uvs)...])
            v.replaceSubrange(0..<(4 * uvs), with: v[(8 * uvs)...])
        }
    }
}

final class VP8RowPipeline: Sendable {
    struct Job: Sendable {
        var mbY: Int
        var row: [VP8Decoder.MBData]
        var info: [VP8Decoder.FInfo]
    }
    struct Queue {
        var jobs: [Job] = []
        var ended = false
        var cancelled = false
        /// Rows the worker is done with, for the parser to fill again.
        var spare: [[VP8Decoder.MBData]] = []
    }

    let width: Int, height: Int, mbW: Int, mbH: Int
    /// 0: no loop filter, 1: simple, 2: normal.
    let references: [VP8Frame?]
    let version: Int
    let filter: Int
    let queue = Mutex(Queue())
    /// A job, the end or a cancel was queued.
    let queued = DispatchSemaphore(value: 0)
    /// How many rows may wait for the worker (the parser waits beyond that).
    let slots = DispatchSemaphore(value: 8)
    let finished = DispatchSemaphore(value: 0)
    let output = Mutex<VP8Frame?>(nil)

    init(width: Int, height: Int, mbW: Int, mbH: Int, filter: Int, references: [VP8Frame?], version: Int) {
        self.references = references
        self.version = version
        self.width = width
        self.height = height
        self.mbW = mbW
        self.mbH = mbH
        self.filter = filter
        // A queue of its own (it may wait for the parser, so not one of the shared pool's).
        DispatchQueue(label: "VP8 rows").async { self.run() }
    }

    func freshRow() -> [VP8Decoder.MBData] {
        queue.withLock { $0.spare.popLast() } ?? [VP8Decoder.MBData](repeating: VP8Decoder.MBData(), count: mbW)
    }

    func send(_ mbY: Int, _ row: [VP8Decoder.MBData], _ info: [VP8Decoder.FInfo]) {
        slots.wait()
        let job = Job(mbY: mbY, row: row, info: info)
        queue.withLock { $0.jobs.append(job) }
        queued.signal()
    }

    /// The parser failed: the worker stops (and is waited for).
    func cancel() {
        queue.withLock { $0.cancelled = true }
        queued.signal()
        finished.wait()
    }

    /// Every row was sent: the frame, once the worker has done them all.
    func finish() -> VP8Frame {
        queue.withLock { $0.ended = true }
        queued.signal()
        finished.wait()
        return output.withLock { $0 }!
    }

    func run() {
        var ws = [UInt8](repeating: 0, count: 32 * 17 + 32 * 9)
        var topY = [UInt8](repeating: 0, count: 16 * mbW)
        var topU = [UInt8](repeating: 0, count: 8 * mbW), topV = topU
        var window = VP8Window(mbW: mbW, mbH: mbH)
        var y: [UInt8] = [], u: [UInt8] = [], v: [UInt8] = []
        y.reserveCapacity(mbW * 16 * mbH * 16)
        u.reserveCapacity(mbW * 8 * mbH * 8)
        v.reserveCapacity(mbW * 8 * mbH * 8)
        while true {
            queued.wait()
            let (next, stop) = queue.withLock { q -> (Job?, Bool) in
                if q.cancelled { return (nil, true) }
                if !q.jobs.isEmpty { return (q.jobs.removeFirst(), false) }
                return (nil, q.ended)
            }
            guard let job = next else {
                if stop { break }
                continue
            }
            slots.signal()
            VP8Decoder.reconstructRow(job.mbY, job.row, &ws, &window, &topY, &topU, &topV, references: references, version: version)
            let row = job.row
            queue.withLock { $0.spare.append(row) }
            if filter > 0 { VP8Decoder.filterRow(&window, job.mbY, job.info, simple: filter == 1) }
            window.emit(mbY: job.mbY, filtered: filter > 0, into: &y, &u, &v)
        }
        if !queue.withLock({ $0.cancelled }) {
            let frame = VP8Frame(width: width, height: height, mbW: mbW, mbH: mbH, y: y, u: u, v: v)
            output.withLock { $0 = frame }
        }
        finished.signal()
    }
}
