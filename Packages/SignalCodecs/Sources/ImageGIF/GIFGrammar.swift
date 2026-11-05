// GIF87a / GIF89a grammar (CompuServe GIF89a specification, 1990).
//
//   gif        := header lsd gct? block* trailer?
//   header     := "GIF87a" | "GIF89a"
//   lsd        := width:u16le height:u16le packed:u8 bg:u8 aspect:u8
//   gct        := rgb{2^(N+1)}                         if lsd.packed.gctFlag
//   block      := image | extension
//   image      := 0x2C left top width height packed lct? minCodeSize:u8{2..11} subblocks
//   extension  := 0x21 label:u8 subblocks
//   subblocks  := (size:u8{1..255} byte{size})* 0x00
//   trailer    := 0x3B
//
// Extensions interpreted: Graphic Control (0xF9, 4-byte body), Application
// NETSCAPE2.0 / ANIMEXTS1.0 loop count (sub-block id 1). All others are
// recognised as sub-block chains and skipped without interpretation.
//
// Ambiguity policy (matches the GIF test suite and browsers):
//   * missing trailer, or input ending inside a block after ≥1 image: the images
//     recognised so far are kept (a truncated last image keeps its partial data);
//   * a file with a trailer and no images is a single transparent frame;
//   * a zero-area image may omit its LZW data (as the GIF test suite's encoder does),
//     and input ending inside a zero-area image still yields that (empty) image;
//   * every image is its own animation frame, as in Chromium (the spec's "images
//     without delay form one frame" is not what any browser implements);
//   * zero-size logical screen, minimum code size ≥ 12, unknown block introducer
//     before any image: reject.

public import CodecCore

public struct GIFGraphicControl: Sendable, Equatable {
    public var disposal: UInt8
    public var delayCentiseconds: UInt16
    public var transparentIndex: UInt8?
}

public struct GIFImage: Sendable, Equatable {
    public var left, top, width, height: Int
    public var interlaced: Bool
    public var localPalette: [RGB8]?
    public var minCodeSize: Int
    public var data: [ByteSlice]
    public var control: GIFGraphicControl?
}

public struct GIFFile: Sendable, Equatable {
    public var is89a: Bool
    public var width, height: Int
    public var globalPalette: [RGB8]?
    public var backgroundIndex: UInt8
    /// NETSCAPE2.0 loop count as stored (0 = forever); nil if absent.
    public var loopCount: Int?
    public var images: [GIFImage]
    public var truncated: Bool
}

public enum GIFGrammar {
    static func palette(_ c: inout ByteCursor, size: Int, _ rule: String) throws(ParseFailure) -> [RGB8] {
        var p: [RGB8] = []
        p.reserveCapacity(size)
        for _ in 0..<size { p.append(RGB8(r: try c.u8(rule), g: try c.u8(rule), b: try c.u8(rule))) }
        return p
    }

    /// subblocks := (size:u8{1..255} byte{size})* 0x00. Returns the data slices and
    /// whether the terminator was reached (false = input ended inside the chain).
    static func subBlocks(_ c: inout ByteCursor, maxBlocks: Int) throws(ParseFailure) -> (blocks: [ByteSlice], terminated: Bool) {
        var blocks: [ByteSlice] = []
        while true {
            guard let size = c.peekU8() else { return (blocks, false) }
            _ = try c.u8("subblock.size")
            if size == 0 { return (blocks, true) }
            guard c.remaining >= Int(size) else {
                blocks.append(c.rest())
                return (blocks, false)
            }
            guard blocks.count < maxBlocks else {
                throw c.fail("subblocks", .limitExceeded("more than \(maxBlocks) sub-blocks"))
            }
            blocks.append(try c.bytes(Int(size), "subblock.data"))
        }
    }

    static let graphicControl = Parser<GIFGraphicControl>("GCE") { (c: inout ByteCursor) throws(ParseFailure) in
        let packed = try c.u8("GCE.packed")
        let delay = try c.u16le("GCE.delay")
        let ti = try c.u8("GCE.transparentIndex")
        return GIFGraphicControl(disposal: (packed >> 2) & 0x07, delayCentiseconds: delay,
                                 transparentIndex: packed & 1 == 1 ? ti : nil)
    }

    public static func file(_ input: ByteSlice, limits: DecodeLimits = .default) throws(ParseFailure) -> GIFFile {
        guard input.count <= limits.maxInputBytes else {
            throw ParseFailure(offset: 0, rule: "gif", reason: .limitExceeded("input \(input.count) bytes"))
        }
        var c = input.cursor()
        let is89a: Bool
        if let six = c.peek(6), six == ByteSlice(Array("GIF89a".utf8)) { is89a = true }
        else if let six = c.peek(6), six == ByteSlice(Array("GIF87a".utf8)) { is89a = false }
        else { throw c.fail("gif.header", .mismatch(expected: "GIF87a or GIF89a")) }
        try c.skip(6)

        let lsdAt = c.position
        let width = Int(try c.u16le("LSD.width")), height = Int(try c.u16le("LSD.height"))
        let packed = try c.u8("LSD.packed")
        let bg = try c.u8("LSD.background")
        _ = try c.u8("LSD.aspect")
        try limits.checkDimensions(width: width, height: height, at: lsdAt, rule: "LSD")
        let gct = packed & 0x80 != 0 ? try palette(&c, size: 2 << Int(packed & 7), "GCT") : nil

        var images: [GIFImage] = []
        var pendingControl: GIFGraphicControl?
        var loop: Int?
        let maxBlocks = limits.maxInputBytes / 2

        // Input ending (or becoming unrecognisable) after an image keeps what we have.
        func stop(_ truncated: Bool) throws(ParseFailure) -> GIFFile {
            if truncated && images.isEmpty {
                throw c.fail("gif", .unexpectedEnd(needed: 1, available: 0))
            }
            return GIFFile(is89a: is89a, width: width, height: height, globalPalette: gct, backgroundIndex: bg,
                           loopCount: loop, images: images, truncated: truncated)
        }

        while true {
            guard let introducer = c.peekU8() else { return try stop(true) }
            _ = try c.u8()
            switch introducer {
            case 0x3B:
                return try stop(false)

            case 0x21:
                guard c.remaining >= 1 else { return try stop(true) }
                let label = try c.u8("extension.label")
                let (blocks, terminated) = try subBlocks(&c, maxBlocks: maxBlocks)
                if !terminated { return try stop(true) }
                switch label {
                case 0xF9:
                    // A malformed GCE is ignored (browsers do the same).
                    if blocks.count == 1, blocks[0].count == 4 { pendingControl = try? graphicControl.parseComplete(blocks[0]) }
                case 0xFF:
                    if blocks.count >= 2, blocks[0].count == 11 {
                        let id = blocks[0]
                        if id == ByteSlice(Array("NETSCAPE2.0".utf8)) || id == ByteSlice(Array("ANIMEXTS1.0".utf8)) {
                            var sc = blocks[1].cursor()
                            if blocks[1].count == 3, (try? sc.u8()) == 1, let n = try? sc.u16le() { loop = Int(n) }
                        }
                    }
                default:
                    break  // comment, plain text, unknown: recognised, not interpreted
                }

            case 0x2C:
                let at = c.position - 1
                guard c.remaining >= 9 else { return try stop(true) }
                let left = Int(try c.u16le("image.left")), top = Int(try c.u16le("image.top"))
                let w = Int(try c.u16le("image.width")), h = Int(try c.u16le("image.height"))
                let ip = try c.u8("image.packed")
                guard w <= limits.maxDimension, h <= limits.maxDimension, w * h <= limits.maxPixels else {
                    throw ParseFailure(offset: at, rule: "image", reason: .limitExceeded("frame \(w)x\(h)"))
                }
                // A zero-area image contributes no pixels: if the input ends anywhere inside
                // it, it is still a complete (empty) image.
                func emptyImage() -> GIFImage {
                    GIFImage(left: left, top: top, width: w, height: h, interlaced: false,
                             localPalette: nil, minCodeSize: 2, data: [], control: pendingControl)
                }
                var lct: [RGB8]?
                if ip & 0x80 != 0 {
                    let n = 2 << Int(ip & 7)
                    guard c.remaining >= 3 * n else {
                        if w * h == 0 { images.append(emptyImage()); return try stop(false) }
                        return try stop(true)
                    }
                    lct = try palette(&c, size: n, "LCT")
                }
                // A zero-area image may omit its LZW data entirely: the next byte is then a
                // block introducer (0x21, 0x2C, 0x3B) or end of input, never a valid code size.
                if w * h == 0, c.peekU8().map({ $0 == 0x21 || $0 == 0x2C || $0 == 0x3B }) ?? true {
                    images.append(GIFImage(left: left, top: top, width: w, height: h, interlaced: false,
                                           localPalette: lct, minCodeSize: 2, data: [], control: pendingControl))
                    pendingControl = nil
                    continue
                }
                guard c.remaining >= 1 else { return try stop(true) }
                let minCode = Int(try c.u8("image.minCodeSize"))
                guard (1...11).contains(minCode) else {
                    throw ParseFailure(offset: c.position - 1, rule: "image.minCodeSize", reason: .invalid("LZW minimum code size \(minCode)"))
                }
                let (blocks, terminated) = try subBlocks(&c, maxBlocks: maxBlocks)
                guard images.count < limits.maxFrames else {
                    throw ParseFailure(offset: at, rule: "gif", reason: .limitExceeded("more than \(limits.maxFrames) frames"))
                }
                images.append(GIFImage(left: left, top: top, width: w, height: h, interlaced: ip & 0x40 != 0,
                                       localPalette: lct, minCodeSize: minCode, data: blocks, control: pendingControl))
                pendingControl = nil
                if !terminated { return try stop(true) }

            default:
                // Unknown introducer: junk. Keep earlier images; reject if there are none.
                if images.isEmpty {
                    throw ParseFailure(offset: c.position - 1, rule: "gif.block", reason: .invalid("block introducer 0x\(String(introducer, radix: 16))"))
                }
                return try stop(true)
            }
        }
    }
}
