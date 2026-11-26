import Foundation

/// Converts between Signal's UTF-16 wire ranges and the visible runs of the desktop text editor.
enum ComposerDraft {
    struct Run: Equatable {
        var text: String
        var mention: String?
        var styles: Int
    }

    static func runs(body: String, ranges: [BodyRange]) -> [Run] {
        let units = Array(body.utf16)
        var masks = [Int](repeating: 0, count: units.count)
        var mentions: [Int: (aci: String, title: String)] = [:]
        for r in ranges where r.start >= 0 && r.length > 0 && r.length <= units.count && r.start <= units.count - r.length {
            switch r.kind {
            case .mention(let aci, _, let title) where r.length == 1 && units[r.start] == 0xFFFC:
                mentions[r.start] = (aci, title)
            case .formatting(let style, _) where style != .none:
                for i in r.start..<(r.start + r.length) { masks[i] |= 1 << style.rawValue }
            default: break
            }
        }
        var result: [Run] = []
        var i = 0
        while i < units.count {
            if let m = mentions[i] {
                result.append(Run(text: "@" + m.title, mention: m.aci, styles: masks[i]))
                i += 1
                continue
            }
            var j = i + 1
            while j < units.count, mentions[j] == nil, masks[j] == masks[i] { j += 1 }
            // Never split a surrogate pair.
            while j < units.count, UTF16.isTrailSurrogate(units[j]) { j += 1 }
            result.append(Run(text: String(decoding: units[i..<j], as: UTF16.self), mention: nil, styles: masks[i]))
            i = j
        }
        return result
    }

    static func outgoing(_ runs: [Run]) -> (body: String, ranges: [BodyRange]) {
        var body = ""
        var ranges: [BodyRange] = []
        var styleRuns: [(start: Int, length: Int, mask: Int)] = []
        var offset = 0
        for run in runs {
            let piece: String
            if let aci = run.mention {
                piece = "\u{FFFC}"
                ranges.append(BodyRange(start: offset, length: 1, kind: .mention(aci: aci, conversationID: aci, replacementText: String(run.text.dropFirst()))))
            } else {
                piece = run.text
            }
            let n = piece.utf16.count
            if run.styles != 0 { styleRuns.append((offset, n, run.styles)) }
            body += piece
            offset += n
        }
        for style in [BodyRange.Style.bold, .italic, .spoiler, .strikethrough, .monospace] {
            var current: (start: Int, end: Int)?
            for run in styleRuns {
                guard run.mask & (1 << style.rawValue) != 0 else { continue }
                if let c = current, c.end == run.start {
                    current = (c.start, run.start + run.length)
                } else {
                    if let c = current { ranges.append(BodyRange(start: c.start, length: c.end - c.start, kind: .formatting(style))) }
                    current = (run.start, run.start + run.length)
                }
            }
            if let c = current { ranges.append(BodyRange(start: c.start, length: c.end - c.start, kind: .formatting(style))) }
        }
        return (body, ranges)
    }
}
