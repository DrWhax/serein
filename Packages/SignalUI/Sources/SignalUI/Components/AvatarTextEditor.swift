// Port of ts/components/AvatarTextEditor.dom.tsx (stylesheets/components/AvatarTextEditor.scss):
// up to three characters typed into a 120px bubble (the font fitted to it), over the colour
// picker, with Cancel / Save. The input focuses itself.

import SignalI18n
import SwiftUI

public struct AvatarTextEditor: View {
    nonisolated static let bubbleSize: CGFloat = 120
    static let maxLength = 3

    let initialText: String
    let initialColor: String
    let isInsideDialog: Bool
    /// `getFittedFontSize(120, text, measure)`; upstream measures a hidden copy of the text.
    let fittedFontSize: (String) -> CGFloat
    let onCancel: () -> Void
    let onDone: (AvatarData) -> Void
    @State private var inputText: String
    @State private var selectedColor: String
    @FocusState private var inputFocused: Bool
    @Environment(\.axoStaticRendering) var staticRendering

    public init(avatarData: AvatarData? = nil, isInsideDialog: Bool = false,
                fittedFontSize: @escaping (String) -> CGFloat = AvatarTextEditor.fittedFontSize,
                onCancel: @escaping () -> Void = {}, onDone: @escaping (AvatarData) -> Void = { _ in }) {
        initialText = avatarData?.text ?? ""
        initialColor = avatarData?.color ?? AxoTokens.Avatar.allColorNames[0]
        self.isInsideDialog = isInsideDialog
        self.fittedFontSize = fittedFontSize
        self.onCancel = onCancel
        self.onDone = onDone
        _inputText = State(initialValue: avatarData?.text ?? "")
        _selectedColor = State(initialValue: avatarData?.color ?? AxoTokens.Avatar.allColorNames[0])
    }

    /// `getFittedFontSize` measuring the text's box in Inter (line-height 20px).
    nonisolated public static func fittedFontSize(_ text: String) -> CGFloat {
        let diameter = (bubbleSize * 0.75).rounded(.up)
        var candidate = (bubbleSize * (text.count == 1 && text.first.map(CSSTextLayout.isEmoji) == true ? 0.6 : 0.45)).rounded(.up)
        let smol = (bubbleSize * 0.05).rounded(.up)
        while candidate >= smol {
            let font = CTFontCreateWithName(AxoFonts.interName(weight: 400) as CFString, candidate, nil)
            let width = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])), nil, nil, nil)
            if CGFloat(width) < diameter && 20 < diameter { return candidate }
            candidate -= 1
        }
        return candidate
    }

    var input: some View {
        let fontSize = fittedFontSize(inputText)
        let style = CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: fontSize, lineHeight: 20)
        let font = style.ctFont
        // The input's box: its line-height or the font's content area, whichever is taller.
        let height = max(20, CTFontGetAscent(font).rounded() + CTFontGetDescent(font).rounded())
        return Group {
            if staticRendering {
                CSSText(runs: [Emojify.run(inputText)], style: CSSTextStyle(fontName: style.fontName, size: fontSize, lineHeight: height),
                        wrap: .nowrap, alignment: .center)
            } else {
                TextField("", text: Binding(get: { inputText }, set: { if $0.count <= Self.maxLength { inputText = $0 } }))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.custom(style.fontName, fixedSize: fontSize))
                    .focused($inputFocused)
                    .onAppear { inputFocused = true }
            }
        }
        .frame(width: Self.bubbleSize - 8, height: height)
        .axoFocusRing(staticRendering || inputFocused, in: Rectangle())
    }

    var content: some View {
        VStack(spacing: 0) {
            BetterAvatarBubble(color: selectedColor, diameter: Self.bubbleSize, onSelect: { inputFocused = true }) { input }
                .frame(maxWidth: .infinity)
            AvatarEditorDivider()
            AvatarColorPicker(selectedColor: selectedColor) { color in
                selectedColor = color
                inputFocused = true
            }
        }
    }

    var buttons: some View {
        AvatarModalButtons(isInsideDialog: isInsideDialog, hasChanges: inputText != initialText || selectedColor != initialColor,
                           onCancel: onCancel, onSave: { onDone(AvatarData(id: UUID().uuidString, color: selectedColor, text: inputText)) })
    }

    public var body: some View {
        if isInsideDialog {
            AxoDialog.Body(forceMaxHeight: true) { content }
            AxoDialog.Footer { buttons }
        } else {
            VStack(spacing: 0) {
                content
                buttons
            }
        }
    }
}
