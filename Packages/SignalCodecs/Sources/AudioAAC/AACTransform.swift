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
    let fftCos: [Float], fftSin: [Float]
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
        var fc = [Float](), fs = [Float]()
        for k in 0..<half / 2 {
            let a = -2 * Double.pi * Double(k) / Double(half)
            fc.append(Float(LibM.cos(a)))
            fs.append(Float(LibM.sin(a)))
        }
        fftCos = fc
        fftSin = fs
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
        let half = m / 2
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        for k in 0..<half {
            let a = x[2 * k], b = x[m - 1 - 2 * k]
            let c = preCos[k], s = preSin[k]
            let j = bitrev[k]
            re[j] = a * c - b * s
            im[j] = a * s + b * c
        }
        var size = 2
        while size <= half {
            let step = half / size
            for start in stride(from: 0, to: half, by: size) {
                for i in 0..<size / 2 {
                    let wr = fftCos[i * step], wi = fftSin[i * step]
                    let p = start + i, q = p + size / 2
                    let tr = re[q] * wr - im[q] * wi, ti = re[q] * wi + im[q] * wr
                    re[q] = re[p] - tr
                    im[q] = im[p] - ti
                    re[p] += tr
                    im[p] += ti
                }
            }
            size <<= 1
        }
        var y = [Float](repeating: 0, count: m)
        for n in 0..<half {
            let c = postCos[n], s = postSin[n]
            let wr = re[n] * c - im[n] * s, wi = re[n] * s + im[n] * c
            y[2 * n] = wr
            y[m - 1 - 2 * n] = -wi
        }
        return y
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
        let y = dct.transform(x)
        let scale = 2 / Float(2 * m)
        var out = [Float](repeating: 0, count: 2 * m)
        let h = m / 2
        for n in 0..<h { out[n] = y[n + h] * scale }
        for n in h..<(3 * h) { out[n] = -y[3 * h - 1 - n] * scale }
        for n in (3 * h)..<(2 * m) { out[n] = -y[n - 3 * h] * scale }
        return out
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
