// Parallel reconstruction and deblocking of a parsed picture: macroblock rows run as a
// wavefront (a macroblock waits for the row above to be two macroblocks ahead, for intra
// prediction's top-right samples and for deblocking's raster order). Rows are claimed in
// order from a shared counter, so a waiting row only ever waits for a row a running worker
// holds. Each row's samples live in their own stripe behind a mutex; nothing else is shared
// mutably.

import Dispatch
import Synchronization

final class RowProgress: Sendable {
    let done = Atomic<Int>(0)
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

        // Reconstruction.
        let recon = (0 ..< rows).map { _ in RowProgress() }
        let counter = RowCounter()
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            var rec = Reconstructor(pd)
            while true {
                let r = counter.next.wrappingAdd(1, ordering: .relaxed).oldValue
                guard r < rows else { break }
                for x in 0 ..< cols {
                    if r > 0 { while recon[r - 1].done.load(ordering: .acquiring) < min(x + 2, cols) {} }
                    let mb = r * cols + x
                    var border = TopBorder()
                    if r > 0 {
                        let cw = width / 2
                        stripes[r - 1].border.spinLock { a in
                            for i in 0 ..< 25 { let c = x * 16 - 1 + i; if c >= 0 && c < width { border.y[i] = a[c] } }
                            for i in 0 ..< 9 {
                                let c = x * 8 - 1 + i
                                if c >= 0 && c < cw { border.u[i] = a[width + c]; border.v[i] = a[width + cw + c] }
                            }
                        }
                    }
                    let s = stripes[r]
                    var bottom = [UInt8](repeating: 0, count: 32)
                    s.y.spinLock { y in s.u.spinLock { u in s.v.spinLock { v in
                        rec.reconstruct(mb, y: &y, u: &u, v: &v, top: border)
                        for i in 0 ..< 16 { bottom[i] = y[15 * width + x * 16 + i] }
                        for i in 0 ..< 8 { bottom[16 + i] = u[7 * (width / 2) + x * 8 + i]; bottom[24 + i] = v[7 * (width / 2) + x * 8 + i] }
                    } } }
                    s.border.spinLock { b in
                        for i in 0 ..< 16 { b[x * 16 + i] = bottom[i] }
                        for i in 0 ..< 8 { b[width + x * 8 + i] = bottom[16 + i]; b[width + width / 2 + x * 8 + i] = bottom[24 + i] }
                    }
                    recon[r].done.store(x + 1, ordering: .releasing)
                }
            }
        }

        // Deblocking.
        if slices.contains(where: { $0.deblock.disable != 1 }) {
            let dbl = (0 ..< rows).map { _ in RowProgress() }
            let counter2 = RowCounter()
            let deblocker = Deblocker(pd)
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                while true {
                    let r = counter2.next.wrappingAdd(1, ordering: .relaxed).oldValue
                    guard r < rows else { break }
                    for x in 0 ..< cols {
                        if r > 0 { while dbl[r - 1].done.load(ordering: .acquiring) < min(x + 2, cols) {} }
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
                        dbl[r].done.store(x + 1, ordering: .releasing)
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
