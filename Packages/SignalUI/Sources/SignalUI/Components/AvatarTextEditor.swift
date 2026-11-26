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
        AvatarTextMetrics.fittedSize(text, canvas: bubbleSize, ink: false)
    }

    var input: some View {
        let fontSize = fittedFontSize(inputText)
        let family = AxoFonts.interName(weight: 400)
        let height = AvatarTextMetrics.inputHeight(fontName: family, size: fontSize)
        return Group {
            if staticRendering {
                CSSText(runs: [Emojify.run(inputText)], style: CSSTextStyle(fontName: family, size: fontSize, lineHeight: height),
                        wrap: .nowrap, alignment: .center)
            } else {
                TextField("", text: Binding(get: { inputText }, set: { if $0.count <= Self.maxLength { inputText = $0 } }))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.custom(family, fixedSize: fontSize))
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
