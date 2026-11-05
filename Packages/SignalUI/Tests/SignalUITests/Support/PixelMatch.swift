// Port of mapbox/pixelmatch 7.x (ISC): perceptual (YIQ) colour distance with
// anti-aliasing detection, the comparison Playwright/Storybook visual tests use.
// Images are RGBA8, same size.

struct PixelMatch {
    var threshold = 0.1
    var includeAA = false

    /// Number of differing pixels; optional diff output (RGBA8) marks them red.
    func compare(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int, diff: inout [UInt8]?) -> Int {
        precondition(a.count == width * height * 4 && b.count == a.count)
        let maxDelta = 35215 * threshold * threshold
        var count = 0
        if diff != nil { diff = [UInt8](repeating: 0, count: a.count) }
        for y in 0..<height {
            for x in 0..<width {
                let pos = (y * width + x) * 4
                let delta = colorDelta(a, b, pos, pos, yOnly: false)
                if abs(delta) > maxDelta {
                    if !includeAA && (antialiased(a, x, y, width, height, b) || antialiased(b, x, y, width, height, a)) {
                        mark(&diff, pos, 255, 255, 0)
                    } else {
                        mark(&diff, pos, 255, 0, 0)
                        count += 1
                    }
                } else if diff != nil {
                    let v = UInt8(max(0, min(255, 255 + (gray(a, pos) - 255) * 0.1)))
                    mark(&diff, pos, v, v, v)
                }
            }
        }
        return count
    }

    func mark(_ d: inout [UInt8]?, _ pos: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
        guard d != nil else { return }
        d![pos] = r; d![pos + 1] = g; d![pos + 2] = b; d![pos + 3] = 255
    }

    func gray(_ img: [UInt8], _ k: Int) -> Double {
        let a = Double(img[k + 3]) / 255
        let r = 255 + (Double(img[k]) - 255) * a, g = 255 + (Double(img[k + 1]) - 255) * a, b = 255 + (Double(img[k + 2]) - 255) * a
        return r * 0.29889531 + g * 0.58662247 + b * 0.11448223
    }

    /// Whether the pixel looks like anti-aliasing (pixelmatch `antialiased`).
    func antialiased(_ img: [UInt8], _ x1: Int, _ y1: Int, _ width: Int, _ height: Int, _ img2: [UInt8]) -> Bool {
        let x0 = max(x1 - 1, 0), y0 = max(y1 - 1, 0), x2 = min(x1 + 1, width - 1), y2 = min(y1 + 1, height - 1)
        let pos = (y1 * width + x1) * 4
        var zeroes = (x1 == x0 || x1 == x2 || y1 == y0 || y1 == y2) ? 1 : 0
        var minD = 0.0, maxD = 0.0
        var minX = 0, minY = 0, maxX = 0, maxY = 0
        for x in x0...x2 {
            for y in y0...y2 {
                if x == x1 && y == y1 { continue }
                let delta = colorDelta(img, img, pos, (y * width + x) * 4, yOnly: true)
                if delta == 0 {
                    zeroes += 1
                    if zeroes > 2 { return false }
                } else if delta < minD {
                    minD = delta; minX = x; minY = y
                } else if delta > maxD {
                    maxD = delta; maxX = x; maxY = y
                }
            }
        }
        if minD == 0 || maxD == 0 { return false }
        return (hasManySiblings(img, minX, minY, width, height) && hasManySiblings(img2, minX, minY, width, height))
            || (hasManySiblings(img, maxX, maxY, width, height) && hasManySiblings(img2, maxX, maxY, width, height))
    }

    func hasManySiblings(_ img: [UInt8], _ x1: Int, _ y1: Int, _ width: Int, _ height: Int) -> Bool {
        let x0 = max(x1 - 1, 0), y0 = max(y1 - 1, 0), x2 = min(x1 + 1, width - 1), y2 = min(y1 + 1, height - 1)
        let pos = (y1 * width + x1) * 4
        var zeroes = (x1 == x0 || x1 == x2 || y1 == y0 || y1 == y2) ? 1 : 0
        for x in x0...x2 {
            for y in y0...y2 {
                if x == x1 && y == y1 { continue }
                let p = (y * width + x) * 4
                if img[pos] == img[p] && img[pos + 1] == img[p + 1] && img[pos + 2] == img[p + 2] && img[pos + 3] == img[p + 3] { zeroes += 1 }
                if zeroes > 2 { return true }
            }
        }
        return false
    }

    func colorDelta(_ img1: [UInt8], _ img2: [UInt8], _ k: Int, _ m: Int, yOnly: Bool) -> Double {
        var r1 = Double(img1[k]), g1 = Double(img1[k + 1]), b1 = Double(img1[k + 2]), a1 = Double(img1[k + 3])
        var r2 = Double(img2[m]), g2 = Double(img2[m + 1]), b2 = Double(img2[m + 2]), a2 = Double(img2[m + 3])
        if a1 == a2 && r1 == r2 && g1 == g2 && b1 == b2 { return 0 }
        if a1 < 255 {
            a1 /= 255
            r1 = 255 + (r1 - 255) * a1; g1 = 255 + (g1 - 255) * a1; b1 = 255 + (b1 - 255) * a1
        }
        if a2 < 255 {
            a2 /= 255
            r2 = 255 + (r2 - 255) * a2; g2 = 255 + (g2 - 255) * a2; b2 = 255 + (b2 - 255) * a2
        }
        let y1 = r1 * 0.29889531 + g1 * 0.58662247 + b1 * 0.11448223
        let y2 = r2 * 0.29889531 + g2 * 0.58662247 + b2 * 0.11448223
        let y = y1 - y2
        if yOnly { return y }
        let i = (r1 * 0.59597799 - g1 * 0.2741761 - b1 * 0.32180189) - (r2 * 0.59597799 - g2 * 0.2741761 - b2 * 0.32180189)
        let q = (r1 * 0.21147017 - g1 * 0.52261711 + b1 * 0.31114694) - (r2 * 0.21147017 - g2 * 0.52261711 + b2 * 0.31114694)
        let delta = 0.5053 * y * y + 0.299 * i * i + 0.1957 * q * q
        return y1 > y2 ? -delta : delta
    }
}
