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
    ///
    /// `.StoryViewsNRepliesModal__input`: a gray-75 pill with a gray-75 border (focused or
    /// not), at least 36px tall, its children (the emoji button) centred at the start.
    public enum Variant: Sendable { case composer, textArea, storyReply }
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
    /// `children`: drawn before the scroller (FunEmojiPickerButton).
    var leading: AnyView?
    /// `CompositionInput__link-preview`: the staged link preview, above the text.
    var linkPreview: AnyView?
    @State private var focused = false
    @Environment(\.i18n) var i18n
    @Environment(\.axoStaticRendering) var staticRendering
    @Environment(\.composerKeys) var keys

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
    /// The live composer's height limit in lines (requested; upstream's box fits about three).
    static let liveMaxLines = 4

    /// Focused on open while active (Quill focuses itself), shown as keyboard focus.
    var showsFocus: Bool { !disabled && !isViewOnceActive && (focused || (staticRendering && isActive)) }

    /// `children`
    public func leading(_ view: some View) -> CompositionInput {
        var copy = self
        copy.leading = AnyView(view)
        return copy
    }

    /// The staged link preview (StagedLinkPreview, `.compositionInput`), or nil.
    public func linkPreview(_ view: AnyView?) -> CompositionInput {
        var copy = self
        copy.linkPreview = view
        return copy
    }

    var background: AxoColor {
        switch variant {
        case .textArea: AxoColor(RGBA(0, 0, 0, 0))
        case .storyReply: AxoColor(LegacyColor.gray75)
        case .composer: AxoColor.surfaceMessageIncoming
        }
    }

    var borderColor: AxoColor {
        if variant == .storyReply { return AxoColor(LegacyColor.gray75) }
        return showsFocus ? AxoColor(LegacyColor.ultramarine) : AxoColor(RGBA(0, 0, 0, 0))
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: variant == .textArea ? 0 : 18)
        VStack(alignment: .leading, spacing: 0) {
            if let linkPreview { linkPreview }
            row
        }
        .overlay {
            if isViewOnceActive {
                CSSText(i18n("icu:CompositionArea--viewOnceMediaPlaceholder"), style: LegacyType.body1(), wrap: .nowrap,
                        color: AxoColor(light: LegacyColor.gray45, dark: LegacyColor.gray25))
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: variant == .storyReply ? 36 - 2 * Self.border : nil)
        .padding(Self.border)        // the 1px border (transparent unless focused)
        .background(shape.fill(background))
        .clipShape(shape)
        .overlay(shape.strokeBorder(borderColor, lineWidth: Self.border))
        .cssTextColor(.labelPrimary)
    }

    var row: some View {
        HStack(alignment: .center, spacing: 0) {
            if let leading { leading }
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
        // `scroller--link-preview`: no top padding under a link preview (not when large).
        let pad = textArea ? EdgeInsets(top: 16, leading: 28, bottom: 16, trailing: 48)
            : EdgeInsets(top: linkPreview != nil && !large ? 0 : 6, leading: 12, bottom: 6, trailing: 12)
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
                // The live composer grows with its text to `liveMaxLines` lines, then scrolls (upstream's
                // 72px cap, about three lines, stays for the static Storybook renders).
                let liveMax = variant == .composer && !large ? CGFloat(Self.liveMaxLines) * style.lineHeight + pad.top + pad.bottom : maxH
                ComposerTextView(text: $text, placeholder: placeholder ?? i18n("icu:sendMessage"), disabled: disabled, autoFocus: isActive,
                                 focused: $focused, onSubmit: onSubmit, keys: keys)
                    .padding(.leading, pad.leading).padding(.trailing, pad.trailing)
                    .frame(minHeight: minH - pad.top - pad.bottom, maxHeight: liveMax - pad.top - pad.bottom)
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
    var keys = ComposerKeys()

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
        // Rich text for mention pills and styles; pastes stay plain (PlaceholderTextView.paste).
        tv.isRichText = true
        tv.importsGraphics = false
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        // The text view grows past the visible box (to any height) so the scroll view can
        // scroll; without a maximum size it stays the box's height and later lines are hidden.
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.allowsUndo = true
        // Spell-check (NSSpellChecker underlines, suggestions in the context menu) as Chromium's
        // spellchecker: no autocorrection, no grammar or text replacement.
        tv.isContinuousSpellCheckingEnabled = context.environment.spellCheckEnabled
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        let style = LegacyType.body1()
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = style.lineHeight
        para.maximumLineHeight = style.lineHeight
        tv.typingAttributes = [.font: style.ctFont as NSFont, .paragraphStyle: para, .kern: style.letterSpacing,
                               .foregroundColor: NSColor.labelColor]
        tv.string = text
        scroll.documentView = tv
        context.environment.composerController?.textView = tv
        if autoFocus { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(tv) } }
        return scroll
    }

    /// The text's height at the proposed width (the frame around clamps it and the scroll view
    /// scrolls past that): what lets the composer grow line by line.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite, let tv = scroll.documentView as? NSTextView else { return nil }
        // A trailing newline starts a line of its own.
        let measured = tv.string.isEmpty || tv.string.hasSuffix("\n") ? tv.string + "x" : tv.string
        let rect = NSAttributedString(string: measured, attributes: tv.typingAttributes)
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        // At most the proposed height (the box's limit): the rest scrolls.
        var height = ceil(rect.height)
        if let limit = proposal.height, limit.isFinite { height = min(height, limit) }
        return CGSize(width: width, height: height)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        (tv as? PlaceholderTextView)?.pasteAttachments = keys.paste
        let controller = context.environment.composerController
        controller?.textView = tv
        context.coordinator.controller = controller
        if let p = tv as? PlaceholderTextView {
            p.controller = controller
            let i18n = context.environment.i18n
            p.formatItems = [(i18n("icu:Keyboard--composer--bold"), .bold), (i18n("icu:Keyboard--composer--italic"), .italic),
                             (i18n("icu:Keyboard--composer--strikethrough"), .strikethrough), (i18n("icu:Keyboard--composer--monospace"), .monospace),
                             (i18n("icu:Keyboard--composer--spoiler"), .spoiler)]
        }
        if tv.string != text { tv.string = text }
        tv.isEditable = !disabled
        if tv.isContinuousSpellCheckingEnabled != context.environment.spellCheckEnabled {
            tv.isContinuousSpellCheckingEnabled = context.environment.spellCheckEnabled
        }
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        /// Keeps the TextKit 2 content storage alive with the view.
        var content: NSTextContentStorage?
        weak var controller: ComposerController?
        init(_ parent: ComposerTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            controller?.reportMentionQuery()
            // Keep the caret in view once the text is taller than the box.
            tv.scrollRangeToVisible(tv.selectedRange())
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Text typed after a pill is plain.
            if tv.typingAttributes[ComposerController.mentionKey] != nil { tv.typingAttributes = ComposerController.plainAttributes(tv) }
            controller?.reportMentionQuery()
        }
        /// A deletion touching a mention pill removes the whole pill.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let controller, replacementString?.isEmpty == true else { return true }
            let expanded = controller.expandDeletion(range)
            guard expanded != range else { return true }
            textView.insertText("", replacementRange: expanded)
            return false
        }
        func textDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func textDidEndEditing(_ notification: Notification) { parent.focused = false }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // While mention suggestions show: Enter / Tab pick the first, Escape hides them.
            if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.insertTab(_:)),
               let pick = controller?.pickFirstMention, pick() {
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)), controller?.dismissMentions() == true { return true }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let mods = NSApp.currentEvent?.modifierFlags ?? []
                if mods.contains(.shift) || mods.contains(.option) { return false }
                parent.onSubmit()
                return true
            }
            // ↑ in an empty composer: edit the last message (`onEditLastMessageShortcut`).
            if selector == #selector(NSResponder.moveUp(_:)), textView.string.isEmpty, !textView.hasMarkedText(), let up = parent.keys.arrowUp {
                return up()
            }
            // Escape: leave editing.
            if selector == #selector(NSResponder.cancelOperation(_:)), let escape = parent.keys.escape { return escape() }
            return false
        }
    }
}

/// NSTextView drawing its placeholder while empty.
final class PlaceholderTextView: NSTextView {
    var placeholder = ""
    weak var controller: ComposerController?
    /// The context menu's Format items (localised labels).
    var formatItems: [(String, BodyRange.Style)] = []

    /// Focused (the shortcuts apply only then).
    private var isFocused = false
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { isFocused = true }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { isFocused = false }
        return ok
    }

    /// ⌘B bold, ⌘I italic, ⌘⇧X strikethrough, ⌘E monospace, ⌘⇧B spoiler.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let controller, isFocused else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        let style: BodyRange.Style? = switch (mods, key) {
        case ([.command], "b"): .bold
        case ([.command], "i"): .italic
        case ([.command, .shift], "x"): .strikethrough
        case ([.command], "e"): .monospace
        case ([.command, .shift], "b"): .spoiler
        default: nil
        }
        guard let style else { return super.performKeyEquivalent(with: event) }
        controller.toggle(style)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard controller != nil, !formatItems.isEmpty else { return menu }
        // The formatting items (localised: Bold, Italic, …) first.
        menu.insertItem(.separator(), at: 0)
        for (title, style) in formatItems.reversed() {
            let item = NSMenuItem(title: title, action: #selector(formatFromMenu(_:)), keyEquivalent: "")
            item.tag = style.rawValue
            item.target = self
            menu.insertItem(item, at: 0)
        }
        return menu
    }

    @objc func formatFromMenu(_ item: NSMenuItem) {
        if let style = BodyRange.Style(rawValue: item.tag) { controller?.toggle(style) }
    }
    /// Attachments pasted (files, images) go to the composer instead of the text.
    var pasteAttachments: ((NSPasteboard) -> Bool)?

    override func paste(_ sender: Any?) {
        if let pasteAttachments, pasteAttachments(NSPasteboard.general) { return }
        pasteAsPlainText(sender)
    }

    // Files and images dropped on the composer are attached as pasted ones are, not inserted as
    // text: files, file promises (a browser's image, Photos), PNG or JPEG data.

    static func isAttachmentDrag(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
            || pb.availableType(from: [.png, NSPasteboard.PasteboardType("public.jpeg")]) != nil
    }

    func takesDrag(_ sender: NSDraggingInfo) -> Bool { pasteAttachments != nil && Self.isAttachmentDrag(sender.draggingPasteboard) }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        let extra = [NSPasteboard.PasteboardType.fileURL, .png, NSPasteboard.PasteboardType("public.jpeg")]
            + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        let types = super.acceptableDragTypes
        return types + extra.filter { !types.contains($0) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        takesDrag(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        takesDrag(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        takesDrag(sender) || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if takesDrag(sender), let pasteAttachments { return pasteAttachments(sender.draggingPasteboard) }
        return super.performDragOperation(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let style = LegacyType.body1()
        let attrs: [NSAttributedString.Key: Any] = [.font: style.ctFont as NSFont, .foregroundColor: NSColor.placeholderTextColor]
        (placeholder as NSString).draw(at: NSPoint(x: 0, y: 0), withAttributes: attrs)
    }
}

extension EnvironmentValues {
    /// The "Enable spell check" setting (`spell-check`), read at launch as upstream applies it
    /// on restart.
    @Entry public var spellCheckEnabled = true
}


/// Composer keys beyond Return (CompositionArea's shortcuts): ↑ in an empty composer edits the
/// last message, Escape leaves editing; each returns whether it handled the key.
public struct ComposerKeys {
    public var arrowUp: (() -> Bool)?
    public var escape: (() -> Bool)?
    /// ⌘V with files or an image on the pasteboard (true: handled, nothing pasted as text).
    public var paste: ((NSPasteboard) -> Bool)?
    public init(arrowUp: (() -> Bool)? = nil, escape: (() -> Bool)? = nil, paste: ((NSPasteboard) -> Bool)? = nil) {
        self.arrowUp = arrowUp
        self.escape = escape
        self.paste = paste
    }
}

extension EnvironmentValues {
    @Entry public var composerKeys = ComposerKeys()
}
