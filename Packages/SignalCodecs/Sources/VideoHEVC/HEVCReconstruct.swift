// Reconstruction, apart from parsing (parsing never reads a sample): what the slice decoder
// records per slice (motion compensation, residuals, intra prediction and PCM in decoding
// order), its replay on a picture's samples (8.4.4.2, 8.5.3.3, 8.6.7), and the stage that
// runs it with the in-loop filters and the output cropping on its own serial queue, so the
// next picture parses while this one reconstructs. The stage owns every picture's samples.

import Dispatch
import Synchronization

/// One step of intra reconstruction, in decoding order.
enum HEVCIntraStep: Sendable {
    case predict(cIdx: Int, x: Int, y: Int, log2Size: Int, mode: Int, ctbRs: Int, ctbTs: Int)
    case residual(HEVCResidualJob)
    /// pcm_sample(): luma then Cb then Cr, already scaled to the bit depth.
    case pcm(x: Int, y: Int, log2Size: Int, samples: [UInt16])
}

/// One slice segment's reconstruction, recorded while parsing.
struct HEVCSliceWork: Sendable {
    var pps: HEVCPPS
    var sliceAddrRs: Int
    var mc: HEVCMCShared
    var mcJobs: [HEVCMCJob]
    var interResiduals: [HEVCResidualJob]
    var intraSteps: [HEVCIntraStep]
    /// The coefficient pool the residual jobs index.
    var coeffs: [Int32]
}

/// A parsed picture, ready to reconstruct.
struct HEVCPictureWork: Sendable {
    var id: Int
    var state: HEVCPictureState
    var geometry: HEVCGeometry
    var pps: HEVCPPS?
    var slices: [HEVCSliceWork]
}

/// Runs `work` over `items` on all cores; results in item order. Each chunk makes its own
/// state (scratch buffers).
func hevcParallel<T: Sendable, R: Sendable, S>(_ items: [T], state: @escaping @Sendable () -> S,
                                                _ work: @escaping @Sendable (inout S, T) -> R) -> [R] {
    guard items.count > 1 else {
        var st = state()
        return items.map { work(&st, $0) }
    }
    let chunks = min(items.count, 64)
    let results = Mutex<[[R]?]>([[R]?](repeating: nil, count: chunks))
    DispatchQueue.concurrentPerform(iterations: chunks) { k in
        let lo = items.count * k / chunks, hi = items.count * (k + 1) / chunks
        var st = state()
        var part: [R] = []
        part.reserveCapacity(hi - lo)
        var i = lo
        while i < hi { part.append(work(&st, items[i])); i += 1 }
        results.withLock { $0[k] = part }
    }
    return results.withLock { r in r.flatMap { $0 ?? [] } }
}

extension HEVCPictureState {
    /// The whole picture's planes, from each slice's references `refs`: the inter work of every
    /// slice (motion compensation and inter residuals, by CTB-row bands in parallel), then the
    /// intra steps (CTB rows as a wavefront). Intra prediction reads only its own slice, whose
    /// inter blocks are then done. Also returns how many bands were shared with references
    /// (`HEVCInterContext.sharedBand`).
    func reconstruct<S: HEVCSample>(_ slices: [HEVCSliceWork], refs: [HEVCRefPlanes<S>], geometry g: HEVCGeometry) -> ([HEVCPlane<S>], Int) {
        var (planes, shared) = reconstructInter(slices, refs: refs)
        reconstructIntra(slices, geometry: g, planes: &planes)
        return (planes, shared)
    }

    /// Makes the planes, a band per CTB row: prediction units and transform blocks never cross
    /// a CTB row, so each band is a worker's own, filled from mid-grey (8.3.3's grey is also what
    /// a picture whose parse failed shows); the planes are these bands, never copied. A band
    /// that is all a copy of its references' (`sharedBand`) is theirs, shared.
    func reconstructInter<S: HEVCSample>(_ slices: [HEVCSliceWork], refs: [HEVCRefPlanes<S>]) -> ([HEVCPlane<S>], Int) {
        let ctb = sps.ctbSize
        let rows = (sps.height + ctb - 1) / ctb
        var bands = (0..<rows).map { HEVCInterBand(row: $0) }
        for (k, s) in slices.enumerated() {
            for j in s.mcJobs { bands[min(rows - 1, Int(j.y) / ctb)].mc.append(HEVCInterBand.MC(slice: k, job: j)) }
            for r in s.interResiduals {
                let yL = r.cIdx == 0 ? r.y : r.y * sps.subHeightC
                bands[min(rows - 1, yL / ctb)].residuals.append(HEVCInterBand.Residual(slice: k, job: r))
            }
            for step in s.intraSteps {
                let yL: Int
                switch step {
                case .predict(let c, _, let y, _, _, _, _): yL = c == 0 ? y : y * sps.subHeightC
                case .residual(let j): yL = j.cIdx == 0 ? j.y : j.y * sps.subHeightC
                case .pcm(_, let y, _, _): yL = y
                }
                bands[min(rows - 1, yL / ctb)].intra = true
            }
        }
        let wc = (sps.width + ctb - 1) / ctb
        for r in 0..<rows where ctbDecoded.count >= (r + 1) * wc {
            bands[r].decoded = !ctbDecoded[(r * wc) ..< ((r + 1) * wc)].contains(false)
        }
        let shared = slices.map(\.mc)
        let pools = slices.map(\.coeffs)
        let sps = self.sps
        let sizes = HEVCPictureState.planeSizes(sps)
        let widths = sizes.map(\.width), heights = sizes.map(\.height)
        let log2s = sizes.indices.map { HEVCPictureState.bandLog2(sps, $0) }
        let grey: [S] = sizes.indices.map { HEVCPictureState.grey(sps, $0) }
        let filled = hevcParallel(bands, state: { HEVCBandScratch() }) { scratch, band -> ([[S]], Bool) in
            if let same = HEVCInterContext.sharedBand(band, shared, refs: refs, widths: widths, heights: heights, log2Rows: log2s) { return (same, true) }
            let base = log2s.map { band.row << $0 }
            var out = (0..<widths.count).map { c in
                [S](repeating: grey[c], count: (min(heights[c], base[c] + (1 << log2s[c])) - base[c]) * widths[c])
            }
            guard !band.mc.isEmpty || !band.residuals.isEmpty else { return (out, false) }
            HEVCInterContext.predictBand(band.mc, shared, refs: refs, &scratch.mc, into: &out, widths: widths, heights: heights, rowBase: base)
            for b in band.residuals {
                let r = b.job
                HEVCResidualJob.residual(r, pools[b.slice], &scratch.residual)
                Self.addBlock(&out[r.cIdx], r, scratch.residual.residual, width: widths[r.cIdx], height: heights[r.cIdx], rowBase: base[r.cIdx])
            }
            return (out, false)
        }
        let planes = sizes.indices.map { c in HEVCPlane(width: widths[c], height: heights[c], log2Rows: log2s[c], bands: filled.map { $0.0[c] }) }
        return (planes, filled.count { $0.1 })
    }

    /// Adds a residual block (clipped) to a plane (or band) whose first row is `rowBase`.
    static func addBlock<S: HEVCSample>(_ dst: inout [S], _ job: HEVCResidualJob, _ r: [Int32], width: Int, height: Int, rowBase: Int) {
        let n = 1 << job.log2Size
        let maxV = Int32((1 << job.bitDepth) - 1)
        let w = min(n, width - job.x), h = min(n, height - job.y)
        var d = dst.mutableSpan
        let rs = r.span
        var j = 0
        while j < h {
            var i = 0
            let row = job.x + (job.y + j - rowBase) * width, src = j * n
            while i < w {
                d[row + i] = S(truncatingIfNeeded: max(0, min(maxV, Int32(d[row + i]) + rs[src + i])))
                i += 1
            }
            j += 1
        }
    }

    /// Every slice's intra steps, a CTB row per worker as a wavefront. Intra prediction reads
    /// its own CTB row and the row of samples just above it, of CTBs up to one to the right, so
    /// a row runs as soon as the row above has finished those: each CTB's last row of samples
    /// goes to the row below by value once the CTB is done (nothing mutable is shared). Within
    /// a row the steps go in CTB order: decoding order but for tiles, and a step reads nothing
    /// of a CTB to its right in its row, nor of another tile.
    func reconstructIntra<S: HEVCSample>(_ slices: [HEVCSliceWork], geometry g: HEVCGeometry, planes: inout [HEVCPlane<S>]) {
        let wc = g.widthCtbs, rows = g.heightCtbs
        let log2Ctb = sps.log2CtbSize, sw = sps.subWidthC, sh = sps.subHeightC
        var rowSteps = [[HEVCIntraRowStep]](repeating: [], count: rows)
        var any = false
        for (k, s) in slices.enumerated() {
            for step in s.intraSteps {
                let xL: Int, yL: Int
                switch step {
                case .predict(let c, let x, let y, _, _, _, _): (xL, yL) = c == 0 ? (x, y) : (x * sw, y * sh)
                case .residual(let j): (xL, yL) = j.cIdx == 0 ? (j.x, j.y) : (j.x * sw, j.y * sh)
                case .pcm(let x, let y, _, _): (xL, yL) = (x, y)
                }
                rowSteps[min(rows - 1, yL >> log2Ctb)].append(HEVCIntraRowStep(slice: k, ctbX: min(wc - 1, xL >> log2Ctb), step: step))
                any = true
            }
        }
        guard any, planes.count > 0, planes[0].bands.count == rows else { return }
        if g.colBd.count > 2 {
            // Tiles: decoding order runs tile by tile; CTB order within each row, stably.
            for r in 0..<rows { rowSteps[r] = rowSteps[r].enumerated().sorted { ($0.element.ctbX, $0.offset) < ($1.element.ctbX, $1.offset) }.map(\.element) }
        }
        let layout = self
        let comps = planes.count
        let widths = planes.map(\.width), heights = planes.map(\.height), log2s = planes.map(\.log2Rows)
        let ctbW = (0..<comps).map { c in c == 0 ? 1 << log2Ctb : (1 << log2Ctb) / sw }
        let ppss = slices.map(\.pps), sliceAddrs = slices.map(\.sliceAddrRs), pools = slices.map(\.coeffs)
        // The bands move to their rows' workers and back: each is written by one worker only.
        var all: [[[S]]] = Array(repeating: [], count: comps)
        for c in 0..<comps { swap(&all[c], &planes[c].bands) }
        let store = Mutex<[[[S]]]>([])
        store.withLock { swap(&$0, &all) }
        let channels = (0..<rows).map { _ in HEVCRowChannel<HEVCSampleEdge<S>>() }
        let counter = HEVCRowCounter()
        let steps = rowSteps
        DispatchQueue.concurrentPerform(iterations: rows) { _ in
            var resid = HEVCResidualScratch()
            var top = widths.map { [S](repeating: 0, count: $0) }
            while true {
                let r = counter.next.wrappingAdd(1, ordering: .relaxed).oldValue
                guard r < rows else { break }
                var mine = store.withLock { s in
                    (0..<comps).map { c in
                        var b: [S] = []
                        swap(&b, &s[c][r])
                        return b
                    }
                }
                let base = log2s.map { r << $0 }
                let above = r > 0 ? channels[r - 1] : nil, own = channels[r]
                var published = 0, received = 0
                /// The last row of CTBs [published, x), finished, for the row below.
                func publish(upTo x: Int) {
                    guard x > published, r + 1 < rows else { published = max(published, x); return }
                    var edges: [HEVCSampleEdge<S>] = []
                    edges.reserveCapacity(x - published)
                    for cx in published..<x {
                        var e = HEVCSampleEdge<S>()
                        for c in 0..<comps {
                            let w = widths[c], x0 = cx * ctbW[c], x1 = min(w, x0 + ctbW[c])
                            let band = mine[c]
                            let last = (band.count / w - 1) * w
                            let src = band.span
                            for i in x0..<x1 { e.samples[HEVCSampleEdge<S>.offset(c) + i - x0] = src[last + i] }
                        }
                        edges.append(e)
                    }
                    own.publish(contentsOf: edges)
                    published = x
                }
                for st in steps[r] {
                    let x = st.ctbX
                    publish(upTo: x)
                    if let above, received < min(x + 2, wc) {
                        let need = min(x + 2, wc)
                        if let edges = above.take(received ..< need, of: wc) {
                            for (k, e) in edges.enumerated() {
                                let cx = received + k
                                for c in 0..<comps {
                                    let x0 = cx * ctbW[c], x1 = min(widths[c], x0 + ctbW[c])
                                    for i in x0..<x1 { top[c][i] = e.samples[HEVCSampleEdge<S>.offset(c) + i - x0] }
                                }
                            }
                        }
                        received = need
                    }
                    switch st.step {
                    case .predict(let c, let x, let y, let l, let m, let rs, let ts):
                        layout.predictIntra(cIdx: c, x: x, y: y, log2Size: l, mode: m, pps: ppss[st.slice], geometry: g, sliceAddrRs: sliceAddrs[st.slice],
                                            ctbRs: rs, ctbTs: ts, band: &mine[c], top: top[c], rowBase: base[c], width: widths[c], height: heights[c])
                    case .residual(let job):
                        HEVCResidualJob.residual(job, pools[st.slice], &resid)
                        Self.addBlock(&mine[job.cIdx], job, resid.residual, width: widths[job.cIdx], height: heights[job.cIdx], rowBase: base[job.cIdx])
                    case .pcm(let x, let y, let l, let samples):
                        Self.writePCM(x: x, y: y, log2Size: l, samples, bands: &mine, widths: widths, heights: heights, rowBase: base, sps: layout.sps)
                    }
                }
                publish(upTo: wc)
                own.end()
                store.withLock { s in for c in 0..<comps { swap(&mine[c], &s[c][r]) } }
            }
        }
        store.withLock { s in for c in 0..<comps { swap(&planes[c].bands, &s[c]) } }
    }

    /// z-scan availability (6.4.1) of the luma location (xN, yN) for a block at (xC, yC), in
    /// the CTB being decoded then (as the parser saw it).
    @inline(__always)
    func available(_ g: HEVCGeometry, sliceAddrRs: Int, ctbRs: Int, ctbTs: Int, _ xC: Int, _ yC: Int, _ xN: Int, _ yN: Int) -> Bool {
        guard xN >= 0, yN >= 0, xN < sps.width, yN < sps.height else { return false }
        if g.zOrder(xN, yN) > g.zOrder(xC, yC) { return false }
        let ctbN = g.ctbAddrRs(xN, yN)
        guard ctbSliceAddr[ctbN] == sliceAddrRs, ctbDecoded[ctbN] || ctbN == ctbRs else { return false }
        guard g.tileId[g.rsToTs[ctbN]] == g.tileId[ctbTs] else { return false }
        return predMode[i4(xN, yN)] != 255
    }

    /// 8.4.4.2: reference samples (with availability and substitution), filtering, prediction,
    /// in a band: `band` holds plane cIdx's rows from `rowBase` (the block's CTB row), `top` the
    /// row just above them (all a block reads outside its CTB row: what lies below is decoded
    /// later, so unavailable).
    func predictIntra<S: HEVCSample>(cIdx: Int, x: Int, y: Int, log2Size: Int, mode: Int, pps: HEVCPPS, geometry g: HEVCGeometry,
                                     sliceAddrRs: Int, ctbRs: Int, ctbTs: Int, band: inout [S], top: [S], rowBase: Int, width pw: Int, height ph: Int) {
        let n = 1 << log2Size
        let sw = cIdx == 0 ? 1 : sps.subWidthC, sh = cIdx == 0 ? 1 : sps.subHeightC
        let bitDepth = cIdx == 0 ? sps.bitDepthLuma : sps.bitDepthChroma
        let xL = x * sw, yL = y * sh
        let constrained = pps.constrainedIntraPred
        // Order of 8.4.4.2.2: p[−1][2n−1] … p[−1][−1], then p[0][−1] … p[2n−1][−1].
        let count = 4 * n + 1
        var samples = InlineArray<129, Int32>(repeating: 0)
        var avail = InlineArray<129, Bool>(repeating: false)
        var any = false
        do {
            let sp = band.span, tp = top.span
            // Availability is the same for every sample of a 4x4 luma unit (z-scan order, CTB,
            // prediction mode are all per unit): checked once per unit along each side.
            var lastUnit = (Int.min, Int.min), lastOk = false
            func ok(_ xs: Int, _ ys: Int) -> Bool {
                let xn = xs * sw, yn = ys * sh
                let unit = (xn >> 2, yn >> 2)
                if unit == lastUnit { return lastOk }
                lastUnit = unit
                lastOk = available(g, sliceAddrRs: sliceAddrRs, ctbRs: ctbRs, ctbTs: ctbTs, xL, yL, xn, yn) && !(constrained && predMode[i4(xn, yn)] != 1)
                return lastOk
            }
            for k in 0..<(2 * n) {
                let ys = y + 2 * n - 1 - k
                if ok(x - 1, ys) { avail[k] = true; samples[k] = Int32(sp[x - 1 + (ys - rowBase) * pw]); any = true }
            }
            // The row above: in the band, or the band above's last.
            let inBand = y - 1 >= rowBase, above = (y - 1 - rowBase) * pw
            if ok(x - 1, y - 1) {
                avail[2 * n] = true
                samples[2 * n] = Int32(inBand ? sp[x - 1 + above] : tp[x - 1])
                any = true
            }
            for k in 0..<(2 * n) {
                if ok(x + k, y - 1) {
                    avail[2 * n + 1 + k] = true
                    samples[2 * n + 1 + k] = Int32(inBand ? sp[x + k + above] : tp[x + k])
                    any = true
                }
            }
        }
        if !any {
            for k in 0..<count { samples[k] = Int32(1 << (bitDepth - 1)) }
        } else {
            if !avail[0] {
                var first = 1
                while first < count && !avail[first] { first += 1 }
                if first < count { samples[0] = samples[first] }
            }
            for k in 1..<count where !avail[k] { samples[k] = samples[k - 1] }
        }
        var left = HEVCIntraPred.Refs(repeating: 0), topRefs = HEVCIntraPred.Refs(repeating: 0)
        left[0] = samples[2 * n]
        topRefs[0] = samples[2 * n]
        for i in 0..<(2 * n) {
            left[1 + i] = samples[2 * n - 1 - i]
            topRefs[1 + i] = samples[2 * n + 1 + i]
        }
        let filterAllowed = cIdx == 0 || sps.chromaArrayType == 3
        if filterAllowed && !sps.intraSmoothingDisabled {
            HEVCIntraPred.filter(left: &left, top: &topRefs, log2Size: log2Size, mode: mode, isLuma: true, strongSmoothing: sps.strongIntraSmoothing && cIdx == 0,
                                 bitDepth: bitDepth)
        }
        var pred = HEVCIntraPred.Block(repeating: 0)
        HEVCIntraPred.predict(left: left, top: topRefs, log2Size: log2Size, mode: mode, isLuma: cIdx == 0, bitDepth: bitDepth, into: &pred)
        let w = min(n, pw - x), h = min(n, ph - y)
        var d = band.mutableSpan
        for j in 0..<h {
            let row = x + (y + j - rowBase) * pw
            for i in 0..<w { d[row + i] = S(truncatingIfNeeded: pred[i + j * n]) }
        }
    }

    /// PCM samples of a coding block, into its CTB row's bands.
    static func writePCM<S: HEVCSample>(x x0: Int, y y0: Int, log2Size: Int, _ samples: [UInt16], bands: inout [[S]], widths: [Int], heights: [Int],
                                        rowBase: [Int], sps: HEVCSPS) {
        let n = 1 << log2Size
        var k = 0
        func put(_ c: Int, _ cx: Int, _ cy: Int, _ cw: Int, _ ch: Int) {
            let w = widths[c]
            for y in 0..<ch {
                for x in 0..<cw {
                    if cx + x < w && cy + y < heights[c] && k < samples.count { bands[c][cx + x + (cy + y - rowBase[c]) * w] = S(truncatingIfNeeded: samples[k]) }
                    k += 1
                }
            }
        }
        put(0, x0, y0, n, n)
        if sps.chromaArrayType != 0 && bands.count == 3 {
            let cw = n / sps.subWidthC, ch = n / sps.subHeightC, cx = x0 / sps.subWidthC, cy = y0 / sps.subHeightC
            put(1, cx, cy, cw, ch)
            put(2, cx, cy, cw, ch)
        }
    }
}

/// An intra step with its slice and CTB column, in its CTB row's list.
struct HEVCIntraRowStep: Sendable {
    var slice: Int
    var ctbX: Int
    var step: HEVCIntraStep
}

/// The last row of samples of one CTB in every plane (luma, then Cb and Cr), for intra
/// prediction in the CTB row below.
struct HEVCSampleEdge<S: HEVCSample>: Sendable {
    var samples = InlineArray<128, S>(repeating: 0)
    /// Where plane c's samples start (a 64-sample CTB has 32 chroma samples per row).
    @inline(__always) static func offset(_ c: Int) -> Int { c == 0 ? 0 : c == 1 ? 64 : 96 }
}

/// One CTB row's inter work.
struct HEVCInterBand: Sendable {
    struct MC: Sendable {
        var slice: Int
        var job: HEVCMCJob
    }
    var row: Int
    /// Whether the row has intra blocks, and whether all its CTBs were decoded.
    var intra = false, decoded = false
    var mc: [MC] = []
    struct Residual: Sendable {
        var slice: Int
        var job: HEVCResidualJob
    }
    var residuals: [Residual] = []
}

/// A band worker's buffers.
struct HEVCBandScratch {
    var mc = HEVCMCScratch()
    var residual = HEVCResidualScratch()
}

/// The reconstruction stage: a serial queue (pictures in decoding order) holding the samples
/// of every picture the decoder still keeps, and the frames finished for output.
final class HEVCReconStage: Sendable {
    struct Store {
        var planes: [Int: HEVCSamples] = [:]
        var frames: [HEVCFrame] = []
    }
    let queue = DispatchQueue(label: "org.signalsafe.hevc.reconstruct", qos: .userInitiated)
    /// Output (cropping, packing) runs behind reconstruction, in order, on a queue of its own.
    let outputQueue = DispatchQueue(label: "org.signalsafe.hevc.output", qos: .userInitiated)
    /// At most this many reconstructed pictures wait for output.
    let outputSlots = DispatchSemaphore(value: 2)
    let store = Mutex(Store())
    /// At most this many parsed pictures wait for reconstruction (bounds the memory).
    let slots = DispatchSemaphore(value: 2)
    /// Bands shared with a reference picture so far (static content).
    let sharedBands = Atomic<Int>(0)

    /// Queues a parsed picture.
    func submit(_ work: HEVCPictureWork) {
        slots.wait()
        queue.async { [self] in
            let planes = reconstruct(work)
            store.withLock { $0.planes[work.id] = planes }
            slots.signal()
        }
    }

    /// The samples of picture `id` (grey if it never decoded: a missing reference).
    func planes(_ id: Int, sps: HEVCSPS) -> HEVCSamples {
        if let p = store.withLock({ $0.planes[id] }) { return p }
        let grey = HEVCSamples.grey(sps)
        store.withLock { $0.planes[id] = grey }
        return grey
    }

    /// A picture's samples: bytes if it is 8-bit, else 16 bits.
    func reconstruct(_ work: HEVCPictureWork) -> HEVCSamples {
        HEVCSamples.storesBytes(work.state.sps) ? .bytes(reconstruct(work, as: UInt8.self)) : .words(reconstruct(work, as: UInt16.self))
    }

    func reconstruct<S: HEVCSample>(_ work: HEVCPictureWork, as _: S.Type) -> [HEVCPlane<S>] {
        let st = work.state
        let refs = work.slices.map { s in s.mc.refIds.map { $0.map { planes($0, sps: st.sps).planes(as: S.self) } } }
        var (planes, shared) = st.reconstruct(work.slices, refs: refs, geometry: work.geometry)
        sharedBands.add(shared, ordering: .relaxed)
        if let pps = work.pps { HEVCLoopFilter.apply(st, &planes, geometry: work.geometry, pps: pps) }
        return planes
    }

    /// Queues the output of picture `id` (after its reconstruction: the queue is serial), made
    /// on the output queue while the next picture reconstructs.
    func output(_ id: Int, sps: HEVCSPS, poc: Int, pts: Int64, packed: HEVCDecoder.PackedOutput) {
        queue.async { [self] in
            let p = planes(id, sps: sps)
            outputSlots.wait()
            outputQueue.async { [self] in
                let f = Self.frame(p, sps: sps, poc: poc, pts: pts, packed: packed)
                store.withLock { $0.frames.append(f) }
                outputSlots.signal()
            }
        }
    }

    /// Drops the samples of pictures the decoder no longer keeps.
    func keep(_ ids: Set<Int>) {
        queue.async { [self] in store.withLock { s in s.planes = s.planes.filter { ids.contains($0.key) } } }
    }

    /// The frames finished so far, in output order.
    func drain() -> [HEVCFrame] {
        store.withLock { s in
            let f = s.frames
            s.frames = []
            return f
        }
    }

    /// Waits until everything queued has run.
    func wait() {
        queue.sync {}
        outputQueue.sync {}
    }

    /// A plane's rectangle (each row from its band), as 16-bit samples.
    static func cropRows<S: HEVCSample>(_ bands: borrowing Span<[S]>, _ p: HEVCPlane<S>, _ x0: Int, _ y0: Int, _ cw: Int, _ ch: Int) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: cw * ch)
        let l = p.log2Rows, mask = (1 << l) - 1
        var o = out.mutableSpan
        for y in 0..<ch {
            let yy = y0 + y, row = x0 + (yy & mask) * p.width, d = y * cw
            let r = bands[yy >> l].span.extracting(row ..< row + cw)
            var k = 0
            for i in d ..< d + cw { o[i] = UInt16(r[k]); k += 1 }
        }
        return out
    }

    /// The same rounded to 8 bits (bytes copied as they are).
    static func cropRows8<S: HEVCSample>(_ bands: borrowing Span<[S]>, _ p: HEVCPlane<S>, _ x0: Int, _ y0: Int, _ cw: Int, _ ch: Int, _ bitDepth: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: cw * ch)
        let shift = S(clamping: max(0, bitDepth - 8)), round: S = shift > 0 ? 1 << (shift - 1) : 0
        let l = p.log2Rows, mask = (1 << l) - 1
        var o = out.mutableSpan
        for y in 0..<ch {
            let yy = y0 + y, row = x0 + (yy & mask) * p.width, d = y * cw
            let r = bands[yy >> l].span.extracting(row ..< row + cw)
            var k = 0
            if S.bitWidth == 8 || shift == 0 {
                // 8-bit samples are in range already.
                for i in d ..< d + cw { o[i] = UInt8(truncatingIfNeeded: r[k]); k += 1 }
            } else {
                for i in d ..< d + cw { o[i] = UInt8(truncatingIfNeeded: min(255, (r[k] &+ round) >> shift)); k += 1 }
            }
        }
        return out
    }

    /// The same as little-endian 16-bit bytes.
    static func cropRows16<S: HEVCSample>(_ bands: borrowing Span<[S]>, _ p: HEVCPlane<S>, _ x0: Int, _ y0: Int, _ cw: Int, _ ch: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 2 * cw * ch)
        let l = p.log2Rows, mask = (1 << l) - 1
        var o = out.mutableSpan
        for y in 0..<ch {
            let yy = y0 + y, row = x0 + (yy & mask) * p.width, d = 2 * y * cw
            let r = bands[yy >> l].span.extracting(row ..< row + cw)
            for x in 0..<cw {
                let v = UInt16(r[x])
                o[d + 2 * x] = UInt8(truncatingIfNeeded: v)
                o[d + 2 * x + 1] = UInt8(truncatingIfNeeded: v >> 8)
            }
        }
        return out
    }

    /// The cropped frame of a picture's samples (or rounded to 8 bits: the planes in parallel).
    static func frame(_ samples: HEVCSamples, sps s: HEVCSPS, poc: Int, pts: Int64, packed: HEVCDecoder.PackedOutput) -> HEVCFrame {
        switch samples {
        case .bytes(let p): frame(p, sps: s, poc: poc, pts: pts, packed: packed)
        case .words(let p): frame(p, sps: s, poc: poc, pts: pts, packed: packed)
        }
    }

    static func frame<S: HEVCSample>(_ planes: [HEVCPlane<S>], sps s: HEVCSPS, poc: Int, pts: Int64, packed: HEVCDecoder.PackedOutput) -> HEVCFrame {
        let cl = s.conformanceWindow.left * s.subWidthC, cr = s.conformanceWindow.right * s.subWidthC
        let ct = s.conformanceWindow.top * s.subHeightC, cb = s.conformanceWindow.bottom * s.subHeightC
        let w = s.width - cl - cr, h = s.height - ct - cb
        func crop(_ p: HEVCPlane<S>, _ x0: Int, _ y0: Int, _ cw: Int, _ ch: Int) -> [UInt16] {
            let all = p.bands
            return cropRows(all.span, p, x0, y0, cw, ch)
        }
        @Sendable func crop8(_ p: HEVCPlane<S>, _ x0: Int, _ y0: Int, _ cw: Int, _ ch: Int, _ bitDepth: Int) -> [UInt8] {
            let all = p.bands
            return cropRows8(all.span, p, x0, y0, cw, ch, bitDepth)
        }
        @Sendable func crop16(_ p: HEVCPlane<S>, _ x0: Int, _ y0: Int, _ cw: Int, _ ch: Int) -> [UInt8] {
            let all = p.bands
            return cropRows16(all.span, p, x0, y0, cw, ch)
        }
        var f = HEVCFrame(width: w, height: h, bitDepth: s.bitDepthLuma, chromaFormat: s.chromaFormatIdc, y: [], u: [], v: [], poc: poc,
                          pts: pts, fullRange: s.videoFullRange, colourPrimaries: s.colourPrimaries,
                          transferCharacteristics: s.transferCharacteristics, matrixCoefficients: s.matrixCoefficients)
        let chroma = s.chromaFormatIdc != 0
        if packed != .none {
            let bl = s.bitDepthLuma, bc = s.bitDepthChroma, sixteen = packed == .littleEndian16 && max(bl, bc) > 8
            let parts = hevcParallel(Array(0..<(chroma ? 3 : 1)), state: { () }) { _, c -> [UInt8] in
                let (x0, y0, cw, ch) = c == 0 ? (cl, ct, w, h) : (cl / 2, ct / 2, w / 2, h / 2)
                return sixteen ? crop16(planes[c], x0, y0, cw, ch) : crop8(planes[c], x0, y0, cw, ch, c == 0 ? bl : bc)
            }
            if !sixteen { f.bitDepth = 8 }
            f.packedBytesPerSample = sixteen ? 2 : 1
            f.packedY = parts[0]
            if chroma { f.packedU = parts[1]; f.packedV = parts[2] }
            return f
        }
        f.y = crop(planes[0], cl, ct, w, h)
        if chroma {
            f.u = crop(planes[1], cl / 2, ct / 2, w / 2, h / 2)
            f.v = crop(planes[2], cl / 2, ct / 2, w / 2, h / 2)
        }
        return f
    }
}
