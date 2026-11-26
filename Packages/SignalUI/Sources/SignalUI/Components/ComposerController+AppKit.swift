#if canImport(AppKit)
import AppKit
import SwiftUI

extension ComposerController {
    static let mentionKey = NSAttributedString.Key("SignalMention")
    static let stylesKey = NSAttributedString.Key("SignalStyles")

    /// The text view's content as runs (UTF-16 offsets), read through AttributedString.
    struct Run {
        var range: NSRange
        var text: String
        var mention: String?
        var styles: Int
        var attributes: AttributeContainer
    }

    func runs(_ ns: NSAttributedString) -> [Run] {
        guard let a = try? AttributedString(ns, including: \.signalComposer) else { return [] }
        var out: [Run] = []
        var offset = 0
        for run in a.runs {
            let text = String(a[run.range].characters)
            let n = text.utf16.count
            out.append(Run(range: NSRange(location: offset, length: n), text: text, mention: run.signalMention, styles: run.signalStyles ?? 0,
                           attributes: run.attributes))
            offset += n
        }
        return out
    }

    func mentionSpans() -> [NSRange] {
        guard let tv = textView else { return [] }
        return runs(tv.attributedString()).filter { $0.mention != nil }.map(\.range)
    }

    /// The composer's plain attributes (no mention or style; the font goes on in `converted`).
    static func plainContainer() -> AttributeContainer { AttributeContainer() }

    /// `a` for the text view, each piece in its font (UTF-16 lengths, in order). An
    /// AttributedString cannot hold an NSFont (not Sendable), so fonts go on after conversion.
    static func converted(_ a: AttributedString, fonts: [(length: Int, font: NSFont)]) -> NSAttributedString? {
        guard let ns = try? NSAttributedString(a, including: \.signalComposer) else { return nil }
        let out = NSMutableAttributedString(attributedString: ns)
        var offset = 0
        for f in fonts where f.length > 0 {
            guard offset + f.length <= out.length else { return nil }
            out.addAttribute(.font, value: f.font, range: NSRange(location: offset, length: f.length))
            offset += f.length
        }
        return out
    }

    /// Replaces the "@query" with the member's pill and a space.
    public func insertMention(_ m: Mention) {
        guard let tv = textView, let q = mentionQuery() else { return }
        var pill = AttributedString("@" + m.title, attributes: Self.plainContainer())
        pill.signalMention = m.aci
        pill.appKit.backgroundColor = NSColor.systemGray.withAlphaComponent(0.25)
        pill += AttributedString(" ", attributes: Self.plainContainer())
        let text = "@" + m.title + " "
        guard let ns = Self.converted(pill, fonts: [(text.utf16.count, Self.baseFont)]) else { return }
        tv.typingAttributes = Self.plainAttributes(tv)
        tv.insertText(ns, replacementRange: q.range)
        tv.typingAttributes = Self.plainAttributes(tv)
        onMentionQuery(nil)
    }

    /// Types `text` at the caret (replacing the selection) as plain text, keeping the pills
    /// and styles around it; false when no composer is attached or a draft is still to load.
    @discardableResult public func insert(_ text: String) -> Bool {
        guard let tv = textView, pendingDraft == nil else { return false }
        tv.typingAttributes = Self.plainAttributes(tv)
        tv.insertText(text, replacementRange: tv.selectedRange())
        tv.typingAttributes = Self.plainAttributes(tv)
        return true
    }

    // MARK: styles

    /// Toggles a style on the selection (all of it styled: removed, else added), or for the
    /// text typed next.
    public func toggle(_ style: BodyRange.Style) {
        guard let tv = textView, style != .none else { return }
        let bit = 1 << style.rawValue
        let sel = tv.selectedRange()
        if sel.length == 0 {
            var attrs = tv.typingAttributes
            let mask = (attrs[Self.stylesKey] as? Int ?? 0) ^ bit
            attrs[Self.stylesKey] = mask == 0 ? nil : mask
            Self.applyVisuals(&attrs, mask: mask, base: Self.baseFont)
            tv.typingAttributes = attrs
            return
        }
        let selected = runs(tv.attributedString().attributedSubstring(from: sel))
        let all = selected.allSatisfy { $0.styles & bit != 0 }
        var rebuilt = AttributedString()
        var fonts: [(length: Int, font: NSFont)] = []
        for run in selected {
            var piece = AttributedString(run.text, attributes: run.attributes)
            let mask = all ? run.styles & ~bit : run.styles | bit
            piece.signalStyles = mask == 0 ? nil : mask
            var dict: [NSAttributedString.Key: Any] = [Self.mentionKey: run.mention as Any]
            if run.mention == nil { dict[Self.mentionKey] = nil }
            Self.applyVisuals(&dict, mask: mask, base: Self.baseFont)
            fonts.append((run.text.utf16.count, dict[.font] as? NSFont ?? Self.baseFont))
            piece.appKit.strikethroughStyle = (dict[.strikethroughStyle] as? Int).map { NSUnderlineStyle(rawValue: $0) }
            if run.mention == nil { piece.appKit.backgroundColor = dict[.backgroundColor] as? NSColor }
            rebuilt += piece
        }
        guard let ns = Self.converted(rebuilt, fonts: fonts) else { return }
        // insertText fills attributes the new text lacks from the typing attributes (the old
        // style's): start from plain ones.
        tv.typingAttributes = Self.plainAttributes(tv)
        // Replacing text with the same characters keeps the old attributes: remove, then insert.
        tv.insertText("", replacementRange: sel)
        tv.typingAttributes = Self.plainAttributes(tv)
        tv.insertText(ns, replacementRange: NSRange(location: sel.location, length: 0))
        tv.setSelectedRange(sel)
    }

    static var baseFont: NSFont { LegacyType.body1().ctFont as NSFont }

    static func plainAttributes(_ tv: NSTextView) -> [NSAttributedString.Key: Any] {
        var attrs = tv.typingAttributes
        attrs[mentionKey] = nil
        attrs[stylesKey] = nil
        attrs[.backgroundColor] = nil
        attrs[.strikethroughStyle] = nil
        attrs[.font] = baseFont
        return attrs
    }

    /// The look of a style mask (the stored mask is what is sent).
    static func applyVisuals(_ attrs: inout [NSAttributedString.Key: Any], mask: Int, base: NSFont) {
        func has(_ s: BodyRange.Style) -> Bool { mask & (1 << s.rawValue) != 0 }
        var font = has(.monospace) ? NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: has(.bold) ? .bold : .regular) : base
        if !has(.monospace) {
            if has(.bold) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if has(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        }
        attrs[.font] = font
        attrs[.strikethroughStyle] = has(.strikethrough) ? NSUnderlineStyle.single.rawValue : nil
        if attrs[mentionKey] == nil { attrs[.backgroundColor] = has(.spoiler) ? NSColor.systemGray.withAlphaComponent(0.45) : nil }
    }

    func applyPendingDraft() {
        guard let tv = textView, ObjectIdentifier(tv) != staleView, let draft = pendingDraft else { return }
        pendingDraft = nil
        staleView = nil
        let (text, fonts) = Self.attributedWithFonts(body: draft.body, ranges: draft.ranges)
        guard let ns = Self.converted(text, fonts: fonts) else { return }
        tv.typingAttributes = Self.plainAttributes(tv)
        tv.insertText(ns, replacementRange: NSRange(location: 0, length: (tv.string as NSString).length))
        tv.typingAttributes = Self.plainAttributes(tv)
    }

    /// The composer content for a body and its ranges: each U+FFFC with a mention range becomes
    /// "@title" (a pill); style ranges set the style mask and its look.
    static func attributed(body: String, ranges: [BodyRange]) -> AttributedString { attributedWithFonts(body: body, ranges: ranges).text }

    /// `attributed`, with each piece's font for `converted`.
    static func attributedWithFonts(body: String, ranges: [BodyRange]) -> (text: AttributedString, fonts: [(length: Int, font: NSFont)]) {
        var fonts: [(length: Int, font: NSFont)] = []
        func piece(_ text: String, mask: Int, mention: String?) -> AttributedString {
            var a = AttributedString(text, attributes: plainContainer())
            var dict: [NSAttributedString.Key: Any] = [:]
            if let mention { dict[mentionKey] = mention }
            applyVisuals(&dict, mask: mask, base: baseFont)
            fonts.append((text.utf16.count, dict[.font] as? NSFont ?? baseFont))
            a.appKit.strikethroughStyle = (dict[.strikethroughStyle] as? Int).map { NSUnderlineStyle(rawValue: $0) }
            if mention != nil {
                a.signalMention = mention
                a.appKit.backgroundColor = NSColor.systemGray.withAlphaComponent(0.25)
            } else {
                a.appKit.backgroundColor = dict[.backgroundColor] as? NSColor
            }
            if mask != 0 { a.signalStyles = mask }
            return a
        }
        var out = AttributedString()
        for run in ComposerDraft.runs(body: body, ranges: ranges) {
            out += piece(run.text, mask: run.styles, mention: run.mention)
        }
        return (out, fonts)
    }

    // MARK: sending

    /// The message body (mentions as U+FFFC) and its ranges, in UTF-16 offsets of that body.
    public func outgoing() -> (body: String, ranges: [BodyRange]) {
        guard let tv = textView else { return ("", []) }
        return ComposerDraft.outgoing(runs(tv.attributedString()).map {
            ComposerDraft.Run(text: $0.text, mention: $0.mention, styles: $0.styles)
        })
    }
}
#endif
