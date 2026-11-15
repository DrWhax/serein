// Wavefront-parallel parsing (H.265 9.3.1, 9.3.2.4 with entropy_coding_sync_enabled_flag):
// each CTB row of a slice segment is a substream of its own, starting at its entry point with
// the contexts the row above had after its second CTB, so rows parse in parallel as long as
// each stays two CTBs behind the one above. Parsing reads nothing of other rows but the last
// grid row of the CTBs above (neighbours: availability, contexts, merge and AMVP candidates),
// whether they are decoded and in which slice, and their SAO (merge-up). So each row parses
// into a band of its own (its CTB row and the grid row above it) and takes in the edges of the
// CTBs above as the row above finishes them, by value; the decoded rows are then merged into
// the picture, and each row's recorded reconstruction becomes one slice work, in row order
// (decoding order). Nothing mutable is shared but the channels between rows.

import Dispatch
import Synchronization

/// A wavefront row's edges (what the row below reads of each CTB: parse state, or samples),
/// published CTB by CTB for the row below, which waits on them: spinning briefly, then
/// sleeping until the row is a CTB further than needed (or done), so a waiting worker gives
/// its core to the row it waits for.
final class HEVCRowChannel<Edge: Sendable>: Sendable {
    private struct State {
        var edges: [Edge] = []
        var ended = false
    }
    private let state = Mutex(State())
    private let published = Atomic<Int>(0)
    private let advanced = DispatchSemaphore(value: 0)

    func publish(_ e: Edge) {
        let n = state.withLock { s in
            s.edges.append(e)
            return s.edges.count
        }
        published.store(n, ordering: .releasing)
        advanced.signal()
    }

    func publish(contentsOf e: [Edge]) {
        guard !e.isEmpty else { return }
        let n = state.withLock { s in
            s.edges += e
            return s.edges.count
        }
        published.store(n, ordering: .releasing)
        advanced.signal()
    }

    /// The row is done, or failed: whatever it did not publish never comes.
    func end() {
        state.withLock { $0.ended = true }
        published.store(Int.max, ordering: .releasing)
        advanced.signal()
    }

    /// The edges of CTBs `range` of a row of `count`, once published; nil if the row ended
    /// without them.
    func take(_ range: Range<Int>, of count: Int) -> [Edge]? {
        let n = range.upperBound
        var spins = 0
        while published.load(ordering: .acquiring) < n {
            spins += 1
            guard spins > 2000 else { continue }
            let target = n
            while published.load(ordering: .acquiring) < target { _ = advanced.wait(timeout: .now() + .microseconds(200)) }
            break
        }
        return state.withLock { s -> [Edge]? in
            guard s.edges.count >= n else { return nil }
            // A buffer of its own: Array(s.edges[range]) of the whole array would share the
            // channel's, which the row above goes on appending to.
            var out: [Edge] = []
            out.reserveCapacity(range.count)
            for i in range { out.append(s.edges[i]) }
            return out
        }
    }
}

/// The row above's channel (nil for a segment's first row) and the row's own.
struct HEVCRowLink: Sendable {
    let above: HEVCRowChannel<HEVCCtbEdge>?
    let own: HEVCRowChannel<HEVCCtbEdge>
}

/// Rows are claimed in order, so a row only ever waits for a row a running worker holds.
final class HEVCRowCounter: Sendable {
    let next = Atomic<Int>(0)
}

extension HEVCDecoder {
    /// Whether a slice segment parses as a wavefront: WPP without tiles, an independent
    /// segment from the start of a CTB row with an entry point per further row.
    static func parsesAsWavefront(_ h: HEVCSliceHeader, pps p: HEVCPPS, geometry g: HEVCGeometry) -> Bool {
        p.entropyCodingSync && !p.tilesEnabled && !h.dependentSliceSegment && !h.entryPointOffsets.isEmpty
            && h.segmentAddress % g.widthCtbs == 0 && h.segmentAddress / g.widthCtbs + h.entryPointOffsets.count < g.heightCtbs
    }

    /// The segment's CTB rows parsed in parallel, each into its own band, while this thread
    /// merges each row into the picture as it finishes (rows finish in order: a row's last CTB
    /// waits for the whole row above) and makes the next picture's grid meanwhile. A malformed
    /// row (or one ending before its CTB row does, but the last) fails the segment from that row
    /// on: the rows above it are independent substreams, decoded and kept.
    func decodeRowsInParallel(_ u: HEVCNALUnit, header h: HEVCSliceHeader, sps s: HEVCSPS, pps p: HEVCPPS, pic: HEVCPicture, geom: HEVCGeometry,
                              inter: HEVCInterContext?) throws {
        let wc = geom.widthCtbs, r0 = h.segmentAddress / wc, rows = h.entryPointOffsets.count + 1
        let ctb = s.ctbSize, h4 = pic.h4
        let sliceAddrRs = lastSliceAddrRs, index = sliceIndex
        // The first row's neighbours above are the picture's (earlier slices').
        let top = r0 == 0 ? [] : (0..<wc).map { pic.edge((r0 - 1) * wc + $0) }
        let channels = (0..<rows).map { _ in HEVCRowChannel<HEVCCtbEdge>() }
        let counter = HEVCRowCounter()
        let results = HEVCRowResults(rows)
        let workers = wavefrontThreads > 0 ? min(rows, wavefrontThreads) : rows
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                while true {
                    let k = counter.next.wrappingAdd(1, ordering: .relaxed).oldValue
                    guard k < rows else { break }
                    let row = r0 + k
                    let first4 = (row * ctb) >> 2
                    let r: Result<HEVCRowParse, HEVCDecodeError>
                    do throws(HEVCDecodeError) {
                        let band = HEVCPicture(sps: s, id: -1, band: max(0, first4 - 1) ..< min(h4, ((row + 1) * ctb) >> 2))
                        if k == 0 { for e in top { band.putAbove(e) } }
                        var d = try HEVCSliceDecoder(sps: s, pps: p, header: h, nal: u, pic: band, geom: geom, sliceAddrRs: sliceAddrRs, sliceIndex: index,
                                                     dependentState: nil, inter: inter)
                        d.startTs = geom.rsToTs[row * wc]
                        d.startEntry = k
                        d.stopAtRowEnd = k < rows - 1
                        d.rowLink = HEVCRowLink(above: k > 0 ? channels[k - 1] : nil, own: channels[k])
                        try d.decode()
                        if k < rows - 1 && !d.stoppedAtRowEnd { throw .malformed("slice segment ended before its last entry point") }
                        r = .success(HEVCRowParse(band, row: row, work: d.recorded(), endState: d.endState, endStat: d.endStat, wppState: d.wppState))
                    } catch {
                        r = .failure(error)
                    }
                    channels[k].end()
                    results.put(k, r)
                }
            }
        }
        // Meanwhile: the next picture's grid (most likely the same size), off the critical path.
        if spare.map({ !$0.fits(s) }) ?? true { spare = HEVCPicture(sps: s, id: -1) }
        var failure: HEVCDecodeError?
        var last: HEVCRowParse?
        for k in 0..<rows {
            switch results.take(k) {
            case .success(let t):
                guard failure == nil else { continue }
                pic.merge(t)
                currentSlices.append(t.work)
                last = t
            case .failure(let e):
                if failure == nil { failure = e }
            }
        }
        if let failure { throw failure }
        if let last {
            dependentState = (last.endState, last.endStat)
            wppCarry = last.wppState
        }
        wavefrontSegments += 1
    }
}

/// The wavefront rows' results, each taken (moved out) once it is there.
final class HEVCRowResults: Sendable {
    private let slots: Mutex<[Result<HEVCRowParse, HEVCDecodeError>?]>
    private let finished = DispatchSemaphore(value: 0)

    init(_ rows: Int) { slots = Mutex(Array(repeating: nil, count: rows)) }

    func put(_ k: Int, _ r: Result<HEVCRowParse, HEVCDecodeError>) {
        slots.withLock { $0[k] = r }
        finished.signal()
    }

    /// Row k's result, waiting for it.
    func take(_ k: Int) -> Result<HEVCRowParse, HEVCDecodeError> {
        while true {
            let r = slots.withLock { s -> Result<HEVCRowParse, HEVCDecodeError>? in
                let r = s[k]
                s[k] = nil
                return r
            }
            if let r { return r }
            finished.wait()
        }
    }
}
