// Y′CbCr 4:2:0 → RGBA for still uses (the poster frame); playback converts on the GPU.
// BT.601 (matrix 5/6 and unspecified SD) or BT.709 (matrix 1, unspecified HD), limited or
// full range, chroma upsampled by its nearest sample, and the clockwise display rotation.

public enum YUVConvert {
    /// RGBA8 of the picture, rotated by `rotation` (0/90/180/270): (width, height, pixels).
    public static func rgba(_ p: YUVPicture, fullRange: Bool, matrix: Int, rotation: Int) -> (Int, Int, [UInt8]) {
        let bt709 = matrix == 1 || (matrix == 2 && p.height > 576)
        // Coefficients ×1024: R = Y + crR·Cr, G = Y − cbG·Cb − crG·Cr, B = Y + cbB·Cb.
        let (crR, cbG, crG, cbB): (Int, Int, Int, Int) = bt709
            ? (fullRange ? (1613, 192, 479, 1900) : (1836, 218, 546, 2163))
            : (fullRange ? (1436, 352, 731, 1815) : (1634, 401, 832, 2066))
        let w = p.width, h = p.height, cw = p.chromaWidth
        let rw = rotation % 180 == 0 ? w : h, rh = rotation % 180 == 0 ? h : w
        var out = [UInt8](repeating: 255, count: rw * rh * 4)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let yy = Int(p.y[y * w + x]), cb = Int(p.u[(y / 2) * cw + x / 2]) - 128, cr = Int(p.v[(y / 2) * cw + x / 2]) - 128
                let l = fullRange ? yy * 1024 : (yy - 16) * 1192
                let r = clip3(0, 255, (l + crR * cr + 512) >> 10), g = clip3(0, 255, (l - cbG * cb - crG * cr + 512) >> 10), b = clip3(0, 255, (l + cbB * cb + 512) >> 10)
                let (ox, oy): (Int, Int)
                switch rotation {
                case 90: (ox, oy) = (h - 1 - y, x)
                case 180: (ox, oy) = (w - 1 - x, h - 1 - y)
                case 270: (ox, oy) = (y, w - 1 - x)
                default: (ox, oy) = (x, y)
                }
                let o = (oy * rw + ox) * 4
                out[o] = UInt8(r); out[o + 1] = UInt8(g); out[o + 2] = UInt8(b)
            }
        }
        return (rw, rh, out)
    }
}
