// The live composer's rich text (upstream's Quill mention blots and formatting): mentions are
// "@name" pills that delete as one, and text can be bold, italic, strikethrough, monospace or a
// spoiler (⌘B, ⌘I, ⌘⇧X, ⌘E, ⌘⇧B, as upstream, or the context menu's Format items). The text
// view keeps them as attributes; `outgoing()` turns the text into the message body (each
// mention one U+FFFC, as on the wire) and its body ranges. `onMentionQuery` reports the
// "@query" being typed, for the suggestions (MentionSuggestions).

#if canImport(AppKit)
import AppKit
typealias ComposerEditor = NSTextView
#else
import Foundation
typealias ComposerEditor = LinuxComposerDocument
#endif
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

    weak var textView: ComposerEditor? {
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

    /// A deletion that touches a pill takes the whole pill.
    func expandDeletion(_ range: NSRange) -> NSRange {
        guard range.length > 0 else { return range }
        var out = range
        for span in mentionSpans() where NSIntersectionRange(span, range).length > 0 { out = NSUnionRange(out, span) }
        return out
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
        ComposerDraft.runs(body: body, ranges: ranges).map(\.text).joined()
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
        #if canImport(AppKit)
        let appKit: AttributeScopes.AppKitAttributes
        #endif
    }

    var signalComposer: SignalComposerAttributes.Type { SignalComposerAttributes.self }
}

extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.SignalComposerAttributes, T>) -> T { self[T.self] }
}
