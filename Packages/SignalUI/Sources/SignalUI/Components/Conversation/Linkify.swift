// Link detection as upstream does it: linkify-it 5.0.2 (lib/re.mjs + index.mjs) ported to
// ICU regular expressions with Signal's configuration (2010 IANA TLDs for fuzzy links,
// ts/components/conversation/Linkify.dom.tsx), the sneaky-link rules of
// ts/types/LinkPreview.std.ts, and the Linkify component. Offsets are UTF-16 (JavaScript's).
//
// JS → ICU: uc.micro's Z / P / Cc / Any classes are \p{Z} / \p{P} / \p{Cc} / (?s:.); JS `$`
// (no m flag) is \z; JS \d is ASCII-only, so [0-9].

import Foundation
import SwiftUI

public enum LinkifyIt {
    public struct Match: Sendable, Hashable {
        public var schema: String
        public var index: Int
        public var lastIndex: Int
        public var text: String
        public var url: String
    }

    /// Signal's `.tlds([...])` (replacing linkify-it's defaults and its 2-letter list), then xn--.
    static let tlds = "ac|ad|ae|aero|af|ag|ai|al|am|an|ao|aq|ar|arpa|as|asia|at|au|aw|ax|az|ba|bb|bd|be|bf|bg|bh|bi|biz|bj|bl|bm|bn|bo|bq|br|bs|bt|bv|bw|by|bz|ca|cat|cc|cd|cf|cg|ch|ci|ck|cl|cm|cn|co|com|coop|cr|cu|cv|cw|cx|cy|cz|de|dj|dk|dm|do|dz|ec|edu|ee|eg|er|es|et|eu|fi|fj|fk|fm|fo|fr|ga|gb|gd|ge|gf|gg|gh|gi|gl|gm|gn|gov|gp|gq|gr|gs|gt|gu|gw|gy|hk|hm|hn|hr|ht|hu|id|ie|il|im|in|info|int|io|iq|ir|is|it|je|jm|jo|jobs|jp|ke|kg|kh|ki|km|kn|kp|kr|kw|ky|kz|la|lb|lc|li|lk|lr|ls|lt|lu|lv|ly|ma|mc|md|me|mf|mg|mh|mil|mk|ml|mm|mn|mo|mobi|mp|mq|mr|ms|mt|mu|museum|mv|mw|mx|my|mz|na|name|nc|ne|net|nf|ng|ni|nl|no|np|nr|nu|nz|om|org|pa|pe|pf|pg|ph|pk|pl|pm|pn|pr|pro|ps|pt|pw|py|qa|re|ro|rs|ru|rw|sa|sb|sc|sd|se|sg|sh|si|sj|sk|sl|sm|sn|so|sr|st|su|sv|sx|sy|sz|tc|td|tel|tf|tg|th|tj|tk|tl|tm|tn|to|tp|tr|travel|tt|tv|tw|tz|ua|ug|uk|um|us|uy|uz|va|vc|ve|vg|vi|vn|vu|wf|ws|中国|中國|ලංකා|香港|台湾|台灣|امارات|الاردن|السعودية|ไทย|рф|تونس|مصر|قطر|இலங்கை|فلسطين|ye|yt|za|zm|zw"

    // lib/re.mjs
    static let srcZPCc = #"\p{Z}|\p{P}|\p{Cc}"#
    static let srcZCc = #"\p{Z}|\p{Cc}"#
    static let textSeparators = #"[><\x{FF5C}]"#
    static let pseudoLetter = "(?:(?!\(textSeparators)|\(srcZPCc))(?s:.))"
    static let ip4 = #"(?:(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)"#
    static let auth = "(?:(?:(?!\(srcZCc)|[@/\\[\\]()]).){1,50}@)?"
    static let port = #"(?::(?:6(?:[0-4][0-9]{3}|5(?:[0-4][0-9]{2}|5(?:[0-2][0-9]|3[0-5])))|[1-5]?[0-9]{1,4}))?"#
    static let hostTerminator = "(?=\\z|\(textSeparators)|\(srcZPCc))(?!-|_|:[0-9]|\\.-|\\.(?!\\z|\(srcZPCc)))"
    static let path = "(?:[/?#](?:"
        + "(?!\(srcZCc)|\(textSeparators)|[()\\[\\]{}.,\"'?!\\-;])." + "|"
        + "\\[(?:(?!\(srcZCc)|\\]).)*\\]" + "|"
        + "\\((?:(?!\(srcZCc)|[)]).)*\\)" + "|"
        + "\\{(?:(?!\(srcZCc)|[}]).)*\\}" + "|"
        + "\\\"(?:(?!\(srcZCc)|[\"]).)+\\\"" + "|"
        + "\\'(?:(?!\(srcZCc)|[']).)+\\'" + "|"
        + "\\'(?=\(pseudoLetter)|[-])" + "|"
        + "\\.{2,}[a-zA-Z0-9%/&]" + "|"
        + "\\.(?!\(srcZCc)|[.]|\\z)" + "|"
        + "\\-+" + "|"
        + ",(?!\(srcZCc)|\\z)" + "|"
        + ";(?!\(srcZCc)|\\z)" + "|"
        + "\\!+(?!\(srcZCc)|[!]|\\z)" + "|"
        + "\\?(?!\(srcZCc)|[?]|\\z)"
        + ")+|\\/)?"
    static let emailName = #"[\-;:&=\+\$,\.a-zA-Z0-9_][\-;:&=\+\$,\"\.a-zA-Z0-9_]{0,63}"#
    static let xn = #"xn--[a-z0-9\-]{1,59}"#
    static let domainRoot = "(?:\(xn)|\(pseudoLetter){1,63})"
    static let domain = "(?:\(xn)|(?:\(pseudoLetter))|(?:\(pseudoLetter)(?:-|\(pseudoLetter)){0,61}\(pseudoLetter)))"
    static let host = "(?:(?:(?:\(domain))\\.)*\(domain))"
    static let srcTlds = tlds + "|" + xn
    static let hostFuzzy = "(?:\(ip4)|(?:(?:(?:\(domain))\\.)+(?:\(srcTlds))))"
    static let hostNoIPFuzzy = "(?:(?:(?:\(domain))\\.)+(?:\(srcTlds)))"
    static let hostStrict = host + hostTerminator
    static let hostFuzzyStrict = hostFuzzy + hostTerminator
    static let hostPortStrict = host + port + hostTerminator
    static let hostPortNoIPFuzzyStrict = hostNoIPFuzzy + port + hostTerminator
    static let emailFuzzySource = "(^|\(textSeparators)|\"|\\(|\(srcZCc))(\(emailName)@\(hostFuzzyStrict))"
    static let linkNoIPFuzzySource = "(^|(?![.:/\\-_@])(?:[$+<=>^`|\\x{FF5C}]|\(srcZPCc)))((?![$+<=>^`|\\x{FF5C}])\(hostPortNoIPFuzzyStrict)\(path))"
    static let schemaSearchSource = "(^|(?!_)(?:[><\\x{FF5C}]|\(srcZPCc)))(http:|https:|ftp:|//|mailto:)"
    static let httpSource = "^//\(auth)\(hostPortStrict)\(path)"
    static let noHttpSource = "^\(auth)(?:localhost|(?:(?:\(domain))\\.)+\(domainRoot))\(port)\(hostTerminator)\(path)"
    static let mailtoSource = "^\(emailName)@\(hostStrict)"

    static func regex(_ pattern: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) } catch {
            preconditionFailure("linkify-it pattern: \(error)")
        }
    }

    static let schemaSearch = regex(schemaSearchSource)
    static let linkNoIPFuzzy = regex(linkNoIPFuzzySource)
    static let emailFuzzy = regex(emailFuzzySource)
    static let http = regex(httpSource)
    static let noHttp = regex(noHttpSource)
    static let mailto = regex(mailtoSource)

    /// Length of the anchored match of `re` in `text` from `pos` (a schema's `validate`).
    static func anchoredLength(_ re: NSRegularExpression, _ text: NSString, from pos: Int) -> Int {
        let range = NSRange(location: pos, length: text.length - pos)
        guard let m = re.firstMatch(in: text as String, options: [.anchored, .withTransparentBounds], range: range) else { return 0 }
        return m.range.length
    }

    static func validate(schema: String, _ text: NSString, at pos: Int) -> Int {
        switch schema.lowercased() {
        case "http:", "https:", "ftp:":
            return anchoredLength(http, text, from: pos)
        case "//":
            let n = anchoredLength(noHttp, text, from: pos)
            guard n > 0 else { return 0 }
            if pos >= 3 {
                let c = text.character(at: pos - 3)
                if c == 0x3A || c == 0x2F { return 0 }    // ':' or '/'
            }
            return n
        case "mailto:":
            return anchoredLength(mailto, text, from: pos)
        default:
            return 0
        }
    }

    /// `LinkifyIt.prototype.match` (fuzzyLink, fuzzyEmail, no fuzzyIP).
    public static func match(_ string: String) -> [Match] {
        let text = string as NSString
        guard text.length > 0 else { return [] }
        let all = NSRange(location: 0, length: text.length)
        struct Candidate { var schema: String; var index: Int; var lastIndex: Int }
        var schemed: [Candidate] = [], fuzzyLinks: [Candidate] = [], emails: [Candidate] = []
        // schema_search: exec loop; each validate starts at the end of the schema match.
        for m in schemaSearch.matches(in: string, range: all) {
            let schema = text.substring(with: m.range(at: 2))
            let end = m.range.location + m.range.length
            let len = validate(schema: schema, text, at: end)
            if len > 0 { schemed.append(Candidate(schema: schema, index: m.range.location + m.range(at: 1).length, lastIndex: end + len)) }
        }
        for m in linkNoIPFuzzy.matches(in: string, range: all) {
            fuzzyLinks.append(Candidate(schema: "", index: m.range.location + m.range(at: 1).length, lastIndex: m.range.location + m.range.length))
        }
        for m in emailFuzzy.matches(in: string, range: all) {
            emails.append(Candidate(schema: "mailto:", index: m.range.location + m.range(at: 1).length, lastIndex: m.range.location + m.range.length))
        }
        func choose(_ a: Candidate?, _ b: Candidate?) -> Candidate? {
            guard let a else { return b }
            guard let b else { return a }
            if a.index != b.index { return a.index < b.index ? a : b }
            return a.lastIndex >= b.lastIndex ? a : b
        }
        var i = [0, 0, 0]
        var lastIndex = 0
        var result: [Match] = []
        while true {
            let c0 = i[0] < schemed.count ? schemed[i[0]] : nil
            let c1 = i[1] < emails.count ? emails[i[1]] : nil
            let c2 = i[2] < fuzzyLinks.count ? fuzzyLinks[i[2]] : nil
            guard let candidate = choose(choose(c0, c1), c2) else { break }
            if let c0, candidate.index == c0.index, candidate.lastIndex == c0.lastIndex, candidate.schema == c0.schema {
                i[0] += 1
            } else if let c1, candidate.index == c1.index, candidate.lastIndex == c1.lastIndex, candidate.schema == c1.schema {
                i[1] += 1
            } else {
                i[2] += 1
            }
            if candidate.index < lastIndex { continue }
            let raw = text.substring(with: NSRange(location: candidate.index, length: candidate.lastIndex - candidate.index))
            var url = raw
            let schema = candidate.schema.lowercased()
            if schema.isEmpty { url = "http://" + url }
            if schema == "mailto:", !url.lowercased().hasPrefix("mailto:") { url = "mailto:" + url }
            result.append(Match(schema: schema, index: candidate.index, lastIndex: candidate.lastIndex, text: raw, url: url))
            lastIndex = candidate.lastIndex
        }
        return result
    }
}

/// ts/types/LinkPreview.std.ts
public enum LinkPreviewRules {
    /// `SUPPORTED_PROTOCOLS`: /^(http|https):/i
    public static func isSupportedProtocol(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http:") || lower.hasPrefix("https:")
    }

    /// `shouldLinkifyMessage`: no links in text with directional overrides.
    public static func shouldLinkifyMessage(_ message: String?) -> Bool {
        guard let message, !message.isEmpty else { return true }
        return !message.unicodeScalars.contains { (0x202C...0x202E).contains($0.value) }
    }

    public enum Sneaky: Sendable { case yes, maybe, no }

    /// `isLinkSneaky`
    public static func isLinkSneaky(_ href: String) -> Sneaky {
        if (href as NSString).length > 4096 { return .yes }
        if href.unicodeScalars.contains(where: { (0x2500...0x25FF).contains($0.value) }) { return .yes }
        guard let components = URLComponents(string: href), let scheme = components.scheme else { return .yes }
        if components.user != nil || components.password != nil { return .yes }
        guard let hostname = components.host?.lowercased(), !hostname.isEmpty else { return .yes }
        if (hostname as NSString).length > 2048 { return .yes }
        if hostname.contains("%") { return .yes }
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count < 2 || labels.contains(where: \.isEmpty) { return .yes }
        let unicodeDomain = labels.map { Punycode.toUnicode(String($0)) }.joined(separator: ".")
        let withoutPeriods = unicodeDomain.replacingOccurrences(of: ".", with: "")
        let hasASCII = withoutPeriods.unicodeScalars.contains { (0x20...0x7F).contains($0.value) }
        let withoutASCII = withoutPeriods.unicodeScalars.filter { !(0x20...0x7F).contains($0.value) }
        if hasASCII && !withoutASCII.isEmpty { return .yes }
        let ns = href as NSString
        let searchFrom = min(ns.length, scheme.count + 1 + 4)
        let slash = ns.range(of: "/", range: NSRange(location: searchFrom, length: ns.length - searchFrom))
        let pathAndHash = slash.location == NSNotFound ? "" : ns.substring(from: slash.location)
        let valid = Set("%:/?#[]@!$&'()*+,;=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if !pathAndHash.allSatisfy({ valid.contains($0) }) { return .maybe }
        return .no
    }
}

/// RFC 3492 decoding of "xn--" labels (`domainToUnicode`).
enum Punycode {
    static func toUnicode(_ label: String) -> String {
        guard label.lowercased().hasPrefix("xn--") else { return label }
        return decode(String(label.dropFirst(4))) ?? label
    }

    static func decode(_ input: String) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        var output: [UnicodeScalar] = []
        var basic = Substring(input)
        var rest = Substring("")
        if let dash = input.lastIndex(of: "-") {
            basic = input[..<dash]
            rest = input[input.index(after: dash)...]
            for ch in basic { guard let s = ch.unicodeScalars.first, s.isASCII else { return nil }; output.append(s) }
        } else {
            rest = Substring(input)
        }
        var n = 128, i = 0, bias = 72
        var chars = Array(rest.lowercased())
        var pos = 0
        func digit(_ c: Character) -> Int? {
            guard let v = c.asciiValue else { return nil }
            if v >= 97 && v <= 122 { return Int(v) - 97 }
            if v >= 48 && v <= 57 { return Int(v) - 48 + 26 }
            return nil
        }
        while pos < chars.count {
            let oldi = i
            var w = 1
            var k = base
            while true {
                guard pos < chars.count, let d = digit(chars[pos]) else { return nil }
                pos += 1
                i += d * w
                let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                if d < t { break }
                w *= base - t
                k += base
                if i > 0x10FFFF * 4 { return nil }
            }
            var delta = (i - oldi) / (oldi == 0 ? damp : 2)
            delta += delta / (output.count + 1)
            var kk = 0
            while delta > ((base - tMin) * tMax) / 2 { delta /= base - tMin; kk += base }
            bias = kk + (((base - tMin + 1) * delta) / (delta + skew))
            n += i / (output.count + 1)
            i %= output.count + 1
            guard let scalar = UnicodeScalar(n) else { return nil }
            output.insert(scalar, at: i)
            i += 1
        }
        chars.removeAll()
        return String(String.UnicodeScalarView(output))
    }
}

/// `extractLinks` (MessageTextRenderer.dom.tsx): links found with emoji blanked to spaces,
/// only those fully visible within `displayedTextLength`.
public func extractLinks(_ originalMessageText: String, displayedTextLength: Int) -> [BodyRange] {
    var blanked = ""
    for ch in originalMessageText {
        blanked += CSSTextLayout.isEmoji(ch) ? String(repeating: " ", count: ch.utf16.count) : String(ch)
    }
    return LinkifyIt.match(blanked).filter { $0.lastIndex <= displayedTextLength }.map {
        BodyRange(start: $0.index, length: $0.lastIndex - $0.index, kind: .link(url: $0.url))
    }
}

/// Linkify (ts/components/conversation/Linkify.dom.tsx): text with its supported, non-sneaky
/// links as tappable runs (`<a>`: the inherited colour, underlined by the UA only on hover).
public struct Linkify: View {
    let text: String
    let style: CSSTextStyle
    @Environment(\.openURL) var openURL

    public init(_ text: String, style: CSSTextStyle) {
        self.text = text
        self.style = style
    }

    /// An unstyled `<a>` (Storybook / UA): underlined, in the UA link colour.
    public static let uaLinkColor = AxoColor(light: RGBA(3 / 255, 15 / 255, 252 / 255), dark: RGBA(153 / 255, 161 / 255, 1))

    /// The runs: emoji segments never contain links; links get the `action` of their URL.
    /// - Parameter emojify: `renderNonLink` is Emojify (MessageBody); the default is plain text.
    public static func runs(_ text: String, emojify: Bool = false) -> [CSSTextRun] {
        func plain(_ t: String) -> CSSTextRun { emojify ? Emojify.run(t) : CSSTextRun(t) }
        guard LinkPreviewRules.shouldLinkifyMessage(text) else { return [plain(text)] }
        var out: [CSSTextRun] = []
        var segment = ""
        func flush() {
            guard !segment.isEmpty else { return }
            let ns = segment as NSString
            var cursor = 0
            for m in LinkifyIt.match(segment) {
                if cursor < m.index { out.append(plain(ns.substring(with: NSRange(location: cursor, length: m.index - cursor)))) }
                var run = CSSTextRun(m.text)
                if LinkPreviewRules.isSupportedProtocol(m.url), LinkPreviewRules.isLinkSneaky(m.url) != .yes {
                    run.action = m.url
                    run.color = Linkify.uaLinkColor
                    run.underline = true
                }
                out.append(run)
                cursor = m.lastIndex
            }
            if cursor < ns.length { out.append(plain(ns.substring(from: cursor))) }
            segment = ""
        }
        for ch in text {
            if CSSTextLayout.isEmoji(ch) {
                flush()
                out.append(plain(String(ch)))
            } else {
                segment.append(ch)
            }
        }
        flush()
        return out
    }

    public var body: some View {
        CSSText(runs: Self.runs(text), style: style, onTap: { url in
            if let u = URL(string: url) { openURL(u) }
        })
    }
}
