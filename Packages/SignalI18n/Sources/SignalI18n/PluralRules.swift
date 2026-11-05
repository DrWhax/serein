// CLDR plural selection with ICU's exact semantics, as Intl.PluralRules (and therefore
// intl-messageformat's `plural` / `selectordinal`) performs it. The rules themselves are
// generated from ICU's plurals.res (Generated/PluralRules.generated.swift).

/// CLDR plural categories.
public enum PluralCategory: String, Sendable, Hashable, CaseIterable {
    case zero, one, two, few, many, other
}

/// Namespace for the generated rule sets.
enum PluralRuleSet {}

/// CLDR plural operands (UTS #35 Part 3 §5.1.1) of a number, computed the way ICU does
/// for Intl.PluralRules with its default options: the shortest decimal of the value is
/// rounded to at most 3 fraction digits (halfExpand); `n` is that value as a double and
/// `i` its low 18 integer digits (ICU `DecimalQuantity::toLong(true)`), also as a double.
/// Compact exponents (`c`, `e`) are always 0 in standard notation.
struct PluralOperands {
    enum Operand { case n, i, v, w, f, t, c, e }

    let n: Double
    let i: Double
    let v: Double
    let w: Double
    let f: Double
    let t: Double

    init(_ x: Double) {
        let rounded = DecimalDigits(shortest: x).rounded(maxFraction: 3)
        let (integer, fraction) = rounded.integerAndFraction
        var low18 = 0.0
        for digit in integer.suffix(18) { low18 = low18 * 10 + Double(digit) }
        var fractionValue = 0.0
        for digit in fraction { fractionValue = fractionValue * 10 + Double(digit) }
        // Correctly rounded, like ICU's DecimalQuantity::toDouble.
        let decimal = String(decoding: integer.map { $0 + 0x30 } + [UInt8(ascii: ".")] + (fraction.isEmpty ? [0x30] : fraction.map { $0 + 0x30 }), as: UTF8.self)
        n = Double(decimal) ?? .nan
        i = low18
        v = Double(fraction.count)
        w = Double(fraction.count) // no trailing zeros: minimumFractionDigits is 0
        f = fractionValue
        t = fractionValue
    }

    /// ICU `AndConstraint::isFulfilled` for `operand [% mod] = ranges` (`in` semantics:
    /// a non-integer value is in no range).
    func test(_ operand: Operand, mod: Int, _ ranges: ClosedRange<Int>...) -> Bool {
        var x: Double = switch operand {
        case .n: n
        case .i: i
        case .v: v
        case .w: w
        case .f: f
        case .t: t
        case .c, .e: 0
        }
        guard x == x.rounded(.down) else { return false }
        if mod != 0 { x = x.truncatingRemainder(dividingBy: Double(mod)) }
        return ranges.contains { Double($0.lowerBound) <= x && x <= Double($0.upperBound) }
    }
}

extension PluralRuleSet {
    /// Intl.PluralRules.prototype.select for rule set `id`.
    static func select(_ id: Int, _ x: Double) -> PluralCategory {
        guard x.isFinite else { return .other }
        return evaluate(id, PluralOperands(x))
    }
}
