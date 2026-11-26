#if os(Linux)
@_spi(Qt) import SwiftUI
import Foundation

struct ComposerTextView: View {
    @Binding var text: String
    let placeholder: String
    let disabled: Bool
    let autoFocus: Bool
    @Binding var focused: Bool
    let onSubmit: () -> Void
    var keys = ComposerKeys()

    @State private var document = LinuxComposerDocument()
    @FocusState private var nativeFocus: Bool
    @Environment(\.composerController) private var controller
    @Environment(\.spellCheckEnabled) private var spellCheck

    private func keyPressed(_ press: KeyPress) -> KeyPress.Result {
        guard !disabled else { return .ignored }
        let mods = press.modifiers.intersection([.control, .shift, .option, .command])
        if press.key == .return || press.key == .tab {
            if mods.isEmpty, controller?.pickFirstMention?() == true { return .handled }
            if press.key == .return, mods.isEmpty { onSubmit(); return .handled }
            return .ignored
        }
        if press.key == .escape, mods.isEmpty {
            return controller?.dismissMentions() == true || keys.escape?() == true ? .handled : .ignored
        }
        if press.key == .upArrow, mods.isEmpty, document.string.isEmpty { return keys.arrowUp?() == true ? .handled : .ignored }
        guard let controller, mods == .control || mods == [.control, .shift] else { return .ignored }
        let style: BodyRange.Style? = switch (press.key.character.lowercased(), mods.contains(.shift)) {
        case ("b", false): .bold
        case ("i", false): .italic
        case ("x", true): .strikethrough
        case ("e", false): .monospace
        case ("b", true): .spoiler
        default: nil
        }
        guard let style else { return .ignored }
        controller.toggle(style)
        return .handled
    }

    private func setSelection(_ new: AttributedTextSelection) {
        if case .insertionPoint(let point) = new.indices(in: document.text), new.typingAttributes(in: document.text).signalMention != nil {
            document.selection = .init(insertionPoint: point, typingAttributes: AttributeContainer())
        } else {
            document.selection = new
        }
        controller?.reportMentionQuery()
    }

    private func attach() {
        document.onTextChange = { updated in if text != updated { text = updated } }
        if document.string != text { document.text = AttributedString(text) }
        controller?.textView = document
        controller?.applyPendingDraft()
        if autoFocus && !disabled { nativeFocus = true }
    }

    var body: some View {
        let style = LegacyType.body1()
        let font = Font.custom(style.fontName, fixedSize: style.size)
        let accepted = keys.paste == nil || disabled ? [] : [.fileURL] + ComposerAttachmentPasteboard.imageTypes
        ComposerEditorLayout(text: document.text, font: font, lineHeight: style.lineHeight) {
            TextEditor(text: Binding(get: { document.text }, set: { document.receive($0); controller?.reportMentionQuery() }),
                       selection: Binding(get: { document.selection }, set: setSelection))
                .font(font)
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled(!spellCheck)
                .disabled(disabled)
                .focused($nativeFocus)
                .onKeyPress(phases: [.down, .repeat], action: keyPressed)
                .onPasteCommand(of: accepted) { providers in _ = keys.paste?(providers) }
                .onDrop(of: accepted, isTargeted: nil) { providers in keys.paste?(providers) ?? false }
                .overlay(alignment: .topLeading) {
                    if document.string.isEmpty {
                        CSSText(placeholder, style: style, wrap: .nowrap, color: AxoColor(light: LegacyColor.gray45, dark: LegacyColor.gray25))
                            .allowsHitTesting(false)
                    }
                }
        }
        .onAppear(perform: attach)
        .onDisappear {
            document.onTextChange = nil
            if controller?.textView === document { controller?.textView = nil }
        }
        .onChange(of: nativeFocus) { _, current in focused = current }
        .onChange(of: text) { _, current in
            if current != document.string { document.text = AttributedString(current); document.selection = .init() }
        }
    }
}

private struct ComposerEditorLayout: Layout {
    let text: AttributedString
    let font: Font
    let lineHeight: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(0, proposal.width ?? 0)
        var measured = text
        if measured.characters.isEmpty || measured.characters.last == "\n" { measured += AttributedString(" ") }
        let lines = QtTextLayout.lines(in: measured, font: font, width: max(1, width - 10), breaksLongWords: true)
        return CGSize(width: width, height: min(proposal.height ?? .infinity, lineHeight * CGFloat(max(1, lines.count))))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
#endif
