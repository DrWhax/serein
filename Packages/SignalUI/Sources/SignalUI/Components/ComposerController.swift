// The live composer's rich text (upstream's Quill mention blots and formatting): mentions are
// "@name" pills that delete as one, and text can be bold, italic, strikethrough, monospace or a
// spoiler (⌘B, ⌘I, ⌘⇧X, ⌘E, ⌘⇧B, as upstream, or the context menu's Format items). The text
// view keeps them as attributes; `outgoing()` turns the text into the message body (each
// mention one U+FFFC, as on the wire) and its body ranges. `onMentionQuery` reports the
// "@query" being typed, for the suggestions (MentionSuggestions).

import AppKit
import SignalI18n
import SwiftUI

@MainActor public final class ComposerController {
    public struct Mention: Sendable, Hashable, Identifiable {
        public var aci: String
        public var title: String
        public var color: String
        public var avatar: RGBAImage?
        public var id: String { aci }
        public init(aci: String, title: String, color: String = "A200", avatar: RGBAImage? = nil) {
            self.aci = aci
            self.title = title
            self.color = color
            self.avatar = avatar
        }
    }

    weak var textView: NSTextView? {
        // A draft loaded before the chat's composer existed goes in once it attaches (after
        // the SwiftUI update that attached it: the edit updates the text binding).
        didSet { if textView !== oldValue, pendingDraft != nil { Task { @MainActor in self.applyPendingDraft() } } }
    }
    /// A saved draft waiting for the text view.
    var pendingDraft: (body: String, ranges: [BodyRange])?
    /// The view a draft must not go into (the chat being left, still attached when the next
    /// chat's draft is loaded).
    var staleView: ObjectIdentifier?
    /// The "@query" before the caret (nil: none), on every edit or caret move.
    public var onMentionQuery: (String?) -> Void = { _ in }
    /// Enter / Tab while suggestions show: pick the first (true: handled).
    public var pickFirstMention: (() -> Bool)?
    /// Escape while suggestions show: hide them until the query changes.
    var dismissedQueryAt: Int?

    public init() {}

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

    // MARK: mentions

    /// The "@query" before the caret: its range (the "@" included) and text.
    func mentionQuery() -> (range: NSRange, query: String)? {
        guard let tv = textView else { return nil }
        let caret = tv.selectedRange()
        let ns = tv.string as NSString
        guard caret.length == 0, caret.location <= ns.length else { return nil }
        let spans = mentionSpans()
        var i = caret.location
        while i > 0 {
            let c = ns.character(at: i - 1)
            if c == 0x40 {    // "@"
                let before = i - 2 >= 0 ? ns.character(at: i - 2) : 0x20
                guard i - 1 == 0 || CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(before) ?? " ") else { return nil }
                if spans.contains(where: { NSLocationInRange(i - 1, $0) }) { return nil }
                let range = NSRange(location: i - 1, length: caret.location - (i - 1))
                return (range, ns.substring(with: NSRange(location: i, length: caret.location - i)))
            }
            if CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(c) ?? " ") { return nil }
            i -= 1
        }
        return nil
    }

    func reportMentionQuery() {
        let q = mentionQuery()
        if let dismissed = dismissedQueryAt, q?.range.location == dismissed { return onMentionQuery(nil) }
        dismissedQueryAt = nil
        onMentionQuery(q?.query)
    }

    func dismissMentions() -> Bool {
        guard let q = mentionQuery() else { return false }
        dismissedQueryAt = q.range.location
        onMentionQuery(nil)
        return true
    }

    /// The composer's plain attributes (the base font, no mention or style).
    static func plainContainer() -> AttributeContainer {
        var c = AttributeContainer()
        c.appKit.font = baseFont
        return c
    }

    /// Replaces the "@query" with the member's pill and a space.
    public func insertMention(_ m: Mention) {
        guard let tv = textView, let q = mentionQuery() else { return }
        var pill = AttributedString("@" + m.title, attributes: Self.plainContainer())
        pill.signalMention = m.aci
        pill.appKit.backgroundColor = NSColor.systemGray.withAlphaComponent(0.25)
        pill += AttributedString(" ", attributes: Self.plainContainer())
        guard let ns = try? NSAttributedString(pill, including: \.signalComposer) else { return }
        tv.typingAttributes = Self.plainAttributes(tv)
        tv.insertText(ns, replacementRange: q.range)
        tv.typingAttributes = Self.plainAttributes(tv)
        onMentionQuery(nil)
    }

    /// A deletion that touches a pill takes the whole pill.
    func expandDeletion(_ range: NSRange) -> NSRange {
        guard range.length > 0 else { return range }
        var out = range
        for span in mentionSpans() where NSIntersectionRange(span, range).length > 0 { out = NSUnionRange(out, span) }
        return out
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
        for run in selected {
            var piece = AttributedString(run.text, attributes: run.attributes)
            let mask = all ? run.styles & ~bit : run.styles | bit
            piece.signalStyles = mask == 0 ? nil : mask
            var dict: [NSAttributedString.Key: Any] = [Self.mentionKey: run.mention as Any]
            if run.mention == nil { dict[Self.mentionKey] = nil }
            Self.applyVisuals(&dict, mask: mask, base: Self.baseFont)
            piece.appKit.font = dict[.font] as? NSFont
            piece.appKit.strikethroughStyle = (dict[.strikethroughStyle] as? Int).map { NSUnderlineStyle(rawValue: $0) }
            if run.mention == nil { piece.appKit.backgroundColor = dict[.backgroundColor] as? NSColor }
            rebuilt += piece
        }
        guard let ns = try? NSAttributedString(rebuilt, including: \.signalComposer) else { return }
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

    // MARK: drafts

    /// Puts a saved draft (mentions as U+FFFC, `outgoing()`'s form) into the composer: the
    /// mention pills and styles come back as they were typed.
    /// `intoNewView`: wait for the next chat's text view instead of the one attached now.
    public func load(body: String, ranges: [BodyRange], intoNewView: Bool = false) {
        pendingDraft = (body, ranges)
        staleView = intoNewView ? textView.map(ObjectIdentifier.init) : nil
        applyPendingDraft()
    }

    /// Drops a draft that has not gone in yet (the chat was left first).
    public func cancelPendingDraft() { pendingDraft = nil }

    /// The text a draft shows (mentions as "@title").
    public static func displayText(body: String, ranges: [BodyRange]) -> String {
        String(attributed(body: body, ranges: ranges).characters)
    }

    func applyPendingDraft() {
        guard let tv = textView, ObjectIdentifier(tv) != staleView, let draft = pendingDraft else { return }
        pendingDraft = nil
        staleView = nil
        guard let ns = try? NSAttributedString(Self.attributed(body: draft.body, ranges: draft.ranges), including: \.signalComposer) else { return }
        tv.typingAttributes = Self.plainAttributes(tv)
        tv.insertText(ns, replacementRange: NSRange(location: 0, length: (tv.string as NSString).length))
        tv.typingAttributes = Self.plainAttributes(tv)
    }

    /// The composer content for a body and its ranges: each U+FFFC with a mention range becomes
    /// "@title" (a pill); style ranges set the style mask and its look.
    static func attributed(body: String, ranges: [BodyRange]) -> AttributedString {
        let units = Array(body.utf16)
        var masks = [Int](repeating: 0, count: units.count)
        var mentions: [Int: (aci: String, title: String)] = [:]
        for r in ranges where r.start >= 0 && r.length > 0 && r.start + r.length <= units.count {
            switch r.kind {
            case .mention(let aci, _, let title) where r.length == 1 && units[r.start] == 0xFFFC:
                mentions[r.start] = (aci, title)
            case .formatting(let style, _) where style != .none:
                for i in r.start..<(r.start + r.length) { masks[i] |= 1 << style.rawValue }
            default: break
            }
        }
        func piece(_ text: String, mask: Int, mention: String?) -> AttributedString {
            var a = AttributedString(text, attributes: plainContainer())
            var dict: [NSAttributedString.Key: Any] = [:]
            if let mention { dict[mentionKey] = mention }
            applyVisuals(&dict, mask: mask, base: baseFont)
            a.appKit.font = dict[.font] as? NSFont
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
        var i = 0
        while i < units.count {
            if let m = mentions[i] {
                out += piece("@" + m.title, mask: masks[i], mention: m.aci)
                i += 1
                continue
            }
            var j = i + 1
            while j < units.count, mentions[j] == nil, masks[j] == masks[i] { j += 1 }
            // Never split a surrogate pair.
            while j < units.count, UTF16.isTrailSurrogate(units[j]) { j += 1 }
            out += piece(String(decoding: units[i..<j], as: UTF16.self), mask: masks[i], mention: nil)
            i = j
        }
        return out
    }

    // MARK: sending

    /// The message body (mentions as U+FFFC) and its ranges, in UTF-16 offsets of that body.
    public func outgoing() -> (body: String, ranges: [BodyRange]) {
        guard let tv = textView else { return ("", []) }
        var body = ""
        var ranges: [BodyRange] = []
        var styleRuns: [(start: Int, length: Int, mask: Int)] = []
        var offset = 0
        for run in runs(tv.attributedString()) {
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

extension EnvironmentValues {
    /// The live composer's controller (mentions, styles, the outgoing body).
    @Entry public var composerController: ComposerController? = nil
}

/// `module-composition-input__suggestions`: the members matching the "@query", above the input
/// (white / gray-75, 8px radius, the popper shadow; 40px rows of a 28px avatar and the name).
public struct MentionSuggestions: View {
    let members: [ComposerController.Mention]
    let onPick: (ComposerController.Mention) -> Void
    @State private var hovered: String?
    @Environment(\.i18n) var i18n

    public init(members: [ComposerController.Mention], onPick: @escaping (ComposerController.Mention) -> Void) {
        self.members = members
        self.onPick = onPick
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(members.enumerated()), id: \.element.id) { i, m in
                    let selected = hovered == m.aci || (hovered == nil && i == 0)
                    SwiftUI.Button { onPick(m) } label: {
                        HStack(spacing: 0) {
                            Avatar(strings: AvatarStrings(i18n: i18n), title: m.title, size: 28, conversationType: .direct, color: m.color,
                                   image: m.avatar.map { AnyView(PixelImage($0, fit: .cover)) })
                            CSSText(m.title, style: LegacyType.body2(), wrap: .truncate,
                                    color: selected ? AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05)
                                                    : AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25))
                                .padding(.leading, 8)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(selected ? AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray60) : AxoColor(RGBA(0, 0, 0, 0)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? m.aci : (hovered == m.aci ? nil : hovered) }
                }
            }
        }
        .frame(maxHeight: min(300, CGFloat(members.count) * 40))
        .background(RoundedRectangle(cornerRadius: 8).fill(AxoColor(light: LegacyColor.white, dark: LegacyColor.gray75)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.04), radius: 2)
        .shadow(color: .black.opacity(0.12), radius: 4, y: 4)
        .padding(.bottom, 6)
    }
}

/// The composer's own attributes: a mention's ACI, and the style mask (1 << BodyRange.Style).
enum SignalMentionAttribute: CodableAttributedStringKey {
    typealias Value = String
    static let name = "SignalMention"
}

enum SignalStylesAttribute: CodableAttributedStringKey {
    typealias Value = Int
    static let name = "SignalStyles"
}

extension AttributeScopes {
    struct SignalComposerAttributes: AttributeScope {
        let signalMention: SignalMentionAttribute
        let signalStyles: SignalStylesAttribute
        let appKit: AttributeScopes.AppKitAttributes
    }

    var signalComposer: SignalComposerAttributes.Type { SignalComposerAttributes.self }
}

extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.SignalComposerAttributes, T>) -> T { self[T.self] }
}
