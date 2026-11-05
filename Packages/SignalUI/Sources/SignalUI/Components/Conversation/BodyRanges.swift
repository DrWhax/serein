// Message body ranges (ts/types/BodyRange.std.ts): mentions, formatting (bold, italic,
// spoiler, strikethrough, monospace), links and search-keyword highlights, collapsed into
// display nodes the way upstream does. Offsets are UTF-16 code units, as in JavaScript.

import Foundation

public struct BodyRange: Sendable, Hashable {
    /// `SignalService.BodyRange.Style`
    public enum Style: Int, Sendable { case none = 0, bold = 1, italic = 2, spoiler = 3, strikethrough = 4, monospace = 5 }

    public enum Kind: Sendable, Hashable {
        /// A hydrated mention: the U+FFFC placeholder shows as "@" + `replacementText`.
        case mention(aci: String, conversationID: String, replacementText: String)
        case formatting(Style, spoilerId: Int? = nil)
        case link(url: String)
        case keywordHighlight
    }

    public var start: Int
    public var length: Int
    public var kind: Kind

    public init(start: Int, length: Int, kind: Kind) {
        self.start = start
        self.length = length
        self.kind = kind
    }

    var isMention: Bool { if case .mention = kind { true } else { false } }
}

/// `DisplayNode`
public struct DisplayNode: Sendable, Hashable {
    public var text: String
    public var start: Int
    public var length: Int
    /// Mentions inside the node, `start` relative to the node.
    public var mentions: [BodyRange] = []
    public var isBold = false
    public var isItalic = false
    public var isMonospace = false
    public var isSpoiler = false
    public var isStrikethrough = false
    public var isKeywordHighlight = false
    public var url: String?
    public var spoilerId: Int?
    public var spoilerChildren: [DisplayNode]?
}

public enum BodyRanges {
    /// UTF-16 slice, as JavaScript's `String.prototype.slice`.
    static func slice(_ s: String, _ start: Int, _ end: Int) -> String {
        let ns = s as NSString
        let a = max(0, min(start, ns.length)), b = max(a, min(end, ns.length))
        return ns.substring(with: NSRange(location: a, length: b - a))
    }

    static func utf16Length(_ s: String) -> Int { (s as NSString).length }

    /// `collapseRangesToDisplayNodes`
    public static func collapseToDisplayNodes(_ text: String, _ ranges: [BodyRange]) -> [DisplayNode] {
        let n = utf16Length(text)
        guard n > 0 else { return [] }
        enum Flag: Hashable { case bold, italic, monospace, strikethrough, keyword }
        struct Events { var start: [Flag] = []; var end: [Flag] = []; var spoilerStart: Int?? = nil; var spoilerEnd = false
            var linkStart: String? = nil; var linkEnd = false }
        var mentions: [BodyRange] = []
        var boundaries: Set<Int> = [0, n]
        var events: [Int: Events] = [:]
        for range in ranges {
            if range.isMention { mentions.append(range); continue }
            let start = max(0, min(range.start, n)), end = max(0, min(range.start + range.length, n))
            guard end > start else { continue }
            boundaries.insert(start)
            boundaries.insert(end)
            switch range.kind {
            case .link(let url):
                events[start, default: Events()].linkStart = url
                events[end, default: Events()].linkEnd = true
            case .keywordHighlight:
                events[start, default: Events()].start.append(.keyword)
                events[end, default: Events()].end.append(.keyword)
            case .formatting(.spoiler, let id):
                events[start, default: Events()].spoilerStart = .some(id)
                events[end, default: Events()].spoilerEnd = true
            case .formatting(let style, _):
                let flag: Flag? = switch style {
                case .bold: .bold
                case .italic: .italic
                case .monospace: .monospace
                case .strikethrough: .strikethrough
                default: nil
                }
                if let flag {
                    events[start, default: Events()].start.append(flag)
                    events[end, default: Events()].end.append(flag)
                }
            case .mention: break
            }
        }
        let points = boundaries.sorted()
        var count: [Flag: Int] = [:]
        var spoiler: Int?? = nil
        var link: String?
        var nodes: [DisplayNode] = []
        mentions.sort { $0.start < $1.start }
        var nextMention = 0
        for i in 0..<(points.count - 1) {
            let start = points[i], end = points[i + 1]
            if let e = events[start] {
                for f in e.end { count[f, default: 0] -= 1 }
                for f in e.start { count[f, default: 0] += 1 }
                spoiler = e.spoilerStart ?? (e.spoilerEnd ? nil : spoiler)
                link = e.linkStart ?? (e.linkEnd ? nil : link)
            }
            var nodeMentions: [BodyRange] = []
            while nextMention < mentions.count, mentions[nextMention].start < end {
                var m = mentions[nextMention]
                m.start -= start
                nodeMentions.append(m)
                nextMention += 1
            }
            var node = DisplayNode(text: slice(text, start, end), start: start, length: end - start, mentions: nodeMentions)
            node.isBold = count[.bold, default: 0] > 0
            node.isItalic = count[.italic, default: 0] > 0
            node.isMonospace = count[.monospace, default: 0] > 0
            node.isStrikethrough = count[.strikethrough, default: 0] > 0
            node.isKeywordHighlight = count[.keyword, default: 0] > 0
            node.url = link
            if let s = spoiler {
                node.isSpoiler = true
                node.spoilerId = s
            }
            nodes.append(node)
        }
        return nodes
    }

    /// `groupContiguousSpoilers`
    public static func groupContiguousSpoilers(_ nodes: [DisplayNode]) -> [DisplayNode] {
        var result: [DisplayNode] = []
        var containerIndex: Int?
        for node in nodes {
            if node.isSpoiler {
                if let i = containerIndex, let id = result[i].spoilerId, id == node.spoilerId {
                    result[i].spoilerChildren = (result[i].spoilerChildren ?? []) + [node]
                } else {
                    var container = node
                    container.isSpoiler = true
                    container.spoilerChildren = [node]
                    result.append(container)
                    containerIndex = result.count - 1
                }
            } else {
                containerIndex = nil
                result.append(node)
            }
        }
        return result
    }

    static let snippetLeft = "<<left>>", snippetRight = "<<right>>", snippetTruncation = "<<truncation>>"
    static let truncationChar = "..."

    /// `processBodyRangesForSearchResult`: the snippet without its FTS markers (truncation as
    /// "..."), the body's ranges moved onto it, plus a keyword highlight per match.
    public static func processForSearchResult(snippet: String, body: String, bodyRanges: [BodyRange]) -> (String, [BodyRange]) {
        let cleaned = snippet.replacingOccurrences(of: snippetLeft, with: "").replacingOccurrences(of: snippetRight, with: "")
        var withNoStart = cleaned
        if withNoStart.hasPrefix(snippetTruncation) { withNoStart.removeFirst(snippetTruncation.count) }
        var withNoEnd = withNoStart
        if withNoEnd.hasSuffix(snippetTruncation) { withNoEnd.removeLast(snippetTruncation.count) }
        var final = cleaned
        if final.hasPrefix(snippetTruncation) { final = truncationChar + final.dropFirst(snippetTruncation.count) }
        if final.hasSuffix(snippetTruncation) { final = final.dropLast(snippetTruncation.count) + truncationChar }
        let truncationDelta = utf16Length(withNoStart) != utf16Length(cleaned) ? utf16Length(truncationChar) : 0

        let found = (body as NSString).range(of: withNoEnd)
        let startOfSnippet = found.location == NSNotFound ? 0 : found.location
        let endOfSnippet = startOfSnippet + utf16Length(withNoEnd)
        var adjusted: [BodyRange] = bodyRanges.filter { $0.start + $0.length > startOfSnippet && $0.start < endOfSnippet }.map { r in
            let normalized = r.start - startOfSnippet + truncationDelta
            let start = max(normalized, truncationDelta)
            let end = min(normalized + r.length, utf16Length(withNoEnd) + truncationDelta)
            return BodyRange(start: start, length: end - start, kind: r.kind)
        }

        // Matches of <<left>>(.*?)<<right>> in the raw snippet.
        let ns = snippet as NSString
        var skipped = 0
        var searchFrom = 0
        let leftLen = utf16Length(snippetLeft), rightLen = utf16Length(snippetRight)
        while true {
            let l = ns.range(of: snippetLeft, range: NSRange(location: searchFrom, length: ns.length - searchFrom))
            guard l.location != NSNotFound else { break }
            let afterLeft = l.location + leftLen
            let r = ns.range(of: snippetRight, range: NSRange(location: afterLeft, length: ns.length - afterLeft))
            guard r.location != NSNotFound else { break }
            let shift = truncationDelta != 0 ? utf16Length(truncationChar) - utf16Length(snippetTruncation) : 0
            adjusted.append(BodyRange(start: l.location - skipped + shift, length: r.location - afterLeft, kind: .keywordHighlight))
            skipped += leftLen + rightLen
            searchFrom = r.location + rightLen
        }
        return (final, adjusted)
    }
}
