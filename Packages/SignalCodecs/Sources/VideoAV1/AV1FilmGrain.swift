// Film grain synthesis (7.18.3): the pseudo-random generator, luma / chroma grain templates
// with the auto-regressive filter, the piecewise-linear scaling functions, and the noise
// stripes blended (with overlap) onto the output.

struct AV1FilmGrain {
    let params: AV1FilmGrainParams
    let bitDepth: Int
    let monochrome: Bool
    let subX: Int, subY: Int
    let matrixCoefficients: Int

    struct Random {
        var register: Int
        mutating func next(_ bits: Int) -> Int {
            let r = register
            let bit = ((r >> 0) ^ (r >> 1) ^ (r >> 3) ^ (r >> 12)) & 1
            let n = (r >> 1) | (bit << 15)
            register = n
            return (n >> (16 - bits)) & ((1 << bits) - 1)
        }
    }

    func apply(_ frame: inout AV1Frame) {
        let p = params
        let bd = bitDepth
        let grainCenter = 128 << (bd - 8)
        let grainMin = -grainCenter, grainMax = (256 << (bd - 8)) - 1 - grainCenter
        let gauss = AV1C.gaussianSequence
        // Generate grain (7.18.3.3).
        var rng = Random(register: p.grainSeed)
        var shift = 12 - bd + p.grainScaleShift
        var luma = [Int](repeating: 0, count: 73 * 82)
        for y in 0..<73 {
            for x in 0..<82 {
                let g = p.pointY.isEmpty ? 0 : gauss[rng.next(11)]
                luma[y * 82 + x] = round2(g, shift)
            }
        }
        let arShift = p.arCoeffShiftMinus6 + 6
        let lag = p.arCoeffLag
        if !p.pointY.isEmpty {
            for y in 3..<73 {
                for x in 3..<(82 - 3) {
                    var s = 0, pos = 0
                    outer: for dr in -lag...0 {
                        for dc in -lag...lag {
                            if dr == 0 && dc == 0 { break outer }
                            s += luma[(y + dr) * 82 + x + dc] * (p.arCoeffsY[pos] - 128)
                            pos += 1
                        }
                    }
                    luma[y * 82 + x] = clip3(grainMin, grainMax, luma[y * 82 + x] + round2(s, arShift))
                }
            }
        }
        let chromaW = subX == 1 ? 44 : 82, chromaH = subY == 1 ? 38 : 73
        var cb = [Int](repeating: 0, count: chromaW * chromaH), cr = cb
        if !monochrome {
            shift = 12 - bd + p.grainScaleShift
            rng.register = p.grainSeed ^ 0xb524
            for y in 0..<chromaH {
                for x in 0..<chromaW {
                    let g = !p.pointCb.isEmpty || p.chromaScalingFromLuma ? gauss[rng.next(11)] : 0
                    cb[y * chromaW + x] = round2(g, shift)
                }
            }
            rng.register = p.grainSeed ^ 0x49d8
            for y in 0..<chromaH {
                for x in 0..<chromaW {
                    let g = !p.pointCr.isEmpty || p.chromaScalingFromLuma ? gauss[rng.next(11)] : 0
                    cr[y * chromaW + x] = round2(g, shift)
                }
            }
            for y in 3..<chromaH {
                for x in 3..<(chromaW - 3) {
                    var s0 = 0, s1 = 0, pos = 0
                    outer: for dr in -lag...0 {
                        for dc in -lag...lag {
                            let c0 = p.arCoeffsCb.isEmpty ? 0 : p.arCoeffsCb[pos] - 128
                            let c1 = p.arCoeffsCr.isEmpty ? 0 : p.arCoeffsCr[pos] - 128
                            if dr == 0 && dc == 0 {
                                if !p.pointY.isEmpty {
                                    var l = 0
                                    let lx = ((x - 3) << subX) + 3, ly = ((y - 3) << subY) + 3
                                    for i in 0...subY { for j in 0...subX { l += luma[(ly + i) * 82 + lx + j] } }
                                    l = round2(l, subX + subY)
                                    s0 += l * c0
                                    s1 += l * c1
                                }
                                break outer
                            }
                            s0 += cb[(y + dr) * chromaW + x + dc] * c0
                            s1 += cr[(y + dr) * chromaW + x + dc] * c1
                            pos += 1
                        }
                    }
                    cb[y * chromaW + x] = clip3(grainMin, grainMax, cb[y * chromaW + x] + round2(s0, arShift))
                    cr[y * chromaW + x] = clip3(grainMin, grainMax, cr[y * chromaW + x] + round2(s1, arShift))
                }
            }
        }
        // Scaling lookup (7.18.3.4).
        func lut(_ points: [(value: Int, scaling: Int)]) -> [Int] {
            var t = [Int](repeating: 0, count: 256)
            guard let first = points.first, let last = points.last else { return t }
            for x in 0..<first.value { t[x] = first.scaling }
            for i in 0..<(points.count - 1) {
                let deltaY = points[i + 1].scaling - points[i].scaling
                let deltaX = points[i + 1].value - points[i].value
                let delta = deltaY * ((65536 + (deltaX >> 1)) / deltaX)
                for x in 0..<deltaX { t[points[i].value + x] = points[i].scaling + ((x * delta + 32768) >> 16) }
            }
            for x in last.value..<256 { t[x] = last.scaling }
            return t
        }
        let lutY = lut(p.pointY)
        let lutCb = p.chromaScalingFromLuma ? lutY : lut(p.pointCb)
        let lutCr = p.chromaScalingFromLuma ? lutY : lut(p.pointCr)
        func scale(_ t: [Int], _ index: Int) -> Int {
            let s = bd - 8
            let x = index >> s
            let rem = index - (x << s)
            if bd == 8 || x == 255 { return t[x] }
            let start = t[x], end = t[x + 1]
            return start + round2((end - start) * rem, s)
        }
        // Noise stripes (7.18.3.5).
        let w = frame.width, h = frame.height
        let numPlanes = monochrome ? 1 : 3
        let stripes = (h + 31) / 32 + 1
        let stripeW = [((w + 1) / 2 + 16) * 2 + 34, (((w + 1) / 2 + 16) * 2 + 34) >> subX, (((w + 1) / 2 + 16) * 2 + 34) >> subX]
        var noiseStripe: [[[Int]]] = Array(repeating: (0..<3).map { [Int](repeating: 0, count: stripeW[$0] * 34) }, count: stripes)
        var lumaNum = 0
        var y = 0
        while y < (h + 1) / 2 {
            var r = Random(register: p.grainSeed)
            r.register ^= ((lumaNum * 37 + 178) & 255) << 8
            r.register ^= (lumaNum * 173 + 105) & 255
            var x = 0
            while x < (w + 1) / 2 {
                let rand = r.next(8)
                let offsetX = rand >> 4, offsetY = rand & 15
                for plane in 0..<numPlanes {
                    let psx = plane > 0 ? subX : 0, psy = plane > 0 ? subY : 0
                    let planeOffsetX = psx == 1 ? 6 + offsetX : 9 + offsetX * 2
                    let planeOffsetY = psy == 1 ? 6 + offsetY : 9 + offsetY * 2
                    let sw = stripeW[plane]
                    for i in 0..<(34 >> psy) {
                        for j in 0..<(34 >> psx) {
                            var g: Int
                            switch plane {
                            case 0: g = luma[(planeOffsetY + i) * 82 + planeOffsetX + j]
                            case 1: g = cb[(planeOffsetY + i) * chromaW + planeOffsetX + j]
                            default: g = cr[(planeOffsetY + i) * chromaW + planeOffsetX + j]
                            }
                            if psx == 0 {
                                let idx = i * sw + x * 2 + j
                                if j < 2 && p.overlapFlag && x > 0 {
                                    let old = noiseStripe[lumaNum][plane][idx]
                                    g = j == 0 ? old * 27 + g * 17 : old * 17 + g * 27
                                    g = clip3(grainMin, grainMax, round2(g, 5))
                                }
                                noiseStripe[lumaNum][plane][idx] = g
                            } else {
                                let idx = i * sw + x + j
                                if j == 0 && p.overlapFlag && x > 0 {
                                    let old = noiseStripe[lumaNum][plane][idx]
                                    g = old * 23 + g * 22
                                    g = clip3(grainMin, grainMax, round2(g, 5))
                                }
                                noiseStripe[lumaNum][plane][idx] = g
                            }
                        }
                    }
                }
                x += 16
            }
            lumaNum += 1
            y += 16
        }
        // Noise image, then blending.
        var noise: [[Int]] = []
        for plane in 0..<numPlanes {
            let psx = plane > 0 ? subX : 0, psy = plane > 0 ? subY : 0
            let pw = (w + psx) >> psx, ph = (h + psy) >> psy
            let sw = stripeW[plane]
            var img = [Int](repeating: 0, count: pw * ph)
            for yy in 0..<ph {
                let ln = yy >> (5 - psy)
                let i = yy - (ln << (5 - psy))
                for xx in 0..<pw {
                    var g = noiseStripe[ln][plane][i * sw + xx]
                    if psy == 0 {
                        if i < 2 && ln > 0 && p.overlapFlag {
                            let old = noiseStripe[ln - 1][plane][(i + 32) * sw + xx]
                            g = i == 0 ? old * 27 + g * 17 : old * 17 + g * 27
                            g = clip3(grainMin, grainMax, round2(g, 5))
                        }
                    } else if i < 1 && ln > 0 && p.overlapFlag {
                        let old = noiseStripe[ln - 1][plane][(i + 16) * sw + xx]
                        g = old * 23 + g * 22
                        g = clip3(grainMin, grainMax, round2(g, 5))
                    }
                    img[yy * pw + xx] = g
                }
            }
            noise.append(img)
        }
        let minValue: Int, maxLuma: Int, maxChroma: Int
        if p.clipToRestrictedRange {
            minValue = 16 << (bd - 8)
            maxLuma = 235 << (bd - 8)
            maxChroma = matrixCoefficients == 0 ? maxLuma : 240 << (bd - 8)
        } else {
            minValue = 0
            maxLuma = (256 << (bd - 8)) - 1
            maxChroma = maxLuma
        }
        let scalingShift = p.grainScalingMinus8 + 8
        let maxV = (1 << bd) - 1
        if numPlanes > 1 {
            let cw = frame.chromaWidth, ch = frame.chromaHeight
            for yy in 0..<ch {
                for xx in 0..<cw {
                    let lumaX = xx << subX, lumaY = yy << subY
                    let lumaNextX = min(lumaX + 1, w - 1)
                    let avg = subX == 1 ? round2(Int(frame.y[lumaY * w + lumaX]) + Int(frame.y[lumaY * w + lumaNextX]), 1) : Int(frame.y[lumaY * w + lumaX])
                    if !p.pointCb.isEmpty || p.chromaScalingFromLuma {
                        let orig = Int(frame.u[yy * cw + xx])
                        let merged: Int
                        if p.chromaScalingFromLuma {
                            merged = avg
                        } else {
                            let combined = avg * (p.cbLumaMult - 128) + orig * (p.cbMult - 128)
                            merged = clip3(0, maxV, (combined >> 6) + ((p.cbOffset - 256) << (bd - 8)))
                        }
                        let n = round2(scale(lutCb, merged) * noise[1][yy * cw + xx], scalingShift)
                        frame.u[yy * cw + xx] = UInt16(clip3(minValue, maxChroma, orig + n))
                    }
                    if !p.pointCr.isEmpty || p.chromaScalingFromLuma {
                        let orig = Int(frame.v[yy * cw + xx])
                        let merged: Int
                        if p.chromaScalingFromLuma {
                            merged = avg
                        } else {
                            let combined = avg * (p.crLumaMult - 128) + orig * (p.crMult - 128)
                            merged = clip3(0, maxV, (combined >> 6) + ((p.crOffset - 256) << (bd - 8)))
                        }
                        let n = round2(scale(lutCr, merged) * noise[2][yy * cw + xx], scalingShift)
                        frame.v[yy * cw + xx] = UInt16(clip3(minValue, maxChroma, orig + n))
                    }
                }
            }
        }
        if !p.pointY.isEmpty {
            for yy in 0..<h {
                for xx in 0..<w {
                    let orig = Int(frame.y[yy * w + xx])
                    let n = round2(scale(lutY, orig) * noise[0][yy * w + xx], scalingShift)
                    frame.y[yy * w + xx] = UInt16(clip3(minValue, maxLuma, orig + n))
                }
            }
        }
    }
}
