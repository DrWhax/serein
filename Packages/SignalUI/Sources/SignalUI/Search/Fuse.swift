// Port of Fuse.js 7.1.0 (Kiro Risk, Apache-2.0), the fuzzy search upstream uses for
// conversations, contacts and members: Bitap matching with location/distance scoring, the
// extended-search operators (=exact, 'include, ^prefix, suffix$, !inverse, "quoted", | OR),
// the field-length norm and weighted keys. Strings are compared as UTF-16 code units and bit
// operations are 32-bit, as in JavaScript, so scores and matches agree with upstream.

import Foundation

public struct Fuse: Sendable {
    public struct Options: Sendable {
        public var threshold: Double = 0.6
        public var distance: Int = 100
        public var location: Int = 0
        public var ignoreLocation = false
        public var useExtendedSearch = false
        public var isCaseSensitive = false
        public var findAllMatches = false
        public var minMatchCharLength = 1
        public var ignoreFieldNorm = false
        public var fieldNormWeight: Double = 1
        public init(threshold: Double = 0.6, distance: Int = 100, useExtendedSearch: Bool = false) {
            self.threshold = threshold
            self.distance = distance
            self.useExtendedSearch = useExtendedSearch
        }
    }

    public struct Key: Sendable {
        public var name: String
        public var weight: Double
        public init(_ name: String, weight: Double = 1) {
            self.name = name
            self.weight = weight
        }
    }

    public struct Result: Sendable {
        /// Index into the documents.
        public var refIndex: Int
        public var score: Double
    }

    struct Value: Sendable {
        var text: String
        var norm: Double
    }

    let options: Options
    /// Key weights as given: Fuse.js scores with its index's keys (`createIndex` →
    /// `createKey`), not the KeyStore's normalised ones.
    let weights: [Double]
    /// Per document, per key: the value (nil when undefined or blank).
    let records: [[Value?]]

    /// `new Fuse(docs, { keys, … })` where each document gives each key's string (or nil).
    public init(documents: [[String?]], keys: [Key], options: Options) {
        self.options = options
        weights = keys.map(\.weight)
        let norm = FieldNorm(weight: options.fieldNormWeight)
        records = documents.map { doc in
            keys.indices.map { k in
                guard k < doc.count, let v = doc[k], !Fuse.isBlank(v) else { return nil }
                return Value(text: v, norm: norm.get(v))
            }
        }
    }

    static func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// `fuse.search(query)`: matches, sorted by score then document order.
    public func search(_ query: String) -> [Result] {
        let searcher: any FuseSearcher = options.useExtendedSearch ? ExtendedSearch(query, options) : BitapSearch(query, options)
        var results: [Result] = []
        for (idx, record) in records.enumerated() {
            var total = 1.0
            var matched = false
            for (k, value) in record.enumerated() {
                guard let value else { continue }
                let r = searcher.searchIn(value.text)
                guard r.isMatch else { continue }
                matched = true
                // computeScore: ∏ score^(weight·norm), a perfect match counting as EPSILON.
                let weight = weights[k]
                total *= pow(r.score == 0 && weight != 0 ? Double.ulpOfOne : r.score, (weight == 0 ? 1 : weight) * (options.ignoreFieldNorm ? 1 : value.norm))
            }
            if matched { results.append(Result(refIndex: idx, score: total)) }
        }
        return results.sorted { a, b in a.score == b.score ? a.refIndex < b.refIndex : a.score < b.score }
    }

    /// `norm()`: 1/√(tokens)^weight, rounded to 3 decimals.
    struct FieldNorm {
        let weight: Double
        func get(_ value: String) -> Double {
            let tokens = value.split(separator: " ", omittingEmptySubsequences: true).count
            let n = 1 / pow(Double(max(tokens, 1)), 0.5 * weight)
            return (n * 1000).rounded(.toNearestOrAwayFromZero) / 1000
        }
    }
}

struct FuseMatch: Sendable {
    var isMatch: Bool
    var score: Double
}

protocol FuseSearcher: Sendable {
    func searchIn(_ text: String) -> FuseMatch
}

/// JS `toLowerCase` on UTF-16 code units.
func fuseLower(_ s: String, _ caseSensitive: Bool) -> [UInt16] { Array((caseSensitive ? s : s.lowercased()).utf16) }

/// `String.prototype.indexOf` on code units.
func fuseIndexOf(_ text: [UInt16], _ pattern: [UInt16], from: Int) -> Int {
    let n = text.count, m = pattern.count
    var i = max(0, from)
    if m == 0 { return min(i, n) }
    while i + m <= n {
        if text[i] == pattern[0] && Array(text[i..<(i + m)]) == pattern { return i }
        i += 1
    }
    return -1
}

// MARK: - Bitap

struct BitapSearch: FuseSearcher {
    static let maxBits = 32
    struct Chunk: Sendable {
        var pattern: [UInt16]
        var alphabet: [UInt16: Int32]
        var startIndex: Int
    }
    let options: Fuse.Options
    let pattern: [UInt16]
    let chunks: [Chunk]

    init(_ pattern: String, _ options: Fuse.Options) {
        self.options = options
        let p = fuseLower(pattern, options.isCaseSensitive)
        self.pattern = p
        func chunk(_ part: [UInt16], _ start: Int) -> Chunk {
            var alphabet: [UInt16: Int32] = [:]
            for (i, c) in part.enumerated() { alphabet[c, default: 0] |= Int32(truncatingIfNeeded: 1 << (part.count - i - 1)) }
            return Chunk(pattern: part, alphabet: alphabet, startIndex: start)
        }
        var chunks: [Chunk] = []
        if !p.isEmpty {
            if p.count > Self.maxBits {
                var i = 0
                let remainder = p.count % Self.maxBits
                let end = p.count - remainder
                while i < end {
                    chunks.append(chunk(Array(p[i..<(i + Self.maxBits)]), i))
                    i += Self.maxBits
                }
                if remainder > 0 {
                    let start = p.count - Self.maxBits
                    chunks.append(chunk(Array(p[start...]), start))
                }
            } else {
                chunks.append(chunk(p, 0))
            }
        }
        self.chunks = chunks
    }

    func searchIn(_ textString: String) -> FuseMatch {
        let text = fuseLower(textString, options.isCaseSensitive)
        if pattern == text { return FuseMatch(isMatch: true, score: 0) }
        var hasMatches = false
        var total = 0.0
        for c in chunks {
            let r = Self.search(text, c.pattern, c.alphabet, location: options.location + c.startIndex, options: options)
            if r.isMatch { hasMatches = true }
            total += r.score
        }
        return FuseMatch(isMatch: hasMatches, score: hasMatches ? total / Double(chunks.count) : 1)
    }

    static func computeScore(_ patternLength: Int, errors: Int, current: Int, expected: Int, distance: Int, ignoreLocation: Bool) -> Double {
        let accuracy = Double(errors) / Double(patternLength)
        if ignoreLocation { return accuracy }
        let proximity = abs(expected - current)
        if distance == 0 { return proximity != 0 ? 1 : accuracy }
        return accuracy + Double(proximity) / Double(distance)
    }

    /// `search()`: Bitap with the errors allowed growing while the score can still beat the
    /// threshold; JS int32 bit arithmetic, undefined slots reading as 0.
    static func search(_ text: [UInt16], _ pattern: [UInt16], _ alphabet: [UInt16: Int32], location: Int, options: Fuse.Options) -> FuseMatch {
        let patternLen = pattern.count, textLen = text.count
        let expected = max(0, min(location, textLen))
        var threshold = options.threshold
        var bestLocation = expected
        func score(_ errors: Int, _ current: Int) -> Double {
            computeScore(patternLen, errors: errors, current: current, expected: expected, distance: options.distance, ignoreLocation: options.ignoreLocation)
        }
        // Exact occurrences tighten the threshold first.
        var index = fuseIndexOf(text, pattern, from: bestLocation)
        while index > -1 {
            threshold = min(score(0, index), threshold)
            bestLocation = index + patternLen
            index = fuseIndexOf(text, pattern, from: bestLocation)
        }
        bestLocation = -1
        var lastBitArr: [Int32] = []
        var finalScore = 1.0
        var binMax = patternLen + textLen
        let mask = Int32(truncatingIfNeeded: 1 << (patternLen - 1))
        func at(_ a: [Int32], _ i: Int) -> Int32 { i >= 0 && i < a.count ? a[i] : 0 }
        for i in 0..<patternLen {
            var binMin = 0, binMid = binMax
            while binMin < binMid {
                if score(i, expected + binMid) <= threshold { binMin = binMid } else { binMax = binMid }
                binMid = Int((Double(binMax - binMin) / 2 + Double(binMin)).rounded(.down))
            }
            binMax = binMid
            var start = max(1, expected - binMid + 1)
            let finish = options.findAllMatches ? textLen : min(expected + binMid, textLen) + patternLen
            var bitArr = [Int32](repeating: 0, count: finish + 2)
            bitArr[finish + 1] = Int32(truncatingIfNeeded: 1 << i) &- 1
            var j = finish
            while j >= start {
                let currentLocation = j - 1
                let charMatch = currentLocation < textLen ? (alphabet[text[currentLocation]] ?? 0) : 0
                bitArr[j] = ((bitArr[j + 1] &<< 1) | 1) & charMatch
                if i > 0 {
                    bitArr[j] |= ((at(lastBitArr, j + 1) | at(lastBitArr, j)) &<< 1) | 1 | at(lastBitArr, j + 1)
                }
                if bitArr[j] & mask != 0 {
                    finalScore = score(i, currentLocation)
                    if finalScore <= threshold {
                        threshold = finalScore
                        bestLocation = currentLocation
                        if bestLocation <= expected { break }
                        start = max(1, 2 * expected - bestLocation)
                    }
                }
                j -= 1
            }
            if score(i + 1, expected) > threshold { break }
            lastBitArr = bitArr
        }
        return FuseMatch(isMatch: bestLocation >= 0, score: max(0.001, finalScore))
    }
}

// MARK: - Extended search

struct ExtendedSearch: FuseSearcher {
    enum Matcher: Sendable {
        case exact([UInt16]), include([UInt16]), prefix([UInt16]), inversePrefix([UInt16]), inverseSuffix([UInt16]), suffix([UInt16])
        case inverseExact([UInt16]), fuzzy(BitapSearch)

        func search(_ text: [UInt16], raw: String) -> FuseMatch {
            func hit(_ b: Bool) -> FuseMatch { FuseMatch(isMatch: b, score: b ? 0 : 1) }
            switch self {
            case .exact(let p): return hit(text == p)
            case .include(let p): return hit(fuseIndexOf(text, p, from: 0) > -1)
            case .prefix(let p): return hit(text.starts(with: p))
            case .inversePrefix(let p): return hit(!text.starts(with: p))
            case .suffix(let p): return hit(text.count >= p.count && Array(text.suffix(p.count)) == p)
            case .inverseSuffix(let p): return hit(!(text.count >= p.count && Array(text.suffix(p.count)) == p))
            case .inverseExact(let p): return hit(fuseIndexOf(text, p, from: 0) == -1)
            case .fuzzy(let b): return b.searchIn(raw)
            }
        }
    }

    let options: Fuse.Options
    /// OR groups of AND-ed matchers.
    let query: [[Matcher]]

    init(_ pattern: String, _ options: Fuse.Options) {
        self.options = options
        let p = options.isCaseSensitive ? pattern : pattern.lowercased()
        query = Self.parseQuery(p, options)
    }

    /// The searchers in upstream's order: (multi-match pattern, single-match pattern, make).
    static func matchers(_ options: Fuse.Options) -> [(multi: (String) -> String?, single: (String) -> String?, make: (String) -> Matcher)] {
        func u(_ s: String) -> [UInt16] { Array(s.utf16) }
        func wrap(_ prefix: String, _ suffix: String) -> (String) -> String? {
            { s in
                guard s.hasPrefix(prefix), s.hasSuffix(suffix), s.count >= prefix.count + suffix.count else { return nil }
                return String(s.dropFirst(prefix.count).dropLast(suffix.count))
            }
        }
        return [
            (wrap("=\"", "\""), wrap("=", ""), { .exact(u($0)) }),
            (wrap("'\"", "\""), wrap("'", ""), { .include(u($0)) }),
            (wrap("^\"", "\""), wrap("^", ""), { .prefix(u($0)) }),
            (wrap("!^\"", "\""), wrap("!^", ""), { .inversePrefix(u($0)) }),
            (wrap("!\"", "\"$"), wrap("!", "$"), { .inverseSuffix(u($0)) }),
            (wrap("\"", "\"$"), wrap("", "$"), { .suffix(u($0)) }),
            (wrap("!\"", "\""), wrap("!", ""), { .inverseExact(u($0)) }),
            (wrap("\"", "\""), { $0 }, { .fuzzy(BitapSearch($0, options)) }),
        ]
    }

    /// `parseQuery`: `|` separates OR groups; spaces (outside quotes) separate AND terms.
    static func parseQuery(_ pattern: String, _ options: Fuse.Options) -> [[Matcher]] {
        let searchers = matchers(options)
        return pattern.components(separatedBy: "|").map { item in
            splitOutsideQuotes(item.trimmingCharacters(in: .whitespaces)).compactMap { term -> Matcher? in
                // Multi-match (quoted) forms first, then single.
                for s in searchers { if let token = s.multi(term), !token.isEmpty { return s.make(token) } }
                for s in searchers { if let token = s.single(term), !token.isEmpty { return s.make(token) } }
                return nil
            }
        }
    }

    /// `split(/ +(?=(?:[^"]*"[^"]*")*[^"]*$)/)`: on runs of spaces followed by an even number of quotes.
    static func splitOutsideQuotes(_ s: String) -> [String] {
        let chars = Array(s)
        var parts: [String] = []
        var current = ""
        var i = 0
        while i < chars.count {
            if chars[i] == " " {
                var j = i
                while j < chars.count && chars[j] == " " { j += 1 }
                let quotesAfter = chars[j...].filter { $0 == "\"" }.count
                if quotesAfter % 2 == 0 {
                    parts.append(current)
                    current = ""
                    i = j
                    continue
                }
                current.append(contentsOf: chars[i..<j])
                i = j
                continue
            }
            current.append(chars[i])
            i += 1
        }
        parts.append(current)
        return parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func searchIn(_ textString: String) -> FuseMatch {
        let raw = options.isCaseSensitive ? textString : textString.lowercased()
        let text = Array(raw.utf16)
        var totalScore = 0.0
        for group in query {
            var numMatches = 0
            for m in group {
                let r = m.search(text, raw: raw)
                if r.isMatch {
                    numMatches += 1
                    totalScore += r.score
                } else {
                    totalScore = 0
                    numMatches = 0
                    break
                }
            }
            if numMatches > 0 { return FuseMatch(isMatch: true, score: totalScore / Double(numMatches)) }
        }
        return FuseMatch(isMatch: false, score: 1)
    }
}
