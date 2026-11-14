// Decoded frames scaled down to the size the player shows them at (VideoFit) before they cross
// to the app: a 3594x2152 screen recording is 11.6 MB a frame as decoded, and the app's view of
// it is often a bubble a few hundred pixels wide. Area averaging: each output sample is the mean
// of the input it covers, by exact overlap (no aliasing, unlike the GPU's linear sampling of a
// much larger texture). Separable: down first, into 16-bit intermediates carrying the extra
// precision, then across; output rows in parallel chunks. Planes are 8-bit, or 16-bit
// little-endian samples of `bitDepth` bits (10/12-bit video).

import CodecCore
import MediaXPCInterface
import VideoH264

enum PlaneScaler {
    /// Weights are fixed point: each output sample's weights sum to exactly 1 << `bits`.
    static let bits = 14

    /// An area-averaging resampler from `n` samples to `m` (1 <= m <= n): output `i` covers
    /// input [i·n/m, (i+1)·n/m), and is the sum over `t < count` of input `first[i] + t` times
    /// `weights[i · count + t]` (the same number of taps for every output, unused ones 0).
    struct Taps: Sendable {
        let count: Int
        var first: [Int]
        var weights: [UInt32]

        init(from n: Int, to m: Int) {
            precondition(m >= 1 && m <= n)
            let one = 1 << PlaneScaler.bits
            // An output spans n/m inputs, touching at most ⌈n/m⌉ + 1 of them.
            let k = min(n, (n + m - 1) / m + 1)
            var starts = [Int](repeating: 0, count: m)
            var table = [UInt32](repeating: 0, count: m * k)
            var f = starts.mutableSpan, w = table.mutableSpan
            for i in 0..<m {
                // In units of 1/m of an input sample: output i is [i·n, (i+1)·n), input j is [j·m, (j+1)·m).
                let lo = i * n, hi = (i + 1) * n
                let j0 = lo / m, j1 = (hi - 1) / m
                // Taps start early enough to stay inside the input.
                let start = min(j0, n - k)
                f[i] = start
                var sum = 0, largest = j0
                var largestWeight = -1
                for j in j0...j1 {
                    let v = ((min((j + 1) * m, hi) - max(j * m, lo)) * one + n / 2) / n
                    w[i * k + j - start] = UInt32(v)
                    sum += v
                    if v > largestWeight { largestWeight = v; largest = j }
                }
                // Rounding leaves the sum a little off: the largest weight takes the difference.
                w[i * k + largest - start] = UInt32(largestWeight + one - sum)
            }
            count = k
            first = starts
            weights = table
        }
    }

    /// `plane` (`n` x `h` samples) scaled to `m` x `mh` (each no larger than the input). Output
    /// rows are made in chunks in parallel, each from the input rows it covers: those rows
    /// resampled down into one row of 16-bit intermediates (keeping `16 − bitDepth` extra bits;
    /// contiguous, so it vectorises), then across. Down first, the across pass, whose reads are
    /// scattered, runs on the output rows only.
    static func scale(_ plane: [UInt8], width n: Int, height h: Int, to m: Int, _ mh: Int, bitDepth: Int) -> [UInt8] {
        let two = bitDepth > 8
        let extra = 16 - (two ? bitDepth : 8)
        let hx = Taps(from: n, to: m), vy = Taps(from: h, to: mh)
        let length = two ? 2 * m : m
        return ParallelRows.build(rows: mh, rowLength: length, chunk: 16, zero: UInt8(0)) { range, out in
            var mid = [UInt16](repeating: 0, count: n)
            var acc = [UInt32](repeating: 0, count: n)
            for (r, y) in range.enumerated() {
                down(plane, width: n, row: y, vy, two: two, extra: extra, acc: &acc, into: &mid)
                across(mid, hx, to: m, two: two, extra: extra, into: &out, at: r * length)
            }
        }
    }

    /// Output row `y` of the input resampled down, into `mid` (`n` samples).
    static func down(_ plane: [UInt8], width n: Int, row y: Int, _ taps: Taps, two: Bool, extra: Int, acc: inout [UInt32], into mid: inout [UInt16]) {
        let shift = UInt32(bits - extra), round = UInt32(1) << (shift - 1), k = taps.count
        let src = plane.span, first = taps.first.span, weights = taps.weights.span
        var a = acc.mutableSpan
        for i in 0..<n { a[i] = round }
        for t in 0..<k {
            let w = weights[y * k + t]
            if w == 0 { continue }
            let base = (first[y] + t) * n
            if two {
                for i in 0..<n { a[i] &+= (UInt32(src[2 * (base + i)]) | UInt32(src[2 * (base + i) + 1]) << 8) &* w }
            } else {
                for i in 0..<n { a[i] &+= UInt32(src[base + i]) &* w }
            }
        }
        var d = mid.mutableSpan
        for i in 0..<n { d[i] = UInt16(truncatingIfNeeded: a[i] >> shift) }
    }

    /// One row of `mid` resampled across to `m` samples, written at `at` in `out`.
    static func across(_ mid: [UInt16], _ taps: Taps, to m: Int, two: Bool, extra: Int, into out: inout [UInt8], at row: Int) {
        let shift = UInt32(bits + extra), round = UInt32(1) << (shift - 1), k = taps.count
        let src = mid.span, first = taps.first.span, weights = taps.weights.span
        var dst = out.mutableSpan
        for i in 0..<m {
            var acc = round
            let j = first[i], wb = i * k
            for t in 0..<k { acc &+= UInt32(src[j + t]) &* weights[wb + t] }
            let v = acc >> shift
            if two {
                dst[row + 2 * i] = UInt8(truncatingIfNeeded: v)
                dst[row + 2 * i + 1] = UInt8(truncatingIfNeeded: v >> 8)
            } else {
                dst[row + i] = UInt8(truncatingIfNeeded: v)
            }
        }
    }
}

extension DecodedVideoFrame {
    /// The frame at the size `fit` shows it at (with the track's `rotation`); itself when it is
    /// not larger than that.
    func scaled(to fit: VideoFit, rotation: Int) -> DecodedVideoFrame {
        let p = picture
        let (w, h) = fit.frameSize(width: p.width, height: p.height, rotation: rotation)
        guard w < p.width || h < p.height else { return self }
        let depth = bitDepth
        var out = YUVPicture(width: 0, height: 0)
        out.width = w
        out.height = h
        out.y = PlaneScaler.scale(p.y, width: p.width, height: p.height, to: w, h, bitDepth: depth)
        let cw = (p.width + 1) / 2, ch = (p.height + 1) / 2
        out.u = PlaneScaler.scale(p.u, width: cw, height: ch, to: w / 2, h / 2, bitDepth: depth)
        out.v = PlaneScaler.scale(p.v, width: cw, height: ch, to: w / 2, h / 2, bitDepth: depth)
        var f = self
        f.picture = out
        return f
    }
}
