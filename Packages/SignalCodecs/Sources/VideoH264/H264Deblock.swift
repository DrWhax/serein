// The deblocking filter (H.264 8.7) for frame pictures, run once a picture is reconstructed:
// per macroblock in raster order, luma vertical edges, then horizontal edges, then each chroma
// plane likewise. Boundary strength (8.7.2.1) from the intra / coded / motion rules;
// α, β, tC0 (Tables 8-16, 8-17) at the averaged QP with the q macroblock's slice offsets.
// Works on the row stripes: a macroblock's top edge spans the stripe above and its own.

extension H264PictureDecoder {
    /// Whether the transform block holding 4x4 block `b` of `mb` has coefficients.
    @inline(__always) func coded(_ mb: Int, _ b: Int) -> Bool {
        if st.kind[mb].contains(.transform8x8) {
            let base = (b >> 3) * 8 + ((b & 3) >> 1) * 2
            return st.nnz[mb * 24 + base] | st.nnz[mb * 24 + base + 1] | st.nnz[mb * 24 + base + 4] | st.nnz[mb * 24 + base + 5] != 0
        }
        return st.nnz[mb * 24 + b] != 0
    }

    func strength(_ pm: Int, _ pb: Int, _ qm: Int, _ qb: Int, mbEdge: Bool) -> Int {
        let pi = st.kind[pm].isIntra, qi = st.kind[qm].isIntra
        if pi || qi { return mbEdge ? 4 : 3 }
        if coded(pm, pb) || coded(qm, qb) { return 2 }
        return motionDiffers(pm, pb, qm, qb) ? 1 : 0
    }

    /// 8.7.2.1's motion rule: different reference pictures, a different number of motion
    /// vectors, or a vector component differing by ≥ 4 quarter samples.
    func motionDiffers(_ pm: Int, _ pb: Int, _ qm: Int, _ qb: Int) -> Bool {
        let pb8 = pm * 4 + (pb >> 3) * 2 + ((pb & 3) >> 1), qb8 = qm * 4 + (qb >> 3) * 2 + ((qb & 3) >> 1)
        let m = st.motion
        let p0 = m.refIdx[(0) * m.n4 + pb8] >= 0 ? m.refID[(0) * m.n4 + pb8] : -1, p1 = m.refIdx[(1) * m.n4 + pb8] >= 0 ? m.refID[(1) * m.n4 + pb8] : -1
        let q0 = m.refIdx[(0) * m.n4 + qb8] >= 0 ? m.refID[(0) * m.n4 + qb8] : -1, q1 = m.refIdx[(1) * m.n4 + qb8] >= 0 ? m.refID[(1) * m.n4 + qb8] : -1
        let np = (p0 >= 0 ? 1 : 0) + (p1 >= 0 ? 1 : 0), nq = (q0 >= 0 ? 1 : 0) + (q1 >= 0 ? 1 : 0)
        if np != nq { return true }
        let pi = pm * 16 + pb, qi = qm * 16 + qb
        @inline(__always) func far(_ la: Int, _ ia: Int, _ lb: Int, _ ib: Int) -> Bool {
            abs(Int(m.mvX[(la) * m.n16 + ia]) - Int(m.mvX[(lb) * m.n16 + ib])) >= 4 || abs(Int(m.mvY[(la) * m.n16 + ia]) - Int(m.mvY[(lb) * m.n16 + ib])) >= 4
        }
        if np == 1 {
            let lp = p0 >= 0 ? 0 : 1, lq = q0 >= 0 ? 0 : 1
            if (lp == 0 ? p0 : p1) != (lq == 0 ? q0 : q1) { return true }
            return far(lp, pi, lq, qi)
        }
        let straight = p0 == q0 && p1 == q1, crossed = p0 == q1 && p1 == q0
        guard straight || crossed else { return true }
        if p0 != p1 {
            return straight ? (far(0, pi, 0, qi) || far(1, pi, 1, qi)) : (far(0, pi, 1, qi) || far(1, pi, 0, qi))
        }
        return (far(0, pi, 0, qi) || far(1, pi, 1, qi)) && (far(0, pi, 1, qi) || far(1, pi, 0, qi))
    }

}

/// One edge line's filter (8.7.2.3/8.7.2.4) on samples p3…p0 | q0…q3; returns the new
/// (p2, p1, p0, q0, q1, q2).
@inline(__always) func filterLine(_ p3: Int, _ p2: Int, _ p1: Int, _ p0: Int, _ q0: Int, _ q1: Int, _ q2: Int, _ q3: Int,
                                  bs: Int, alpha: Int, beta: Int, tc0: Int, chroma: Bool) -> (Int, Int, Int, Int, Int, Int)? {
    guard abs(p0 - q0) < alpha, abs(p1 - p0) < beta, abs(q1 - q0) < beta else { return nil }
    if chroma {
        if bs < 4 {
            let tc = tc0 + 1
            let d = clip3(-tc, tc, (((q0 - p0) << 2) + (p1 - q1) + 4) >> 3)
            return (p2, p1, clip3(0, 255, p0 + d), clip3(0, 255, q0 - d), q1, q2)
        }
        return (p2, p1, (2 * p1 + p0 + q1 + 2) >> 2, (2 * q1 + q0 + p1 + 2) >> 2, q1, q2)
    }
    let ap = abs(p2 - p0), aq = abs(q2 - q0)
    if bs < 4 {
        let tc = tc0 + (ap < beta ? 1 : 0) + (aq < beta ? 1 : 0)
        let d = clip3(-tc, tc, (((q0 - p0) << 2) + (p1 - q1) + 4) >> 3)
        let np1 = ap < beta ? p1 + clip3(-tc0, tc0, (p2 + ((p0 + q0 + 1) >> 1) - (p1 << 1)) >> 1) : p1
        let nq1 = aq < beta ? q1 + clip3(-tc0, tc0, (q2 + ((p0 + q0 + 1) >> 1) - (q1 << 1)) >> 1) : q1
        return (p2, np1, clip3(0, 255, p0 + d), clip3(0, 255, q0 - d), nq1, q2)
    }
    let strong = abs(p0 - q0) < ((alpha >> 2) + 2)
    var r = (p2, p1, p0, q0, q1, q2)
    if ap < beta && strong {
        r.2 = (p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3
        r.1 = (p2 + p1 + p0 + q0 + 2) >> 2
        r.0 = (2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) >> 3
    } else {
        r.2 = (2 * p1 + p0 + q1 + 2) >> 2
    }
    if aq < beta && strong {
        r.3 = (p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) >> 3
        r.4 = (p0 + q0 + q1 + q2 + 2) >> 2
        r.5 = (2 * q3 + 3 * q2 + q1 + q0 + p0 + 4) >> 3
    } else {
        r.3 = (2 * q1 + q0 + p1 + 2) >> 2
    }
    return r
}

/// Deblocks macroblocks of a reconstructed picture's stripes.
struct Deblocker: Sendable {
    let pd: H264PictureDecoder
    let width: Int, cwidth: Int

    let st: MBState

    init(_ pd: H264PictureDecoder) {
        self.pd = pd
        st = pd.st
        width = pd.st.widthMbs * 16
        cwidth = width / 2
    }


    struct Edges {
        var leftMb: Int?, topMb: Int?
        /// bS per (edge 0…3, segment 0…3), vertical and horizontal.
        var v = [Int](repeating: 0, count: 16), h = [Int](repeating: 0, count: 16)
        var params: SliceDeblock
    }

    func edges(_ mb: Int) -> Edges? {
        guard st.slice[mb] >= 0 else { return nil }
        let p = pd.slices[Int(st.slice[mb])].deblock
        guard p.disable != 1 else { return nil }
        let w = st.widthMbs, mx = mb % w, my = mb / w
        var e = Edges(leftMb: mx > 0 && (p.disable != 2 || st.slice[mb - 1] == st.slice[mb]) && st.slice[mb - 1] >= 0 ? mb - 1 : nil,
                      topMb: my > 0 && (p.disable != 2 || st.slice[mb - w] == st.slice[mb]) && st.slice[mb - w] >= 0 ? mb - w : nil, params: p)
        let t8 = st.kind[mb].contains(.transform8x8)
        for edge in 0 ..< 4 {
            if edge % 2 == 1 && t8 { continue }
            if edge > 0 || e.leftMb != nil {
                for k in 0 ..< 4 {
                    let q = k * 4 + edge
                    let (pm, pb) = edge == 0 ? (e.leftMb!, k * 4 + 3) : (mb, q - 1)
                    e.v[edge * 4 + k] = pd.strength(pm, pb, mb, q, mbEdge: edge == 0)
                }
            }
            if edge > 0 || e.topMb != nil {
                for k in 0 ..< 4 {
                    let q = edge * 4 + k
                    let (pm, pb) = edge == 0 ? (e.topMb!, 12 + k) : (mb, q - 4)
                    e.h[edge * 4 + k] = pd.strength(pm, pb, mb, q, mbEdge: edge == 0)
                }
            }
        }
        return e
    }

    func thresholds(_ qpav: Int, _ p: SliceDeblock) -> (alpha: Int, beta: Int, indexA: Int)? {
        let indexA = clip3(0, 51, qpav + p.alpha), indexB = clip3(0, 51, qpav + p.beta)
        let a = Int(H264Tables.alpha[indexA]), b = Int(H264Tables.beta[indexB])
        return a > 0 && b > 0 ? (a, b, indexA) : nil
    }

    /// Vertical edges and internal horizontal edges (rows 4, 8, 12 / chroma 4) of `mb`:
    /// `horizontal` false = vertical edges, true = internal horizontal edges.
    func filterInside(_ mb: Int, _ e: Edges, horizontal: Bool, y: inout [UInt8], u: inout [UInt8], v: inout [UInt8]) {
        let mx = (mb % st.widthMbs) * 16
        let qp = Int(st.qp[mb])
        for edge in (horizontal ? 1 : 0) ..< 4 {
            let bs = horizontal ? Array(e.h[edge * 4 ..< edge * 4 + 4]) : Array(e.v[edge * 4 ..< edge * 4 + 4])
            guard bs != [0, 0, 0, 0] else { continue }
            let pqp = !horizontal && edge == 0 ? Int(st.qp[e.leftMb!]) : qp
            if let t = thresholds((pqp + qp + 1) >> 1, e.params) {
                for k in 0 ..< 4 where bs[k] > 0 {
                    let tc0 = bs[k] < 4 ? Int(H264Tables.tc0[t.indexA * 3 + bs[k] - 1]) : 0
                    for i in 0 ..< 4 {
                        // q0 position and the step across the edge.
                        let q0 = horizontal ? (edge * 4) * width + mx + k * 4 + i : (k * 4 + i) * width + mx + edge * 4
                        let s = horizontal ? width : 1
                        if let r = filterLine(Int(y[q0 - 4 * s]), Int(y[q0 - 3 * s]), Int(y[q0 - 2 * s]), Int(y[q0 - s]), Int(y[q0]), Int(y[q0 + s]), Int(y[q0 + 2 * s]), Int(y[q0 + 3 * s]),
                                              bs: bs[k], alpha: t.alpha, beta: t.beta, tc0: tc0, chroma: false) {
                            y[q0 - 3 * s] = UInt8(r.0); y[q0 - 2 * s] = UInt8(r.1); y[q0 - s] = UInt8(r.2)
                            y[q0] = UInt8(r.3); y[q0 + s] = UInt8(r.4); y[q0 + 2 * s] = UInt8(r.5)
                        }
                    }
                }
            }
            guard edge == 0 || edge == 2 else { continue }
            for c in 0 ..< 2 {
                let qc = Int(st.qpc[c * st.mbs + mb])
                let pqc = !horizontal && edge == 0 ? Int(st.qpc[c * st.mbs + e.leftMb!]) : qc
                guard let t = thresholds((pqc + qc + 1) >> 1, e.params) else { continue }
                for k in 0 ..< 4 where bs[k] > 0 {
                    let tc0 = bs[k] < 4 ? Int(H264Tables.tc0[t.indexA * 3 + bs[k] - 1]) : 0
                    for i in 0 ..< 2 {
                        let q0 = horizontal ? (edge * 2) * cwidth + mx / 2 + k * 2 + i : (k * 2 + i) * cwidth + mx / 2 + edge * 2
                        let s = horizontal ? cwidth : 1
                        if c == 0 {
                            if let r = filterLine(0, 0, Int(u[q0 - 2 * s]), Int(u[q0 - s]), Int(u[q0]), Int(u[q0 + s]), 0, 0, bs: bs[k], alpha: t.alpha, beta: t.beta, tc0: tc0, chroma: true) {
                                u[q0 - s] = UInt8(r.2); u[q0] = UInt8(r.3)
                            }
                        } else if let r = filterLine(0, 0, Int(v[q0 - 2 * s]), Int(v[q0 - s]), Int(v[q0]), Int(v[q0 + s]), 0, 0, bs: bs[k], alpha: t.alpha, beta: t.beta, tc0: tc0, chroma: true) {
                            v[q0 - s] = UInt8(r.2); v[q0] = UInt8(r.3)
                        }
                    }
                }
            }
        }
    }

    /// The top macroblock edge: p samples in the stripe above (`ay`, …), q in this one.
    func filterTop(_ mb: Int, _ e: Edges, ay: inout [UInt8], au: inout [UInt8], av: inout [UInt8], y: inout [UInt8], u: inout [UInt8], v: inout [UInt8]) {
        guard let top = e.topMb else { return }
        let bs = Array(e.h[0 ..< 4])
        guard bs != [0, 0, 0, 0] else { return }
        let mx = (mb % st.widthMbs) * 16
        let qp = Int(st.qp[mb])
        if let t = thresholds((Int(st.qp[top]) + qp + 1) >> 1, e.params) {
            for k in 0 ..< 4 where bs[k] > 0 {
                let tc0 = bs[k] < 4 ? Int(H264Tables.tc0[t.indexA * 3 + bs[k] - 1]) : 0
                for i in 0 ..< 4 {
                    let x = mx + k * 4 + i
                    let p0 = 15 * width + x
                    if let r = filterLine(Int(ay[p0 - 3 * width]), Int(ay[p0 - 2 * width]), Int(ay[p0 - width]), Int(ay[p0]), Int(y[x]), Int(y[width + x]), Int(y[2 * width + x]), Int(y[3 * width + x]),
                                          bs: bs[k], alpha: t.alpha, beta: t.beta, tc0: tc0, chroma: false) {
                        ay[p0 - 2 * width] = UInt8(r.0); ay[p0 - width] = UInt8(r.1); ay[p0] = UInt8(r.2)
                        y[x] = UInt8(r.3); y[width + x] = UInt8(r.4); y[2 * width + x] = UInt8(r.5)
                    }
                }
            }
        }
        for c in 0 ..< 2 {
            let qc = Int(st.qpc[c * st.mbs + mb])
            guard let t = thresholds((Int(st.qpc[c * st.mbs + top]) + qc + 1) >> 1, e.params) else { continue }
            for k in 0 ..< 4 where bs[k] > 0 {
                let tc0 = bs[k] < 4 ? Int(H264Tables.tc0[t.indexA * 3 + bs[k] - 1]) : 0
                for i in 0 ..< 2 {
                    let x = mx / 2 + k * 2 + i
                    let p0 = 7 * cwidth + x
                    if c == 0 {
                        if let r = filterLine(0, 0, Int(au[p0 - cwidth]), Int(au[p0]), Int(u[x]), Int(u[cwidth + x]), 0, 0, bs: bs[k], alpha: t.alpha, beta: t.beta, tc0: tc0, chroma: true) {
                            au[p0] = UInt8(r.2); u[x] = UInt8(r.3)
                        }
                    } else if let r = filterLine(0, 0, Int(av[p0 - cwidth]), Int(av[p0]), Int(v[x]), Int(v[cwidth + x]), 0, 0, bs: bs[k], alpha: t.alpha, beta: t.beta, tc0: tc0, chroma: true) {
                        av[p0] = UInt8(r.2); v[x] = UInt8(r.3)
                    }
                }
            }
        }
    }
}
