// Parallel reconstruction and deblocking of a parsed picture: macroblock rows run as a
// wavefront (a macroblock waits for the row above to be two macroblocks ahead, for intra
// prediction's top-right samples and for deblocking's raster order). Rows are claimed in
// order from a shared counter, so a waiting row only ever waits for a row a running worker
// holds. Each row's samples live in their own stripe behind a mutex; nothing else is shared
// mutably.

import Dispatch
import Synchronization

/// How many macroblocks of a row are done. The row below waits on it: spinning briefly, then
/// sleeping until the row advances, so a waiting worker gives its core to the one it waits
/// for (pictures parse alongside, so workers can outnumber free cores).
final class RowProgress: Sendable {
    private let done = Atomic<Int>(0)
    private let advanced = DispatchSemaphore(value: 0)

    func publish(_ n: Int) {
        done.store(n, ordering: .releasing)
        advanced.signal()
    }

    /// Spins about as long as a few macroblocks take; then sleeps until the row is `lead`
    /// macroblocks further than needed (or done), so one wake-up buys several macroblocks of
    /// work instead of waking per macroblock.
    func wait(until n: Int, finalCount: Int, lead: Int = 6) {
        var spins = 0
        while done.load(ordering: .acquiring) < n {
            spins += 1
            guard spins > 4000 else { continue }
            let target = min(n + lead, finalCount)
            while done.load(ordering: .acquiring) < target { _ = advanced.wait(timeout: .now() + .microseconds(200)) }
            return
        }
    }
}

final class RowCounter: Sendable {
    let next = Atomic<Int>(0)
}

extension H264PictureDecoder {
    /// Reconstructs and deblocks the picture with `threads` workers.
    func reconstructPicture(threads: Int) -> YUVPicture {
        let rows = st.heightMbs, cols = st.widthMbs, width = cols * 16
        let stripes = (0 ..< rows).map { _ in Stripe(width: width) }
        let pd = self
        let workers = max(1, min(threads, rows))
        // The reference pictures' samples (complete: see finishPicture), each once, and which
        // one each slice's list entries name.
        var byID: [Int32: Int] = [:]
        var refs: [RefPlanes] = []
        var slot = [Int](repeating: -1, count: slices.count * 2 * ReconContext.listStride)
        for (si, s) in slices.enumerated() {
            for (l, list) in s.refs.lists.prefix(2).enumerated() {
                for (i, r) in list.prefix(ReconContext.listStride).enumerated() {
                    guard let r else { continue }
                    if byID[r.id] == nil { byID[r.id] = refs.count; refs.append(RefPlanes(r.samples.picture)) }
                    slot[(si * 2 + l) * ReconContext.listStride + i] = byID[r.id]!
                }
            }
        }
        let ctx = ReconContext(slices: slices, refs: refs, slot: slot)

        // Reconstruction.
        let recon = (0 ..< rows).map { _ in RowProgress() }
        let counter = RowCounter()
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            var rec = Reconstructor(pd, ctx: ctx.forWorker())
            // Per worker, reused for every macroblock (allocating them per macroblock cost more
            // than predicting it).
            var border = TopBorder()
            var bottom = [UInt8](repeating: 0, count: 32)
            while true {
                let r = counter.next.wrappingAdd(1, ordering: .relaxed).oldValue
                guard r < rows else { break }
                // Only this worker touches row r's samples until deblocking: the row below reads
                // its border. So the row's planes are locked once.
                let s = stripes[r]
                s.y.spinLock { y in s.u.spinLock { u in s.v.spinLock { v in
                    for x in 0 ..< cols {
                        if r > 0 { recon[r - 1].wait(until: min(x + 2, cols), finalCount: cols) }
                        let mb = r * cols + x
                        // Only intra prediction reads the row above (unfiltered, through the
                        // border); inter macroblocks skip the exchange.
                        if r > 0 && pd.st.kind[mb].isIntra {
                            let cw = width / 2
                            stripes[r - 1].border.spinLock { a in
                                for i in 0 ..< 25 { let c = x * 16 - 1 + i; border.y[i] = c >= 0 && c < width ? a[c] : 0 }
                                for i in 0 ..< 9 {
                                    let c = x * 8 - 1 + i
                                    if c >= 0 && c < cw { border.u[i] = a[width + c]; border.v[i] = a[width + cw + c] } else { border.u[i] = 0; border.v[i] = 0 }
                                }
                            }
                        }
                        rec.reconstruct(mb, y: &y, u: &u, v: &v, top: border)
                        // Published for the intra macroblocks below (this one's bottom line is
                        // their top, top-right or top-left).
                        let below = mb + cols
                        if r + 1 < rows && (pd.st.kind[below].isIntra || (x > 0 && pd.st.kind[below - 1].isIntra) || (x + 1 < cols && pd.st.kind[below + 1].isIntra)) {
                            for i in 0 ..< 16 { bottom[i] = y[15 * width + x * 16 + i] }
                            for i in 0 ..< 8 { bottom[16 + i] = u[7 * (width / 2) + x * 8 + i]; bottom[24 + i] = v[7 * (width / 2) + x * 8 + i] }
                            s.border.spinLock { b in
                                for i in 0 ..< 16 { b[x * 16 + i] = bottom[i] }
                                for i in 0 ..< 8 { b[width + x * 8 + i] = bottom[16 + i]; b[width + width / 2 + x * 8 + i] = bottom[24 + i] }
                            }
                        }
                        recon[r].publish(x + 1)
                    }
                } } }
            }
        }

        // Deblocking.
        if slices.contains(where: { $0.deblock.disable != 1 }) {
            let dbl = (0 ..< rows).map { _ in RowProgress() }
            let counter2 = RowCounter()
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                let deblocker = Deblocker(pd)   // per worker (see ReconContext.forWorker)
                while true {
                    let r = counter2.next.wrappingAdd(1, ordering: .relaxed).oldValue
                    guard r < rows else { break }
                    for x in 0 ..< cols {
                        if r > 0 { dbl[r - 1].wait(until: min(x + 2, cols), finalCount: cols) }
                        let mb = r * cols + x
                        if let e = deblocker.edges(mb) {
                            let s = stripes[r]
                            s.y.spinLock { y in s.u.spinLock { u in s.v.spinLock { v in deblocker.filterInside(mb, e, horizontal: false, y: &y, u: &u, v: &v) } } }
                            if r > 0, e.topMb != nil {
                                let a = stripes[r - 1]
                                a.y.spinLock { ay in a.u.spinLock { au in a.v.spinLock { av in
                                    s.y.spinLock { y in s.u.spinLock { u in s.v.spinLock { v in
                                        deblocker.filterTop(mb, e, ay: &ay, au: &au, av: &av, y: &y, u: &u, v: &v)
                                    } } }
                                } } }
                            }
                            s.y.spinLock { y in s.u.spinLock { u in s.v.spinLock { v in deblocker.filterInside(mb, e, horizontal: true, y: &y, u: &u, v: &v) } } }
                        }
                        dbl[r].publish(x + 1)
                    }
                }
            }
        }

        var out = YUVPicture(width: 0, height: 0)
        out.width = width
        out.height = rows * 16
        out.y.reserveCapacity(width * rows * 16)
        out.u.reserveCapacity(width * rows * 4)
        out.v.reserveCapacity(width * rows * 4)
        for s in stripes {
            s.y.spinLock { out.y += $0 }
            s.u.spinLock { out.u += $0 }
            s.v.spinLock { out.v += $0 }
        }
        return out
    }
}
