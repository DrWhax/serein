// BlurHash (https://github.com/woltapp/blurhash, Algorithm.md).
//
// Grammar of a hash string (base83 alphabet, see `alphabet`):
//   hash := size:b83{1} qmax:b83{1} dc:b83{4} ac:b83{2}^(nx*ny-1)
//   size ∈ 0..80, nx = size % 9 + 1, ny = size / 9 + 1;  dc ≤ 0xFFFFFF;  ac < 19^3
//
// Arithmetic follows the C reference implementation exactly, including where it
// evaluates in double versus float (built -O2 without FMA contraction, where LLVM
// lowers powf(x, 0.5) to sqrtf), so hashes and decoded pixels are bit-identical.

public import CodecCore

public struct BlurhashComponents: Sendable, Equatable {
    public var x: Int
    public var y: Int
    public var maxAC: Int
    public var dc: Int
    public var ac: [Int]
}

public enum Blurhash {
    static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~".utf8)
    static let digitOf: [Int8] = {
        var t = [Int8](repeating: -1, count: 256)
        for (i, c) in alphabet.enumerated() { t[Int(c)] = Int8(i) }
        return t
    }()

    // MARK: grammar

    static func base83(_ c: inout ByteCursor, digits: Int, _ rule: String) throws(ParseFailure) -> Int {
        var v = 0
        for _ in 0..<digits {
            let at = c.position
            let b = try c.u8(rule)
            let d = digitOf[Int(b)]
            guard d >= 0 else { throw ParseFailure(offset: at, rule: rule, reason: .invalid("not a base83 digit: 0x\(String(b, radix: 16))")) }
            v = v * 83 + Int(d)
        }
        return v
    }

    public static func parse(_ hash: String) throws(ParseFailure) -> BlurhashComponents {
        let bytes = Array(hash.utf8)
        guard bytes.count <= 2 + 4 + 80 * 2 else {
            throw ParseFailure(offset: 0, rule: "blurhash", reason: .limitExceeded("length \(bytes.count)"))
        }
        var c = ByteCursor(bytes)
        let size = try base83(&c, digits: 1, "blurhash.size")
        guard size <= 80 else { throw ParseFailure(offset: 0, rule: "blurhash.size", reason: .invalid("size flag \(size)")) }
        let nx = size % 9 + 1, ny = size / 9 + 1
        guard bytes.count == 4 + 2 * nx * ny else {
            throw ParseFailure(offset: 0, rule: "blurhash", reason: .invalid("length \(bytes.count) for \(nx)x\(ny) components, expected \(4 + 2 * nx * ny)"))
        }
        let qmax = try base83(&c, digits: 1, "blurhash.maxAC")
        // DC and AC values are not range-checked, as in the C and JS references (Signal Desktop
        // renders such hashes): a DC above 0xFFFFFF gives a red channel over 255 and an AC
        // above 19³−1 a quantised value of 19; both stay finite and the output is clamped.
        let dc = try base83(&c, digits: 4, "blurhash.dc")
        var ac: [Int] = []
        for _ in 0..<(nx * ny - 1) {
            ac.append(try base83(&c, digits: 2, "blurhash.ac"))
        }
        try c.expectEnd("blurhash")
        return BlurhashComponents(x: nx, y: ny, maxAC: qmax, dc: dc, ac: ac)
    }

    // MARK: colour helpers (C reference semantics)

    static let linearTable: [Float] = (0..<256).map { sRGBToLinear($0) }

    static func sRGBToLinear(_ value: Int) -> Float {
        let v = Float(value) / 255
        if Double(v) <= 0.04045 { return Float(Double(v) / 12.92) }
        return LibM.powf(Float((Double(v) + 0.055) / 1.055), Float(2.4))
    }

    static func linearToSRGB(_ value: Float) -> Int {
        let v = max(0, min(1, value))
        if Double(v) <= 0.0031308 { return Int(Double(v) * 12.92 * 255 + 0.5) }
        return Int((1.055 * Double(LibM.powf(v, Float(1 / 2.4))) - 0.055) * 255 + 0.5)
    }

    /// copysign(pow(|value|, exp), value). The reference only uses exp 0.5 and 2;
    /// compiled C turns powf(x, 0.5) into sqrtf(x) and powf(x, 2) into x*x, which
    /// are correctly rounded (macOS powf is not), so we do the same.
    static func signPow(_ value: Float, _ exp: Float) -> Float {
        let m = abs(value)
        let p: Float
        switch exp {
        case 0.5: p = m.squareRoot()
        case 2: p = m * m
        default: p = LibM.powf(m, exp)
        }
        return Float(signOf: value, magnitudeOf: p)
    }

    // MARK: encode

    /// Encodes the RGB channels of `image` (alpha is ignored, as in Signal Desktop).
    public static func encode(_ image: PixelBuffer, xComponents: Int = 4, yComponents: Int = 3) -> String {
        precondition((1...9).contains(xComponents) && (1...9).contains(yComponents))
        let w = image.width, h = image.height
        var factors: [[Float]] = []
        for yc in 0..<yComponents {
            for xc in 0..<xComponents {
                let normalisation: Float = (xc == 0 && yc == 0) ? 1 : 2
                var r: Float = 0, g: Float = 0, b: Float = 0
                let cosY = (0..<h).map { LibM.cosf(Float(Double.pi * Double(yc) * Double($0) / Double(h))) }
                let cosX = (0..<w).map { LibM.cosf(Float(Double.pi * Double(xc) * Double($0) / Double(w))) }
                for y in 0..<h {
                    for x in 0..<w {
                        let basis = cosX[x] * cosY[y]
                        let p = (y * w + x) * 4
                        r += basis * linearTable[Int(image.rgba[p])]
                        g += basis * linearTable[Int(image.rgba[p + 1])]
                        b += basis * linearTable[Int(image.rgba[p + 2])]
                    }
                }
                let scale = normalisation / Float(w * h)
                factors.append([r * scale, g * scale, b * scale])
            }
        }

        var out: [UInt8] = []
        func put(_ value: Int, _ length: Int) {
            var divisor = 1
            for _ in 0..<(length - 1) { divisor *= 83 }
            for _ in 0..<length {
                out.append(alphabet[(value / divisor) % 83])
                divisor /= 83
            }
        }
        put((xComponents - 1) + (yComponents - 1) * 9, 1)

        let ac = factors.dropFirst()
        let maximumValue: Float
        if !ac.isEmpty {
            var actual: Float = 0
            for f in ac { for v in f { actual = max(abs(v), actual) } }
            let q = Int(max(0, min(82, Float(Double(actual * 166) - 0.5).rounded(.down))))
            maximumValue = (Float(q) + 1) / 166
            put(q, 1)
        } else {
            maximumValue = 1
            put(0, 1)
        }
        let dc = factors[0]
        put((linearToSRGB(dc[0]) << 16) + (linearToSRGB(dc[1]) << 8) + linearToSRGB(dc[2]), 4)
        for f in ac {
            func quant(_ v: Float) -> Int {
                Int(max(0, min(18, Float(Double(signPow(v / maximumValue, Float(0.5)) * 9) + 9.5).rounded(.down))))
            }
            put(quant(f[0]) * 19 * 19 + quant(f[1]) * 19 + quant(f[2]), 2)
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: decode

    /// Renders `hash` at `width`×`height`; `punch` scales the AC contrast (≥ 1).
    public static func decode(_ hash: String, width: Int, height: Int, punch: Int = 1, limits: DecodeLimits = .default) throws(ParseFailure) -> PixelBuffer {
        let comp = try parse(hash)
        try limits.checkDimensions(width: width, height: height, at: 0, rule: "blurhash.output")
        let punch = max(1, punch)
        let maxValue = Float(comp.maxAC + 1) / 166

        var colours: [(Float, Float, Float)] = [(sRGBToLinear(comp.dc >> 16), sRGBToLinear((comp.dc >> 8) & 255), sRGBToLinear(comp.dc & 255))]
        let scaled = maxValue * Float(punch)
        for v in comp.ac {
            let qr = v / (19 * 19), qg = (v / 19) % 19, qb = v % 19
            colours.append((signPow((Float(qr) - 9) / 9, Float(2.0)) * scaled,
                            signPow((Float(qg) - 9) / 9, Float(2.0)) * scaled,
                            signPow((Float(qb) - 9) / 9, Float(2.0)) * scaled))
        }

        let cosX = (0..<width).map { x in (0..<comp.x).map { i in LibM.cos(Double.pi * Double(x) * Double(i) / Double(width)) } }
        let cosY = (0..<height).map { y in (0..<comp.y).map { j in LibM.cos(Double.pi * Double(y) * Double(j) / Double(height)) } }
        var out = PixelBuffer(transparentWidth: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                var r: Float = 0, g: Float = 0, b: Float = 0
                for j in 0..<comp.y {
                    for i in 0..<comp.x {
                        let basis = Float(cosX[x][i] * cosY[y][j])
                        let c = colours[i + j * comp.x]
                        r += c.0 * basis
                        g += c.1 * basis
                        b += c.2 * basis
                    }
                }
                let p = (y * width + x) * 4
                out.rgba[p] = UInt8(clamping: linearToSRGB(r))
                out.rgba[p + 1] = UInt8(clamping: linearToSRGB(g))
                out.rgba[p + 2] = UInt8(clamping: linearToSRGB(b))
                out.rgba[p + 3] = 255
            }
        }
        return out
    }
}
