#if canImport(AppKit)
import AppKit
import SignalI18n
import SwiftUI

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
        tv.pasteAttachments = keys.paste
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
        guard isEditable else { return }
        if let pasteAttachments, pasteAttachments(.general) { return }
        pasteAsPlainText(sender)
    }

    // AppKit validates Edit → Paste against the text view's readable types.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        let types = super.readablePasteboardTypes
        guard pasteAttachments != nil else { return types }
        let attachments = ComposerAttachmentPasteboard.attachmentTypes
        return attachments + types.filter { !attachments.contains($0) }
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if isEditable, ComposerAttachmentPasteboard.attachmentTypes.contains(type), let pasteAttachments {
            return pasteAttachments(pasteboard)
        }
        return super.readSelection(from: pasteboard, type: type)
    }

    static func isAttachmentDrag(_ pb: NSPasteboard) -> Bool {
        pb.availableType(from: ComposerAttachmentPasteboard.attachmentTypes) != nil
    }

    func takesDrag(_ sender: NSDraggingInfo) -> Bool { isEditable && pasteAttachments != nil && Self.isAttachmentDrag(sender.draggingPasteboard) }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        let types = super.acceptableDragTypes
        return types + ComposerAttachmentPasteboard.attachmentTypes.filter { !types.contains($0) }
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
#endif
