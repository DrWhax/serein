// Number handling with the semantics formatjs gets from JavaScript and ICU:
//   * `jsString` is ECMAScript Number::toString (what `{n}` and `=N` matching use);
//   * `jsToNumber` is ECMAScript StringToNumber (a string passed to plural / number);
//   * `NumberSymbols.format` is Intl.NumberFormat's default decimal / percent styles
//     (ICU: shortest round-trip decimal, halfExpand rounding, locale grouping and digits).

/// A finite non-negative decimal: 0.d₁d₂… × 10^exponent, without leading or trailing
/// zero digits (zero has no digits).
struct DecimalDigits: Hashable {
    var digits: [UInt8]
    var exponent: Int

    static let zero = DecimalDigits(digits: [], exponent: 0)

    /// The shortest decimal that round-trips to `|x|` (Swift's description and ECMAScript's
    /// Number::toString both produce it). `x` must be finite.
    init(shortest x: Double) {
        let text = x.magnitude.description // e.g. "123.45", "1e-07", "1.2345e+16", "0.0"
        var mantissa = Substring(text)
        var exp10 = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<e]
            exp10 = Int(text[text.index(after: e)...]) ?? 0
        }
        var digits: [UInt8] = []
        var pointAt: Int?
        for c in mantissa.utf8 {
            if c == UInt8(ascii: ".") { pointAt = digits.count } else if c >= 0x30, c <= 0x39 { digits.append(c - 0x30) }
        }
        var exponent = (pointAt ?? digits.count) + exp10
        while let first = digits.first, first == 0 {
            digits.removeFirst()
            exponent -= 1
        }
        while let last = digits.last, last == 0 { digits.removeLast() }
        self = digits.isEmpty ? .zero : DecimalDigits(digits: digits, exponent: exponent)
    }

    init(digits: [UInt8], exponent: Int) {
        self.digits = digits
        self.exponent = exponent
    }

    /// Rounds to `maxFraction` fraction digits, halfExpand (ties away from zero).
    func rounded(maxFraction: Int) -> DecimalDigits {
        let keep = exponent + maxFraction
        guard digits.count > keep else { return self }
        guard keep >= 0 else { return .zero }
        var kept = Array(digits[0..<keep])
        var exp = exponent
        if digits[keep] >= 5 {
            var i = kept.count - 1
            while i >= 0, kept[i] == 9 {
                kept[i] = 0
                i -= 1
            }
            if i < 0 {
                kept.insert(1, at: 0)
                exp += 1
            } else {
                kept[i] += 1
            }
        }
        while let last = kept.last, last == 0 { kept.removeLast() }
        return kept.isEmpty ? .zero : DecimalDigits(digits: kept, exponent: exp)
    }

    /// Integer digits (at least "0") and fraction digits (possibly empty), as ASCII digit values.
    var integerAndFraction: (integer: [UInt8], fraction: [UInt8]) {
        if digits.isEmpty { return ([0], []) }
        if exponent <= 0 {
            return ([0], Array(repeating: 0, count: -exponent) + digits)
        }
        if digits.count <= exponent {
            return (digits + Array(repeating: 0, count: exponent - digits.count), [])
        }
        return (Array(digits[0..<exponent]), Array(digits[exponent...]))
    }
}

private func asciiString(_ digits: some Sequence<UInt8>) -> String {
    String(decoding: digits.map { $0 + 0x30 }, as: UTF8.self)
}

/// ECMAScript `Number.prototype.toString()` / `String(x)`.
func jsString(_ x: Double) -> String {
    if x.isNaN { return "NaN" }
    if x == 0 { return "0" }
    if x.isInfinite { return x < 0 ? "-Infinity" : "Infinity" }
    let sign = x < 0 ? "-" : ""
    let d = DecimalDigits(shortest: x)
    let k = d.digits.count, n = d.exponent
    let all = asciiString(d.digits)
    if k <= n, n <= 21 {
        return sign + all + String(repeating: "0", count: n - k)
    }
    if n > 0, n <= 21 {
        return sign + asciiString(d.digits[0..<n]) + "." + asciiString(d.digits[n...])
    }
    if n > -6, n <= 0 {
        return sign + "0." + String(repeating: "0", count: -n) + all
    }
    let e = n - 1
    let expPart = "e" + (e >= 0 ? "+" : "-") + String(e.magnitude)
    if k == 1 { return sign + all + expPart }
    return sign + asciiString(d.digits[0..<1]) + "." + asciiString(d.digits[1...]) + expPart
}

/// ECMAScript StringToNumber: decimal / Infinity / 0x 0o 0b literals, surrounding
/// whitespace ignored, the empty string is 0, anything else is NaN.
func jsToNumber(_ string: String) -> Double {
    let trimmed = MessageParser.trimEnd(MessageParser.trimStart(string))
    if trimmed.isEmpty { return 0 }
    let u = Array(trimmed.utf8)
    switch trimmed {
    case "Infinity", "+Infinity": return .infinity
    case "-Infinity": return -.infinity
    default: break
    }
    if u.count > 2, u[0] == UInt8(ascii: "0") {
        let radix: Int? = switch u[1] | 0x20 {
        case UInt8(ascii: "x"): 16
        case UInt8(ascii: "o"): 8
        case UInt8(ascii: "b"): 2
        default: nil
        }
        if let radix {
            var value = 0.0
            for c in u[2...] {
                guard let digit = Int(String(UnicodeScalar(c)), radix: radix) else { return .nan }
                value = value * Double(radix) + Double(digit)
            }
            return value
        }
    }
    // StrDecimalLiteral: [+-] (digits [. digits] | . digits) [(e|E) [+-] digits]
    var i = 0
    func digitsRun() -> Int {
        let start = i
        while i < u.count, u[i] >= 0x30, u[i] <= 0x39 { i += 1 }
        return i - start
    }
    if i < u.count, u[i] == UInt8(ascii: "+") || u[i] == UInt8(ascii: "-") { i += 1 }
    var mantissaDigits = digitsRun()
    if i < u.count, u[i] == UInt8(ascii: ".") {
        i += 1
        mantissaDigits += digitsRun()
    }
    guard mantissaDigits > 0 else { return .nan }
    if i < u.count, u[i] | 0x20 == UInt8(ascii: "e") {
        i += 1
        if i < u.count, u[i] == UInt8(ascii: "+") || u[i] == UInt8(ascii: "-") { i += 1 }
        guard digitsRun() > 0 else { return .nan }
    }
    guard i == u.count else { return .nan }
    return Double(trimmed) ?? .nan
}

/// Prefix and suffix around the digits of one pattern (sign, percent sign, bidi marks).
struct Affixes: Hashable {
    let prefix: String
    let suffix: String
}

/// ICU grouping: sizes from the right, and the minimum number of digits the leftmost
/// group needs before any separator is used (CLDR minimumGroupingDigits).
struct Grouping: Hashable {
    let primary: Int
    let secondary: Int
    let minimum: Int
}

/// Number symbols and patterns of one locale, as Intl.NumberFormat uses them.
struct NumberSymbols: Hashable {
    let digits: [String]
    let decimal: String
    let group: String
    let decimalGrouping: Grouping
    let percentGrouping: Grouping
    let decimalPositive: Affixes
    let decimalNegative: Affixes
    let percentPositive: Affixes
    let percentNegative: Affixes
    let nan: String
    let infinity: String

    enum Style {
        /// `{n, number}` and `#`: maximumFractionDigits 3.
        case decimal
        /// `{n, number, integer}`: maximumFractionDigits 0.
        case integer
        /// `{n, number, percent}`: ×100, maximumFractionDigits 0.
        case percent
    }

    func format(_ x: Double, style: Style = .decimal) -> String {
        if x.isNaN { return nan }
        let negative = x.sign == .minus
        let percent = style == .percent
        let affixes = percent ? (negative ? percentNegative : percentPositive) : (negative ? decimalNegative : decimalPositive)
        if x.isInfinite { return affixes.prefix + infinity + affixes.suffix }
        var d = DecimalDigits(shortest: x)
        if percent, !d.digits.isEmpty { d.exponent += 2 }
        d = d.rounded(maxFraction: style == .decimal ? 3 : 0)
        let (integer, fraction) = d.integerAndFraction
        let grouping = percent ? percentGrouping : decimalGrouping
        var out = affixes.prefix
        out += grouped(integer, grouping)
        if !fraction.isEmpty {
            out += decimal
            for digit in fraction { out += digits[Int(digit)] }
        }
        return out + affixes.suffix
    }

    private func grouped(_ integer: [UInt8], _ g: Grouping) -> String {
        guard g.primary > 0, integer.count >= g.primary + g.minimum else {
            return integer.map { digits[Int($0)] }.joined()
        }
        // Separator positions counted from the right: primary, then every secondary.
        var separatorsBefore: Set<Int> = []
        var boundary = integer.count - g.primary
        while boundary > 0 {
            separatorsBefore.insert(boundary)
            boundary -= max(g.secondary, 1)
        }
        var out = ""
        for (i, digit) in integer.enumerated() {
            if separatorsBefore.contains(i) { out += group }
            out += digits[Int(digit)]
        }
        return out
    }
}
