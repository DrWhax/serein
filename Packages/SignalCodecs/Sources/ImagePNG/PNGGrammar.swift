// PNG (ISO/IEC 15948:2004, W3C PNG 3rd ed.) and APNG grammar.
//
// File level:
//   png        := SIGNATURE chunk+ trailing*
//   chunk      := LENGTH:u32be{≤ 2^31-1} TYPE:4{[A-Za-z]^4} DATA:byte{LENGTH} CRC:u32be
//
// Chunk *sequence* (a regular language over chunk types, checked by the DFA in
// `PNGGrammar.file`):
//   IHDR  pre*  IDAT+  post*  IEND
//   pre   := PLTE? | tRNS | acTL | fcTL | ancillary          (PLTE before tRNS)
//   post  := fcTL | fdAT | ancillary
//
// Policy for ambiguous input (documented, deterministic):
//   * critical structure violations, bad CRC on critical chunks, unknown critical
//     chunks: reject the file;
//   * malformed or misplaced *ancillary* chunks (incl. tRNS): treated as absent;
//   * APNG-layer violations: the APNG layer is dropped and the file decodes as a
//     still PNG (what browsers do), with the reason recorded;
//   * bytes after IEND: ignored.

public import CodecCore

public enum PNGColorType: UInt8, Sendable {
    case grayscale = 0, truecolor = 2, indexed = 3, grayscaleAlpha = 4, truecolorAlpha = 6

    var channels: Int {
        switch self {
        case .grayscale, .indexed: 1
        case .grayscaleAlpha: 2
        case .truecolor: 3
        case .truecolorAlpha: 4
        }
    }

    var allowedBitDepths: Set<UInt8> {
        switch self {
        case .grayscale: [1, 2, 4, 8, 16]
        case .indexed: [1, 2, 4, 8]
        case .truecolor, .grayscaleAlpha, .truecolorAlpha: [8, 16]
        }
    }
}

public struct PNGHeader: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var bitDepth: UInt8
    public var colorType: PNGColorType
    public var interlaced: Bool

    var bitsPerPixel: Int { Int(bitDepth) * colorType.channels }
}

public struct PNGRGB: Sendable, Equatable { public var r, g, b: UInt8 }

public enum PNGTransparency: Sendable, Equatable {
    case grayKey(UInt16)
    case rgbKey(UInt16, UInt16, UInt16)
    case paletteAlpha([UInt8])
}

public struct APNGFrameControl: Sendable, Equatable {
    public enum Dispose: UInt8, Sendable { case none = 0, background = 1, previous = 2 }
    public enum Blend: UInt8, Sendable { case source = 0, over = 1 }
    public var sequence: UInt32
    public var width, height, x, y: Int
    public var delayNumerator, delayDenominator: UInt16
    public var dispose: Dispose
    public var blend: Blend

    public var delayMilliseconds: Int {
        let den = delayDenominator == 0 ? 100 : Int(delayDenominator)
        return Int(delayNumerator) * 1000 / den
    }
}

public struct APNGFrame: Sendable, Equatable {
    public var control: APNGFrameControl
    /// zlib stream split across IDAT or fdAT chunks (fdAT sequence numbers stripped).
    public var data: [ByteSlice]
}

public struct APNGAnimation: Sendable, Equatable {
    public var playCount: Int
    /// True if the IDAT image is frame 0 of the animation.
    public var defaultImageIsFirstFrame: Bool
    public var frames: [APNGFrame]
}

/// The recognised file: everything a decoder needs, nothing it must re-parse.
public struct PNGFile: Sendable, Equatable {
    public var header: PNGHeader
    public var palette: [PNGRGB]?
    public var transparency: PNGTransparency?
    public var imageData: [ByteSlice]
    public var animation: APNGAnimation?
    /// Why an APNG layer, if present, was ignored.
    public var animationRejection: String?
}

public enum PNGGrammar {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    struct FourCC: Hashable, Sendable, CustomStringConvertible {
        let raw: UInt32
        init(_ s: String) {
            precondition(s.utf8.count == 4)
            raw = s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
        }
        init(raw: UInt32) { self.raw = raw }
        /// Bit 5 of the first byte clear = critical.
        var isCritical: Bool { (raw >> 24) & 0x20 == 0 }
        var description: String {
            String(decoding: [UInt8(raw >> 24), UInt8(raw >> 16 & 0xFF), UInt8(raw >> 8 & 0xFF), UInt8(raw & 0xFF)], as: UTF8.self)
        }
        static let IHDR = FourCC("IHDR"), PLTE = FourCC("PLTE"), IDAT = FourCC("IDAT"), IEND = FourCC("IEND")
        static let tRNS = FourCC("tRNS"), acTL = FourCC("acTL"), fcTL = FourCC("fcTL"), fdAT = FourCC("fdAT")
    }

    struct Chunk: Sendable {
        var type: FourCC
        var data: ByteSlice
        var offset: Int
        var crcValid: Bool
    }

    static let maxChunkLength = 0x7FFF_FFFF
    static let maxChunks = 1 << 20

    // MARK: chunk := LENGTH TYPE DATA CRC

    static let chunk = Parser<Chunk>("chunk") { (c: inout ByteCursor) throws(ParseFailure) -> Chunk in
        let at = c.position
        let length = Int(try c.u32be("chunk.length"))
        guard length <= maxChunkLength else {
            throw ParseFailure(offset: at, rule: "chunk.length", reason: .invalid("length \(length) ≥ 2^31"))
        }
        let typeSlice = try c.bytes(4, "chunk.type")
        var tc = typeSlice.cursor()
        let type = FourCC(raw: try tc.u32be())
        var letters = true
        typeSlice.forEachByte { b in letters = letters && ((0x41...0x5A).contains(b) || (0x61...0x7A).contains(b)) }
        guard letters else {
            throw ParseFailure(offset: at + 4, rule: "chunk.type", reason: .invalid("non-letter chunk type"))
        }
        let data = try c.bytes(length, "chunk.data")
        let stored = try c.u32be("chunk.crc")
        var crc = CRC32()
        crc.update(typeSlice)
        crc.update(data)
        if crc.value != stored && type.isCritical {
            throw ParseFailure(offset: at, rule: "chunk.crc(\(type))", reason: .checksum(expected: stored, computed: crc.value))
        }
        return Chunk(type: type, data: data, offset: at, crcValid: crc.value == stored)
    }

    // MARK: chunk bodies

    static let ihdr = Parser<PNGHeader>("IHDR") { (c: inout ByteCursor) throws(ParseFailure) -> PNGHeader in
        let at = c.position
        let w = try c.u32be("IHDR.width"), h = try c.u32be("IHDR.height")
        guard w > 0, h > 0, w <= 0x7FFF_FFFF, h <= 0x7FFF_FFFF else {
            throw ParseFailure(offset: at, rule: "IHDR", reason: .invalid("dimensions \(w)x\(h)"))
        }
        let depth = try c.u8("IHDR.bitDepth")
        let rawType = try c.u8("IHDR.colorType")
        guard let type = PNGColorType(rawValue: rawType) else {
            throw ParseFailure(offset: at + 9, rule: "IHDR.colorType", reason: .invalid("color type \(rawType)"))
        }
        guard type.allowedBitDepths.contains(depth) else {
            throw ParseFailure(offset: at + 8, rule: "IHDR.bitDepth", reason: .invalid("bit depth \(depth) for color type \(rawType)"))
        }
        _ = try c.u8("IHDR.compression", require: "compression method must be 0") { $0 == 0 }
        _ = try c.u8("IHDR.filter", require: "filter method must be 0") { $0 == 0 }
        let interlace = try c.u8("IHDR.interlace", require: "interlace method must be 0 or 1") { $0 <= 1 }
        return PNGHeader(width: Int(w), height: Int(h), bitDepth: depth, colorType: type, interlaced: interlace == 1)
    }

    static let rgb = Parser<PNGRGB>("PLTE.entry") { (c: inout ByteCursor) throws(ParseFailure) -> PNGRGB in
        PNGRGB(r: try c.u8(), g: try c.u8(), b: try c.u8())
    }

    static func plte(_ header: PNGHeader) -> Parser<[PNGRGB]> {
        Parser("PLTE") { (c: inout ByteCursor) throws(ParseFailure) -> [PNGRGB] in
            let n = c.remaining
            guard n % 3 == 0, n >= 3, n / 3 <= 256 else { throw c.fail("PLTE", .invalid("length \(n)")) }
            if header.colorType == .indexed && n / 3 > 1 << Int(header.bitDepth) {
                throw c.fail("PLTE", .invalid("\(n / 3) entries for bit depth \(header.bitDepth)"))
            }
            return try rgb.repeatedToEnd(maxCount: 256).parse(&c)
        }
    }

    static func trns(_ header: PNGHeader, paletteCount: Int) -> Parser<PNGTransparency> {
        Parser("tRNS") { (c: inout ByteCursor) throws(ParseFailure) -> PNGTransparency in
            switch header.colorType {
            case .grayscale:
                return .grayKey(try c.u16be())
            case .truecolor:
                return .rgbKey(try c.u16be(), try c.u16be(), try c.u16be())
            case .indexed:
                guard c.remaining <= paletteCount else { throw c.fail("tRNS", .invalid("more entries than palette")) }
                return .paletteAlpha(try Grammar.u8.repeatedToEnd(maxCount: 256).parse(&c))
            case .grayscaleAlpha, .truecolorAlpha:
                throw c.fail("tRNS", .invalid("not allowed with an alpha channel"))
            }
        }
    }

    static let actl = Parser<(frames: UInt32, plays: UInt32)>("acTL") { (c: inout ByteCursor) throws(ParseFailure) in
        let frames = try c.u32be("acTL.num_frames")
        let plays = try c.u32be("acTL.num_plays")
        guard frames >= 1 else { throw c.fail("acTL", .invalid("num_frames = 0")) }
        return (frames, plays)
    }

    static func fctl(_ header: PNGHeader) -> Parser<APNGFrameControl> {
        Parser("fcTL") { (c: inout ByteCursor) throws(ParseFailure) -> APNGFrameControl in
            let seq = try c.u32be("fcTL.sequence")
            let w = Int(try c.u32be("fcTL.width")), h = Int(try c.u32be("fcTL.height"))
            let x = Int(try c.u32be("fcTL.x_offset")), y = Int(try c.u32be("fcTL.y_offset"))
            let dn = try c.u16be("fcTL.delay_num"), dd = try c.u16be("fcTL.delay_den")
            let dispose = APNGFrameControl.Dispose(rawValue: try c.u8("fcTL.dispose_op", require: "dispose_op ≤ 2") { $0 <= 2 })!
            let blend = APNGFrameControl.Blend(rawValue: try c.u8("fcTL.blend_op", require: "blend_op ≤ 1") { $0 <= 1 })!
            guard w > 0, h > 0, x + w <= header.width, y + h <= header.height else {
                throw ParseFailure(offset: c.start + 4, rule: "fcTL", reason: .invalid("frame \(w)x\(h)+\(x)+\(y) outside \(header.width)x\(header.height)"))
            }
            return APNGFrameControl(sequence: seq, width: w, height: h, x: x, y: y,
                                    delayNumerator: dn, delayDenominator: dd, dispose: dispose, blend: blend)
        }
    }

    static let fdat = Parser<(UInt32, ByteSlice)>("fdAT") { (c: inout ByteCursor) throws(ParseFailure) in
        let seq = try c.u32be("fdAT.sequence")
        guard c.remaining > 0 else { throw c.fail("fdAT", .invalid("empty frame data")) }
        return (seq, c.rest())
    }

    // MARK: file

    private enum State { case beforeIDAT, inIDAT, afterIDAT }

    /// Recognises a complete PNG/APNG file.
    public static func file(_ input: ByteSlice, limits: DecodeLimits = .default) throws(ParseFailure) -> PNGFile {
        guard input.count <= limits.maxInputBytes else {
            throw ParseFailure(offset: 0, rule: "png", reason: .limitExceeded("input \(input.count) bytes"))
        }
        var c = input.cursor()
        try c.expect(signature, "png.signature")

        let first = try chunk.parse(&c)
        guard first.type == .IHDR else {
            throw ParseFailure(offset: first.offset, rule: "png", reason: .invalid("first chunk is \(first.type), not IHDR"))
        }
        let header = try ihdr.parseComplete(first.data)
        try limits.checkDimensions(width: header.width, height: header.height, at: first.offset, rule: "IHDR")

        var palette: [PNGRGB]?
        var transparency: PNGTransparency?
        var idat: [ByteSlice] = []
        var state = State.beforeIDAT

        // APNG layer, validated separately so that it can be dropped as a unit.
        var apng = APNGCollector(header: header, limits: limits)

        var chunkCount = 1
        while true {
            chunkCount += 1
            guard chunkCount <= maxChunks else {
                throw ParseFailure(offset: c.position, rule: "png", reason: .limitExceeded("more than \(maxChunks) chunks"))
            }
            let ch = try chunk.parse(&c)
            if state == .inIDAT && ch.type != .IDAT { state = .afterIDAT }

            switch ch.type {
            case .IEND:
                guard state != .beforeIDAT else {
                    throw ParseFailure(offset: ch.offset, rule: "png", reason: .invalid("IEND before IDAT"))
                }
                guard ch.data.isEmpty else {
                    throw ParseFailure(offset: ch.offset, rule: "IEND", reason: .trailingBytes(ch.data.count))
                }
                if header.colorType == .indexed && palette == nil {
                    throw ParseFailure(offset: ch.offset, rule: "png", reason: .invalid("indexed image without PLTE"))
                }
                let animation = apng.finish(idatFollowedFirstFCTL: true)
                return PNGFile(header: header, palette: palette, transparency: transparency, imageData: idat,
                               animation: animation.animation, animationRejection: animation.rejection)

            case .IHDR:
                throw ParseFailure(offset: ch.offset, rule: "png", reason: .invalid("duplicate IHDR"))

            case .PLTE:
                guard state == .beforeIDAT, palette == nil else {
                    throw ParseFailure(offset: ch.offset, rule: "png", reason: .invalid("misplaced or duplicate PLTE"))
                }
                guard header.colorType != .grayscale && header.colorType != .grayscaleAlpha else {
                    throw ParseFailure(offset: ch.offset, rule: "png", reason: .invalid("PLTE in grayscale image"))
                }
                guard transparency == nil else {
                    throw ParseFailure(offset: ch.offset, rule: "png", reason: .invalid("PLTE after tRNS"))
                }
                palette = try plte(header).parseComplete(ch.data)

            case .IDAT:
                guard state != .afterIDAT else {
                    throw ParseFailure(offset: ch.offset, rule: "png", reason: .invalid("non-consecutive IDAT"))
                }
                if header.colorType == .indexed && palette == nil {
                    throw ParseFailure(offset: ch.offset, rule: "png", reason: .invalid("IDAT before PLTE in indexed image"))
                }
                if state == .beforeIDAT { apng.noteIDATStart() }
                state = .inIDAT
                idat.append(ch.data)

            case .tRNS:
                // Ancillary: ignore when malformed, misplaced or duplicated.
                if ch.crcValid, state == .beforeIDAT, transparency == nil,
                   let t = try? trns(header, paletteCount: palette?.count ?? 0).parseComplete(ch.data) {
                    if header.colorType != .indexed || palette != nil { transparency = t }
                }

            case .acTL:
                apng.acTL(ch, beforeIDAT: state == .beforeIDAT)
            case .fcTL:
                apng.fcTL(ch, beforeIDAT: state == .beforeIDAT)
            case .fdAT:
                apng.fdAT(ch, afterIDAT: state == .afterIDAT)

            default:
                if ch.type.isCritical {
                    throw ParseFailure(offset: ch.offset, rule: "png", reason: .invalid("unknown critical chunk \(ch.type)"))
                }
                // Unknown ancillary chunk: length-delimited and never interpreted.
            }
        }
    }
}

/// Recognises the APNG layer: acTL, fcTL, fdAT ordering and sequence numbers.
/// Any violation drops the whole layer (the file still decodes as a still PNG).
struct APNGCollector {
    let header: PNGHeader
    let limits: DecodeLimits
    var numFrames: UInt32?
    var numPlays: UInt32 = 0
    var nextSequence: UInt32 = 0
    var frames: [APNGFrame] = []
    var firstFrameUsesIDAT = false
    var sawIDAT = false
    var rejection: String?

    init(header: PNGHeader, limits: DecodeLimits) {
        self.header = header
        self.limits = limits
    }

    mutating func reject(_ why: String) { if rejection == nil { rejection = why } }

    mutating func acTL(_ ch: PNGGrammar.Chunk, beforeIDAT: Bool) {
        guard ch.crcValid else { return reject("acTL CRC") }
        guard beforeIDAT, numFrames == nil else { return reject("misplaced or duplicate acTL") }
        guard let v = try? PNGGrammar.actl.parseComplete(ch.data) else { return reject("malformed acTL") }
        guard Int(v.frames) <= limits.maxFrames else { return reject("too many frames (\(v.frames))") }
        numFrames = v.frames
        numPlays = v.plays
    }

    mutating func checkSequence(_ seq: UInt32) -> Bool {
        guard seq == nextSequence else { reject("sequence number \(seq), expected \(nextSequence)"); return false }
        nextSequence &+= 1
        return true
    }

    mutating func fcTL(_ ch: PNGGrammar.Chunk, beforeIDAT: Bool) {
        guard ch.crcValid else { return reject("fcTL CRC") }
        guard numFrames != nil else { return reject("fcTL without acTL") }
        guard let fc = try? PNGGrammar.fctl(header).parseComplete(ch.data) else { return reject("malformed fcTL") }
        guard checkSequence(fc.sequence) else { return }
        if let last = frames.last, last.data.isEmpty, !(frames.count == 1 && firstFrameUsesIDAT) {
            return reject("fcTL without frame data")
        }
        if beforeIDAT {
            guard frames.isEmpty else { return reject("more than one fcTL before IDAT") }
            guard fc.x == 0, fc.y == 0, fc.width == header.width, fc.height == header.height else {
                return reject("first fcTL must cover the whole image")
            }
            firstFrameUsesIDAT = true
        }
        guard frames.count < limits.maxFrames else { return reject("too many frames") }
        frames.append(APNGFrame(control: fc, data: []))
    }

    mutating func noteIDATStart() { sawIDAT = true }

    mutating func fdAT(_ ch: PNGGrammar.Chunk, afterIDAT: Bool) {
        guard ch.crcValid else { return reject("fdAT CRC") }
        guard afterIDAT else { return reject("fdAT before or inside IDAT") }
        guard let (seq, data) = try? PNGGrammar.fdat.parseComplete(ch.data) else { return reject("malformed fdAT") }
        guard checkSequence(seq) else { return }
        guard !frames.isEmpty, !(frames.count == 1 && firstFrameUsesIDAT) else { return reject("fdAT without fcTL") }
        frames[frames.count - 1].data.append(data)
    }

    func finish(idatFollowedFirstFCTL: Bool) -> (animation: APNGAnimation?, rejection: String?) {
        guard let n = numFrames else {
            return (nil, frames.isEmpty ? nil : "fcTL without acTL")
        }
        if let r = rejection { return (nil, r) }
        guard frames.count == Int(n) else { return (nil, "acTL says \(n) frames, found \(frames.count)") }
        for (i, f) in frames.enumerated() where f.data.isEmpty && !(i == 0 && firstFrameUsesIDAT) {
            return (nil, "frame \(i) has no data")
        }
        return (APNGAnimation(playCount: Int(numPlays), defaultImageIsFirstFrame: firstFrameUsesIDAT, frames: frames), nil)
    }
}
