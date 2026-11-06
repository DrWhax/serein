// Poster frames of HDR video (BT.2020 HLG / PQ) as SDR RGBA: the renderer's shader maths on
// the CPU (VideoRenderer's COLOUR 3 / 4 path), so a poster matches what playback shows.

import Foundation
import VideoH264

enum HDRConvert {
    static func rgba(_ p: YUVPicture, fullRange: Bool, pq: Bool, rotation: Int) -> (Int, Int, [UInt8]) {
        let w = p.width, h = p.height, cw = (w + 1) / 2
        // Per-code lookup of the transfer's signal → display light (relative to 203 cd/m²).
        var out = [UInt8](repeating: 255, count: w * h * 4)
        let k = fullRange ? 1.0 : 255.0 / 224
        for y in 0..<h {
            for x in 0..<w {
                let yy = Double(p.y[x + y * w]), cb = Double(p.u[x / 2 + (y / 2) * cw]) - 128, cr = Double(p.v[x / 2 + (y / 2) * cw]) - 128
                let l = fullRange ? yy / 255 : (yy - 16) / 219
                var rgb = [l + 1.4746 * k * cr / 255, l - 0.16455 * k * cb / 255 - 0.57135 * k * cr / 255, l + 1.8814 * k * cb / 255].map { min(max($0, 0), 1) }
                var lin: [Double]
                if pq {
                    let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
                    lin = rgb.map { let e = pow($0, 1 / m2); return pow(max(e - c1, 0) / (c2 - c3 * e), 1 / m1) * 10000 / 203 }
                } else {
                    let a = 0.17883277, b = 0.28466892, c = 0.55991073
                    let scene = rgb.map { $0 <= 0.5 ? $0 * $0 * 3 / 12 : (exp(($0 - c) / a) + b) / 12 }
                    let ys = 0.2627 * scene[0] + 0.6780 * scene[1] + 0.0593 * scene[2]
                    lin = scene.map { $0 * pow(max(ys, 1e-6), 0.2) * 1000 / 203 }
                }
                let lumIn = 0.2627 * lin[0] + 0.6780 * lin[1] + 0.0593 * lin[2]
                let lumOut = lumIn <= 0.8 ? lumIn : 0.8 + 0.2 * (1 - exp(-(lumIn - 0.8) / 0.2))
                lin = lin.map { $0 * (lumIn > 0 ? lumOut / lumIn : 0) }
                rgb = [1.6605 * lin[0] - 0.5876 * lin[1] - 0.0728 * lin[2], -0.1246 * lin[0] + 1.1329 * lin[1] - 0.0083 * lin[2],
                       -0.0182 * lin[0] - 0.1006 * lin[1] + 1.1187 * lin[2]].map { pow(min(max($0, 0), 1), 1 / 2.4) }
                let o = (x + y * w) * 4
                out[o] = UInt8((rgb[0] * 255).rounded())
                out[o + 1] = UInt8((rgb[1] * 255).rounded())
                out[o + 2] = UInt8((rgb[2] * 255).rounded())
            }
        }
        return rotate(w, h, out, rotation)
    }

    /// RGBA rotated clockwise by 0 / 90 / 180 / 270.
    static func rotate(_ w: Int, _ h: Int, _ px: [UInt8], _ rotation: Int) -> (Int, Int, [UInt8]) {
        let r = ((rotation % 360) + 360) % 360
        guard r != 0 else { return (w, h, px) }
        let (ow, oh) = r % 180 == 0 ? (w, h) : (h, w)
        var out = [UInt8](repeating: 0, count: px.count)
        for y in 0..<h {
            for x in 0..<w {
                let (nx, ny): (Int, Int) = switch r {
                case 90: (h - 1 - y, x)
                case 180: (w - 1 - x, h - 1 - y)
                default: (y, w - 1 - x)
                }
                for c in 0..<4 { out[(nx + ny * ow) * 4 + c] = px[(x + y * w) * 4 + c] }
            }
        }
        return (ow, oh, out)
    }
}
