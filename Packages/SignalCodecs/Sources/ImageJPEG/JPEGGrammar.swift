// JPEG (ITU-T T.81 / ISO 10918-1, Annex B) grammar for the Huffman-coded DCT
// processes SignalSafe supports: baseline (SOF0), extended sequential 8-bit (SOF1)
// and progressive (SOF2). Recognises the whole file into a typed `JPEGFile`.
//
//   jpeg     := SOI segment* EOI? trailing*
//   segment  := (non-FF garbage)* FF+ marker body
//   SOF0-2   := L:u16 P:u8{8} Y:u16{>0} X:u16{>0} Nf:u8{1,3,4} (C:u8 H:4{1..4} V:4{1..4} Tq:u8{0..3}){Nf}
//   DHT      := L:u16 (Tc:4{0,1} Th:4{0..3} counts:u8{16} symbols:u8{Σcounts ≤ 256})+   { valid canonical code }
//   DQT      := L:u16 (Pq:4{0,1} Tq:4{0..3} Q:(u8|u16){64})+                             { Q ≠ 0 }
//   DRI      := L:u16{4} Ri:u16
//   SOS      := L:u16 Ns:u8{1..4} (Cs Td:4 Ta:4){Ns} Ss Se Ah:4 Al:4  ecs (RSTm ecs)*   { m = 0,1,..,7,0,.. }
//   APPn,COM := L:u16 byte{L-2}       (APP0 JFIF, APP1 Exif orientation, APP14 Adobe are interpreted)
//   ecs      := (byte ≠ FF | FF FF* 00)*                                                  (byte stuffing)
//
// Policy (libjpeg-turbo compatible, which is what Chromium/Signal Desktop use):
//   * lossless, hierarchical, arithmetic-coded and 12-bit JPEGs are rejected;
//   * missing EOI, garbage (incl. FF 00) between segments, stray RST/TEM/DNL markers: tolerated;
//   * Huffman tables 0/1 that a scan references but the file never defines get the
//     Annex K defaults (Motion-JPEG), as libjpeg-turbo does;
//   * quantisation tables are latched at each component's first scan;
//   * a malformed Exif block is ignored (orientation 1).

public import CodecCore

public struct JPEGComponent: Sendable, Equatable {
    public var id: UInt8
    public var h: Int
    public var v: Int
    public var quantTable: Int
}

public struct JPEGFrame: Sendable, Equatable {
    public enum Process: Sendable, Equatable { case baseline, extended, progressive }
    public var process: Process
    public var width: Int
    public var height: Int
    public var components: [JPEGComponent]
    public var maxH: Int { components.map(\.h).max()! }
    public var maxV: Int { components.map(\.v).max()! }
}

public struct JPEGHuffmanSpec: Sendable, Equatable {
    public var counts: [Int]   // 16 entries: number of codes of length 1...16
    public var symbols: [UInt8]
}

public struct JPEGScanComponent: Sendable, Equatable {
    public var index: Int       // into frame.components
    public var dcTable: JPEGHuffmanSpec?
    public var acTable: JPEGHuffmanSpec?
}

public struct JPEGScan: Sendable, Equatable {
    public var components: [JPEGScanComponent]
    public var ss, se, ah, al: Int
    public var restartInterval: Int
    /// Unstuffed entropy-coded data, one element per restart interval.
    public var intervals: [[UInt8]]
}

public enum JPEGColorTransform: Sendable, Equatable { case grayscale, ycbcr, rgb, cmyk, ycck }

public struct JPEGFile: Sendable, Equatable {
    public var frame: JPEGFrame
    public var scans: [JPEGScan]
    /// Quantisation table per component (natural order), latched at its first scan.
    public var quant: [[Int32]]
    public var colorTransform: JPEGColorTransform
    /// EXIF orientation 1...8 (1 if absent or invalid).
    public var orientation: Int
}

public enum JPEGGrammar {
    /// Zig-zag to natural order, with 16 trailing 63s so that run-overflowing
    /// coefficient indices land on position 63 exactly as in libjpeg.
    public static let naturalOrder: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ] + [Int](repeating: 63, count: 16)

    // Annex K.3 default tables (used only for undefined tables 0 and 1).
    static let stdDC0 = JPEGHuffmanSpec(counts: [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0], symbols: Array(0...11))
    static let stdDC1 = JPEGHuffmanSpec(counts: [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0], symbols: Array(0...11))
    static let stdAC0 = JPEGHuffmanSpec(counts: [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D], symbols: [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
        0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
        0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6,
        0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
        0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA])
    static let stdAC1 = JPEGHuffmanSpec(counts: [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77], symbols: [
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
        0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0, 0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34, 0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
        0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
        0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4,
        0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
        0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA])

    // MARK: segment bodies

    static func sof(_ body: ByteSlice, process: JPEGFrame.Process, limits: DecodeLimits) throws(ParseFailure) -> JPEGFrame {
        var c = body.cursor()
        let at = c.position
        _ = try c.u8("SOF.P", require: "only 8-bit precision is supported") { $0 == 8 }
        let height = Int(try c.u16be("SOF.Y")), width = Int(try c.u16be("SOF.X"))
        guard height > 0 else { throw ParseFailure(offset: at + 1, rule: "SOF.Y", reason: .invalid("height 0 (DNL) not supported")) }
        try limits.checkDimensions(width: width, height: height, at: at, rule: "SOF")
        let n = Int(try c.u8("SOF.Nf", require: "1, 3 or 4 components") { [1, 3, 4].contains($0) })
        var comps: [JPEGComponent] = []
        for _ in 0..<n {
            let id = try c.u8("SOF.C")
            let hv = try c.u8("SOF.HV", require: "sampling factors 1..4") { (1...4).contains($0 >> 4) && (1...4).contains($0 & 15) }
            let tq = try c.u8("SOF.Tq", require: "quantisation table 0..3") { $0 <= 3 }
            guard !comps.contains(where: { $0.id == id }) else { throw c.fail("SOF.C", .invalid("duplicate component id \(id)")) }
            comps.append(JPEGComponent(id: id, h: Int(hv >> 4), v: Int(hv & 15), quantTable: Int(tq)))
        }
        try c.expectEnd("SOF")
        let frame = JPEGFrame(process: process, width: width, height: height, components: comps)
        // Upsampling needs integral ratios (libjpeg: JERR_FRACT_SAMPLE_NOTIMPL).
        for comp in comps where frame.maxH % comp.h != 0 || frame.maxV % comp.v != 0 {
            throw ParseFailure(offset: at, rule: "SOF", reason: .invalid("fractional sampling ratio \(frame.maxH)/\(comp.h) x \(frame.maxV)/\(comp.v)"))
        }
        if n > 1 {
            let blocks = comps.reduce(0) { $0 + $1.h * $1.v }
            guard blocks <= 10 else { throw ParseFailure(offset: at, rule: "SOF", reason: .invalid("\(blocks) blocks per MCU > 10")) }
        }
        return frame
    }

    static func dht(_ body: ByteSlice, dc: inout [JPEGHuffmanSpec?], ac: inout [JPEGHuffmanSpec?]) throws(ParseFailure) {
        var c = body.cursor()
        while !c.isAtEnd {
            let at = c.position
            let tcth = try c.u8("DHT.TcTh", require: "Tc ≤ 1, Th ≤ 3") { $0 >> 4 <= 1 && $0 & 15 <= 3 }
            var counts: [Int] = []
            for _ in 0..<16 { counts.append(Int(try c.u8("DHT.L"))) }
            let total = counts.reduce(0, +)
            guard total <= 256 else { throw ParseFailure(offset: at, rule: "DHT", reason: .invalid("\(total) symbols")) }
            var symbols: [UInt8] = []
            for _ in 0..<total { symbols.append(try c.u8("DHT.V")) }
            // Canonical code must fit (libjpeg jpeg_make_d_derived_tbl).
            var code = 0
            for len in 1...16 {
                code += counts[len - 1]
                guard code <= 1 << len else { throw ParseFailure(offset: at, rule: "DHT", reason: .invalid("over-subscribed Huffman code")) }
                code <<= 1
            }
            let isDC = tcth >> 4 == 0
            if isDC, let bad = symbols.first(where: { $0 > 15 }) {
                throw ParseFailure(offset: at, rule: "DHT", reason: .invalid("DC symbol \(bad) > 15"))
            }
            let spec = JPEGHuffmanSpec(counts: counts, symbols: symbols)
            if isDC { dc[Int(tcth & 15)] = spec } else { ac[Int(tcth & 15)] = spec }
        }
    }

    static func dqt(_ body: ByteSlice, quant: inout [[Int32]?]) throws(ParseFailure) {
        var c = body.cursor()
        while !c.isAtEnd {
            let pqtq = try c.u8("DQT.PqTq", require: "Pq ≤ 1, Tq ≤ 3") { $0 >> 4 <= 1 && $0 & 15 <= 3 }
            var table = [Int32](repeating: 0, count: 64)
            for i in 0..<64 {
                let v = pqtq >> 4 == 0 ? Int32(try c.u8("DQT.Q")) : Int32(try c.u16be("DQT.Q"))
                table[naturalOrder[i]] = v
            }
            quant[Int(pqtq & 15)] = table
        }
    }

    static func sos(_ body: ByteSlice, frame: JPEGFrame, dc: [JPEGHuffmanSpec?], ac: [JPEGHuffmanSpec?]) throws(ParseFailure)
        -> (components: [JPEGScanComponent], ss: Int, se: Int, ah: Int, al: Int) {
        var c = body.cursor()
        let at = c.position
        let ns = Int(try c.u8("SOS.Ns", require: "1..4 components") { (1...4).contains($0) })
        var comps: [JPEGScanComponent] = []
        var tableRefs: [(Int, Int)] = []
        for _ in 0..<ns {
            let id = try c.u8("SOS.Cs")
            guard let idx = frame.components.firstIndex(where: { $0.id == id }) else {
                throw c.fail("SOS.Cs", .invalid("component \(id) not in frame"))
            }
            guard !comps.contains(where: { $0.index == idx }) else { throw c.fail("SOS.Cs", .invalid("component repeated in scan")) }
            let t = try c.u8("SOS.TdTa", require: "table selectors ≤ 3") { $0 >> 4 <= 3 && $0 & 15 <= 3 }
            comps.append(JPEGScanComponent(index: idx, dcTable: nil, acTable: nil))
            tableRefs.append((Int(t >> 4), Int(t & 15)))
        }
        let ss = Int(try c.u8("SOS.Ss")), se = Int(try c.u8("SOS.Se"))
        let a = try c.u8("SOS.AhAl")
        try c.expectEnd("SOS")
        let ah = Int(a >> 4), al = Int(a & 15)

        if frame.process == .progressive {
            // jdphuff.c start_pass_phuff_decoder (JERR_BAD_PROGRESSION conditions).
            var bad = false
            if ss == 0 { bad = se != 0 } else { bad = ss > se || se > 63 || ns != 1 }
            if ah != 0 && al != ah - 1 { bad = true }
            if al > 13 { bad = true }
            guard !bad else { throw ParseFailure(offset: at, rule: "SOS", reason: .invalid("bad progression Ss=\(ss) Se=\(se) Ah=\(ah) Al=\(al)")) }
        } else if ns > 1 {
            let blocks = comps.reduce(0) { $0 + frame.components[$1.index].h * frame.components[$1.index].v }
            guard blocks <= 10 else { throw ParseFailure(offset: at, rule: "SOS", reason: .invalid("\(blocks) blocks per MCU > 10")) }
        }

        // Resolve the tables this scan needs (snapshot: later DHTs may redefine them).
        let isProgressive = frame.process == .progressive
        let needsDC = !isProgressive || (ss == 0 && ah == 0)
        let needsAC = !isProgressive || ss > 0
        for i in 0..<comps.count {
            let (td, ta) = tableRefs[i]
            if needsDC {
                comps[i].dcTable = dc[td] ?? (td == 0 ? stdDC0 : td == 1 ? stdDC1 : nil)
                guard comps[i].dcTable != nil else { throw ParseFailure(offset: at, rule: "SOS", reason: .invalid("undefined DC table \(td)")) }
            }
            if needsAC {
                comps[i].acTable = ac[ta] ?? (ta == 0 ? stdAC0 : ta == 1 ? stdAC1 : nil)
                guard comps[i].acTable != nil else { throw ParseFailure(offset: at, rule: "SOS", reason: .invalid("undefined AC table \(ta)")) }
            }
        }
        return (comps, ss, se, ah, al)
    }

    /// ecs (RSTm ecs)*: unstuffs entropy-coded data, splitting it at restart markers.
    /// Leaves `c` at the FF that starts the next marker (or at end of input).
    static func entropyData(_ c: inout ByteCursor, maxBytes: Int) throws(ParseFailure) -> [[UInt8]] {
        var intervals: [[UInt8]] = []
        var current: [UInt8] = []
        var expectedRST: UInt8 = 0
        var total = 0
        while let b = c.peekU8() {
            if b != 0xFF {
                current.append(try c.u8())
                total += 1
                guard total <= maxBytes else { throw c.fail("scan", .limitExceeded("entropy data > \(maxBytes) bytes")) }
                continue
            }
            // FF FF* then: 00 = stuffed FF; D0-D7 = restart; anything else = marker.
            var look = c
            _ = try look.u8()
            while look.peekU8() == 0xFF { _ = try look.u8() }
            guard let next = look.peekU8() else { c = look; break }  // input ends inside FF run
            if next == 0x00 {
                _ = try look.u8()
                current.append(0xFF)
                c = look
            } else if (0xD0...0xD7).contains(next) {
                guard next == 0xD0 + expectedRST else {
                    throw look.fail("RST", .invalid("RST\(next - 0xD0), expected RST\(expectedRST)"))
                }
                _ = try look.u8()
                expectedRST = (expectedRST + 1) & 7
                intervals.append(current)
                current = []
                c = look
            } else {
                break  // a real marker: leave c at its first FF
            }
        }
        intervals.append(current)
        return intervals
    }

    // MARK: APPn

    /// APP1 "Exif\0\0" → TIFF IFD0 → tag 0x0112 Orientation (SHORT, count 1, 1..8).
    static func exifOrientation(_ body: ByteSlice) -> Int? {
        var c = body.cursor()
        guard (try? c.expect(Array("Exif".utf8) + [0, 0], "Exif")) != nil else { return nil }
        let tiff = c.rest()
        var t = tiff.cursor()
        guard let order = t.peek(2)?.copyBytes() else { return nil }
        let little: Bool
        if order == [0x49, 0x49] { little = true } else if order == [0x4D, 0x4D] { little = false } else { return nil }
        func u16(_ c: inout ByteCursor) -> Int? { (little ? try? c.u16le() : try? c.u16be()).map(Int.init) }
        func u32(_ c: inout ByteCursor) -> Int? { (little ? try? c.u32le() : try? c.u32be()).map(Int.init) }
        try? t.skip(2)
        guard u16(&t) == 42, let ifd = u32(&t), ifd >= 8, ifd < tiff.count else { return nil }
        var d = tiff.cursor()
        guard (try? d.skip(ifd)) != nil, let n = u16(&d), n <= 1024 else { return nil }
        for _ in 0..<n {
            guard let tag = u16(&d), let type = u16(&d), let count = u32(&d), let entry = d.peek(4) else { return nil }
            try? d.skip(4)
            if tag == 0x0112 {
                var v = entry.cursor()
                guard type == 3, count == 1, let o = u16(&v), (1...8).contains(o) else { return nil }
                return o
            }
        }
        return nil
    }

    // MARK: file

    public static func file(_ input: ByteSlice, limits: DecodeLimits = .default) throws(ParseFailure) -> JPEGFile {
        guard input.count <= limits.maxInputBytes else {
            throw ParseFailure(offset: 0, rule: "jpeg", reason: .limitExceeded("input \(input.count) bytes"))
        }
        var c = input.cursor()
        try c.expect([0xFF, 0xD8], "jpeg.SOI")

        var frame: JPEGFrame?
        var quant = [[Int32]?](repeating: nil, count: 4)
        var dc = [JPEGHuffmanSpec?](repeating: nil, count: 4)
        var ac = [JPEGHuffmanSpec?](repeating: nil, count: 4)
        var restart = 0
        var scans: [JPEGScan] = []
        var latched: [[Int32]?] = []
        var sawJFIF = false
        var adobeTransform: Int?
        var orientation = 1
        let maxScans = 1_000

        func finish() throws(ParseFailure) -> JPEGFile {
            guard let f = frame else { throw ParseFailure(offset: c.position, rule: "jpeg", reason: .invalid("no frame header")) }
            guard !scans.isEmpty else { throw ParseFailure(offset: c.position, rule: "jpeg", reason: .invalid("no scans")) }
            // Components never scanned latch their table now (their coefficients stay zero).
            var q: [[Int32]] = []
            for (i, comp) in f.components.enumerated() {
                guard let t = latched[i] ?? quant[comp.quantTable] else {
                    throw ParseFailure(offset: c.position, rule: "jpeg", reason: .invalid("no quantisation table \(comp.quantTable)"))
                }
                q.append(t)
            }
            let transform: JPEGColorTransform
            switch f.components.count {
            case 1: transform = .grayscale
            case 3:
                if sawJFIF { transform = .ycbcr }
                else if let t = adobeTransform { transform = t == 0 ? .rgb : .ycbcr }
                else {
                    let ids = f.components.map(\.id)
                    transform = ids == [82, 71, 66] ? .rgb : .ycbcr
                }
            default:
                transform = adobeTransform.map { $0 == 0 ? JPEGColorTransform.cmyk : .ycck } ?? .cmyk
            }
            return JPEGFile(frame: f, scans: scans, quant: q, colorTransform: transform, orientation: orientation)
        }

        var garbage = 0
        while true {
            // Skip non-FF garbage and FF fill bytes.
            while let b = c.peekU8(), b != 0xFF {
                _ = try c.u8()
                garbage += 1
                guard garbage <= 1 << 20 else { throw c.fail("jpeg", .limitExceeded("too much garbage between segments")) }
            }
            while c.peekU8() == 0xFF, c.peek(2).map({ $0.copyBytes()[1] == 0xFF }) == true { _ = try c.u8() }
            guard c.remaining >= 2 else { return try finish() }  // missing EOI
            let at = c.position
            _ = try c.u8()
            let marker = try c.u8("marker")

            switch marker {
            case 0x00:
                continue  // FF 00 outside a scan: stuffed-zero garbage (libjpeg next_marker discards it)
            case 0xD9:
                return try finish()
            case 0xD0...0xD7, 0x01:
                continue  // stray RSTn / TEM: no body
            case 0xD8:
                throw ParseFailure(offset: at, rule: "jpeg", reason: .invalid("second SOI"))
            default:
                break
            }

            guard c.remaining >= 2 else { return try finish() }
            let length = Int(try c.u16be("segment.length"))
            guard length >= 2 else { throw ParseFailure(offset: at + 2, rule: "segment.length", reason: .invalid("length \(length)")) }
            guard c.remaining >= length - 2 else {
                if scans.isEmpty { throw ParseFailure(offset: at, rule: "segment", reason: .unexpectedEnd(needed: length - 2, available: c.remaining)) }
                return try finish()
            }
            let body = try c.bytes(length - 2, "segment.body")

            switch marker {
            case 0xC0, 0xC1, 0xC2:
                guard frame == nil else { throw ParseFailure(offset: at, rule: "SOF", reason: .invalid("second frame header")) }
                frame = try sof(body, process: marker == 0xC0 ? .baseline : marker == 0xC1 ? .extended : .progressive, limits: limits)
                latched = [[Int32]?](repeating: nil, count: frame!.components.count)
            case 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF:
                throw ParseFailure(offset: at, rule: "SOF", reason: .invalid("unsupported JPEG process (SOF\(marker - 0xC0)): lossless, hierarchical or arithmetic"))
            case 0xC4:
                try dht(body, dc: &dc, ac: &ac)
            case 0xCC:
                throw ParseFailure(offset: at, rule: "DAC", reason: .invalid("arithmetic coding not supported"))
            case 0xDB:
                try dqt(body, quant: &quant)
            case 0xDD:
                guard body.count == 2 else { throw ParseFailure(offset: at, rule: "DRI", reason: .invalid("length \(length)")) }
                var b = body.cursor()
                restart = Int(try b.u16be("DRI.Ri"))
            case 0xDA:
                guard let f = frame else { throw ParseFailure(offset: at, rule: "SOS", reason: .invalid("scan before frame header")) }
                guard scans.count < maxScans else { throw ParseFailure(offset: at, rule: "SOS", reason: .limitExceeded("more than \(maxScans) scans")) }
                let h = try sos(body, frame: f, dc: dc, ac: ac)
                for sc in h.components where latched[sc.index] == nil {
                    guard let t = quant[f.components[sc.index].quantTable] else {
                        throw ParseFailure(offset: at, rule: "SOS", reason: .invalid("no quantisation table \(f.components[sc.index].quantTable)"))
                    }
                    latched[sc.index] = t
                }
                let intervals = try entropyData(&c, maxBytes: limits.maxInputBytes)
                scans.append(JPEGScan(components: h.components, ss: h.ss, se: h.se, ah: h.ah, al: h.al, restartInterval: restart, intervals: intervals))
            case 0xE0:
                var b = body.cursor()
                if body.count >= 14, (try? b.expect(Array("JFIF".utf8) + [0], "JFIF")) != nil { sawJFIF = true }
            case 0xE1:
                if let o = exifOrientation(body) { orientation = o }
            case 0xEE:
                var b = body.cursor()
                if body.count >= 12, (try? b.expect(Array("Adobe".utf8), "Adobe")) != nil {
                    try b.skip(6)
                    adobeTransform = Int(try b.u8("Adobe.transform"))
                }
            case 0xE2...0xEF, 0xFE, 0xDC:
                break  // other APPn, COM, DNL: recognised, not interpreted
            default:
                throw ParseFailure(offset: at, rule: "jpeg", reason: .invalid("unknown marker 0xFF\(String(marker, radix: 16, uppercase: true))"))
            }
        }
    }
}
