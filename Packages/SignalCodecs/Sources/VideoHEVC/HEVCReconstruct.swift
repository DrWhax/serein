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
    /// The whole picture: the inter work of every slice (motion compensation and inter
    /// residuals, by CTB-row bands in parallel), then each slice's intra steps in decoding
    /// order. Intra prediction reads only its own slice, whose inter blocks are then done.
    mutating func reconstruct(_ slices: [HEVCSliceWork], geometry g: HEVCGeometry) {
        reconstructInter(slices)
        for s in slices { reconstructIntra(s, geometry: g) }
    }

    /// Plane `c`'s rows covering luma rows [y0, y1).
    func bandRows(_ c: Int, _ y0: Int, _ y1: Int) -> Range<Int> {
        let sh = c == 0 ? 1 : sps.subHeightC
        return (y0 / sh) ..< min(planes[c].height, (y1 + sh - 1) / sh)
    }

    /// Prediction units and transform blocks never cross a CTB row, so each row is a band a
    /// worker fills on its own (from the mid-grey the picture starts as); the bands are then
    /// copied into the planes.
    mutating func reconstructInter(_ slices: [HEVCSliceWork]) {
        let ctb = sps.ctbSize
        let rows = (sps.height + ctb - 1) / ctb
        var bands = (0..<rows).map { HEVCInterBand(row: $0) }
        for (k, s) in slices.enumerated() {
            for j in s.mcJobs { bands[min(rows - 1, Int(j.y) / ctb)].mc.append(HEVCInterBand.MC(slice: k, job: j)) }
            for r in s.interResiduals {
                let yL = r.cIdx == 0 ? r.y : r.y * sps.subHeightC
                bands[min(rows - 1, yL / ctb)].residuals.append(HEVCInterBand.Residual(slice: k, job: r))
            }
        }
        bands.removeAll { $0.mc.isEmpty && $0.residuals.isEmpty }
        guard !bands.isEmpty else { return }
        let shared = slices.map(\.mc)
        let pools = slices.map(\.coeffs)
        let layout = self.withoutSamples()
        let grey = planes.enumerated().map { c, _ in UInt16(1 << ((c == 0 ? sps.bitDepthLuma : sps.bitDepthChroma) - 1)) }
        let widths = planes.map(\.width), heights = planes.map(\.height)
        let filled = hevcParallel(bands, state: { HEVCBandScratch() }) { scratch, band -> [[UInt16]] in
            let y0 = band.row * ctb, y1 = min(y0 + ctb, layout.sps.height)
            var out = (0..<widths.count).map { c in
                [UInt16](repeating: grey[c], count: layout.bandRows(c, y0, y1, heights: heights).count * widths[c])
            }
            let base = (0..<widths.count).map { layout.bandRows($0, y0, y1, heights: heights).lowerBound }
            for m in band.mc {
                let sh = shared[m.slice]
                let pred = HEVCInterContext.predict(m.job, sh, &scratch.mc)
                Self.put(&out, m.job, pred, sh, widths: widths, heights: heights, rowBase: base)
            }
            for b in band.residuals {
                let r = b.job
                let res = HEVCResidualJob.residual(r, pools[b.slice], &scratch.work)
                Self.addBlock(&out[r.cIdx], r, res, width: widths[r.cIdx], height: heights[r.cIdx], rowBase: base[r.cIdx])
            }
            return out
        }
        for (band, out) in zip(bands, filled) {
            let y0 = band.row * ctb, y1 = min(y0 + ctb, sps.height)
            for c in 0..<planes.count {
                let start = bandRows(c, y0, y1).lowerBound * widths[c]
                planes[c].samples.replaceSubrange(start ..< start + out[c].count, with: out[c])
            }
        }
    }

    /// The picture's metadata alone (for the workers: no samples to share).
    func withoutSamples() -> HEVCPictureState {
        var s = self
        s.planes = []
        return s
    }

    /// `bandRows` for a state without planes.
    func bandRows(_ c: Int, _ y0: Int, _ y1: Int, heights: [Int]) -> Range<Int> {
        let sh = c == 0 ? 1 : sps.subHeightC
        return (y0 / sh) ..< min(heights[c], (y1 + sh - 1) / sh)
    }

    /// A PU's predicted samples into planes (or bands) whose first rows are `rowBase`.
    static func put(_ dst: inout [[UInt16]], _ job: HEVCMCJob, _ pred: [UInt16], _ sh: HEVCMCShared, widths: [Int], heights: [Int], rowBase: [Int]) {
        let ps = pred.span
        var base = 0
        let jx = Int(job.x), jy = Int(job.y), jw = Int(job.w), jh = Int(job.h)
        for c in 0..<sh.comps {
            let chroma = c > 0
            let cx = chroma ? jx / sh.subW : jx, cy = chroma ? jy / sh.subH : jy
            let cw = chroma ? jw / sh.subW : jw, ch = chroma ? jh / sh.subH : jh
            let pw = widths[c], ph = heights[c], rb = rowBase[c]
            do {
                var d = dst[c].mutableSpan
                let rw = min(cw, pw - cx)
                var j = 0
                while j < ch && cy + j < ph {
                    var i = 0
                    let row = (cy + j - rb) * pw + cx, src = base + j * cw
                    while i < rw { d[row + i] = ps[src + i]; i += 1 }
                    j += 1
                }
            }
            base += cw * ch
        }
    }

    /// Adds a residual block (clipped) to a plane (or band) whose first row is `rowBase`.
    static func addBlock(_ dst: inout [UInt16], _ job: HEVCResidualJob, _ r: [Int32], width: Int, height: Int, rowBase: Int) {
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
                d[row + i] = UInt16(max(0, min(maxV, Int32(d[row + i]) + rs[src + i])))
                i += 1
            }
            j += 1
        }
    }

    /// A slice's intra steps in decoding order (their residuals computed up front in
    /// parallel: they do not depend on any sample).
    mutating func reconstructIntra(_ s: HEVCSliceWork, geometry g: HEVCGeometry) {
        var intraJobs: [HEVCResidualJob] = []
        for case .residual(let job) in s.intraSteps { intraJobs.append(job) }
        let pool = s.coeffs
        let intraResiduals = hevcParallel(intraJobs, state: { [Int32]() }) { HEVCResidualJob.residual($1, pool, &$0) }
        var next = 0
        for step in s.intraSteps {
            switch step {
            case .predict(let c, let x, let y, let l, let m, let rs, let ts):
                predictIntra(cIdx: c, x: x, y: y, log2Size: l, mode: m, pps: s.pps, geometry: g, sliceAddrRs: s.sliceAddrRs, ctbRs: rs, ctbTs: ts)
            case .residual(let job):
                add(job, intraResiduals[next])
                next += 1
            case .pcm(let x, let y, let l, let samples):
                writePCM(x: x, y: y, log2Size: l, samples)
            }
        }
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

    /// 8.4.4.2: reference samples (with availability and substitution), filtering, prediction.
    mutating func predictIntra(cIdx: Int, x: Int, y: Int, log2Size: Int, mode: Int, pps: HEVCPPS, geometry g: HEVCGeometry,
                               sliceAddrRs: Int, ctbRs: Int, ctbTs: Int) {
        let n = 1 << log2Size
        let sw = cIdx == 0 ? 1 : sps.subWidthC, sh = cIdx == 0 ? 1 : sps.subHeightC
        let bitDepth = cIdx == 0 ? sps.bitDepthLuma : sps.bitDepthChroma
        let pw = planes[cIdx].width, ph = planes[cIdx].height
        let xL = x * sw, yL = y * sh
        let constrained = pps.constrainedIntraPred
        // Order of 8.4.4.2.2: p[−1][2n−1] … p[−1][−1], then p[0][−1] … p[2n−1][−1].
        var samples = [Int32](repeating: 0, count: 4 * n + 1)
        var avail = [Bool](repeating: false, count: 4 * n + 1)
        var any = false
        do {
            let src = planes[cIdx].samples
            let sp = src.span
            func ok(_ xs: Int, _ ys: Int) -> Bool {
                let xn = xs * sw, yn = ys * sh
                guard available(g, sliceAddrRs: sliceAddrRs, ctbRs: ctbRs, ctbTs: ctbTs, xL, yL, xn, yn) else { return false }
                if constrained && predMode[i4(xn, yn)] != 1 { return false }
                return true
            }
            for k in 0..<(2 * n) {
                let ys = y + 2 * n - 1 - k
                if ok(x - 1, ys) { avail[k] = true; samples[k] = Int32(sp[x - 1 + ys * pw]); any = true }
            }
            if ok(x - 1, y - 1) { avail[2 * n] = true; samples[2 * n] = Int32(sp[x - 1 + (y - 1) * pw]); any = true }
            for k in 0..<(2 * n) {
                if ok(x + k, y - 1) { avail[2 * n + 1 + k] = true; samples[2 * n + 1 + k] = Int32(sp[x + k + (y - 1) * pw]); any = true }
            }
        }
        if !any {
            for k in 0..<samples.count { samples[k] = Int32(1 << (bitDepth - 1)) }
        } else {
            if !avail[0], let first = avail.firstIndex(of: true) { samples[0] = samples[first] }
            for k in 1..<samples.count where !avail[k] { samples[k] = samples[k - 1] }
        }
        var left = [Int32](repeating: 0, count: 2 * n + 1), top = [Int32](repeating: 0, count: 2 * n + 1)
        left[0] = samples[2 * n]
        top[0] = samples[2 * n]
        for i in 0..<(2 * n) {
            left[1 + i] = samples[2 * n - 1 - i]
            top[1 + i] = samples[2 * n + 1 + i]
        }
        let filterAllowed = cIdx == 0 || sps.chromaArrayType == 3
        if filterAllowed && !sps.intraSmoothingDisabled {
            HEVCIntraPred.filter(left: &left, top: &top, log2Size: log2Size, mode: mode, isLuma: true, strongSmoothing: sps.strongIntraSmoothing && cIdx == 0,
                                 bitDepth: bitDepth)
        }
        let pred = HEVCIntraPred.predict(left: left, top: top, log2Size: log2Size, mode: mode, isLuma: cIdx == 0, bitDepth: bitDepth)
        let w = min(n, pw - x), h = min(n, ph - y)
        var dst = take(cIdx)
        do {
            var d = dst.mutableSpan
            let ps = pred.span
            for j in 0..<h {
                let row = x + (y + j) * pw
                for i in 0..<w { d[row + i] = UInt16(ps[i + j * n]) }
            }
        }
        restore(cIdx, dst)
    }

    /// PCM samples of a coding block.
    mutating func writePCM(x x0: Int, y y0: Int, log2Size: Int, _ samples: [UInt16]) {
        let n = 1 << log2Size
        var k = 0
        for y in 0..<n { for x in 0..<n { planes[0][x0 + x, y0 + y] = samples[k]; k += 1 } }
        if sps.chromaArrayType != 0 {
            let cw = n / sps.subWidthC, ch = n / sps.subHeightC, cx = x0 / sps.subWidthC, cy = y0 / sps.subHeightC
            for c in 1...2 { for y in 0..<ch { for x in 0..<cw { planes[c][cx + x, cy + y] = samples[k]; k += 1 } } }
        }
    }

    /// Adds a residual block (clipped) to the samples.
    mutating func add(_ job: HEVCResidualJob, _ r: [Int32]) {
        let c = job.cIdx
        let w = planes[c].width, h = planes[c].height
        var dst = take(c)
        Self.addBlock(&dst, job, r, width: w, height: h, rowBase: 0)
        restore(c, dst)
    }
}

/// One CTB row's inter work.
struct HEVCInterBand: Sendable {
    struct MC: Sendable {
        var slice: Int
        var job: HEVCMCJob
    }
    var row: Int
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
    var work: [Int32] = []
}

/// The reconstruction stage: a serial queue (pictures in decoding order) holding the samples
/// of every picture the decoder still keeps, and the frames finished for output.
final class HEVCReconStage: Sendable {
    struct Store {
        var planes: [Int: [HEVCPlane]] = [:]
        var frames: [HEVCFrame] = []
    }
    let queue = DispatchQueue(label: "org.signalsafe.hevc.reconstruct", qos: .userInitiated)
    let store = Mutex(Store())
    /// At most this many parsed pictures wait for reconstruction (bounds the memory).
    let slots = DispatchSemaphore(value: 2)

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
    func planes(_ id: Int, sps: HEVCSPS) -> [HEVCPlane] {
        if let p = store.withLock({ $0.planes[id] }) { return p }
        let grey = HEVCPictureState.greyPlanes(sps)
        store.withLock { $0.planes[id] = grey }
        return grey
    }

    func reconstruct(_ work: HEVCPictureWork) -> [HEVCPlane] {
        var st = work.state
        st.planes = HEVCPictureState.greyPlanes(st.sps)
        var slices = work.slices
        for k in slices.indices { slices[k].mc.planes = slices[k].mc.refIds.map { $0.map { planes($0, sps: st.sps) } } }
        st.reconstruct(slices, geometry: work.geometry)
        if let pps = work.pps { HEVCLoopFilter.apply(&st, geometry: work.geometry, pps: pps) }
        return st.planes
    }

    /// Queues the output of picture `id` (after its reconstruction: the queue is serial).
    func output(_ id: Int, sps: HEVCSPS, poc: Int, pts: Int64, packed: HEVCDecoder.PackedOutput) {
        queue.async { [self] in
            let f = Self.frame(planes(id, sps: sps), sps: sps, poc: poc, pts: pts, packed: packed)
            store.withLock { $0.frames.append(f) }
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
    func wait() { queue.sync {} }

    /// The cropped frame of a picture's samples (or rounded to 8 bits: the planes in parallel).
    static func frame(_ planes: [HEVCPlane], sps s: HEVCSPS, poc: Int, pts: Int64, packed: HEVCDecoder.PackedOutput) -> HEVCFrame {
        let cl = s.conformanceWindow.left * s.subWidthC, cr = s.conformanceWindow.right * s.subWidthC
        let ct = s.conformanceWindow.top * s.subHeightC, cb = s.conformanceWindow.bottom * s.subHeightC
        let w = s.width - cl - cr, h = s.height - ct - cb
        func crop(_ p: HEVCPlane, _ x0: Int, _ y0: Int, _ cw: Int, _ ch: Int) -> [UInt16] {
            var out = [UInt16](repeating: 0, count: cw * ch)
            let src = p.samples
            let sp = src.span
            do {
                var o = out.mutableSpan
                for y in 0..<ch {
                    let row = x0 + (y0 + y) * p.width, d = y * cw
                    for x in 0..<cw { o[d + x] = sp[row + x] }
                }
            }
            return out
        }
        @Sendable func crop8(_ p: HEVCPlane, _ x0: Int, _ y0: Int, _ cw: Int, _ ch: Int, _ bitDepth: Int) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: cw * ch)
            let shift = UInt16(bitDepth - 8), round: UInt16 = shift > 0 ? 1 << (shift - 1) : 0
            let src = p.samples
            let sp = src.span
            do {
                var o = out.mutableSpan
                for y in 0..<ch {
                    let row = x0 + (y0 + y) * p.width, d = y * cw
                    for x in 0..<cw { o[d + x] = UInt8(min(255, (sp[row + x] &+ round) >> shift)) }
                }
            }
            return out
        }
        @Sendable func crop16(_ p: HEVCPlane, _ x0: Int, _ y0: Int, _ cw: Int, _ ch: Int) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: 2 * cw * ch)
            let src = p.samples
            let sp = src.span
            do {
                var o = out.mutableSpan
                for y in 0..<ch {
                    let row = x0 + (y0 + y) * p.width, d = 2 * y * cw
                    for x in 0..<cw {
                        let v = sp[row + x]
                        o[d + 2 * x] = UInt8(truncatingIfNeeded: v)
                        o[d + 2 * x + 1] = UInt8(truncatingIfNeeded: v >> 8)
                    }
                }
            }
            return out
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
