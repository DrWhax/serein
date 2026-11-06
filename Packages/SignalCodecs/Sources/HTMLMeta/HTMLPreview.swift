// Link-preview HTML (untrusted): the subset of HTML that ts/linkPreviews/linkPreviewFetch's
// DOMParser + querySelector calls read, and nothing else.
//
// Grammar (a regular language over the decoded text; everything not listed is skipped):
//   document  := ( comment | decl | endtag | rawtext | starttag | text )*
//   comment   := "<!--" … "-->"              decl := "<!" … ">" | "<?" … ">"
//   starttag  := "<" name ( ws+ attr )* ws* "/"? ">"
//   attr      := attrname ( ws* "=" ws* ( '"' … '"' | "'" … "'" | unquoted ) )?
//   rawtext   := "<" ("script"|"style"|"textarea"|"title"|…) attrs ">" … "</" name   (title keeps its text)
// Attribute names and tag names are ASCII case-insensitive; the first duplicate attribute
// wins; character references are decoded in attribute values and the title.
//
// Extraction (parseMetadata): title = og:title || <title>; description = og:description ||
// meta[name=description]; image = og:image || og:image:url || link[rel=apple-touch-icon |
// apple-touch-icon-precomposed | shortcut icon | icon]; date = og:/article: modified/published
// time. Charset (parseHtmlBytes): UTF-8 BOM, else the HTTP charset, else UTF-8 with a second
// pass under <meta http-equiv=content-type> or <meta charset>.
//
// Limits: the caller passes at most 1000 KiB (MAX_HTML_BYTES_TO_LOAD); at most 20 000 tags
// and 64 attributes per tag are looked at; strings returned are at most 4096 characters.

public import CodecCore

public struct HTMLPreviewMetadata: Sendable, Equatable {
    public var title: String?
    public var description: String?
    /// As written in the document (resolve against the page URL).
    public var imageHref: String?
    /// As written (`Date.parse` input).
    public var rawDate: String?

    public init(title: String?, description: String?, imageHref: String?, rawDate: String?) {
        self.title = title
        self.description = description
        self.imageHref = imageHref
        self.rawDate = rawDate
    }
}

public enum HTMLPreview {
    public static let maxBytes = 1000 * 1024
    static let maxTags = 20_000
    static let maxAttributes = 64
    static let maxString = 4096

    struct Tag {
        var name: String
        var attributes: [(name: String, value: String)]
        func attr(_ n: String) -> String? { attributes.first { $0.name == n }?.value }
    }

    struct Document {
        var title: String?
        var metas: [Tag] = []
        var links: [Tag] = []
    }

    /// `fetchLinkPreviewMetadata` from the HTML on: nil when there is no title.
    public static func parse(_ bytes: ByteSlice, httpCharset: String?) -> HTMLPreviewMetadata? {
        let doc = document(bytes, httpCharset: httpCharset)
        func og(_ properties: [String]) -> String? {
            for p in properties {
                if let c = doc.metas.first(where: { $0.attr("property") == p })?.attr("content").map(trim), !c.isEmpty { return cap(c) }
            }
            return nil
        }
        guard let title = og(["og:title"]) ?? doc.title.map(trim).flatMap({ $0.isEmpty ? nil : cap($0) }) else { return nil }
        let description = og(["og:description"])
            ?? doc.metas.first(where: { $0.attr("name") == "description" })?.attr("content").map(trim).flatMap { $0.isEmpty ? nil : cap($0) }
        var image = og(["og:image", "og:image:url"])
        if image == nil {
            for rel in ["apple-touch-icon", "apple-touch-icon-precomposed", "shortcut icon", "icon"] {
                if let href = doc.links.first(where: { $0.attr("rel").map(asciiLower) == rel })?.attr("href").map(trim), !href.isEmpty {
                    image = cap(href)
                    break
                }
            }
        }
        let date = og(["og:modified_time", "article:modified_time", "og:published_time", "article:published_time"])
        return HTMLPreviewMetadata(title: title, description: description, imageHref: image, rawDate: date)
    }

    static func document(_ bytes: ByteSlice, httpCharset: String?) -> Document {
        let hasBOM = bytes.peekPrefix(3) == [0xEF, 0xBB, 0xBF]
        if hasBOM { return tokenize(decode(bytes, charset: "utf-8")) }
        if let httpCharset, let text = decodeIfKnown(bytes, charset: httpCharset) { return tokenize(text) }
        let first = tokenize(decode(bytes, charset: "utf-8"))
        // Not sure of the charset: a declared one gets a second pass.
        if let content = first.metas.first(where: { $0.attr("http-equiv").map(asciiLower) == "content-type" })?.attr("content"),
           let cs = charset(fromContentType: content), let text = decodeIfKnown(bytes, charset: cs) {
            return tokenize(text)
        }
        if let cs = first.metas.first(where: { $0.attr("charset") != nil })?.attr("charset"), let text = decodeIfKnown(bytes, charset: cs) {
            return tokenize(text)
        }
        return first
    }

    /// `parseContentType(...).charset`
    public static func charset(fromContentType value: String) -> String? {
        guard value.count <= 100 else { return nil }
        for part in asciiLower(value).split(separator: ";").dropFirst() {
            let p = trim(String(part))
            if p.hasPrefix("charset=") {
                var v = trim(String(p.dropFirst("charset=".count)))
                if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 { v = String(v.dropFirst().dropLast()) }
                if !v.isEmpty { return v }
            }
        }
        return nil
    }

    // MARK: decoding

    static func decodeIfKnown(_ bytes: ByteSlice, charset: String) -> [Unicode.Scalar]? {
        let cs = asciiLower(trim(charset))
        guard ["utf-8", "utf8", "unicode-1-1-utf-8", "us-ascii", "ascii", "iso-8859-1", "latin1", "l1", "windows-1252", "cp1252",
               "utf-16", "utf-16le", "utf-16be"].contains(cs) else { return nil }
        return decode(bytes, charset: cs)
    }

    /// windows-1252 0x80–0x9F (WHATWG's mapping for iso-8859-1 and us-ascii too).
    static let cp1252: [UInt32] = [0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
                                   0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178]

    static func decode(_ bytes: ByteSlice, charset: String) -> [Unicode.Scalar] {
        let raw = bytes.copyBytes()
        switch charset {
        case "utf-16", "utf-16le", "utf-16be":
            var units: [UInt16] = []
            units.reserveCapacity(raw.count / 2)
            var c = ByteCursor(bytes)
            let bigEndian = charset == "utf-16be"
            while c.remaining >= 2 {
                guard let u = try? (bigEndian ? c.u16be() : c.u16le()) else { break }
                units.append(u)
            }
            return Array(String(decoding: units, as: UTF16.self).unicodeScalars)
        case "us-ascii", "ascii", "iso-8859-1", "latin1", "l1", "windows-1252", "cp1252":
            return raw.map { b in
                if b >= 0x80 && b <= 0x9F, let s = Unicode.Scalar(cp1252[Int(b - 0x80)]) { return s }
                return Unicode.Scalar(b)
            }
        default:
            return Array(String(decoding: raw, as: UTF8.self).unicodeScalars)
        }
    }

    // MARK: tokenizer

    static let rawTextElements: Set<String> = ["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "plaintext"]

    static func tokenize(_ s: [Unicode.Scalar]) -> Document {
        var doc = Document()
        var i = 0
        var tags = 0
        let n = s.count
        while i < n, tags < maxTags {
            guard s[i] == "<" else { i += 1; continue }
            if starts(s, i, "<!--") {
                i = find(s, from: i + 4, "-->").map { $0 + 3 } ?? n
                continue
            }
            if i + 1 < n, s[i + 1] == "!" || s[i + 1] == "?" {
                i = find(s, from: i + 2, ">").map { $0 + 1 } ?? n
                continue
            }
            if i + 1 < n, s[i + 1] == "/" {
                i = find(s, from: i + 2, ">").map { $0 + 1 } ?? n
                continue
            }
            guard i + 1 < n, isASCIILetter(s[i + 1]) else { i += 1; continue }
            tags += 1
            var j = i + 1
            var name = ""
            while j < n, !isSpace(s[j]), s[j] != "/", s[j] != ">" { name.unicodeScalars.append(lower(s[j])); j += 1 }
            var attributes: [(name: String, value: String)] = []
            // attributes
            while j < n {
                while j < n, isSpace(s[j]) || s[j] == "/" { j += 1 }
                guard j < n, s[j] != ">" else { break }
                var an = ""
                // An attribute name may start with "=" (then it is part of the name).
                if s[j] == "=" { an.unicodeScalars.append("="); j += 1 }
                while j < n, !isSpace(s[j]), s[j] != "/", s[j] != ">", s[j] != "=" { an.unicodeScalars.append(lower(s[j])); j += 1 }
                var k = j
                while k < n, isSpace(s[k]) { k += 1 }
                var value = ""
                if k < n, s[k] == "=" {
                    k += 1
                    while k < n, isSpace(s[k]) { k += 1 }
                    if k < n, s[k] == "\"" || s[k] == "'" {
                        let q = s[k]
                        let end = find(s, from: k + 1, q) ?? n
                        value = decodeReferences(s, k + 1, end)
                        k = min(end + 1, n)
                    } else {
                        let start = k
                        while k < n, !isSpace(s[k]), s[k] != ">" { k += 1 }
                        value = decodeReferences(s, start, k)
                    }
                    j = k
                }
                if attributes.count < maxAttributes, !attributes.contains(where: { $0.name == an }) { attributes.append((an, value)) }
            }
            i = min(j + 1, n)
            let tag = Tag(name: name, attributes: attributes)
            switch name {
            case "meta": doc.metas.append(tag)
            case "link": doc.links.append(tag)
            default: break
            }
            if rawTextElements.contains(name) {
                let close = findEndTag(s, from: i, name) ?? n
                if name == "title", doc.title == nil { doc.title = collapse(decodeReferences(s, i, close)) }
                i = close
            }
        }
        return doc
    }

    /// The start of `</name` (ASCII case-insensitive) from `from`.
    static func findEndTag(_ s: [Unicode.Scalar], from: Int, _ name: String) -> Int? {
        let target = Array(name.unicodeScalars)
        var i = from
        while let lt = find(s, from: i, "</") {
            var k = lt + 2, m = 0
            while m < target.count, k < s.count, lower(s[k]) == target[m] { k += 1; m += 1 }
            if m == target.count, k == s.count || isSpace(s[k]) || s[k] == ">" || s[k] == "/" { return lt }
            i = lt + 2
        }
        return nil
    }

    static func starts(_ s: [Unicode.Scalar], _ i: Int, _ lit: String) -> Bool {
        var k = i
        for c in lit.unicodeScalars {
            guard k < s.count, s[k] == c else { return false }
            k += 1
        }
        return true
    }

    static func find(_ s: [Unicode.Scalar], from: Int, _ lit: String) -> Int? {
        guard let first = lit.unicodeScalars.first else { return nil }
        var i = from
        while i < s.count {
            if s[i] == first, starts(s, i, lit) { return i }
            i += 1
        }
        return nil
    }

    static func find(_ s: [Unicode.Scalar], from: Int, _ c: Unicode.Scalar) -> Int? {
        var i = from
        while i < s.count {
            if s[i] == c { return i }
            i += 1
        }
        return nil
    }

    /// Character references in `s[from..<to]`: `&name;` (HTML 4 names), `&#123;`, `&#x7B;`.
    static func decodeReferences(_ s: [Unicode.Scalar], _ from: Int, _ to: Int) -> String {
        var out = String.UnicodeScalarView()
        var i = from
        let end = min(to, s.count)
        while i < end, out.count < maxString * 4 {
            let c = s[i]
            guard c == "&" else { out.append(c); i += 1; continue }
            var k = i + 1
            if k < end, s[k] == "#" {
                k += 1
                var hex = false
                if k < end, s[k] == "x" || s[k] == "X" { hex = true; k += 1 }
                var v: UInt32 = 0, digits = 0
                while k < end, let d = digit(s[k], hex: hex), digits < 8 { v = v * (hex ? 16 : 10) + d; k += 1; digits += 1 }
                if digits > 0 {
                    if k < end, s[k] == ";" { k += 1 }
                    let scalar = v == 0 || (v >= 0xD800 && v <= 0xDFFF) || v > 0x10FFFF ? nil : Unicode.Scalar(v)
                    out.append(scalar ?? "\u{FFFD}")
                    i = k
                    continue
                }
            } else {
                var name = ""
                while k < end, k - i <= 32, isASCIILetter(s[k]) || isASCIIDigit(s[k]) { name.unicodeScalars.append(s[k]); k += 1 }
                if k < end, s[k] == ";", let v = HTMLEntities.named[name], let scalar = Unicode.Scalar(v) {
                    out.append(scalar)
                    i = k + 1
                    continue
                }
            }
            out.append("&")
            i += 1
        }
        return String(out)
    }

    static func digit(_ c: Unicode.Scalar, hex: Bool) -> UInt32? {
        switch c.value {
        case 0x30...0x39: return c.value - 0x30
        case 0x61...0x66 where hex: return c.value - 0x61 + 10
        case 0x41...0x46 where hex: return c.value - 0x41 + 10
        default: return nil
        }
    }

    // MARK: text helpers (ASCII whitespace as in the DOM's "strip and collapse")

    static func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}" }
    static func isASCIILetter(_ c: Unicode.Scalar) -> Bool { (c.value >= 0x41 && c.value <= 0x5A) || (c.value >= 0x61 && c.value <= 0x7A) }
    static func isASCIIDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }
    static func lower(_ c: Unicode.Scalar) -> Unicode.Scalar { c.value >= 0x41 && c.value <= 0x5A ? Unicode.Scalar(c.value + 32)! : c }
    static func asciiLower(_ s: String) -> String { String(String.UnicodeScalarView(s.unicodeScalars.map(lower))) }

    /// `String.prototype.trim` (JS whitespace: ASCII, NBSP, Zs, line/paragraph separators, BOM).
    static func trim(_ s: String) -> String {
        func ws(_ c: Unicode.Scalar) -> Bool {
            isSpace(c) || c == "\u{0B}" || c == "\u{A0}" || c == "\u{FEFF}" || c == "\u{2028}" || c == "\u{2029}"
                || c.properties.generalCategory == .spaceSeparator
        }
        let scalars = Array(s.unicodeScalars)
        var a = 0, b = scalars.count
        while a < b, ws(scalars[a]) { a += 1 }
        while b > a, ws(scalars[b - 1]) { b -= 1 }
        return String(String.UnicodeScalarView(scalars[a..<b]))
    }

    /// `document.title`: strip and collapse ASCII whitespace.
    static func collapse(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for c in s.unicodeScalars {
            if isSpace(c) { pendingSpace = !out.isEmpty; continue }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(c)
        }
        return String(out)
    }

    static func cap(_ s: String) -> String { s.count <= maxString ? s : String(s.prefix(maxString)) }
}

extension ByteSlice {
    func peekPrefix(_ n: Int) -> [UInt8]? { cursor().peek(n)?.copyBytes() }
}
