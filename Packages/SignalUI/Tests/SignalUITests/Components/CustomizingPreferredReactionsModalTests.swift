// ts/components/CustomizingPreferredReactionsModal.dom.stories.tsx

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct CustomizingPreferredReactionsModalTests {
    static let draft = ["✨", "❇️", "🎇", "🦈", "💖", "🅿️"]

    static func modal(selected: Int? = nil, saving: Bool = false, error: Bool = false) -> some View {
        PortalStage { EmptyView() } modal: {
            AxoBaseDialog.Host {
                CustomizingPreferredReactionsModal(draftPreferredReactions: draft, originalPreferredReactions: ReactionEmoji.defaultPreferred,
                                                   selectedDraftEmojiIndex: selected, emojiSkinToneDefault: .type4, hadSaveError: error, isSaving: saving)
            }
        }
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let c = "components-customizingpreferredreactionsmodal--"
        try Snapshot.assertMatches(Self.modal(), story: c + "default", theme: theme)
        try Snapshot.assertMatches(Self.modal(selected: 4), story: c + "draft-emoji-selected", theme: theme)
        try Snapshot.assertMatches(Self.modal(saving: true), story: c + "saving", theme: theme)
        try Snapshot.assertMatches(Self.modal(error: true), story: c + "had-error", theme: theme)
    }
}
