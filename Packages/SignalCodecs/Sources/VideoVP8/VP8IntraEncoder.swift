// VP8 intra pictures (RFC 6386). Each picture is independently decodable. The
// encoder reconstructs each quantized block before predicting its neighbours.
public enum VP8IntraEncoder {
    /// Tightly packed 8-bit YUV 4:2:0. Odd-sized pictures round chroma dimensions up.
    public static func encode(width: Int, height: Int, y: [UInt8], u: [UInt8], v: [UInt8],
                              quantizer: Int = 32) -> [UInt8]? {
        var encoder = VP8VideoEncoder()
        return encoder.encode(width: width, height: height, y: y, u: u, v: v, quantizer: quantizer, keyframe: true)
    }
}

/// The last decoded picture is the predictor for unchanged camera or screen regions.
/// Changed macroblocks use intra prediction, so they can change arbitrarily between frames.
public struct VP8VideoEncoder: Sendable {
    private var previous: [Plane] = []
    private var sinceKeyframe = 0
    public init() {}

    public mutating func encode(width: Int, height: Int, y: [UInt8], u: [UInt8], v: [UInt8],
                                quantizer: Int = 32, keyframe: Bool = false) -> [UInt8]? {
        guard (1...4096).contains(width), (1...4096).contains(height), width * height <= 3840 * 2160,
              y.count == width * height, u.count == ((width + 1) / 2) * ((height + 1) / 2),
              v.count == u.count, (0...127).contains(quantizer) else { return nil }
        let mbWidth = (width + 15) / 16, mbHeight = (height + 15) / 16
        let key = keyframe || sinceKeyframe >= 60 || previous.first?.width != width || previous.first?.height != height
        var header = BooleanWriter()
        if key { header.literal(0, bits: 2) } // colour space and clipping
        header.literal(0, bits: 1) // segmentation disabled
        header.literal(0, bits: 11) // normal filter, level and sharpness zero, no deltas
        header.literal(0, bits: 2) // one token partition
        header.literal(quantizer, bits: 7)
        header.literal(0, bits: 5) // no quantizer deltas
        if !key { header.literal(0, bits: 8) } // Keep golden and alternate references, no sign bias.
        header.put(false) // probability updates apply only to this picture
        if !key { header.put(true) } // refresh last reference
        for probability in VP8Tables.coeffsUpdateProba { header.put(false, Int(probability)) }
        header.put(!key)
        if !key {
            header.literal(120, bits: 8) // skip
            header.literal(128, bits: 8) // intra/inter
            header.literal(200, bits: 8) // last/golden-or-alternate
            header.literal(128, bits: 8) // golden/alternate
            header.literal(0, bits: 2)   // retain intra mode probabilities
            for axis in VP8ModeProbabilities.mvUpdates { for probability in axis { header.put(false, probability) } }
        }

        var tokens = BooleanWriter()
        let dc = Int(VP8Tables.dcTable[quantizer]), ac = Int(VP8Tables.acTable[quantizer])
        let chromaDC = Int(VP8Tables.dcTable[min(117, quantizer)])
        var luma = Plane(y, width, height, mbWidth * 16, mbHeight * 16)
        var cb = Plane(u, (width + 1) / 2, (height + 1) / 2, mbWidth * 8, mbHeight * 8)
        var cr = Plane(v, cb.width, cb.height, mbWidth * 8, mbHeight * 8)
        if !key {
            luma.decoded = previous[0].decoded
            cb.decoded = previous[1].decoded
            cr.decoded = previous[2].decoded
        }
        var skipped = [Bool](repeating: false, count: mbWidth*mbHeight)
        for my in 0..<mbHeight {
            for mx in 0..<mbWidth {
                if key {
                    header.put(false, 145) // B_PRED, sixteen B_DC_PRED modes
                    for _ in 0..<16 { header.put(false, Int(VP8Tables.bModesProba[0])) }
                    header.put(false, 142)
                } else {
                    let pos = my * mbWidth + mx
                    let same = luma.matches(previous[0], mx, my, size: 16) && cb.matches(previous[1], mx, my, size: 8)
                        && cr.matches(previous[2], mx, my, size: 8)
                    header.put(same, 120)
                    header.put(same, 128)
                    if same {
                        header.put(false, 200) // last reference
                        let context = (mx > 0 && skipped[pos-1] ? 2 : 0) + (my > 0 && skipped[pos-mbWidth] ? 2 : 0)
                            + (mx > 0 && my > 0 && skipped[pos-mbWidth-1] ? 1 : 0)
                        header.put(false, [7,14,135,60,159,234][context]) // zero motion
                        skipped[pos] = true
                        continue
                    }
                    header.put(true, 112); header.put(true, 86); header.put(true, 37) // B_PRED
                    for _ in 0..<16 { header.put(false, 120) }
                    header.put(false, 162)
                }
                for by in 0..<4 {
                    for bx in 0..<4 {
                        let x = mx * 16 + bx * 4, yy = my * 16 + by * 4
                        let pred = luma.intra4Prediction(x, yy)
                        luma.block(x, yy, pred, type: 3, dc: dc, ac: ac, into: &tokens)
                    }
                }
                cb.chroma(mx * 8, my * 8, dc: chromaDC, ac: ac, into: &tokens)
                cr.chroma(mx * 8, my * 8, dc: chromaDC, ac: ac, into: &tokens)
            }
        }
        let modes = header.finish(), residuals = tokens.finish()
        guard modes.count < 1 << 19 else { return nil }
        let tag = (modes.count << 5) | (key ? 0x10 : 0x11)
        var frame = [UInt8(truncatingIfNeeded: tag), UInt8(truncatingIfNeeded: tag >> 8), UInt8(tag >> 16)]
        if key {
            frame += [0x9d, 0x01, 0x2a, UInt8(truncatingIfNeeded: width), UInt8(width >> 8),
                      UInt8(truncatingIfNeeded: height), UInt8(height >> 8)]
        }
        previous = [luma, cb, cr]
        sinceKeyframe = key ? 0 : sinceKeyframe + 1
        return frame + modes + residuals
    }

    private struct Plane {
        let input: [UInt8]
        let width, height, stride: Int
        var decoded, nz: [UInt8]
        init(_ input: [UInt8], _ width: Int, _ height: Int, _ stride: Int, _ rows: Int) {
            self.input = input
            self.width = width
            self.height = height
            self.stride = stride
            decoded = .init(repeating: 0, count: stride * rows)
            nz = .init(repeating: 0, count: (stride / 4) * (rows / 4))
        }

        func matches(_ other: Self, _ mx: Int, _ my: Int, size: Int) -> Bool {
            let x = mx*size, end = min(x+size,width)
            for row in (my*size)..<min((my+1)*size,height) {
                let start = row*width
                if input[(start+x)..<(start+end)] != other.input[(start+x)..<(start+end)] { return false }
            }
            return true
        }

        func intra4Prediction(_ x: Int, _ y: Int) -> Int {
            var value = 4
            for n in 0..<4 {
                value += x == 0 ? 129 : Int(decoded[(y + n) * stride + x - 1])
                value += y == 0 ? 127 : Int(decoded[(y - 1) * stride + x + n])
            }
            return value >> 3
        }

        mutating func chroma(_ x: Int, _ y: Int, dc: Int, ac: Int, into writer: inout BooleanWriter) {
            var sum = 0, count = 0
            if x > 0 {
                for n in 0..<8 { sum += Int(decoded[(y + n) * stride + x - 1]) }
                count += 8
            }
            if y > 0 {
                for n in 0..<8 { sum += Int(decoded[(y - 1) * stride + x + n]) }
                count += 8
            }
            let prediction = count > 0 ? (sum + count / 2) / count : 128
            for dy in [0, 4] {
                for dx in [0, 4] { block(x + dx, y + dy, prediction, type: 2, dc: dc, ac: ac, into: &writer) }
            }
        }

        mutating func block(_ x: Int, _ y: Int, _ prediction: Int, type: Int, dc: Int, ac: Int, into writer: inout BooleanWriter) {
            var values = [Int](repeating: 0, count: 16)
            for row in 0..<4 {
                let base = min(y + row, height - 1) * width
                for col in 0..<4 { values[row * 4 + col] = Int(input[base + min(x + col, width - 1)]) - prediction }
            }
            VP8VideoEncoder.forward(&values)
            var dequantized = [Int16](repeating: 0, count: 16)
            var end = 0
            for (i, z) in VP8Decoder.zigzag.enumerated() {
                let step = i == 0 ? dc : ac, value = values[z]
                let q = min(2047, (abs(value) + step / 2) / step)
                values[z] = value < 0 ? -q : q
                dequantized[z] = Int16(clamping: values[z] * step)
                if q > 0 { end = i + 1 }
            }
            let i = (y / 4) * (stride / 4) + x / 4
            let context = (x > 0 ? Int(nz[i-1]) : 0) + (y > 0 ? Int(nz[i-stride/4]) : 0)
            nz[i] = end > 0 ? 1 : 0
            writer.coefficients(values, end: end, type: type, context: context)
            var reconstructed = [UInt8](repeating: UInt8(prediction), count: 4 * VP8Decoder.BPS)
            if end > 0 { VP8Decoder.transformOne(dequantized, 0, &reconstructed, 0) }
            for r in 0..<4 {
                for c in 0..<4 { decoded[(y+r)*stride + x+c] = reconstructed[r * VP8Decoder.BPS+c] }
            }
        }
    }

    private static func forward(_ a: inout [Int]) {
        for y in stride(from: 0, to: 16, by: 4) {
            let x0 = a[y], x1 = a[y+1], x2 = a[y+2], x3 = a[y+3]
            let p = (x0 + x3) * 8, q = (x1 + x2) * 8, r = (x1 - x2) * 8, s = (x0 - x3) * 8
            a[y] = p + q
            a[y+2] = p - q
            a[y+1] = (r * 2217 + s * 5352 + 14500) >> 12
            a[y+3] = (s * 2217 - r * 5352 + 7500) >> 12
        }
        for x in 0..<4 {
            let x0 = a[x], x1 = a[x+4], x2 = a[x+8], x3 = a[x+12]
            let p = x0 + x3, q = x1 + x2, r = x1 - x2, s = x0 - x3
            a[x] = (p + q + 7) >> 4
            a[x+8] = (p - q + 7) >> 4
            a[x+4] = ((r * 2217 + s * 5352 + 12000) >> 16) + (s == 0 ? 0 : 1)
            a[x+12] = (s * 2217 - r * 5352 + 51000) >> 16
        }
    }
}

private struct BooleanWriter {
    private var bytes: [UInt8] = []
    private var low: UInt32 = 0
    private var range = 255
    private var count = -24

    mutating func put(_ bit: Bool, _ probability: Int = 128) {
        let split = 1 + (((range - 1) * probability) >> 8)
        if bit { low &+= UInt32(split); range -= split } else { range = split }
        var shift = UInt8(range).leadingZeroBitCount
        range <<= shift
        count += shift
        if count >= 0 {
            let offset = shift - count
            if low & (UInt32(1) << (32 - offset)) != 0 {
                var i = bytes.count
                while i > 0, bytes[i-1] == 255 { i -= 1; bytes[i] = 0 }
                if i > 0 { bytes[i-1] += 1 } else { bytes.insert(1, at: 0) }
            }
            bytes.append(UInt8(truncatingIfNeeded: low >> (24 - offset)))
            low = (low << offset) & 0xff_ffff
            shift = count
            count -= 8
        }
        low <<= shift
    }

    mutating func literal(_ value: Int, bits: Int) {
        for i in (0..<bits).reversed() { put(value & (1 << i) != 0) }
    }

    mutating func finish() -> [UInt8] {
        for _ in 0..<32 { put(false) }
        return bytes
    }

    mutating func coefficients(_ values: [Int], end: Int, type: Int, context: Int) {
        var c = context, afterZero = false
        for pos in 0..<16 {
            let p = ((type * 8 + Int(VP8Tables.bands[pos])) * 3 + c) * 11
            let probs = VP8Tables.coeffsProba0
            if !afterZero { put(pos < end, Int(probs[p])) }
            if pos == end { return }
            let signedValue = values[VP8Decoder.zigzag[pos]], v = abs(signedValue)
            put(v != 0, Int(probs[p+1]))
            if v == 0 { c = 0; afterZero = true; continue }
            afterZero = false
            put(v > 1, Int(probs[p+2]))
            if v > 1 {
                put(v >= 5, Int(probs[p+3]))
                if v <= 4 {
                    put(v != 2, Int(probs[p+4]))
                    if v >= 3 { put(v == 4, Int(probs[p+5])) }
                } else {
                    put(v >= 11, Int(probs[p+6]))
                    if v < 11 {
                        put(v >= 7, Int(probs[p+7]))
                        if v < 7 { put(v == 6, 159) }
                        else { put(v >= 9, 165); put((v - 7) & 1 != 0, 145) }
                    } else {
                        let cat = v < 19 ? 0 : v < 35 ? 1 : v < 67 ? 2 : 3
                        put(cat >= 2, Int(probs[p+8]))
                        put(cat & 1 != 0, Int(probs[p+9+cat/2]))
                        let extra = v - 3 - (8 << cat), tree = VP8Decoder.cat3456[cat]
                        for (i, prob) in tree.enumerated() { put(extra & (1 << (tree.count - 1 - i)) != 0, prob) }
                    }
                }
            }
            put(signedValue < 0)
            c = v == 1 ? 1 : 2
        }
    }
}
