// Y′CbCr planes → RGBA8 for still images (H.273 code points):
//   matrix 0 identity (G, B, R in Y, Cb, Cr), 1 BT.709, 4 FCC, 5/6 BT.601, 7 SMPTE 240M,
//   8 YCgCo, 9/10 BT.2020, 2 and anything else BT.601 (what libavif and libheif assume);
//   limited or full range; any bit depth; 4:0:0, 4:2:0, 4:2:2, 4:4:4 with bilinear chroma
//   upsampling (centred siting). PQ (16) and HLG (18) are tone-mapped to SDR with the video
//   renderer's maths (203 cd/m² white, soft shoulder, BT.2020 → BT.709 when the primaries
//   are BT.2020), so a still matches what an HDR video poster shows.

import CodecCore
import ContainerMP4

enum HEIFColourConvert {
    static func coefficients(_ matrix: Int) -> (kr: Double, kb: Double) {
        switch matrix {
        case 1: (0.2126, 0.0722)
        case 4: (0.30, 0.11)
        case 7: (0.212, 0.087)
        case 9, 10: (0.2627, 0.0593)
        default: (0.299, 0.114)
        }
    }

    /// Chroma sample at full resolution (x, y), bilinear from the subsampled plane.
    @inline(__always)
    static func chroma(_ c: [UInt16], _ cw: Int, _ ch: Int, _ x: Int, _ y: Int, _ ssx: Int, _ ssy: Int) -> Int {
        // Taps (and weights out of 4) along one axis: subsampled ×2 → 3:1 between neighbours.
        func taps(_ p: Int, _ ss: Int, _ n: Int) -> (Int, Int, Int) {
            guard ss == 1 else { return (p, p, 4) }
            let base = p >> 1
            let other = p & 1 == 0 ? max(base - 1, 0) : min(base + 1, n - 1)
            return (base, other, 3)
        }
        let (x0, x1, wx) = taps(x, ssx, cw), (y0, y1, wy) = taps(y, ssy, ch)
        let a = Int(c[y0 * cw + x0]), b = Int(c[y0 * cw + x1]), d = Int(c[y1 * cw + x0]), e = Int(c[y1 * cw + x1])
        let top = a * wx + b * (4 - wx), bottom = d * wx + e * (4 - wx)
        return (top * wy + bottom * (4 - wy) + 8) >> 4
    }

    static func rgba(_ p: HEIFPlanes, alpha: HEIFPlanes?, premultiplied: Bool) -> [UInt8] {
        let w = p.width, h = p.height, depth = p.bitDepth
        let maxCode = Double((1 << depth) - 1), scale = Double(1 << (depth - 8))
        let full = p.colour.fullRange
        // Normalised Y′ and C (C ∈ [-0.5, 0.5]) from codes.
        let yOff = full ? 0 : 16 * scale, yDiv = full ? maxCode : 219 * scale
        let cOff = Double(1 << (depth - 1)), cDiv = full ? maxCode : 224 * scale
        let (kr, kb) = coefficients(p.colour.matrix)
        let kg = 1 - kr - kb
        let crR = 2 * (1 - kr), cbB = 2 * (1 - kb), cbG = 2 * kb * (1 - kb) / kg, crG = 2 * kr * (1 - kr) / kg
        let hdr = p.colour.transfer == 16 || p.colour.transfer == 18
        let toneMap = hdr ? HDRToneMap(pq: p.colour.transfer == 16, bt2020: p.colour.primaries == 9) : nil
        var out = [UInt8](repeating: 255, count: w * h * 4)
        let cw = p.chromaWidth, ch = p.chromaHeight, ssx = p.subsamplingX, ssy = p.subsamplingY
        let matrix = p.colour.matrix
        for y in 0..<h {
            for x in 0..<w {
                let yy = (Double(p.y[y * w + x]) - yOff) / yDiv
                var cbCode = 0, crCode = 0, cb = 0.0, cr = 0.0
                if p.chromaFormat != 0 {
                    cbCode = chroma(p.u, cw, ch, x, y, ssx, ssy)
                    crCode = chroma(p.v, cw, ch, x, y, ssx, ssy)
                    cb = (Double(cbCode) - cOff) / cDiv
                    cr = (Double(crCode) - cOff) / cDiv
                }
                var r: Double, g: Double, b: Double
                switch matrix {
                case 0 where p.chromaFormat != 0:
                    // GBR: every plane is coded like luma.
                    g = yy; b = (Double(cbCode) - yOff) / yDiv; r = (Double(crCode) - yOff) / yDiv
                case 8 where p.chromaFormat != 0:
                    let t = yy - cb
                    g = yy + cb; b = t - cr; r = t + cr
                default:
                    r = yy + crR * cr
                    g = yy - cbG * cb - crG * cr
                    b = yy + cbB * cb
                }
                if let toneMap { (r, g, b) = toneMap.map(r, g, b) }
                let o = (y * w + x) * 4
                out[o] = UInt8(max(0, min(255, (r * 255).rounded())))
                out[o + 1] = UInt8(max(0, min(255, (g * 255).rounded())))
                out[o + 2] = UInt8(max(0, min(255, (b * 255).rounded())))
            }
        }
        if let a = alpha {
            // Alpha codes are full range (AVIF; HEIF auxiliary alpha as written by encoders).
            let am = (1 << a.bitDepth) - 1
            for i in 0..<(w * h) {
                let v = (Int(a.y[i]) * 255 + am / 2) / am
                out[i * 4 + 3] = UInt8(v)
                if premultiplied {
                    for c in 0..<3 {
                        let s = Int(out[i * 4 + c])
                        out[i * 4 + c] = v == 0 ? 0 : UInt8(min(255, (s * 255 + v / 2) / v))
                    }
                }
            }
        }
        return out
    }
}

/// PQ / HLG signal → SDR display values (VideoRenderer's COLOUR 3 / 4 path and HDRConvert).
struct HDRToneMap {
    let pq: Bool
    let bt2020: Bool
    /// Signal (0…1, 4096 steps) → linear light relative to 203 cd/m² (PQ), or scene light (HLG).
    let lut: [Double]

    init(pq: Bool, bt2020: Bool) {
        self.pq = pq
        self.bt2020 = bt2020
        var lut = [Double](repeating: 0, count: 4097)
        for i in 0...4096 {
            let v = Double(i) / 4096
            if pq {
                let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
                let e = LibM.pow(v, 1 / m2)
                lut[i] = LibM.pow(max(e - c1, 0) / (c2 - c3 * e), 1 / m1) * 10000 / 203
            } else {
                let a = 0.17883277, b = 0.28466892, c = 0.55991073
                lut[i] = v <= 0.5 ? v * v * 3 / 12 : (LibM.exp((v - c) / a) + b) / 12
            }
        }
        self.lut = lut
    }

    func signal(_ v: Double) -> Double {
        let x = min(max(v, 0), 1) * 4096
        let i = min(Int(x), 4095), f = x - Double(i)
        return lut[i] + (lut[i + 1] - lut[i]) * f
    }

    func map(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        var lr = signal(r), lg = signal(g), lb = signal(b)
        if !pq {
            // HLG OOTF for a 1000 cd/m² display, then relative to 203 cd/m².
            let ys = 0.2627 * lr + 0.6780 * lg + 0.0593 * lb
            let k = LibM.pow(max(ys, 1e-6), 0.2) * 1000 / 203
            lr *= k; lg *= k; lb *= k
        }
        let lumIn = 0.2627 * lr + 0.6780 * lg + 0.0593 * lb
        let lumOut = lumIn <= 0.8 ? lumIn : 0.8 + 0.2 * (1 - LibM.exp(-(lumIn - 0.8) / 0.2))
        let k = lumIn > 0 ? lumOut / lumIn : 0
        lr *= k; lg *= k; lb *= k
        if bt2020 {
            (lr, lg, lb) = (1.6605 * lr - 0.5876 * lg - 0.0728 * lb, -0.1246 * lr + 1.1329 * lg - 0.0083 * lb, -0.0182 * lr - 0.1006 * lg + 1.1187 * lb)
        }
        func encode(_ v: Double) -> Double { LibM.pow(min(max(v, 0), 1), 1 / 2.4) }
        return (encode(lr), encode(lg), encode(lb))
    }
}

/// clap / irot / imir on RGBA8.
enum HEIFTransform {
    /// The clean aperture (23008-12 / 14496-12 12.1.4): centred at the image centre plus the
    /// offset; edges rounded to whole pixels, which must lie inside the image.
    static func crop(_ px: [UInt8], _ w: Int, _ h: Int, _ c: HEIFCleanAperture) throws(ParseFailure) -> (Int, Int, [UInt8]) {
        guard c.widthD > 0, c.heightD > 0, c.horizOffD > 0, c.vertOffD > 0 else {
            throw ParseFailure(offset: 0, rule: "clap", reason: .invalid("zero denominator"))
        }
        let cw = Double(c.widthN) / Double(c.widthD), chh = Double(c.heightN) / Double(c.heightD)
        let cx = Double(c.horizOffN) / Double(c.horizOffD) + Double(w - 1) / 2
        let cy = Double(c.vertOffN) / Double(c.vertOffD) + Double(h - 1) / 2
        let left = (cx - (cw - 1) / 2).rounded(), top = (cy - (chh - 1) / 2).rounded()
        let width = cw.rounded(), height = chh.rounded()
        guard left >= 0, top >= 0, width >= 1, height >= 1, left + width <= Double(w), top + height <= Double(h) else {
            throw ParseFailure(offset: 0, rule: "clap", reason: .invalid("aperture outside the image"))
        }
        let l = Int(left), t = Int(top), nw = Int(width), nh = Int(height)
        if l == 0, t == 0, nw == w, nh == h { return (w, h, px) }
        var out = [UInt8](repeating: 0, count: nw * nh * 4)
        for y in 0..<nh { out.replaceSubrange(y * nw * 4 ..< (y + 1) * nw * 4, with: px[((t + y) * w + l) * 4 ..< ((t + y) * w + l + nw) * 4]) }
        return (nw, nh, out)
    }

    static func rotateAnticlockwise(_ px: [UInt8], _ w: Int, _ h: Int, quarterTurns: Int) -> (Int, Int, [UInt8]) {
        let q = quarterTurns & 3
        guard q != 0 else { return (w, h, px) }
        let (ow, oh) = q == 2 ? (w, h) : (h, w)
        var out = [UInt8](repeating: 0, count: px.count)
        for y in 0..<h {
            for x in 0..<w {
                let (nx, ny): (Int, Int) = switch q {
                case 1: (y, w - 1 - x)
                case 2: (w - 1 - x, h - 1 - y)
                default: (h - 1 - y, x)
                }
                let s = (y * w + x) * 4, d = (ny * ow + nx) * 4
                out[d] = px[s]; out[d + 1] = px[s + 1]; out[d + 2] = px[s + 2]; out[d + 3] = px[s + 3]
            }
        }
        return (ow, oh, out)
    }

    /// imir mode (23008-12:2022 6.5.12, as libavif and so Chromium read it): 0 exchanges top
    /// and bottom, 1 exchanges left and right.
    static func mirror(_ px: [UInt8], _ w: Int, _ h: Int, axis: Int) -> [UInt8] {
        var out = px
        for y in 0..<h {
            for x in 0..<w {
                let (sx, sy) = axis == 0 ? (x, h - 1 - y) : (w - 1 - x, y)
                let s = (sy * w + sx) * 4, d = (y * w + x) * 4
                out[d] = px[s]; out[d + 1] = px[s + 1]; out[d + 2] = px[s + 2]; out[d + 3] = px[s + 3]
            }
        }
        return out
    }
}
