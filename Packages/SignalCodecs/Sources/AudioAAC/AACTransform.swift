// The synthesis filterbank (14496-3 4.6.11): IMDCT of 1024 (long) or 128 (short) coefficients,
// windowed with the sine or Kaiser–Bessel-derived window, overlap-added.
//
// IMDCT(X)[n] = 2/N Σ_k X[k] cos(2π/N (n + n0)(k + ½)),  n0 = (N/2 + 1)/2,  N = 2·len(X).
// Computed as a DCT-IV of size M = N/2 (via an M/2-point complex FFT) and unfolded:
//   x[n] = y[n + M/2]            for n < M/2
//        = −y[3M/2 − 1 − n]      for M/2 ≤ n < 3M/2
//        = −y[n − 3M/2]          for n ≥ 3M/2

import CodecCore

struct DCT4: Sendable {
    let m: Int
    /// e^(−iπn/M) before the FFT, e^(−iπ(4n+1)/(4M)) after it.
    let preCos: [Float], preSin: [Float]
    let postCos: [Float], postSin: [Float]
    /// The FFT's twiddles stage by stage (a stage of `size` points uses size/2 of them, in
    /// order), so each stage reads them contiguously.
    let twiddleCos: [Float], twiddleSin: [Float]
    let bitrev: [Int]

    init(size m: Int) {
        self.m = m
        let half = m / 2
        var pc = [Float](), ps = [Float](), qc = [Float](), qs = [Float]()
        for k in 0..<half {
            let a = -Double.pi * Double(k) / Double(m)
            pc.append(Float(LibM.cos(a)))
            ps.append(Float(LibM.sin(a)))
            let b = -Double.pi * Double(4 * k + 1) / Double(4 * m)
            qc.append(Float(LibM.cos(b)))
            qs.append(Float(LibM.sin(b)))
        }
        preCos = pc
        preSin = ps
        postCos = qc
        postSin = qs
        var tc = [Float](), ts = [Float]()
        var size = 2
        while size <= half {
            for i in 0..<size / 2 {
                let a = -2 * Double.pi * Double(i) / Double(size)
                tc.append(Float(LibM.cos(a)))
                ts.append(Float(LibM.sin(a)))
            }
            size <<= 1
        }
        twiddleCos = tc
        twiddleSin = ts
        var bits = 0
        while (1 << bits) < half { bits += 1 }
        bitrev = (0..<half).map { i in
            var r = 0, v = i
            for _ in 0..<bits { r = r << 1 | (v & 1); v >>= 1 }
            return r
        }
    }

    /// y[n] = Σ_k x[k] cos(π/M (n + ½)(k + ½)).
    func transform(_ x: [Float]) -> [Float] {
        var y = [Float](repeating: 0, count: m), re = [Float](repeating: 0, count: m / 2), im = re
        transform(x.span, into: &y, re: &re, im: &im)
        return y
    }

    /// As `transform`, into `y` (m values), with `re` and `im` (at least m/2 each) as scratch:
    /// no allocation.
    func transform(_ x: Span<Float>, into y: inout [Float], re: inout [Float], im: inout [Float]) {
        let half = m / 2
        var r = re.mutableSpan, i = im.mutableSpan
        do {
            let pc = preCos.span, ps = preSin.span, br = bitrev.span
            for k in 0..<half {
                let a = x[2 * k], b = x[m - 1 - 2 * k]
                let c = pc[k], s = ps[k], j = br[k]
                r[j] = a * c - b * s
                i[j] = a * s + b * c
            }
        }
        // Stages of 2 and 4 points: twiddles 1 and −i, no multiplications.
        var p = 0
        while p < half {
            let ar = r[p], ai = i[p], br = r[p + 1], bi = i[p + 1]
            r[p] = ar + br; i[p] = ai + bi
            r[p + 1] = ar - br; i[p + 1] = ai - bi
            p += 2
        }
        if half >= 4 {
            p = 0
            while p < half {
                let ar = r[p], ai = i[p], cr = r[p + 2], ci = i[p + 2]
                r[p] = ar + cr; i[p] = ai + ci
                r[p + 2] = ar - cr; i[p + 2] = ai - ci
                // × −i: (re, im) → (im, −re).
                let br = r[p + 1], bi = i[p + 1], dr = i[p + 3], di = -r[p + 3]
                r[p + 1] = br + dr; i[p + 1] = bi + di
                r[p + 3] = br - dr; i[p + 3] = bi - di
                p += 4
            }
        }
        let wc = twiddleCos.span, ws = twiddleSin.span
        var size = 8, tw = 3   // stages 2 and 4 used twiddles 0 and 1…2
        while size <= half {
            let h = size / 2
            var start = 0
            while start < half {
                for t in 0..<h {
                    let wr = wc[tw + t], wi = ws[tw + t]
                    let a = start + t, b = a + h
                    let tr = r[b] * wr - i[b] * wi, ti = r[b] * wi + i[b] * wr
                    r[b] = r[a] - tr
                    i[b] = i[a] - ti
                    r[a] += tr
                    i[a] += ti
                }
                start += size
            }
            tw += h
            size <<= 1
        }
        var out = y.mutableSpan
        let qc = postCos.span, qs = postSin.span
        for n in 0..<half {
            let c = qc[n], s = qs[n]
            out[2 * n] = r[n] * c - i[n] * s
            out[m - 1 - 2 * n] = -(r[n] * s + i[n] * c)
        }
    }
}

struct IMDCT: Sendable {
    let m: Int
    let dct: DCT4
    init(coefficients m: Int) {
        self.m = m
        dct = DCT4(size: m)
    }

    /// 2M outputs, scaled by 2/N (the standard's integer PCM scale).
    func transform(_ x: [Float]) -> [Float] {
        var s = Scratch()
        transform(x.span, &s)
        return Array(s.z.prefix(2 * m))
    }

    /// Buffers for `transform`, made once per decoder.
    struct Scratch: Sendable {
        var y: [Float], re: [Float], im: [Float]
        /// The 2M outputs.
        var z: [Float]

        init() {
            y = [Float](repeating: 0, count: 1024)
            re = [Float](repeating: 0, count: 512)
            im = re
            z = [Float](repeating: 0, count: 2048)
        }

        /// No buffers (what is left in a decoder while its own are in use): allocates nothing.
        init(empty: ()) { y = []; re = []; im = []; z = [] }
    }

    /// The 2M outputs into `scratch.z`.
    func transform(_ x: Span<Float>, _ scratch: inout Scratch) {
        dct.transform(x, into: &scratch.y, re: &scratch.re, im: &scratch.im)
        let scale = 2 / Float(2 * m)
        // z out of `scratch` while it is written (a span of y borrows `scratch` meanwhile).
        var z: [Float] = []
        swap(&z, &scratch.z)
        do {
            let y = scratch.y.span
            var out = z.mutableSpan
            let h = m / 2
            for n in 0..<h { out[n] = y[n + h] * scale }
            for n in h..<(3 * h) { out[n] = -y[3 * h - 1 - n] * scale }
            for n in (3 * h)..<(2 * m) { out[n] = -y[n - 3 * h] * scale }
        }
        swap(&z, &scratch.z)
    }
}

enum AACWindows {
    static func sine(_ n: Int) -> [Float] {
        (0..<n).map { Float(LibM.sin(Double.pi / Double(n) * (Double($0) + 0.5))) }
    }

    /// Kaiser–Bessel derived window (4.6.11.3.2), alpha 4 (long) or 6 (short).
    static func kbd(_ n: Int, alpha: Double) -> [Float] {
        func besselI0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0
            for k in 1..<50 {
                term *= (x / 2) * (x / 2) / Double(k * k)
                sum += term
                if term < sum * 1e-15 { break }
            }
            return sum
        }
        let half = n / 2
        var kernel = [Double](repeating: 0, count: half + 1)
        for i in 0...half {
            let t = (Double(i) - Double(half) / 2) / (Double(half) / 2)
            kernel[i] = besselI0(Double.pi * alpha * max(0, 1 - t * t).squareRoot())
        }
        let total = kernel.reduce(0, +)
        var w = [Float](repeating: 0, count: n)
        var acc = 0.0
        for i in 0..<half {
            acc += kernel[i]
            w[i] = Float((acc / total).squareRoot())
            w[n - 1 - i] = w[i]
        }
        return w
    }

    static let sineLong = sine(2048), sineShort = sine(256)
    static let kbdLong = kbd(2048, alpha: 4), kbdShort = kbd(256, alpha: 6)

    static func long(_ shape: Int) -> [Float] { shape == 1 ? kbdLong : sineLong }
    static func short(_ shape: Int) -> [Float] { shape == 1 ? kbdShort : sineShort }
}
