// X BitMap (X11 XBM, plus the X10 `short` variant) grammar.
//
// XBM is a subset of C source. Tokens: identifiers, integers (decimal or 0x hex),
// punctuation, `#define`; /* */ comments and whitespace are skipped.
//
//   xbm    := define("_width") define("_height") define("_x_hot")? define("_y_hot")? decl
//   define(s) := "#define" IDENT{ends with s} INT
//   decl   := "static"? "const"? "unsigned"? ("char" | "short") IDENT{ends with "_bits"}
//             "[" "]" "=" "{" INT ("," INT)* ","? "}" ";"?
//   { count(INT) == height * ceil(width / (8|16)); every INT fits in 8|16 bits }
//
// Semantics (X11): bit 1 = foreground (black), 0 = background (white); bits are
// stored least-significant first; rows are padded to whole bytes (or shorts).

public import CodecCore

public struct XBMFile: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var unitBits: Int  // 8 (X11 char) or 16 (X10 short)
    public var values: [UInt16]
}

public enum XBMGrammar {
    enum Token: Equatable {
        case ident(String), number(UInt64), punct(UInt8), define
    }

    /// Lexer: regular language over ASCII. Rejects any byte outside it.
    static func tokens(_ input: ByteSlice, maxTokens: Int) throws(ParseFailure) -> [(Token, Int)] {
        var c = input.cursor()
        var out: [(Token, Int)] = []
        func isIdentStart(_ b: UInt8) -> Bool { (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F }
        func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
        func isHex(_ b: UInt8) -> Bool { isDigit(b) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66) }

        while let b = c.peekU8() {
            let at = c.position
            guard out.count < maxTokens else { throw c.fail("xbm", .limitExceeded("more than \(maxTokens) tokens")) }
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C || b == 0x0B { _ = try c.u8(); continue }
            if b == 0x2F, c.peek(2) == ByteSlice([0x2F, 0x2A]) {  // /* comment */
                try c.skip(2)
                while true {
                    guard c.remaining >= 2 else { throw c.fail("xbm.comment", .unexpectedEnd(needed: 2, available: c.remaining)) }
                    if c.peek(2) == ByteSlice([0x2A, 0x2F]) { try c.skip(2); break }
                    _ = try c.u8()
                }
                continue
            }
            if b == 0x23 {  // #define
                try c.expect(Array("#define".utf8), "xbm.define")
                out.append((.define, at))
                continue
            }
            if isIdentStart(b) {
                var s: [UInt8] = []
                while let d = c.peekU8(), isIdentStart(d) || isDigit(d) {
                    guard s.count < 256 else { throw c.fail("xbm.identifier", .limitExceeded("identifier longer than 256")) }
                    s.append(try c.u8())
                }
                out.append((.ident(String(decoding: s, as: UTF8.self)), at))
                continue
            }
            if isDigit(b) {
                var v: UInt64 = 0
                var digits = 0
                if c.peek(2).map({ $0 == ByteSlice([0x30, 0x78]) || $0 == ByteSlice([0x30, 0x58]) }) == true {
                    try c.skip(2)
                    while let d = c.peekU8(), isHex(d) {
                        _ = try c.u8()
                        let n = isDigit(d) ? d - 0x30 : (d | 0x20) - 0x61 + 10
                        v = v << 4 | UInt64(n)
                        digits += 1
                        guard digits <= 8 else { throw ParseFailure(offset: at, rule: "xbm.number", reason: .invalid("integer too long")) }
                    }
                    guard digits > 0 else { throw ParseFailure(offset: at, rule: "xbm.number", reason: .invalid("empty hex literal")) }
                } else {
                    while let d = c.peekU8(), isDigit(d) {
                        _ = try c.u8()
                        v = v * 10 + UInt64(d - 0x30)
                        digits += 1
                        guard digits <= 9 else { throw ParseFailure(offset: at, rule: "xbm.number", reason: .invalid("integer too long")) }
                    }
                }
                if let d = c.peekU8(), isIdentStart(d) {
                    throw ParseFailure(offset: c.position, rule: "xbm.number", reason: .invalid("letter after integer"))
                }
                out.append((.number(v), at))
                continue
            }
            if [0x7B, 0x7D, 0x5B, 0x5D, 0x2C, 0x3B, 0x3D].contains(b) {  // { } [ ] , ; =
                out.append((.punct(try c.u8()), at))
                continue
            }
            throw ParseFailure(offset: at, rule: "xbm", reason: .invalid("unexpected byte 0x\(String(b, radix: 16))"))
        }
        return out
    }

    public static func file(_ input: ByteSlice, limits: DecodeLimits = .default) throws(ParseFailure) -> XBMFile {
        guard input.count <= limits.maxInputBytes else {
            throw ParseFailure(offset: 0, rule: "xbm", reason: .limitExceeded("input \(input.count) bytes"))
        }
        let toks = try tokens(input, maxTokens: limits.maxPixels / 4 + 64)
        var i = 0
        func fail(_ what: String) -> ParseFailure {
            ParseFailure(offset: i < toks.count ? toks[i].1 : input.upperBound, rule: "xbm", reason: .invalid(what))
        }
        func next() throws(ParseFailure) -> Token {
            guard i < toks.count else { throw ParseFailure(offset: input.upperBound, rule: "xbm", reason: .unexpectedEnd(needed: 1, available: 0)) }
            defer { i += 1 }
            return toks[i].0
        }
        func define(_ suffix: String) throws(ParseFailure) -> UInt64? {
            guard i < toks.count, toks[i].0 == .define else { return nil }
            guard i + 1 < toks.count, case .ident(let name) = toks[i + 1].0, name.hasSuffix(suffix) else { return nil }
            i += 1
            _ = try next()
            guard case .number(let v) = try next() else { throw fail("#define \(suffix) needs an integer") }
            return v
        }
        func expectPunct(_ p: UInt8) throws(ParseFailure) {
            guard try next() == .punct(p) else { i -= 1; throw fail("expected '\(Character(Unicode.Scalar(p)))'") }
        }

        guard let w = try define("_width") else { throw fail("missing #define *_width") }
        guard let h = try define("_height") else { throw fail("missing #define *_height") }
        _ = try define("_x_hot")
        _ = try define("_y_hot")
        try limits.checkDimensions(width: Int(w), height: Int(h), at: 0, rule: "xbm")

        var tok = try next()
        for qualifier in ["static", "const", "unsigned"] where tok == .ident(qualifier) { tok = try next() }
        let unitBits: Int
        switch tok {
        case .ident("char"): unitBits = 8
        case .ident("short"): unitBits = 16
        default: i -= 1; throw fail("expected char or short")
        }
        guard case .ident(let name) = try next(), name.hasSuffix("_bits") else { i -= 1; throw fail("expected *_bits") }
        try expectPunct(0x5B); try expectPunct(0x5D); try expectPunct(0x3D); try expectPunct(0x7B)

        let expected = Int(h) * ((Int(w) + unitBits - 1) / unitBits)
        var values: [UInt16] = []
        values.reserveCapacity(expected)
        while true {
            let t = try next()
            if t == .punct(0x7D) { break }
            guard case .number(let v) = t else { i -= 1; throw fail("expected integer") }
            guard v < 1 << UInt64(unitBits) else { i -= 1; throw fail("value \(v) does not fit in \(unitBits) bits") }
            guard values.count < expected else { i -= 1; throw fail("more than \(expected) values") }
            values.append(UInt16(v))
            let sep = try next()
            if sep == .punct(0x7D) { break }
            guard sep == .punct(0x2C) else { i -= 1; throw fail("expected ',' or '}'") }
        }
        if i < toks.count, toks[i].0 == .punct(0x3B) { i += 1 }
        guard i == toks.count else { throw fail("trailing tokens") }
        guard values.count == expected else { throw fail("\(values.count) values, expected \(expected)") }
        return XBMFile(width: Int(w), height: Int(h), unitBits: unitBits, values: values)
    }
}

public enum XBMDecoder {
    public static func decode(_ bytes: [UInt8], limits: DecodeLimits = .default) throws(ParseFailure) -> PixelBuffer {
        let f = try XBMGrammar.file(ByteSlice(bytes), limits: limits)
        var out = PixelBuffer(transparentWidth: f.width, height: f.height)
        let perRow = (f.width + f.unitBits - 1) / f.unitBits
        for y in 0..<f.height {
            for x in 0..<f.width {
                let v = f.values[y * perRow + x / f.unitBits]
                let on = (v >> UInt16(x % f.unitBits)) & 1 == 1
                let g: UInt8 = on ? 0 : 255
                let i = (y * f.width + x) * 4
                out.rgba[i] = g; out.rgba[i + 1] = g; out.rgba[i + 2] = g; out.rgba[i + 3] = 255
            }
        }
        return out
    }
}
