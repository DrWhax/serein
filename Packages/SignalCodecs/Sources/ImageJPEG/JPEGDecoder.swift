// JPEG decoder for files recognised by `JPEGGrammar`. Bit-exact with
// libjpeg-turbo's `djpeg -dct int` (islow IDCT, fancy upsampling, default colour
// conversion), which is the decoder Chromium — and so Signal Desktop — uses.

public import CodecCore

// MARK: Huffman (jdhuff.c semantics)

struct JPEGHuffmanTable {
    var maxcode = [Int](repeating: -1, count: 18)
    var valoffset = [Int](repeating: 0, count: 17)
    var symbols: [UInt8]

    init(_ spec: JPEGHuffmanSpec) {
        symbols = spec.symbols
        var p = 0, code = 0
        for l in 1...16 {
            let n = spec.counts[l - 1]
            if n > 0 {
                valoffset[l] = p - code
                p += n
                code += n
                maxcode[l] = code - 1
            }
            code <<= 1
        }
        maxcode[17] = 0xFFFFF
    }

    /// Bad codes consume 17 bits and decode as 0 (libjpeg JWRN_HUFF_BAD_CODE).
    @inline(__always)
    func decode(_ r: inout MSBBitReader) -> Int {
        var code = Int(try! r.bit("huffman"))
        var l = 1
        while code > maxcode[l] {
            code = code << 1 | Int(try! r.bit("huffman"))
            l += 1
        }
        if l > 16 { return 0 }
        return Int(symbols[(code + valoffset[l]) & 0xFF])
    }
}

@inline(__always)
func huffExtend(_ x: Int, _ s: Int) -> Int { x < (1 << (s - 1)) ? x + ((-1) << s) + 1 : x }

// MARK: coefficient planes

struct CoefficientPlane {
    let widthInBlocks: Int   // blocks covering the downsampled component
    let heightInBlocks: Int
    let allocW: Int          // padded to whole MCUs
    let allocH: Int
    var coef: [Int16]

    @inline(__always) func base(_ bx: Int, _ by: Int) -> Int { (by * allocW + bx) * 64 }
}

public enum JPEGDecoder {
    /// Decodes and applies EXIF orientation (browser default `image-orientation: from-image`).
    public static func decode(_ bytes: [UInt8], limits: DecodeLimits = .default) throws(ParseFailure) -> PixelBuffer {
        let file = try JPEGGrammar.file(ByteSlice(bytes), limits: limits)
        return applyOrientation(try decodeRaw(file), file.orientation)
    }

    /// Decodes without applying orientation (what `djpeg` outputs).
    public static func decodeRaw(_ file: JPEGFile) throws(ParseFailure) -> PixelBuffer {
        let f = file.frame
        let hmax = f.maxH, vmax = f.maxV
        let mcusPerRow = (f.width + 8 * hmax - 1) / (8 * hmax)
        let mcuRows = (f.height + 8 * vmax - 1) / (8 * vmax)

        var planes: [CoefficientPlane] = f.components.map { comp in
            let dsW = (f.width * comp.h + hmax - 1) / hmax
            let dsH = (f.height * comp.v + vmax - 1) / vmax
            let wb = (dsW + 7) / 8, hb = (dsH + 7) / 8
            let aw = max(mcusPerRow * comp.h, wb), ah = max(mcuRows * comp.v, hb)
            return CoefficientPlane(widthInBlocks: wb, heightInBlocks: hb, allocW: aw, allocH: ah,
                                    coef: [Int16](repeating: 0, count: aw * ah * 64))
        }

        for scan in file.scans {
            try decodeScan(scan, frame: f, planes: &planes, mcusPerRow: mcusPerRow, mcuRows: mcuRows)
        }

        // IDCT and upsample each component to full size.
        var full: [[UInt8]] = []
        for (ci, comp) in f.components.enumerated() {
            let plane = planes[ci]
            let pw = plane.widthInBlocks * 8
            var samples = [UInt8](repeating: 0, count: pw * plane.heightInBlocks * 8)
            let q = file.quant[ci]
            for by in 0..<plane.heightInBlocks {
                for bx in 0..<plane.widthInBlocks {
                    IDCT.islow(plane.coef, plane.base(bx, by), q, &samples, by * 8 * pw + bx * 8, pw)
                }
            }
            let dsW = (f.width * comp.h + hmax - 1) / hmax
            let dsH = (f.height * comp.v + vmax - 1) / vmax
            full.append(Upsample.component(samples, stride: pw, dsW: dsW, dsH: dsH, h: comp.h, v: comp.v,
                                           hmax: hmax, vmax: vmax, width: f.width, height: f.height))
        }
        return ColorConvert.toRGBA(full, transform: file.colorTransform, width: f.width, height: f.height)
    }

    // MARK: scans

    static func decodeScan(_ scan: JPEGScan, frame f: JPEGFrame, planes: inout [CoefficientPlane],
                           mcusPerRow: Int, mcuRows: Int) throws(ParseFailure) {
        let comps = scan.components
        let interleaved = comps.count > 1
        // MCU geometry (libjpeg per_scan_setup).
        let rowMCUs = interleaved ? mcusPerRow : planes[comps[0].index].widthInBlocks
        let colMCUs = interleaved ? mcuRows : planes[comps[0].index].heightInBlocks
        let totalMCUs = rowMCUs * colMCUs
        let dcTables = comps.map { $0.dcTable.map(JPEGHuffmanTable.init) }
        let acTables = comps.map { $0.acTable.map(JPEGHuffmanTable.init) }
        let progressive = f.process == .progressive
        let interval = scan.restartInterval > 0 ? scan.restartInterval : totalMCUs

        var mcu = 0
        var intervalIndex = 0
        while mcu < totalMCUs {
            var r = MSBBitReader(intervalIndex < scan.intervals.count ? scan.intervals[intervalIndex] : [], policy: .zeroFill)
            intervalIndex += 1
            var lastDC = [Int32](repeating: 0, count: comps.count)
            var eobrun = 0
            let end = min(totalMCUs, mcu + interval)
            while mcu < end {
                if !r.exhausted {  // libjpeg: after insufficient data, remaining MCUs are skipped
                    let mx = mcu % rowMCUs, my = mcu / rowMCUs
                    for (si, sc) in comps.enumerated() {
                        let comp = f.components[sc.index]
                        let bw = interleaved ? comp.h : 1, bh = interleaved ? comp.v : 1
                        for v in 0..<bh {
                            for h in 0..<bw {
                                let bx = interleaved ? mx * comp.h + h : mx
                                let by = interleaved ? my * comp.v + v : my
                                let base = planes[sc.index].base(bx, by)
                                if !progressive {
                                    try baselineBlock(&r, dcTables[si]!, acTables[si]!, &lastDC[si], &planes[sc.index].coef, base)
                                } else if scan.ss == 0 {
                                    if scan.ah == 0 {
                                        try dcFirst(&r, dcTables[si]!, &lastDC[si], scan.al, &planes[sc.index].coef, base)
                                    } else if try r.bit("DC refine") == 1 {
                                        planes[sc.index].coef[base] |= Int16(truncatingIfNeeded: 1 << scan.al)
                                    }
                                } else if scan.ah == 0 {
                                    acFirst(&r, acTables[si]!, &eobrun, scan, &planes[sc.index].coef, base)
                                } else {
                                    acRefine(&r, acTables[si]!, &eobrun, scan, &planes[sc.index].coef, base)
                                }
                            }
                        }
                    }
                }
                mcu += 1
            }
        }
    }

    static let order = JPEGGrammar.naturalOrder

    static func baselineBlock(_ r: inout MSBBitReader, _ dct: JPEGHuffmanTable, _ act: JPEGHuffmanTable,
                              _ lastDC: inout Int32, _ coef: inout [Int16], _ base: Int) throws(ParseFailure) {
        var s = dct.decode(&r)
        if s != 0 { s = huffExtend(Int(try r.bits(s, "DC")), s) }
        lastDC = lastDC &+ Int32(truncatingIfNeeded: s)  // libjpeg-turbo wraps here
        coef[base] = Int16(truncatingIfNeeded: lastDC)
        var k = 1
        while k < 64 {
            let rs = act.decode(&r)
            let run = rs >> 4, size = rs & 15
            if size != 0 {
                k += run
                let v = huffExtend(Int(try r.bits(size, "AC")), size)
                coef[base + order[k]] = Int16(truncatingIfNeeded: v)
            } else {
                if run != 15 { break }
                k += 15
            }
            k += 1
        }
    }

    static func dcFirst(_ r: inout MSBBitReader, _ t: JPEGHuffmanTable, _ lastDC: inout Int32, _ al: Int,
                        _ coef: inout [Int16], _ base: Int) throws(ParseFailure) {
        var s = t.decode(&r)
        if s != 0 { s = huffExtend(Int(try r.bits(s, "DC")), s) }
        let (sum, overflow) = lastDC.addingReportingOverflow(Int32(truncatingIfNeeded: s))
        guard !overflow else { throw ParseFailure(offset: r.bitPosition / 8, rule: "DC", reason: .invalid("DC predictor overflow")) }
        lastDC = sum
        coef[base] = Int16(truncatingIfNeeded: Int(sum) << al)
    }

    static func acFirst(_ r: inout MSBBitReader, _ t: JPEGHuffmanTable, _ eobrun: inout Int, _ scan: JPEGScan,
                        _ coef: inout [Int16], _ base: Int) {
        if eobrun > 0 { eobrun -= 1; return }
        var k = scan.ss
        while k <= scan.se {
            let rs = t.decode(&r)
            var run = rs >> 4
            let size = rs & 15
            if size != 0 {
                k += run
                let v = huffExtend(Int(try! r.bits(size, "AC")), size)
                coef[base + order[k]] = Int16(truncatingIfNeeded: v << scan.al)
            } else if run == 15 {
                k += 15
            } else {
                eobrun = 1 << run
                if run != 0 { run = Int(try! r.bits(run, "EOBRUN")); eobrun += run }
                eobrun -= 1
                break
            }
            k += 1
        }
    }

    static func acRefine(_ r: inout MSBBitReader, _ t: JPEGHuffmanTable, _ eobrun: inout Int, _ scan: JPEGScan,
                         _ coef: inout [Int16], _ base: Int) {
        let p1 = 1 << scan.al, m1 = -1 << scan.al
        var k = scan.ss
        func refine(_ pos: Int) {
            let c = Int(coef[pos])
            if c != 0, try! r.bit("refine") == 1, c & p1 == 0 {
                coef[pos] = Int16(truncatingIfNeeded: c >= 0 ? c + p1 : c + m1)
            }
        }
        if eobrun == 0 {
            while k <= scan.se {
                let rs = t.decode(&r)
                var run = rs >> 4
                var s = rs & 15
                if s != 0 {
                    s = try! r.bit("sign") == 1 ? p1 : m1  // size other than 1 is a warning in libjpeg
                } else if run != 15 {
                    eobrun = 1 << run
                    if run != 0 { run = Int(try! r.bits(run, "EOBRUN")); eobrun += run }
                    break
                }
                repeat {
                    let pos = base + order[k]
                    if coef[pos] != 0 {
                        refine(pos)
                    } else {
                        run -= 1
                        if run < 0 { break }
                    }
                    k += 1
                } while k <= scan.se
                if s != 0 { coef[base + order[k]] = Int16(truncatingIfNeeded: s) }
                k += 1
            }
        }
        if eobrun > 0 {
            while k <= scan.se {
                refine(base + order[k])
                k += 1
            }
            eobrun -= 1
        }
    }

    // MARK: orientation

    /// Applies EXIF orientation 1...8.
    public static func applyOrientation(_ img: PixelBuffer, _ o: Int) -> PixelBuffer {
        guard (2...8).contains(o) else { return img }
        let W = img.width, H = img.height
        let swap = o >= 5
        var out = PixelBuffer(transparentWidth: swap ? H : W, height: swap ? W : H)
        for y in 0..<H {
            for x in 0..<W {
                let (dx, dy): (Int, Int)
                switch o {
                case 2: (dx, dy) = (W - 1 - x, y)
                case 3: (dx, dy) = (W - 1 - x, H - 1 - y)
                case 4: (dx, dy) = (x, H - 1 - y)
                case 5: (dx, dy) = (y, x)
                case 6: (dx, dy) = (H - 1 - y, x)
                case 7: (dx, dy) = (H - 1 - y, W - 1 - x)
                default: (dx, dy) = (y, W - 1 - x)
                }
                let s = (y * W + x) * 4, d = (dy * out.width + dx) * 4
                out.rgba[d] = img.rgba[s]; out.rgba[d + 1] = img.rgba[s + 1]
                out.rgba[d + 2] = img.rgba[s + 2]; out.rgba[d + 3] = img.rgba[s + 3]
            }
        }
        return out
    }
}

// MARK: IDCT (jidctint.c, jpeg_idct_islow)

enum IDCT {
    static let constBits = 13, pass1Bits = 2
    static let f0_298631336: Int64 = 2446, f0_390180644: Int64 = 3196, f0_541196100: Int64 = 4433
    static let f0_765366865: Int64 = 6270, f0_899976223: Int64 = 7373, f1_175875602: Int64 = 9633
    static let f1_501321110: Int64 = 12299, f1_847759065: Int64 = 15137, f1_961570560: Int64 = 16069
    static let f2_053119869: Int64 = 16819, f2_562915447: Int64 = 20995, f3_072711026: Int64 = 25172

    @inline(__always) static func descale(_ x: Int64, _ n: Int) -> Int64 { (x + (1 << (n - 1))) >> n }

    /// Output = clamp(signed10(v) + 128) — libjpeg's IDCT range-limit table.
    @inline(__always) static func rangeLimit(_ v: Int64) -> UInt8 {
        let m = Int(v & 1023)
        let s = m >= 512 ? m - 1024 : m
        return UInt8(max(0, min(255, s + 128)))
    }

    static func islow(_ coef: [Int16], _ base: Int, _ q: [Int32], _ out: inout [UInt8], _ outBase: Int, _ stride: Int) {
        var ws = [Int32](repeating: 0, count: 64)
        for col in 0..<8 {
            @inline(__always) func dq(_ row: Int) -> Int64 { Int64(coef[base + row * 8 + col]) * Int64(q[row * 8 + col]) }
            if coef[base + 8 + col] == 0 && coef[base + 16 + col] == 0 && coef[base + 24 + col] == 0 && coef[base + 32 + col] == 0
                && coef[base + 40 + col] == 0 && coef[base + 48 + col] == 0 && coef[base + 56 + col] == 0 {
                let dc = Int32(truncatingIfNeeded: dq(0) << pass1Bits)
                for row in 0..<8 { ws[row * 8 + col] = dc }
                continue
            }
            var z2 = dq(2), z3 = dq(6)
            var z1 = (z2 &+ z3) &* f0_541196100
            var tmp2 = z1 &+ z3 &* -f1_847759065
            var tmp3 = z1 &+ z2 &* f0_765366865
            z2 = dq(0); z3 = dq(4)
            var tmp0 = (z2 &+ z3) << constBits
            var tmp1 = (z2 &- z3) << constBits
            let tmp10 = tmp0 &+ tmp3, tmp13 = tmp0 &- tmp3, tmp11 = tmp1 &+ tmp2, tmp12 = tmp1 &- tmp2
            tmp0 = dq(7); tmp1 = dq(5); tmp2 = dq(3); tmp3 = dq(1)
            z1 = tmp0 &+ tmp3; z2 = tmp1 &+ tmp2; z3 = tmp0 &+ tmp2; var z4 = tmp1 &+ tmp3
            let z5 = (z3 &+ z4) &* f1_175875602
            tmp0 = tmp0 &* f0_298631336; tmp1 = tmp1 &* f2_053119869
            tmp2 = tmp2 &* f3_072711026; tmp3 = tmp3 &* f1_501321110
            z1 = z1 &* -f0_899976223; z2 = z2 &* -f2_562915447
            z3 = z3 &* -f1_961570560; z4 = z4 &* -f0_390180644
            z3 = z3 &+ z5; z4 = z4 &+ z5
            tmp0 = tmp0 &+ z1 &+ z3; tmp1 = tmp1 &+ z2 &+ z4
            tmp2 = tmp2 &+ z2 &+ z3; tmp3 = tmp3 &+ z1 &+ z4
            let n = constBits - pass1Bits
            ws[0 * 8 + col] = Int32(truncatingIfNeeded: descale(tmp10 &+ tmp3, n))
            ws[7 * 8 + col] = Int32(truncatingIfNeeded: descale(tmp10 &- tmp3, n))
            ws[1 * 8 + col] = Int32(truncatingIfNeeded: descale(tmp11 &+ tmp2, n))
            ws[6 * 8 + col] = Int32(truncatingIfNeeded: descale(tmp11 &- tmp2, n))
            ws[2 * 8 + col] = Int32(truncatingIfNeeded: descale(tmp12 &+ tmp1, n))
            ws[5 * 8 + col] = Int32(truncatingIfNeeded: descale(tmp12 &- tmp1, n))
            ws[3 * 8 + col] = Int32(truncatingIfNeeded: descale(tmp13 &+ tmp0, n))
            ws[4 * 8 + col] = Int32(truncatingIfNeeded: descale(tmp13 &- tmp0, n))
        }
        let n2 = constBits + pass1Bits + 3
        for row in 0..<8 {
            let w = row * 8
            let o = outBase + row * stride
            if ws[w + 1] == 0 && ws[w + 2] == 0 && ws[w + 3] == 0 && ws[w + 4] == 0 && ws[w + 5] == 0 && ws[w + 6] == 0 && ws[w + 7] == 0 {
                let dc = rangeLimit(descale(Int64(ws[w]), pass1Bits + 3))
                for i in 0..<8 { out[o + i] = dc }
                continue
            }
            var z2 = Int64(ws[w + 2]), z3 = Int64(ws[w + 6])
            var z1 = (z2 &+ z3) &* f0_541196100
            var tmp2 = z1 &+ z3 &* -f1_847759065
            var tmp3 = z1 &+ z2 &* f0_765366865
            var tmp0 = (Int64(ws[w]) &+ Int64(ws[w + 4])) << constBits
            var tmp1 = (Int64(ws[w]) &- Int64(ws[w + 4])) << constBits
            let tmp10 = tmp0 &+ tmp3, tmp13 = tmp0 &- tmp3, tmp11 = tmp1 &+ tmp2, tmp12 = tmp1 &- tmp2
            tmp0 = Int64(ws[w + 7]); tmp1 = Int64(ws[w + 5]); tmp2 = Int64(ws[w + 3]); tmp3 = Int64(ws[w + 1])
            z1 = tmp0 &+ tmp3; z2 = tmp1 &+ tmp2; z3 = tmp0 &+ tmp2; var z4 = tmp1 &+ tmp3
            let z5 = (z3 &+ z4) &* f1_175875602
            tmp0 = tmp0 &* f0_298631336; tmp1 = tmp1 &* f2_053119869
            tmp2 = tmp2 &* f3_072711026; tmp3 = tmp3 &* f1_501321110
            z1 = z1 &* -f0_899976223; z2 = z2 &* -f2_562915447
            z3 = z3 &* -f1_961570560; z4 = z4 &* -f0_390180644
            z3 = z3 &+ z5; z4 = z4 &+ z5
            tmp0 = tmp0 &+ z1 &+ z3; tmp1 = tmp1 &+ z2 &+ z4
            tmp2 = tmp2 &+ z2 &+ z3; tmp3 = tmp3 &+ z1 &+ z4
            out[o + 0] = rangeLimit(descale(tmp10 &+ tmp3, n2))
            out[o + 7] = rangeLimit(descale(tmp10 &- tmp3, n2))
            out[o + 1] = rangeLimit(descale(tmp11 &+ tmp2, n2))
            out[o + 6] = rangeLimit(descale(tmp11 &- tmp2, n2))
            out[o + 2] = rangeLimit(descale(tmp12 &+ tmp1, n2))
            out[o + 5] = rangeLimit(descale(tmp12 &- tmp1, n2))
            out[o + 3] = rangeLimit(descale(tmp13 &+ tmp0, n2))
            out[o + 4] = rangeLimit(descale(tmp13 &- tmp0, n2))
        }
    }
}

// MARK: upsampling (jdsample.c)

enum Upsample {
    /// Returns a width×height plane. Rows outside the component are clamped
    /// (jdmainct.c context rows); columns are never read past `dsW`.
    static func component(_ s: [UInt8], stride: Int, dsW: Int, dsH: Int, h: Int, v: Int,
                          hmax: Int, vmax: Int, width W: Int, height H: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: W * H)
        @inline(__always) func at(_ x: Int, _ y: Int) -> Int { Int(s[min(max(y, 0), dsH - 1) * stride + x]) }

        if h == hmax && v == vmax {
            for y in 0..<H { for x in 0..<W { out[y * W + x] = UInt8(at(x, y)) } }
        } else if 2 * h == hmax && v == vmax && dsW > 2 {
            for y in 0..<H {
                var row = [UInt8](repeating: 0, count: 2 * dsW)
                h2v1Row({ at($0, y) }, dsW, &row)
                for x in 0..<W { out[y * W + x] = row[x] }
            }
        } else if h == hmax && 2 * v == vmax {
            for y in 0..<H {
                let inrow = y / 2
                let other = y % 2 == 0 ? inrow - 1 : inrow + 1
                let bias = y % 2 == 0 ? 1 : 2
                for x in 0..<W { out[y * W + x] = UInt8((at(x, inrow) * 3 + at(x, other) + bias) >> 2) }
            }
        } else if 2 * h == hmax && 2 * v == vmax && dsW > 2 {
            for y in 0..<H {
                let inrow = y / 2
                let other = y % 2 == 0 ? inrow - 1 : inrow + 1
                var row = [UInt8](repeating: 0, count: 2 * dsW)
                h2v2Row({ at($0, inrow) * 3 + at($0, other) }, dsW, &row)
                for x in 0..<W { out[y * W + x] = row[x] }
            }
        } else {
            // Box replication (int_upsample / h2v1_upsample / h2v2_upsample).
            let hx = hmax / h, vx = vmax / v
            for y in 0..<H { for x in 0..<W { out[y * W + x] = UInt8(at(x / hx, y / vx)) } }
        }
        return out
    }

    static func h2v1Row(_ sample: (Int) -> Int, _ n: Int, _ out: inout [UInt8]) {
        var o = 0
        var v = sample(0)
        out[o] = UInt8(v); out[o + 1] = UInt8((v * 3 + sample(1) + 2) >> 2); o += 2
        for i in 1..<(n - 1) {
            v = sample(i) * 3
            out[o] = UInt8((v + sample(i - 1) + 1) >> 2)
            out[o + 1] = UInt8((v + sample(i + 1) + 2) >> 2)
            o += 2
        }
        v = sample(n - 1)
        out[o] = UInt8((v * 3 + sample(n - 2) + 1) >> 2); out[o + 1] = UInt8(v)
    }

    /// `colsum(i)` = 3 * nearer row + further row at column i.
    static func h2v2Row(_ colsum: (Int) -> Int, _ n: Int, _ out: inout [UInt8]) {
        var o = 0
        var this = colsum(0), next = colsum(1)
        out[o] = UInt8((this * 4 + 8) >> 4); out[o + 1] = UInt8((this * 3 + next + 7) >> 4); o += 2
        var last = this
        this = next
        for i in 2..<n {
            next = colsum(i)
            out[o] = UInt8((this * 3 + last + 8) >> 4)
            out[o + 1] = UInt8((this * 3 + next + 7) >> 4)
            o += 2
            last = this
            this = next
        }
        out[o] = UInt8((this * 3 + last + 8) >> 4); out[o + 1] = UInt8((this * 4 + 7) >> 4)
    }
}

// MARK: colour conversion (jdcolor.c)

enum ColorConvert {
    static let scaleBits = 16
    static let oneHalf: Int = 1 << 15
    static func fix(_ x: Double) -> Int { Int(x * Double(1 << 16) + 0.5) }
    static let crR: [Int] = (0..<256).map { (fix(1.40200) * ($0 - 128) + oneHalf) >> scaleBits }
    static let cbB: [Int] = (0..<256).map { (fix(1.77200) * ($0 - 128) + oneHalf) >> scaleBits }
    static let crG: [Int] = (0..<256).map { -fix(0.71414) * ($0 - 128) }
    static let cbG: [Int] = (0..<256).map { -fix(0.34414) * ($0 - 128) + oneHalf }

    @inline(__always) static func clamp(_ v: Int) -> UInt8 { UInt8(max(0, min(255, v))) }
    /// Skia's SkMulDiv255Round.
    @inline(__always) static func mulDiv255(_ a: Int, _ b: Int) -> UInt8 {
        let p = a * b + 128
        return UInt8((p + (p >> 8)) >> 8)
    }

    static func toRGBA(_ c: [[UInt8]], transform: JPEGColorTransform, width: Int, height: Int) -> PixelBuffer {
        var out = PixelBuffer(transparentWidth: width, height: height)
        for i in 0..<(width * height) {
            let o = i * 4
            switch transform {
            case .grayscale:
                out.rgba[o] = c[0][i]; out.rgba[o + 1] = c[0][i]; out.rgba[o + 2] = c[0][i]
            case .rgb:
                out.rgba[o] = c[0][i]; out.rgba[o + 1] = c[1][i]; out.rgba[o + 2] = c[2][i]
            case .ycbcr:
                let y = Int(c[0][i]), cb = Int(c[1][i]), cr = Int(c[2][i])
                out.rgba[o] = clamp(y + crR[cr])
                out.rgba[o + 1] = clamp(y + ((cbG[cb] + crG[cr]) >> scaleBits))
                out.rgba[o + 2] = clamp(y + cbB[cb])
            case .cmyk, .ycck:
                // Adobe CMYK/YCCK JPEGs store inverted ink values (as Chromium assumes).
                var cc = Int(c[0][i]), mm = Int(c[1][i]), yy = Int(c[2][i])
                if transform == .ycck {
                    let y = cc, cb = mm, cr = yy
                    cc = 255 - Int(clamp(y + crR[cr]))
                    mm = 255 - Int(clamp(y + ((cbG[cb] + crG[cr]) >> scaleBits)))
                    yy = 255 - Int(clamp(y + cbB[cb]))
                }
                let k = Int(c[3][i])
                out.rgba[o] = mulDiv255(cc, k); out.rgba[o + 1] = mulDiv255(mm, k); out.rgba[o + 2] = mulDiv255(yy, k)
            }
            out.rgba[o + 3] = 255
        }
        return out
    }
}
