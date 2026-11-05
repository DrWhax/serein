// Port of ts/util/unicodeBidi.std.ts: what upstream's `i18n()` does to every string
// substitution before formatting (setupI18nMain.std.ts `normalizeSubstitutions`).

/// How string arguments are prepared before they are substituted.
public enum BidiHandling: Sendable, Hashable {
    /// Upstream's default: wrap in FIRST STRONG ISOLATE … POP DIRECTIONAL ISOLATE after
    /// balancing any directional controls inside (`bidiIsolate`).
    case isolate
    /// Upstream's `{ bidi: 'strip' }`: remove all directional controls (`bidiStrip`).
    case strip
    /// Pass strings through untouched (upstream's test environment, and `<I18n>` components).
    case none
}

enum Bidi {
    static let lri: Unicode.Scalar = "\u{2066}", rli: Unicode.Scalar = "\u{2067}"
    static let fsi: Unicode.Scalar = "\u{2068}", pdi: Unicode.Scalar = "\u{2069}"
    static let lre: Unicode.Scalar = "\u{202A}", rle: Unicode.Scalar = "\u{202B}"
    static let pdf: Unicode.Scalar = "\u{202C}", lro: Unicode.Scalar = "\u{202D}", rlo: Unicode.Scalar = "\u{202E}"

    static func isControl(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case lri, rli, fsi, pdi, lre, rle, pdf, lro, rlo: true
        default: false
        }
    }

    static func apply(_ handling: BidiHandling, to text: String) -> String {
        switch handling {
        case .isolate: isolate(text)
        case .strip: strip(text)
        case .none: text
        }
    }

    /// `_bidiIsolate`: FSI + balanced text + PDI.
    static func isolate(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        out.append(fsi)
        out.append(contentsOf: balance(text).unicodeScalars)
        out.append(pdi)
        return String(out)
    }

    /// `balanceUnicodeDirControlChars`: drop closers that close nothing, close what is open.
    static func balance(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isControl) else { return text }
        var out = String.UnicodeScalarView()
        var formatting = 0, isolates = 0
        for c in text.unicodeScalars {
            switch c {
            case lre, rle, lro, rlo:
                formatting += 1
                out.append(c)
            case pdf:
                if formatting > 0 {
                    formatting -= 1
                    out.append(c)
                }
            case lri, rli, fsi:
                isolates += 1
                out.append(c)
            case pdi:
                if isolates > 0 {
                    isolates -= 1
                    out.append(c)
                }
            default:
                out.append(c)
            }
        }
        out.append(contentsOf: repeatElement(pdf, count: formatting))
        out.append(contentsOf: repeatElement(pdi, count: isolates))
        return String(out)
    }

    static func strip(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        out.append(contentsOf: text.unicodeScalars.filter { !isControl($0) })
        return String(out)
    }
}
