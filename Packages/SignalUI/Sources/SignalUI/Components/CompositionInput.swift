// Port of ts/components/CompositionInput.dom.tsx (+ stylesheets/components/CompositionInput.scss):
// the message field. An 18px-rounded incoming-surface pill (1px ultramarine border while
// keyboard-focused) whose scroller (6px above and below, 30–70px tall, 210px when large)
// holds the editor: body-1 text 12px in, "Message" in gray-45 / gray-25 when empty, mentions
// as gray-20 pills, emoji at the text size. With the view-once button the icon sits 8px from
// the end; while view-once is on, the text is hidden behind "View once media".
//
// Editing runs in an NSTextView (ComposerTextView); offscreen rendering draws the same text
// with CSSText, scrolled to the end as Quill leaves it. Not ported yet: the formatting menu,
// emoji / mention completion popovers, the recovery-key paste warning, edit-message banner.

import AppKit
import SignalI18n
import SwiftUI

/// A mention in the draft (`DraftBodyRange` with `mentionAci`): `length` characters at
/// `start` stand for "@" + `replacementText`.
public struct ComposerMention: Sendable, Hashable {
    public var start: Int
    public var length: Int
    public var replacementText: String
    public init(start: Int, length: Int, replacementText: String) {
        self.start = start
        self.length = length
        self.replacementText = replacementText
    }
}

public struct CompositionInput: View {
    /// `.CompositionTextArea__input` restyles the input as a borderless, square text area
    /// (the forward and GIF-send modals): 16px padding (36px at the end, for the floating emoji
    /// button), 100–300px tall, a 1px ultramarine border when focused.
    public enum Variant: Sendable { case composer, textArea }
    @Binding var text: String
    let variant: Variant
    let mentions: [ComposerMention]
    let placeholder: String?
    let large: Bool
    let disabled: Bool
    let isActive: Bool
    let showViewOnceButton: Bool
    let isViewOnceActive: Bool
    let onToggleViewOnce: () -> Void
    let onSubmit: () -> Void
    @State private var focused = false
    @Environment(\.i18n) var i18n
    @Environment(\.axoStaticRendering) var staticRendering

    public init(text: Binding<String>, mentions: [ComposerMention] = [], placeholder: String? = nil, large: Bool = false, disabled: Bool = false,
                isActive: Bool = true, showViewOnceButton: Bool = false, isViewOnceActive: Bool = false,
                onToggleViewOnce: @escaping () -> Void = {}, onSubmit: @escaping () -> Void = {}, variant: Variant = .composer) {
        self.variant = variant
        _text = text
        self.mentions = mentions
        self.placeholder = placeholder
        self.large = large
        self.disabled = disabled
        self.isActive = isActive
        self.showViewOnceButton = showViewOnceButton
        self.isViewOnceActive = isViewOnceActive
        self.onToggleViewOnce = onToggleViewOnce
        self.onSubmit = onSubmit
    }

    static let border: CGFloat = 1
    static var minHeight: CGFloat { 32 - 2 * border }
    static var maxHeight: CGFloat { 72 - 2 * border }
    static var largeHeight: CGFloat { 212 - 2 * border }

    /// Focused on open while active (Quill focuses itself), shown as keyboard focus.
    var showsFocus: Bool { !disabled && !isViewOnceActive && (focused || (staticRendering && isActive)) }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: variant == .textArea ? 0 : 18)
        HStack(alignment: .center, spacing: 0) {
            scroller
            if showViewOnceButton {
                SwiftUI.Button(action: onToggleViewOnce) {
                    AxoSymbol.Icon(isViewOnceActive ? "viewonce" : "viewonce-slash", size: 20, label: nil)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(i18n("icu:CompositionArea--viewOnceToggle"))
                .accessibilityLabel(i18n("icu:CompositionArea--viewOnceToggle"))
                .padding(.leading, 4)
                .padding(.trailing, 8)
            }
        }
        .overlay {
            if isViewOnceActive {
                CSSText(i18n("icu:CompositionArea--viewOnceMediaPlaceholder"), style: LegacyType.body1(), wrap: .nowrap,
                        color: AxoColor(light: LegacyColor.gray45, dark: LegacyColor.gray25))
                    .allowsHitTesting(false)
            }
        }
        .padding(Self.border)        // the 1px border (transparent unless focused)
        .background(shape.fill(variant == .textArea ? AxoColor(RGBA(0, 0, 0, 0)) : AxoColor.surfaceMessageIncoming))
        .clipShape(shape)
        .overlay(shape.strokeBorder(showsFocus ? AxoColor(LegacyColor.ultramarine) : AxoColor(RGBA(0, 0, 0, 0)), lineWidth: Self.border))
        .cssTextColor(.labelPrimary)
    }

    /// The draft as runs: text with mentions as "@name" pills and emoji boxes.
    var runs: [CSSTextRun] {
        var out: [CSSTextRun] = []
        let units = Array(text.utf16)
        var i = 0
        for m in mentions.sorted(by: { $0.start < $1.start }) where m.start >= i && m.start + m.length <= units.count {
            if m.start > i { out.append(Emojify.run(String(decoding: units[i..<m.start], as: UTF16.self))) }
            var pill = CSSTextRun.inlineBlock("@" + m.replacementText, CSSInlineBlock(paddingInline: 4, background: AxoColor(light: LegacyColor.gray20, dark: LegacyColor.gray60), radius: 4))
            pill.emojify = true
            out.append(pill)
            i = m.start + m.length
        }
        if i < units.count { out.append(Emojify.run(String(decoding: units[i...], as: UTF16.self))) }
        // Quill inserts emoji as FunStaticEmoji blots.
        for j in out.indices { out[j].emojiStaticBlot = true }
        return out
    }

    @ViewBuilder var scroller: some View {
        let style = LegacyType.body1()
        let textArea = variant == .textArea
        let minH = textArea ? 100 : Self.minHeight, maxH = textArea ? 300 : large ? Self.largeHeight : Self.maxHeight
        // The scroller's padding (6px block; 16px, 36px at the end, in a text area) plus
        // Quill's 12px inline padding.
        let pad = textArea ? EdgeInsets(top: 16, leading: 28, bottom: 16, trailing: 48) : EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        Group {
            if isViewOnceActive {
                Color.clear.frame(height: 32)
            } else if staticRendering {
                let content = Group {
                    if text.isEmpty {
                        CSSText(placeholder ?? i18n("icu:sendMessage"), style: style, wrap: .wrap,
                                color: AxoColor(light: LegacyColor.gray45, dark: LegacyColor.gray25))
                    } else {
                        CSSText(runs: runs, style: style, wrap: .wrap)
                    }
                }
                .padding(pad)     // inside the scrolling box
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                // Quill scrolls the caret into view: on overflow the caret's bottom sits on the
                // viewport's bottom edge. After text the caret is Inter's content area (line top
                // + 18, so the line box hangs 2px past the edge); after an emoji blot it is the
                // 20px box. The bottom padding stays below the viewport.
                let caretInset: CGFloat = text.last.map { CSSTextLayout.isEmoji($0) } == true ? 0 : 2
                ScrollEndClip(minHeight: minH, maxHeight: maxH, fixedHeight: large ? maxH : nil, overflowBottomInset: pad.bottom + caretInset) { content }
            } else {
                ComposerTextView(text: $text, placeholder: placeholder ?? i18n("icu:sendMessage"), disabled: disabled, autoFocus: isActive,
                                 focused: $focused, onSubmit: onSubmit)
                    .padding(.leading, pad.leading).padding(.trailing, pad.trailing)
                    .frame(minHeight: minH - pad.top - pad.bottom, maxHeight: maxH - pad.top - pad.bottom)
                    .frame(height: large && !textArea ? maxH - pad.top - pad.bottom : nil)
                    .padding(.top, pad.top).padding(.bottom, pad.bottom)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Sizes to its content between `minHeight` and `maxHeight` (or `fixedHeight`), pinning the
/// content's bottom when it overflows (a scroller scrolled to the end), or its top otherwise.
struct ScrollEndClip<Content: View>: View {
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let fixedHeight: CGFloat?
    let overflowBottomInset: CGFloat
    let content: Content
    init(minHeight: CGFloat, maxHeight: CGFloat, fixedHeight: CGFloat?, overflowBottomInset: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.fixedHeight = fixedHeight
        self.overflowBottomInset = overflowBottomInset
        self.content = content()
    }
    var body: some View {
        ScrollEndLayout(minHeight: minHeight, maxHeight: maxHeight, fixedHeight: fixedHeight, overflowBottomInset: overflowBottomInset) { content }.clipped()
    }
}

struct ScrollEndLayout: Layout {
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let fixedHeight: CGFloat?
    var overflowBottomInset: CGFloat = 0
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let h = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)).height ?? 0
        return CGSize(width: proposal.width ?? 0, height: fixedHeight ?? min(max(h, minHeight), maxHeight))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let s = subviews.first else { return }
        let h = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
        let y = h > bounds.height ? bounds.maxY - h + overflowBottomInset : bounds.minY
        s.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
    }
}

/// The live editor: an NSTextView in Inter 14 / 20, no insets. Return sends; Shift-Return
/// (or Option-Return) inserts a line break.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let disabled: Bool
    let autoFocus: Bool
    @Binding var focused: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        // Our own TextKit 2 stack (NSTextView.textContainer is unowned(unsafe)).
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        let layout = NSTextLayoutManager()
        layout.textContainer = container
        let content = NSTextContentStorage()
        content.addTextLayoutManager(layout)
        context.coordinator.content = content
        let tv = PlaceholderTextView(frame: .zero, textContainer: container)
        tv.placeholder = placeholder
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.allowsUndo = true
        let style = LegacyType.body1()
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = style.lineHeight
        para.maximumLineHeight = style.lineHeight
        tv.typingAttributes = [.font: style.ctFont as NSFont, .paragraphStyle: para, .kern: style.letterSpacing,
                               .foregroundColor: NSColor.labelColor]
        tv.string = text
        scroll.documentView = tv
        if autoFocus { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(tv) } }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        tv.isEditable = !disabled
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        /// Keeps the TextKit 2 content storage alive with the view.
        var content: NSTextContentStorage?
        init(_ parent: ComposerTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
        func textDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func textDidEndEditing(_ notification: Notification) { parent.focused = false }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let mods = NSApp.currentEvent?.modifierFlags ?? []
                if mods.contains(.shift) || mods.contains(.option) { return false }
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

/// NSTextView drawing its placeholder while empty.
final class PlaceholderTextView: NSTextView {
    var placeholder = ""
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let style = LegacyType.body1()
        let attrs: [NSAttributedString.Key: Any] = [.font: style.ctFont as NSFont, .foregroundColor: NSColor.placeholderTextColor]
        (placeholder as NSString).draw(at: NSPoint(x: 0, y: 0), withAttributes: attrs)
    }
}
