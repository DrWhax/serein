#if os(Linux)
import Foundation
import SwiftUI

@MainActor @Observable final class LinuxComposerDocument {
    @ObservationIgnored var onTextChange: ((String) -> Void)?
    var text = AttributedString() { didSet { if !oldValue.characters.elementsEqual(text.characters) { onTextChange?(string) } } }
    var selection = AttributedTextSelection()
    var string: String { String(text.characters) }

    func selectedRange() -> NSRange {
        let range: Range<AttributedString.Index>
        switch selection.indices(in: text) {
        case .insertionPoint(let index): range = index..<index
        case .ranges(let set):
            guard let first = set.ranges.first else { return NSRange(location: string.utf16.count, length: 0) }
            range = first
        }
        let plain = string
        guard let converted = Range<String.Index>(range, in: plain) else { return NSRange(location: plain.utf16.count, length: 0) }
        return NSRange(converted, in: plain)
    }

    func replace(_ range: NSRange, with replacement: AttributedString) {
        let plain = string
        guard let plainRange = Range(range, in: plain),
              let span = Range<AttributedString.Index>(plainRange, in: text) else { return }
        let start = text.unicodeScalars.distance(from: text.startIndex, to: span.lowerBound)
        text.replaceSubrange(span, with: replacement)
        let end = text.index(text.startIndex, offsetByUnicodeScalars: start + replacement.unicodeScalars.count)
        selection = .init(insertionPoint: end, typingAttributes: AttributeContainer())
    }

    /// Qt reports the edited text along with all attributes retained by its native document.
    /// A deletion into a pill removes the whole mention, just like the macOS editor delegate.
    func receive(_ edited: AttributedString) {
        guard edited != text else { return }
        let before = string, after = String(edited.characters)
        if after.utf16.count < before.utf16.count {
            let old = Array(before.utf16), new = Array(after.utf16)
            var prefix = 0
            while prefix < new.count && old[prefix] == new[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < new.count - prefix && old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
            if prefix + suffix == new.count {
                let deletion = NSRange(location: prefix, length: old.count - new.count)
                var expanded = deletion
                for span in mentionSpans where NSIntersectionRange(span, deletion).length > 0 { expanded = NSUnionRange(expanded, span) }
                if expanded != deletion {
                    replace(expanded, with: AttributedString())
                    return
                }
            }
        }
        text = edited
    }

    var mentionSpans: [NSRange] {
        let plain = string
        return text.runs.compactMap { run in
            guard run.signalMention != nil, let range = Range<String.Index>(run.range, in: plain) else { return nil }
            return NSRange(range, in: plain)
        }
    }

    static func style(_ attrs: inout AttributeContainer, mask: Int) {
        func has(_ s: BodyRange.Style) -> Bool { mask & (1 << s.rawValue) != 0 }
        attrs.signalStyles = mask == 0 ? nil : mask
        let size = LegacyType.body1().size
        if has(.monospace) {
            attrs.font = .system(size: size, weight: has(.bold) ? .bold : .regular, design: .monospaced)
        } else {
            attrs.font = .custom(AxoFonts.interName(weight: has(.bold) ? 700 : 400, italic: has(.italic)), fixedSize: size)
        }
        attrs.strikethroughStyle = has(.strikethrough) ? .single : nil
        attrs.backgroundColor = attrs.signalMention == nil ? (has(.spoiler) ? Color.gray.opacity(0.45) : nil) : Color.gray.opacity(0.25)
    }
}

extension ComposerController {
    func mentionSpans() -> [NSRange] { textView?.mentionSpans ?? [] }

    public func insertMention(_ mention: Mention) {
        guard let editor = textView, let query = mentionQuery() else { return }
        var attrs = AttributeContainer()
        attrs.signalMention = mention.aci
        LinuxComposerDocument.style(&attrs, mask: 0)
        editor.replace(query.range, with: AttributedString("@" + mention.title, attributes: attrs) + AttributedString(" "))
        onMentionQuery(nil)
    }

    @discardableResult public func insert(_ text: String) -> Bool {
        guard let editor = textView, pendingDraft == nil else { return false }
        editor.replace(editor.selectedRange(), with: AttributedString(text))
        return true
    }

    public func toggle(_ style: BodyRange.Style) {
        guard let editor = textView, style != .none else { return }
        let bit = 1 << style.rawValue
        var selection = editor.selection
        let all = selection.attributes(in: editor.text).allSatisfy { ($0.signalStyles ?? 0) & bit != 0 }
        editor.text.transformAttributes(in: &selection) { attrs in
            let mask = attrs.signalStyles ?? 0
            LinuxComposerDocument.style(&attrs, mask: all ? mask & ~bit : mask | bit)
        }
        editor.selection = selection
    }

    func applyPendingDraft() {
        guard let editor = textView, ObjectIdentifier(editor) != staleView, let draft = pendingDraft else { return }
        pendingDraft = nil
        staleView = nil
        var text = AttributedString()
        for run in ComposerDraft.runs(body: draft.body, ranges: draft.ranges) {
            var attrs = AttributeContainer()
            attrs.signalMention = run.mention
            LinuxComposerDocument.style(&attrs, mask: run.styles)
            text += AttributedString(run.text, attributes: attrs)
        }
        editor.text = text
        editor.selection = .init(insertionPoint: text.endIndex, typingAttributes: AttributeContainer())
    }

    public func outgoing() -> (body: String, ranges: [BodyRange]) {
        guard let editor = textView else { return ("", []) }
        return ComposerDraft.outgoing(editor.text.runs.map {
            ComposerDraft.Run(text: String(editor.text[$0.range].characters), mention: $0.signalMention, styles: $0.signalStyles ?? 0)
        })
    }
}
#endif
