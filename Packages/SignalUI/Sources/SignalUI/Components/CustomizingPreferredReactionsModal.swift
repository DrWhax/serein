// Port of ts/components/CustomizingPreferredReactionsModal.dom.tsx: choose the six reaction
// emoji. A small dialog with the reaction bar in menu style (the emoji being replaced grows,
// the others dim to 40% at 90%), "Tap an emoji to replace it" (or the save error), and Reset
// (only while the draft isn't the default set) and Save (pending while saving). Clicking an
// emoji selects it and opens the emoji picker under it.

import SignalI18n
import SwiftUI

public struct CustomizingPreferredReactionsModal: View {
    let draftPreferredReactions: [String]
    let originalPreferredReactions: [String]
    let selectedDraftEmojiIndex: Int?
    let emojiSkinToneDefault: EmojiSkinTone?
    let hadSaveError: Bool
    let isSaving: Bool
    let selectDraftEmojiToBeReplaced: (Int) -> Void
    let resetDraftEmoji: () -> Void
    let savePreferredReactions: () -> Void
    let cancel: () -> Void
    @Environment(\.i18n) var i18n

    public init(draftPreferredReactions: [String], originalPreferredReactions: [String], selectedDraftEmojiIndex: Int? = nil,
                emojiSkinToneDefault: EmojiSkinTone? = nil, hadSaveError: Bool = false, isSaving: Bool = false,
                selectDraftEmojiToBeReplaced: @escaping (Int) -> Void = { _ in }, resetDraftEmoji: @escaping () -> Void = {},
                savePreferredReactions: @escaping () -> Void = {}, cancel: @escaping () -> Void = {}) {
        self.draftPreferredReactions = draftPreferredReactions
        self.originalPreferredReactions = originalPreferredReactions
        self.selectedDraftEmojiIndex = selectedDraftEmojiIndex
        self.emojiSkinToneDefault = emojiSkinToneDefault
        self.hadSaveError = hadSaveError
        self.isSaving = isSaving
        self.selectDraftEmojiToBeReplaced = selectDraftEmojiToBeReplaced
        self.resetDraftEmoji = resetDraftEmoji
        self.savePreferredReactions = savePreferredReactions
        self.cancel = cancel
    }

    /// `getDefaultPreferredReactionEmojis(skinTone)`
    var defaults: [String] {
        let tone = emojiSkinToneDefault ?? .none
        return ReactionEmoji.defaultPreferred.map { EmojiData.shared.variant($0, skinTone: tone) }
    }

    public var body: some View {
        AxoDialog.Content(size: .sm) {
            AxoDialog.Header {
                AxoDialog.Title(i18n("icu:CustomizingPreferredReactions__title"))
                AxoDialog.Close(action: cancel)
            }
            AxoDialog.Body {
                VStack(spacing: 0) {
                    ReactionPickerPicker(isSomethingSelected: selectedDraftEmojiIndex != nil, pickerStyle: .menu) {
                        ForEach(draftPreferredReactions.indices, id: \.self) { i in
                            ReactionPickerPickerEmojiButton(emoji: draftPreferredReactions[i], isSelected: i == selectedDraftEmojiIndex) {
                                selectDraftEmojiToBeReplaced(i)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 16)
                    CSSText(i18n(hadSaveError ? "icu:CustomizingPreferredReactions__had-save-error" : "icu:CustomizingPreferredReactions__subtitle"),
                            type: .bodyMedium, alignment: .center)     // text-pretty
                        .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 24)
            }
            AxoDialog.Footer {
                AxoDialog.Actions {
                    AxoDialog.Action(i18n("icu:reset"), variant: .subtleSecondary, disabled: draftPreferredReactions != defaults || isSaving,
                                     action: resetDraftEmoji)
                    AxoDialog.Action(i18n("icu:save"), variant: .strongPrimary, pending: isSaving,
                                     disabled: draftPreferredReactions == originalPreferredReactions, action: savePreferredReactions)
                }
            }
        }
    }
}
