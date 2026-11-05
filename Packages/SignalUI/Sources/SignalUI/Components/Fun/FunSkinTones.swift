// Port of ts/components/fun/FunSkinTones.dom.tsx (FunSkinTones.scss): the six skin tones of
// an emoji as a single-selection row (42px items, 4px-padded 32px emoji, selected filled).

import SignalI18n
import SwiftUI

public struct FunSkinTonesList: View {
    let emoji: String
    let skinTone: EmojiSkinTone?
    let onSelectSkinTone: (EmojiSkinTone) -> Void
    @Environment(\.i18n) var i18n

    public init(emoji: String, skinTone: EmojiSkinTone?, onSelectSkinTone: @escaping (EmojiSkinTone) -> Void = { _ in }) {
        self.emoji = emoji
        self.skinTone = skinTone
        self.onSelectSkinTone = onSelectSkinTone
    }

    static let labels: [(EmojiSkinTone, String)] = [(.none, "icu:FunSkinTones__ListItem--None"), (.type1, "icu:FunSkinTones__ListItem--Light"),
                                                     (.type2, "icu:FunSkinTones__ListItem--MediumLight"), (.type3, "icu:FunSkinTones__ListItem--Medium"),
                                                     (.type4, "icu:FunSkinTones__ListItem--MediumDark"), (.type5, "icu:FunSkinTones__ListItem--Dark")]

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.labels, id: \.0) { tone, key in
                Item(emoji: EmojiData.shared.variant(emoji, skinTone: tone), selected: skinTone == tone, label: i18n(key)) { onSelectSkinTone(tone) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(i18n("icu:FunSkinTones__List"))
    }

    struct Item: View {
        let emoji: String
        let selected: Bool
        let label: String
        let action: () -> Void
        @State private var hovered = false
        var body: some View {
            Button(action: action) {
                FunStaticEmoji(emoji, size: 32)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 10).fill(selected ? AxoColor.fillPrimaryPressed : hovered ? AxoColor.fillPrimary : AxoColor(RGBA(0, 0, 0, 0))))
            }
            .buttonStyle(.plain)
            .padding(1)
            .onHover { hovered = $0 }
            .accessibilityLabel(label)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
        }
    }
}
