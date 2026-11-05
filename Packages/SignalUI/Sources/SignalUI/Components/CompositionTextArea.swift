// Port of ts/components/CompositionTextArea.dom.tsx (stylesheets/components/CompositionTextArea.scss)
// and the emoji-picker button of ts/components/fun/FunButton.dom.tsx: a CompositionInput
// restyled as a borderless text area, with the emoji picker button floating 8px from its top
// end corner and an optional remaining-character count.

import SignalI18n
import SwiftUI

public struct CompositionTextArea: View {
    @Binding var text: String
    let placeholder: String?
    let isActive: Bool
    let maxLength: Int?
    let whenToShowRemainingCount: Int
    let emojiPicker: AnyView?
    let onSubmit: () -> Void
    @State private var emojiPickerOpen = false

    public init(text: Binding<String>, placeholder: String? = nil, isActive: Bool = true, maxLength: Int? = nil,
                whenToShowRemainingCount: Int = .max, emojiPicker: AnyView? = nil, onSubmit: @escaping () -> Void = {}) {
        _text = text
        self.placeholder = placeholder
        self.isActive = isActive
        self.maxLength = maxLength
        self.whenToShowRemainingCount = whenToShowRemainingCount
        self.emojiPicker = emojiPicker
        self.onSubmit = onSubmit
    }

    public var body: some View {
        let count = text.count
        CompositionInput(text: $text, placeholder: placeholder, isActive: isActive, onSubmit: onSubmit, variant: .textArea)
            .overlay(alignment: .topTrailing) {
                FunEmojiPickerButton(isOpen: $emojiPickerOpen, picker: emojiPicker).padding(8)
            }
            .overlay(alignment: .bottomLeading) {
                if let maxLength, count >= whenToShowRemainingCount {
                    // __remaining-character-count: font-subtitle, gray-45, 12px / 24px 12px
                    CSSText("\(maxLength - count)", style: LegacyType.subtitle(), wrap: .nowrap, color: AxoColor(LegacyColor.gray45))
                        .padding(.vertical, 12).padding(.leading, 24).padding(.trailing, 12)
                }
            }
    }
}

/// `FunEmojiPickerButton`: a 32px `.FunButton` with the 20px emoji icon (label-primary), or
/// the selected emoji; it opens the emoji picker below it.
public struct FunEmojiPickerButton: View {
    @Binding var isOpen: Bool
    let selectedEmoji: String?
    let picker: AnyView?
    @State private var id = UUID().uuidString
    @Environment(\.i18n) var i18n

    public init(isOpen: Binding<Bool>, selectedEmoji: String? = nil, picker: AnyView? = nil) {
        _isOpen = isOpen
        self.selectedEmoji = selectedEmoji
        self.picker = picker
    }

    public var body: some View {
        SwiftUI.Button { isOpen.toggle() } label: {
            Group {
                if let selectedEmoji {
                    FunStaticEmoji(selectedEmoji, size: 20)
                } else {
                    SignalIcon("v3/emoji/emoji", size: 20, color: .labelPrimary)
                }
            }
            .frame(width: 32, height: 32)
            // [aria-expanded='true']: fill-primary-pressed
            .background(isOpen ? AxoColor.fillPrimaryPressed : AxoColor(RGBA(0, 0, 0, 0)), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(i18n("icu:FunButton__Label--EmojiPicker"))
        .axoPopper(id: id, isPresented: isOpen && picker != nil,
                   placement: AxoPopper.Placement(side: .bottom, align: .center, sideOffset: 4, collisionPadding: 6), dismiss: { isOpen = false }) {
            picker
        }
    }
}
