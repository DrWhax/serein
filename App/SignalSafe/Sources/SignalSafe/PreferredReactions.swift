// Customizing the six reaction emoji (ts/state/ducks/preferredReactions.preload.ts): a draft of
// the saved set, an emoji picked to replace one, Reset to the defaults (in the skin tone), and
// Save (`savePreferredReactions`, synced to our other devices through storage).

import SignalCore
import SignalUI

/// The customizing modal's state.
struct PreferredReactionsDraft {
    var draft: [String]
    var original: [String]
    var selected: Int?
    var isSaving = false
    var hadSaveError = false
}

extension SignalSession {
    /// `openCustomizePreferredReactionsModal`
    func openCustomizePreferredReactions() {
        customizingReactions = PreferredReactionsDraft(draft: preferredReactions, original: preferredReactions)
    }

    func selectReactionToReplace(_ index: Int) { customizingReactions?.selected = index }

    func deselectReactionToReplace() { customizingReactions?.selected = nil }

    /// `replaceSelectedDraftEmoji`
    func replaceSelectedReaction(_ emoji: String) {
        guard var d = customizingReactions, let i = d.selected, d.draft.indices.contains(i) else { return }
        d.draft[i] = emoji
        d.selected = nil
        customizingReactions = d
    }

    /// `resetDraftEmoji`: the defaults in the chosen skin tone.
    func resetReactionDraft() {
        let tone = emojiSkinTone ?? .none
        customizingReactions?.draft = ReactionEmoji.defaultPreferred.map { EmojiData.shared.variant($0, skinTone: tone) }
        customizingReactions?.selected = nil
    }

    /// `savePreferredReactions`: closes on success, else says the save failed.
    func savePreferredReactions() {
        guard let session, var d = customizingReactions, !d.isSaving else { return }
        d.isSaving = true
        d.hadSaveError = false
        customizingReactions = d
        let draft = d.draft
        Task {
            do {
                try await session.messenger.setPreferredReactions(draft)
                customizingReactions = nil
            } catch {
                Self.trace("saving preferred reactions failed: \(error)")
                customizingReactions?.isSaving = false
                customizingReactions?.hadSaveError = true
            }
        }
    }
}
