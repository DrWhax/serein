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

/// Key pictures code every macroblock as B_PRED with DC sub-blocks. Inter pictures predict
/// each 16x16 macroblock from the last picture with a searched vector (the decoder's own
/// near-vector prediction, six-tap interpolation and reconstruction), or fall back to the
/// intra path when nothing predicts it well.
public struct VP8VideoEncoder: Sendable {
    private var previous: [Plane] = []
    /// The last picture's vector per macroblock (zero for intra): temporal search candidates.
    private var previousVectors: [VP8Vector] = []
    private var sinceKeyframe = 0
    public init() {}

    /// What a decoder holds after the last picture: macroblock-aligned Y, U and V.
    var reconstruction: [[UInt8]] { previous.map(\.decoded) }

    /// P(intra) for inter pictures, where nearly every macroblock is inter.
    private static let intraProbability = 32

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
            header.literal(Self.intraProbability, bits: 8) // intra/inter
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
        var inter = key ? nil : InterCoder(previous: previous, previousVectors: previousVectors, width: width, height: height,
                                           mbWidth: mbWidth, mbHeight: mbHeight, quantizer: quantizer)
        for my in 0..<mbHeight {
            inter?.startRow()
            for mx in 0..<mbWidth {
                if key {
                    header.put(false, 145) // B_PRED, sixteen B_DC_PRED modes
                    for _ in 0..<16 { header.put(false, Int(VP8Tables.bModesProba[0])) }
                    header.put(false, 142)
                } else if inter!.code(mx, my, &luma, &cb, &cr, header: &header, tokens: &tokens) {
                    continue
                } else {
                    header.put(false, 120) // coded
                    header.put(false, Self.intraProbability) // intra
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
        previousVectors = inter?.vectors ?? .init(repeating: VP8Vector(), count: mbWidth*mbHeight)
        sinceKeyframe = key ? 0 : sinceKeyframe + 1
        return frame + modes + residuals
    }

    /// Inter macroblocks: motion search on the last picture, mode decision, the residual as the
    /// decoder parses it (Y2, luma AC from the second coefficient, chroma) and reconstruction
    /// through the decoder's own prediction and transforms, in its workspace layout.
    private struct InterCoder {
        typealias Block = InlineArray<16, Int>
        let reference: VP8Frame
        let width, height, mbWidth, mbHeight, quantizer: Int
        let y1: (Int, Int), y2: (Int, Int), uv: (Int, Int)
        private let y1AC: Divider, y2DC: Divider, y2AC: Divider, uvDC: Divider, uvAC: Divider
        /// libvpx sad_per_bit16 for this quantizer: SAD units worth one bit.
        let lambda: Int
        /// The reference luma (macroblock-aligned, as the decoder clamps it) with `border`
        /// samples repeated on every side, so searched positions read it without tests.
        static let border = 48
        let search: [UInt8], searchStride: Int
        private var topMotion: [VP8Motion], left = VP8Motion(), corner = VP8Motion()
        let previousVectors: [VP8Vector]
        private(set) var vectors: [VP8Vector]
        /// The last picture's source: a macroblock identical to it is not searched.
        let previousInput: [[UInt8]]
        private var y2Top: [Int], y2Left = 0
        private var workspace = [UInt8](repeating: 0, count: 32 * 17 + 32 * 9)
        private var exact = [UInt8](repeating: 0, count: 16 * VP8Decoder.BPS)
        /// The exact luma prediction of the chosen fractional vector, kept from the search.
        private var chosen = [UInt8](repeating: 0, count: 256), chosenVector: VP8Vector?
        private var coefficients = [Int16](repeating: 0, count: 384)
        private var source = [UInt8](repeating: 0, count: 256)
        private static let noBias = [false, false, false, false]

        init(previous: [Plane], previousVectors: [VP8Vector], width: Int, height: Int, mbWidth: Int, mbHeight: Int, quantizer q: Int) {
            self.previousVectors = previousVectors.count == mbWidth*mbHeight ? previousVectors : .init(repeating: VP8Vector(), count: mbWidth*mbHeight)
            previousInput = previous.map(\.input)
            vectors = .init(repeating: VP8Vector(), count: mbWidth*mbHeight)
            self.width = width; self.height = height; self.mbWidth = mbWidth; self.mbHeight = mbHeight; quantizer = q
            reference = VP8Frame(width: width, height: height, mbW: mbWidth, mbH: mbHeight,
                                 y: previous[0].decoded, u: previous[1].decoded, v: previous[2].decoded)
            y1 = (Int(VP8Tables.dcTable[q]), Int(VP8Tables.acTable[q]))
            y2 = (Int(VP8Tables.dcTable[q]) * 2, max(8, (Int(VP8Tables.acTable[q]) * 101_581) >> 16))
            uv = (Int(VP8Tables.dcTable[min(117, q)]), Int(VP8Tables.acTable[q]))
            y1AC = Divider(y1.1); y2DC = Divider(y2.0); y2AC = Divider(y2.1); uvDC = Divider(uv.0); uvAC = Divider(uv.1)
            lambda = max(1, (Int(VP8Tables.acTable[q]) * 418 + 24_107) / 10_000)
            topMotion = .init(repeating: VP8Motion(), count: mbWidth)
            y2Top = .init(repeating: 0, count: mbWidth)
            let b = Self.border, planeWidth = mbWidth * 16, planeHeight = mbHeight * 16, stride = planeWidth + 2*b
            var plane = [UInt8]()
            plane.reserveCapacity(stride * (planeHeight + 2*b))
            let luma = previous[0].decoded
            for row in 0..<(planeHeight + 2*b) {
                let line = min(planeHeight-1, max(0, row-b)) * planeWidth
                plane.append(contentsOf: repeatElement(luma[line], count: b))
                plane.append(contentsOf: luma[line..<(line+planeWidth)])
                plane.append(contentsOf: repeatElement(luma[line+planeWidth-1], count: b))
            }
            search = plane; searchStride = stride
        }

        mutating func startRow() { left = VP8Motion(); corner = VP8Motion(); y2Left = 0 }

        /// Code macroblock (mx, my) as inter, or return false (header untouched) for the intra path.
        mutating func code(_ mx: Int, _ my: Int, _ luma: inout Plane, _ cb: inout Plane, _ cr: inout Plane,
                           header: inout BooleanWriter, tokens: inout BooleanWriter) -> Bool {
            let found = VP8ModeProbabilities.nearVectors(left: left, top: topMotion[mx], corner: corner, biases: Self.noBias,
                                                          reference: 1, x: mx, y: my, width: mbWidth, height: mbHeight)
            let still = unchanged(mx, my, luma, cb, cr)
            guard let choice = still ? stillChoice(mx, my, luma, found) : chooseMotion(mx, my, luma, found) else {
                corner = topMotion[mx]; topMotion[mx] = VP8Motion(); left = VP8Motion()
                return false
            }
            let motion = VP8Motion(reference: 1, vector: choice.vector)
            if !still, chosenVector == choice.vector {
                // The search already made this prediction (VP8Prediction.luma, as inter does).
                for r in 0..<16 { for c in 0..<16 { workspace[VP8Decoder.yOff + r*VP8Decoder.BPS + c] = chosen[r*16 + c] } }
                VP8Prediction.inter(motion, x: mx, y: my, reference: reference, version: 0, workspace: &workspace, luma: false)
            } else {
                VP8Prediction.inter(motion, x: mx, y: my, reference: reference, version: 0, workspace: &workspace)
            }
            let ws = workspace, BPS = VP8Decoder.BPS, zz = VP8Decoder.zigzag

            // Luma: forward transform each 4x4; its DC goes to the second-order (Y2) block.
            var levels = InlineArray<384, Int>(repeating: 0), ends = InlineArray<24, Int>(repeating: 0)
            var dcs = Block(repeating: 0)
            for n in 0..<16 {
                var values = residual(luma, mx*16 + (n & 3)*4, my*16 + (n >> 2)*4, ws, VP8Decoder.yOff + VP8Decoder.scan[n])
                if let dc = Self.onlyDC(values, y1AC) {
                    dcs[n] = dc
                    ends[n] = 1
                    continue
                }
                VP8VideoEncoder.forward(&values)
                dcs[n] = values[0]
                var end = 1
                for i in 1..<16 {
                    let level = Self.quantize(values[zz[i]], y1AC)
                    levels[n*16 + zz[i]] = level
                    if level != 0 { end = i + 1 }
                }
                ends[n] = end
            }
            var second = Self.walsh(dcs), secondEnd = 0
            for i in 0..<16 {
                second[zz[i]] = Self.quantize(second[zz[i]], i == 0 ? y2DC : y2AC)
                if second[zz[i]] != 0 { secondEnd = i + 1 }
            }
            for k in 0..<8 {
                let (plane, base) = k < 4 ? (cb, VP8Decoder.uOff) : (cr, VP8Decoder.vOff), b = k & 3
                var values = residual(plane, mx*8 + (b & 1)*4, my*8 + (b >> 1)*4, ws, base + (b >> 1)*4*BPS + (b & 1)*4)
                if let dc = Self.onlyDC(values, uvAC) {
                    let level = Self.quantize(dc, uvDC)
                    levels[(16+k)*16] = level
                    ends[16+k] = level != 0 ? 1 : 0
                    continue
                }
                VP8VideoEncoder.forward(&values)
                var end = 0
                for i in 0..<16 {
                    let level = Self.quantize(values[zz[i]], i == 0 ? uvDC : uvAC)
                    levels[(16+k)*16 + zz[i]] = level
                    if level != 0 { end = i + 1 }
                }
                ends[16+k] = end
            }
            var skip = secondEnd == 0
            for n in 0..<24 where ends[n] != (n < 16 ? 1 : 0) { skip = false }
            // Block n of the levels, read in place (passing the 3 KB array would copy it).
            func block(_ n: Int) -> Block {
                var values = Block(repeating: 0)
                for i in 0..<16 { values[i] = levels[n*16 + i] }
                return values
            }

            // Reconstruction, as VP8Decoder.parseResiduals and reconstructRow do it.
            if !skip {
                for i in 0..<384 { coefficients[i] = 0 }
                var dc = InlineArray<16, Int16>(repeating: 0)
                for i in 0..<16 { dc[zz[i]] = Int16(truncatingIfNeeded: second[zz[i]] * (i == 0 ? y2.0 : y2.1)) }
                do {
                    var out = coefficients.mutableSpan
                    if secondEnd > 1 { VP8Decoder.transformWHT(dc, &out) }
                    else {
                        let dc0 = Int16(truncatingIfNeeded: (Int(dc[0]) + 3) >> 3)
                        for i in stride(from: 0, to: 256, by: 16) { out[i] = dc0 }
                    }
                }
                var nonZeroY: UInt32 = 0
                for row in 0..<4 {
                    var bits: UInt32 = 0
                    for col in 0..<4 {
                        let n = row*4 + col
                        for i in 1..<16 { coefficients[n*16 + zz[i]] = Int16(truncatingIfNeeded: levels[n*16 + zz[i]] * y1.1) }
                        bits = VP8Decoder.nzCode(bits, ends[n], coefficients[n*16] != 0)
                    }
                    nonZeroY = (nonZeroY << 8) | bits
                }
                var nonZeroUV: UInt32 = 0
                for plane in 0..<2 {
                    var bits: UInt32 = 0
                    for b in 0..<4 {
                        let k = plane*4 + b, base = 256 + k*16
                        for i in 0..<16 { coefficients[base + zz[i]] = Int16(truncatingIfNeeded: levels[(16+k)*16 + zz[i]] * (i == 0 ? uv.0 : uv.1)) }
                        bits = VP8Decoder.nzCode(bits, ends[16+k], coefficients[base] != 0)
                    }
                    nonZeroUV |= bits << UInt32(8 * plane)
                }
                var bits = nonZeroY
                for n in 0..<16 { VP8Decoder.doTransform(bits, coefficients, n*16, &workspace, VP8Decoder.yOff + VP8Decoder.scan[n]); bits <<= 2 }
                VP8Decoder.doUVTransform(nonZeroUV, coefficients, 256, &workspace, VP8Decoder.uOff)
                VP8Decoder.doUVTransform(nonZeroUV >> 8, coefficients, 320, &workspace, VP8Decoder.vOff)
            }
            // An unchanged macroblock's residual refines what the decoder holds; once it no
            // longer lowers the error (quantization can cycle between near-equal pictures),
            // the macroblock is skipped, so a still picture settles to skips.
            if still && !skip && error(workspace, luma, cb, cr, mx, my) >= error(ws, luma, cb, cr, mx, my) {
                skip = true
                workspace = ws
            }

            header.put(skip, 120)
            header.put(true, VP8VideoEncoder.intraProbability) // inter
            header.put(false, 200) // last picture
            let p = VP8ModeProbabilities.modeProbabilities, c = found.counts
            header.put(choice.mode != 0, p[c[0]][0])
            if choice.mode != 0 {
                header.put(choice.mode != 1, p[c[1]][1])
                if choice.mode != 1 {
                    header.put(choice.mode != 2, p[c[2]][2])
                    if choice.mode != 2 {
                        header.put(false, p[c[3]][3]) // a whole-macroblock vector
                        header.vector(y: choice.vector.y - found.best.y, x: choice.vector.x - found.best.x)
                    }
                }
            }

            if skip {
                for n in 0..<16 { luma.setNonzero(mx*16 + (n & 3)*4, my*16 + (n >> 2)*4, false) }
                for b in 0..<4 { cb.setNonzero(mx*8 + (b & 1)*4, my*8 + (b >> 1)*4, false); cr.setNonzero(mx*8 + (b & 1)*4, my*8 + (b >> 1)*4, false) }
                y2Top[mx] = 0; y2Left = 0
            } else {
                // Tokens in the decoder's order, with its contexts.
                tokens.coefficients(second, end: secondEnd, type: 1, context: y2Top[mx] + y2Left)
                y2Top[mx] = secondEnd > 0 ? 1 : 0; y2Left = y2Top[mx]
                for n in 0..<16 {
                    let x = mx*16 + (n & 3)*4, y = my*16 + (n >> 2)*4
                    tokens.coefficients(block(n), end: ends[n], type: 0, context: luma.context(x, y), first: 1)
                    luma.setNonzero(x, y, ends[n] > 1)
                }
                for k in 0..<8 {
                    let b = k & 3, x = mx*8 + (b & 1)*4, y = my*8 + (b >> 1)*4
                    if k < 4 {
                        tokens.coefficients(block(16+k), end: ends[16+k], type: 2, context: cb.context(x, y))
                        cb.setNonzero(x, y, ends[16+k] > 0)
                    } else {
                        tokens.coefficients(block(16+k), end: ends[16+k], type: 2, context: cr.context(x, y))
                        cr.setNonzero(x, y, ends[16+k] > 0)
                    }
                }
            }
            for r in 0..<16 { for c in 0..<16 { luma.decoded[(my*16 + r)*luma.stride + mx*16 + c] = workspace[VP8Decoder.yOff + r*BPS + c] } }
            for r in 0..<8 {
                for c in 0..<8 {
                    cb.decoded[(my*8 + r)*cb.stride + mx*8 + c] = workspace[VP8Decoder.uOff + r*BPS + c]
                    cr.decoded[(my*8 + r)*cr.stride + mx*8 + c] = workspace[VP8Decoder.vOff + r*BPS + c]
                }
            }
            corner = topMotion[mx]; topMotion[mx] = motion; left = motion
            vectors[my*mbWidth + mx] = choice.vector
            return true
        }

        /// Squared error of the macroblock in a workspace against the source (inside the picture).
        private func error(_ ws: [UInt8], _ luma: Plane, _ cb: Plane, _ cr: Plane, _ mx: Int, _ my: Int) -> Int {
            var total = 0
            for (plane, size, base) in [(luma, 16, VP8Decoder.yOff), (cb, 8, VP8Decoder.uOff), (cr, 8, VP8Decoder.vOff)] {
                for r in 0..<min(size, plane.height - my*size) {
                    let line = (my*size + r)*plane.width + mx*size
                    for c in 0..<min(size, plane.width - mx*size) {
                        let d = Int(ws[base + r*VP8Decoder.BPS + c]) - Int(plane.input[line + c])
                        total += d*d
                    }
                }
            }
            return total
        }

        /// The macroblock's source samples are exactly the last picture's (nothing to search for).
        private func unchanged(_ mx: Int, _ my: Int, _ luma: Plane, _ cb: Plane, _ cr: Plane) -> Bool {
            same(luma, previousInput[0], mx, my, 16) && same(cb, previousInput[1], mx, my, 8) && same(cr, previousInput[2], mx, my, 8)
        }

        private func same(_ plane: Plane, _ old: [UInt8], _ mx: Int, _ my: Int, _ size: Int) -> Bool {
            let x = mx*size, count = min(x+size, plane.width) - x, now = plane.input.span, before = old.span
            for row in (my*size)..<min((my+1)*size, plane.height) where !isZero(sampleDifference(now, before, row*plane.width + x, count)) {
                return false
            }
            return true
        }

        /// The DC of a residual's forward transform when every AC coefficient quantizes to zero
        /// with step ac, else nil. For every block, |AC| <= 0.854 * sum|residual| + 2.35 (each
        /// pass's factors bounded, roundings included; at most 0.843 over 300 000 test blocks),
        /// and a level is zero below step - half. The DC is (8 * sum + 7) >> 4 exactly.
        @inline(__always)
        private static func onlyDC(_ values: Block, _ ac: Divider) -> Int? {
            var sum = 0, magnitude = 0
            for i in 0..<16 {
                let v = values[i], sign = v >> 63
                sum &+= v
                magnitude &+= (v ^ sign) &- sign
            }
            guard magnitude*86 + 300 < (ac.step - ac.half)*100 else { return nil }
            return (8*sum + 7) >> 4
        }

        /// The input block (edge samples repeated) minus the prediction in the workspace.
        private func residual(_ plane: Plane, _ x: Int, _ y: Int, _ ws: [UInt8], _ at: Int) -> Block {
            var values = Block(repeating: 0)
            for r in 0..<4 {
                let base = min(y + r, plane.height - 1) * plane.width
                for c in 0..<4 { values[r*4 + c] = Int(plane.input[base + min(x + c, plane.width - 1)]) - Int(ws[at + r*VP8Decoder.BPS + c]) }
            }
            return values
        }

        /// round(|value| / step) by a reciprocal: with m = ceil(2^32 / step), floor(n*m / 2^32) is
        /// floor(n / step) for every n below 2^32 / step (steps < 2^12, n < 2^16 here).
        private struct Divider { let step: Int, half: Int, reciprocal: Int
            init(_ step: Int) { self.step = step; half = step / 2; reciprocal = ((1 << 32) + step - 1) / step }
        }
        @inline(__always)
        private static func quantize(_ value: Int, _ d: Divider) -> Int {
            // Branchless: the signs of residual coefficients are unpredictable.
            let sign = value >> 63
            let q = min(2047, ((((value ^ sign) &- sign) &+ d.half) &* d.reciprocal) >> 32)
            return (q ^ sign) &- sign
        }

        /// libvpx vp8_short_walsh4x4_c over the 16 luma DC terms (raster order).
        private static func walsh(_ input: Block) -> Block {
            var out = Block(repeating: 0)
            for i in 0..<4 {
                let ip = 4*i
                let a1 = (input[ip] + input[ip+2]) * 4, d1 = (input[ip+1] + input[ip+3]) * 4
                let c1 = (input[ip+1] - input[ip+3]) * 4, b1 = (input[ip] - input[ip+2]) * 4
                out[ip] = a1 + d1 + (a1 != 0 ? 1 : 0); out[ip+1] = b1 + c1; out[ip+2] = b1 - c1; out[ip+3] = a1 - d1
            }
            var result = Block(repeating: 0)
            for i in 0..<4 {
                let a1 = out[i] + out[8+i], d1 = out[4+i] + out[12+i], c1 = out[4+i] - out[12+i], b1 = out[i] - out[8+i]
                var a2 = a1 + d1, b2 = b1 + c1, c2 = b1 - c1, d2 = a1 - d1
                a2 += a2 < 0 ? 1 : 0; b2 += b2 < 0 ? 1 : 0; c2 += c2 < 0 ? 1 : 0; d2 += d2 < 0 ? 1 : 0
                result[i] = (a2 + 3) >> 3; result[4+i] = (b2 + 3) >> 3; result[8+i] = (c2 + 3) >> 3; result[12+i] = (d2 + 3) >> 3
            }
            return result
        }

        // MARK: Motion

        static let bitCost: [Int] = [
        4096, 2048, 1792, 1642, 1536, 1454, 1386, 1329, 1280, 1236, 1198, 1162, 1130, 1101, 1073, 1048, 1024, 1002, 980, 961,
        942, 924, 906, 890, 874, 859, 845, 831, 817, 804, 792, 780, 768, 757, 746, 735, 724, 714, 705, 695,
        686, 676, 668, 659, 650, 642, 634, 626, 618, 611, 603, 596, 589, 582, 575, 568, 561, 555, 548, 542,
        536, 530, 524, 518, 512, 506, 501, 495, 490, 484, 479, 474, 468, 463, 458, 453, 449, 444, 439, 434,
        430, 425, 420, 416, 412, 407, 403, 399, 394, 390, 386, 382, 378, 374, 370, 366, 362, 358, 355, 351,
        347, 343, 340, 336, 333, 329, 326, 322, 319, 315, 312, 309, 305, 302, 299, 296, 292, 289, 286, 283,
        280, 277, 274, 271, 268, 265, 262, 259, 256, 253, 250, 247, 245, 242, 239, 236, 234, 231, 228, 226,
        223, 220, 218, 215, 212, 210, 207, 205, 202, 200, 197, 195, 193, 190, 188, 185, 183, 181, 178, 176,
        174, 171, 169, 167, 164, 162, 160, 158, 156, 153, 151, 149, 147, 145, 143, 140, 138, 136, 134, 132,
        130, 128, 126, 124, 122, 120, 118, 116, 114, 112, 110, 108, 106, 104, 102, 101, 99, 97, 95, 93,
        91, 89, 87, 86, 84, 82, 80, 78, 77, 75, 73, 71, 70, 68, 66, 64, 63, 61, 59, 58,
        56, 54, 53, 51, 49, 48, 46, 44, 43, 41, 40, 38, 36, 35, 33, 32, 30, 28, 27, 25,
        24, 22, 21, 19, 18, 16, 15, 13, 12, 10, 9, 7, 6, 4, 3, 1, 0
        ]
        static func cost(_ bit: Bool, _ probability: Int) -> Int { bitCost[bit ? 256-probability : probability] }

        /// The SAD of the 16x16 luma at (x, y) predicted with `vector` (eighth samples) from the
        /// edge-extended reference; fractional positions ranked with the bilinear filter.
        private func sad(_ vector: VP8Vector, _ x: Int, _ y: Int) -> Int {
            let b = Self.border, stride = searchStride
            let origin = (y + (vector.y >> 3) + b)*stride + x + (vector.x >> 3) + b
            let plane = search.span, block = source.span
            let fx = vector.x & 7, fy = vector.y & 7
            var total = Row(repeating: 0)
            if fx == 0 && fy == 0 {
                for r in 0..<16 {
                    let p = Self.row(plane, origin &+ r &* stride), s = Self.row(block, r &* 16)
                    total &+= Self.absoluteDifference(p, s)
                }
            } else {
                // Bilinear weights sum to 64: a weighted sample stays below 16 384.
                let w00 = Row(repeating: UInt16((8-fx)*(8-fy))), w01 = Row(repeating: UInt16(fx*(8-fy)))
                let w10 = Row(repeating: UInt16((8-fx)*fy)), w11 = Row(repeating: UInt16(fx*fy))
                let half = Row(repeating: 32), six = Row(repeating: 6)
                for r in 0..<16 {
                    let i = origin &+ r &* stride
                    let p = (Self.row(plane, i) &* w00 &+ Self.row(plane, i &+ 1) &* w01 &+ Self.row(plane, i &+ stride) &* w10
                             &+ Self.row(plane, i &+ stride &+ 1) &* w11 &+ half) &>> six
                    let s = Self.row(block, r &* 16)
                    total &+= Self.absoluteDifference(p, s)
                }
            }
            return Int(SIMD16<UInt32>(truncatingIfNeeded: total).wrappedSum())
        }

        private typealias Row = SIMD16<UInt16>

        /// |a - b| per lane for samples below 32 768, in vector operations only (pointwiseMax and
        /// pointwiseMin stay out-of-line calls in the SAD loops).
        @inline(__always)
        private static func absoluteDifference(_ a: Row, _ b: Row) -> Row {
            let d = a &- b, negative = Row(repeating: 0) &- (d &>> Row(repeating: 15))
            return (d ^ negative) &- negative
        }

        @inline(__always)
        private static func row(_ s: borrowing Span<UInt8>, _ i: Int) -> Row {
            // One check for the run (sixteen element checks cost more than the load).
            let w = s.extracting(i..<(i &+ 16))
            return Row(UInt16(w[0]), UInt16(w[1]), UInt16(w[2]), UInt16(w[3]), UInt16(w[4]), UInt16(w[5]), UInt16(w[6]), UInt16(w[7]),
                       UInt16(w[8]), UInt16(w[9]), UInt16(w[10]), UInt16(w[11]), UInt16(w[12]), UInt16(w[13]), UInt16(w[14]), UInt16(w[15]))
        }

        /// The exact SAD: the decoder's six-tap prediction.
        private mutating func exactSad(_ vector: VP8Vector, _ x: Int, _ y: Int) -> Int {
            guard vector.x & 7 != 0 || vector.y & 7 != 0 else { return sad(vector, x, y) }
            VP8Prediction.luma(reference, x: x, y: y, vector: vector, version: 0, into: &exact)
            var total = 0
            for r in 0..<16 { for c in 0..<16 { total &+= abs(Int(exact[r*VP8Decoder.BPS + c]) &- Int(source[r*16 + c])) } }
            return total
        }

        /// The bits of a vector difference: each component looked up (they code independently).
        private static func vectorBits(y: Int, x: Int) -> Int {
            let r = Self.range
            guard (-r...r).contains(y), (-r...r).contains(x) else {
                var bits = 0
                BooleanWriter.vectorSymbols(y: y, x: x) { bits += cost($0, $1) }
                return bits
            }
            return rowBits[y + r] + columnBits[x + r]
        }
        private static let range = 2046
        private static let rowBits = componentBits(axis: 0), columnBits = componentBits(axis: 1)
        private static func componentBits(axis: Int) -> [Int] {
            let zero = { var b = 0; BooleanWriter.vectorSymbols(y: 0, x: 0) { b += cost($0, $1) }; return b }()
            return (-range...range).map { value in
                var bits = 0
                BooleanWriter.vectorSymbols(y: axis == 0 ? value : 0, x: axis == 0 ? 0 : value) { bits += cost($0, $1) }
                return bits - zero / 2
            }
        }

        private mutating func loadSource(_ x: Int, _ y: Int, _ luma: Plane) {
            let width = width, height = height, input = luma.input.span, inside = x + 16 <= width && y + 16 <= height
            var out = source.mutableSpan
            for r in 0..<16 {
                let line = min(height-1, y+r)*width
                if inside { for c in 0..<16 { out[r*16 + c] = input[line + x + c] } }
                else { for c in 0..<16 { out[r*16 + c] = input[line + min(width-1, x+c)] } }
            }
        }

        /// An unchanged macroblock is not searched: ZERO, NEAREST or NEAR, whichever predicts it
        /// best (exact SAD + lambda * mode bits). Its residual still refines the reconstruction
        /// (skipped once nothing survives quantization). A static picture keeps zero vectors;
        /// flat areas in a pan keep the pan's vector for the blocks around them.
        private mutating func stillChoice(_ mx: Int, _ my: Int, _ luma: Plane, _ found: VP8ModeProbabilities.NearVectors)
            -> (mode: Int, vector: VP8Vector)? {
            let x = mx*16, y = my*16
            loadSource(x, y, luma)
            let p = VP8ModeProbabilities.modeProbabilities, n = found.counts
            let notZero = Self.cost(true, p[n[0]][0])
            var best = (mode: 0, vector: VP8Vector(), cost: exactSad(VP8Vector(), x, y)*256 + lambda*Self.cost(false, p[n[0]][0]))
            for (mode, v, bits) in [(1, found.nearest, notZero + Self.cost(false, p[n[1]][1])),
                                    (2, found.near, notZero + Self.cost(true, p[n[1]][1]) + Self.cost(false, p[n[2]][2]))]
                where v != VP8Vector() {
                let c = exactSad(v, x, y)*256 + lambda*bits
                if c < best.cost { best = (mode, v, c) }
            }
            return (best.mode, best.vector)
        }

        /// The cheapest of ZERO, NEAREST, NEAR and a searched NEW vector by luma SAD + lambda * bits,
        /// or nil when an intra macroblock looks clearly cheaper.
        private mutating func chooseMotion(_ mx: Int, _ my: Int, _ luma: Plane, _ found: VP8ModeProbabilities.NearVectors)
            -> (mode: Int, vector: VP8Vector)? {
            let x = mx*16, y = my*16
            loadSource(x, y, luma)
            let p = VP8ModeProbabilities.modeProbabilities, n = found.counts
            let notZero = Self.cost(true, p[n[0]][0]), notNearest = notZero + Self.cost(true, p[n[1]][1])
            let notNear = notNearest + Self.cost(true, p[n[2]][2])
            let modeBits: InlineArray<4, Int> = [Self.cost(false, p[n[0]][0]), notZero + Self.cost(false, p[n[1]][1]),
                                                 notNearest + Self.cost(false, p[n[2]][2]), notNear + Self.cost(false, p[n[3]][3])]
            var seen = InlineArray<64, (key: Int, sad: Int)>(repeating: (Int.min, 0)), seenCount = 0
            func measure(_ v: VP8Vector) -> Int {
                let key = v.y << 32 | (v.x & 0xffff_ffff)
                for i in 0..<min(seenCount, 64) where seen[i].key == key { return seen[i].sad }
                let value = sad(v, x, y)
                seen[seenCount % 64] = (key, value); seenCount += 1
                return value
            }
            func cost(_ mode: Int, _ v: VP8Vector) -> Int {
                var bits = modeBits[mode]
                if mode == 3 { bits += Self.vectorBits(y: v.y - found.best.y, x: v.x - found.best.x) }
                return measure(v)*256 + lambda*bits
            }
            if measure(VP8Vector()) == 0 { return (0, VP8Vector()) }
            // Search within 64 samples of the macroblock (repeating texture far away would make
            // the vector field chaotic), within 16 samples of the macroblock-aligned picture, and
            // with a difference from the best vector that codes: at most 1023 quarter samples.
            func clampVector(_ v: VP8Vector) -> VP8Vector {
                func bound(_ value: Int, _ low: Int, _ high: Int, _ base: Int) -> Int {
                    max(max(low, -512, base - 2046), min(min(high, 512, base + 2046), value))
                }
                return VP8Vector(x: bound(v.x, -(x+16)*8, (mbWidth*16 - x)*8, found.best.x),
                                 y: bound(v.y, -(y+16)*8, (mbHeight*16 - y)*8, found.best.y))
            }
            var center = clampVector(VP8Vector()), centerCost = cost(3, center)
            for v in [found.nearest, found.near, found.best, previousVectors[my*mbWidth + mx]] {
                let whole = clampVector(VP8Vector(x: (v.x/8)*8, y: (v.y/8)*8)), c = cost(3, whole)
                if c < centerCost { center = whole; centerCost = c }
            }
            let wide = measure(center) > 16*16*2
            for step in wide ? [64, 32, 16, 8] : [8] {
                var moved = true, rounds = 0
                while moved && rounds < (step == 8 ? 16 : 4) {
                    moved = false; rounds += 1
                    let origin = center
                    for d in 0..<4 {
                        let dx = d < 2 ? 0 : (d == 2 ? -step : step), dy = d < 2 ? (d == 0 ? -step : step) : 0
                        let v = clampVector(VP8Vector(x: origin.x+dx, y: origin.y+dy)), c = cost(3, v)
                        if c < centerCost { center = v; centerCost = c; moved = true }
                    }
                }
            }
            if measure(center)*2 > 16*16 {
                var improved = false
                for step in [4, 2] where step == 4 || improved || measure(center) > 16*16*4 {
                    let origin = center
                    for d in 0..<4 {
                        let dx = d < 2 ? 0 : (d == 2 ? -step : step), dy = d < 2 ? (d == 0 ? -step : step) : 0
                        let v = clampVector(VP8Vector(x: origin.x+dx, y: origin.y+dy)), c = cost(3, v)
                        if c < centerCost { center = v; centerCost = c; improved = true }
                    }
                }
            }
            // The finalists by exact SAD.
            var final = (mode: 0, vector: VP8Vector(), cost: measure(VP8Vector())*256 + lambda*modeBits[0], sad: measure(VP8Vector()))
            chosenVector = nil
            for (mode, v) in [(1, found.nearest), (2, found.near), (3, center)] {
                var bits = modeBits[mode]
                if mode == 3 {
                    if v == found.nearest || v == found.near { continue }
                    bits += Self.vectorBits(y: v.y - found.best.y, x: v.x - found.best.x)
                }
                let s = exactSad(v, x, y), c = s*256 + lambda*bits
                if c < final.cost {
                    final = (mode, v, c, s)
                    if v.x & 7 != 0 || v.y & 7 != 0 {
                        // exactSad left its prediction in exact.
                        for r in 0..<16 { for col in 0..<16 { chosen[r*16 + col] = exact[r*VP8Decoder.BPS + col] } }
                        chosenVector = v
                    } else {
                        chosenVector = nil
                    }
                }
            }
            // The intra path predicts each 4x4 from the mean of the 4 samples above and the 4 to the
            // left (B_DC_PRED). Neighbours in the macroblocks above and to the left are already
            // reconstructed (with their quantization error, which matters as much as the vector's
            // reference error); inside the macroblock the source stands in for them.
            func sample(_ sx: Int, _ sy: Int) -> Int { Int(luma.decoded[sy*luma.stride + sx]) }
            var intra = 0
            for by in 0..<4 {
                for bx in 0..<4 {
                    let px = x + bx*4, py = y + by*4
                    var sum = 4
                    for k in 0..<4 {
                        sum += px == 0 ? 129 : (bx == 0 ? sample(px-1, py+k) : Int(source[(by*4+k)*16 + bx*4-1]))
                        sum += py == 0 ? 127 : (by == 0 ? sample(px+k, py-1) : Int(source[(by*4-1)*16 + bx*4+k]))
                    }
                    let prediction = sum >> 3
                    for r in 0..<4 { for c in 0..<4 { intra += abs(Int(source[(by*4+r)*16 + bx*4+c]) - prediction) } }
                }
            }
            // A fine quantizer keeps the reference's noise, so an inter residual carries two
            // pictures' noise and intra often wins; a coarse one smooths it, and the same SAD
            // codes cheaper as inter. Scale the intra estimate from 0.75x at q32 to 2x from q96.
            let scale = 48 + min(80, max(0, quantizer - 32) * 80 / 64)
            if final.cost > intra*256*scale/64 + lambda*(16*Self.cost(false, 120) + 600) { return nil }
            return (final.mode, final.vector)
        }
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

        /// The token context of the 4x4 at (x, y): its left and above blocks' nonzero flags.
        func context(_ x: Int, _ y: Int) -> Int {
            let i = (y / 4) * (stride / 4) + x / 4
            return (x > 0 ? Int(nz[i-1]) : 0) + (y > 0 ? Int(nz[i-stride/4]) : 0)
        }

        mutating func setNonzero(_ x: Int, _ y: Int, _ value: Bool) { nz[(y / 4) * (stride / 4) + x / 4] = value ? 1 : 0 }

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

    static func forward(_ a: inout InlineArray<16, Int>) {
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

    private static func forward(_ a: inout [Int]) {
        var block = InlineArray<16, Int>(repeating: 0)
        for i in 0..<16 { block[i] = a[i] }
        forward(&block)
        for i in 0..<16 { a[i] = block[i] }
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

    /// The symbols of a vector difference (eighth samples, even: VP8 vectors are quarter
    /// samples), row then column, as VP8ModeProbabilities.vector reads them with the default
    /// probabilities.
    private static let defaultVectorProbabilities = VP8ModeProbabilities().mv

    static func vectorSymbols(y: Int, x: Int, _ emit: (Bool, Int) -> Void) {
        let probabilities = defaultVectorProbabilities
        for (axis, value) in [(0, y), (1, x)] {
            let p = probabilities[axis], v = abs(value) / 2
            if v < 8 {
                emit(false, p[0])
                if v < 4 {
                    emit(false, p[2])
                    if v < 2 { emit(false, p[3]); emit(v == 1, p[4]) } else { emit(true, p[3]); emit(v == 3, p[5]) }
                } else {
                    emit(true, p[2])
                    if v < 6 { emit(false, p[6]); emit(v == 5, p[7]) } else { emit(true, p[6]); emit(v == 7, p[8]) }
                }
            } else {
                emit(true, p[0])
                for i in 0...2 { emit((v >> i) & 1 == 1, p[9+i]) }
                for i in (4...9).reversed() { emit((v >> i) & 1 == 1, p[9+i]) }
                // Bit 3 is implied when the higher bits are zero (the value is then at least 8).
                if v & 0xFFF0 != 0 { emit((v >> 3) & 1 == 1, p[12]) }
            }
            if v != 0 { emit(value < 0, p[1]) }
        }
    }

    mutating func vector(y: Int, x: Int) {
        var symbols: [(Bool, Int)] = []
        Self.vectorSymbols(y: y, x: x) { symbols.append(($0, $1)) }
        for (bit, probability) in symbols { put(bit, probability) }
    }

    mutating func finish() -> [UInt8] {
        for _ in 0..<32 { put(false) }
        return bytes
    }

    mutating func coefficients(_ values: [Int], end: Int, type: Int, context: Int, first: Int = 0) {
        var block = InlineArray<16, Int>(repeating: 0)
        for i in 0..<16 { block[i] = values[i] }
        coefficients(block, end: end, type: type, context: context, first: first)
    }

    mutating func coefficients(_ values: InlineArray<16, Int>, end: Int, type: Int, context: Int, first: Int = 0) {
        var c = context, afterZero = false
        for pos in first..<16 {
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

/// The OR of the XORs of count samples from i in a and b: zero when they are the same. Vector
/// operations only (SIMD equality compiles to a loop over the lanes).
@inline(__always)
private func sampleDifference(_ a: borrowing Span<UInt8>, _ b: borrowing Span<UInt8>, _ i: Int, _ count: Int) -> SIMD8<UInt8> {
    var difference = SIMD8<UInt8>()
    var k = 0
    while k &+ 8 <= count {
        difference |= eightSamples(a, i &+ k) ^ eightSamples(b, i &+ k)
        k &+= 8
    }
    while k < count {
        difference[0] |= a[i &+ k] ^ b[i &+ k]
        k &+= 1
    }
    return difference
}

/// Whether every lane is zero (a widened sum cannot wrap to zero).
@inline(__always)
private func isZero(_ v: SIMD8<UInt8>) -> Bool { SIMD8<UInt16>(truncatingIfNeeded: v).wrappedSum() == 0 }

@inline(__always)
private func eightSamples(_ s: borrowing Span<UInt8>, _ i: Int) -> SIMD8<UInt8> {
    let w = s.extracting(i..<(i &+ 8))
    return SIMD8(w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7])
}
