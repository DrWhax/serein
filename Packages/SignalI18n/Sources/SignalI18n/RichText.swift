import Foundation

/// A formatted message with its rich-text structure: what upstream's `<I18n>` component
/// renders. Tags (`<bold>`, `<learnMoreLink>`, `<emojify>`, …) are not interpreted here;
/// they come back as names on runs and as ranges, for SignalUI to style.
public struct RichText: Sendable, Hashable {
    public struct Run: Sendable, Hashable {
        public enum Content: Sendable, Hashable {
            case text(String)
            /// An `I18nArgument.element(id)` placeholder.
            case element(String)
        }

        public let content: Content
        /// Enclosing tag names, outermost first.
        public let tags: [String]
    }

    /// One tag instance.
    public struct TagRange: Sendable, Hashable {
        public let name: String
        /// Range in `plainText`.
        public let range: Range<String.Index>
        /// Range in `runs`.
        public let runs: Range<Int>
        /// 0 for an outermost tag.
        public let depth: Int
    }

    /// Text and element runs in reading order. Adjacent text is split exactly where
    /// intl-messageformat splits it (at tag and element boundaries); empty text is dropped.
    public let runs: [Run]
    /// Every tag instance, in document (pre-) order.
    public let tagRanges: [TagRange]
    /// All text with each element replaced by U+FFFC OBJECT REPLACEMENT CHARACTER.
    public let plainText: String

    static let objectReplacement = "\u{FFFC}"

    init(parts: [FormattedPart]) {
        var runs: [Run] = []
        var ranges: [(name: String, start: Int, startRun: Int, depth: Int, end: Int, endRun: Int)] = []
        var text = ""
        var offsets: [Int] = [] // utf8 offset in `text` where each run starts
        func walk(_ parts: [FormattedPart], _ stack: [String]) {
            for part in parts {
                switch part {
                case .literal(let s):
                    guard !s.isEmpty else { continue }
                    offsets.append(text.utf8.count)
                    runs.append(Run(content: .text(s), tags: stack))
                    text += s
                case .element(let id):
                    offsets.append(text.utf8.count)
                    runs.append(Run(content: .element(id), tags: stack))
                    text += Self.objectReplacement
                case .tag(let name, let children):
                    let index = ranges.count
                    ranges.append((name, text.utf8.count, runs.count, stack.count, 0, 0))
                    walk(children, stack + [name])
                    ranges[index].end = text.utf8.count
                    ranges[index].endRun = runs.count
                }
            }
        }
        walk(parts, [])
        let utf8 = text.utf8
        self.runs = runs
        self.plainText = text
        self.tagRanges = ranges.map { r in
            TagRange(name: r.name,
                     range: utf8.index(utf8.startIndex, offsetBy: r.start)..<utf8.index(utf8.startIndex, offsetBy: r.end),
                     runs: r.startRun..<r.endRun,
                     depth: r.depth)
        }
    }

    /// Builds an `AttributedString`: `style` is called for each enclosing tag of each run,
    /// outermost first; `element` supplies the text for element placeholders.
    ///
    ///     Text(rich.attributedString { tag, attributes in
    ///         if tag == "bold" { attributes.inlinePresentationIntent = .stronglyEmphasized }
    ///     })
    public func attributedString(
        element: (String) -> AttributedString = { _ in AttributedString() },
        style: (String, inout AttributeContainer) -> Void
    ) -> AttributedString {
        var out = AttributedString()
        for run in runs {
            var piece: AttributedString
            switch run.content {
            case .text(let s): piece = AttributedString(s)
            case .element(let id): piece = element(id)
            }
            var container = AttributeContainer()
            for tag in run.tags { style(tag, &container) }
            piece.mergeAttributes(container)
            out += piece
        }
        return out
    }
}
