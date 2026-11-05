// TypingBubble (ts/components/conversation/TypingBubble.dom.tsx): an incoming message row
// (`.module-message--incoming`, 16px inset) with the typing dots in an incoming bubble
// (radius 18, padding 8px 12px, 6px above and below; the animation 30px wide) and, in
// groups, the typists' 28px avatars before it: the last 3 to start typing, overlapping by
// 4px with the leftmost on top, each ringed by a 3px surface-coloured outline, and a "+N"
// avatar for the rest. Row-reverse with a 24px shrinkable spacer, bottom-aligned 6px up.
//
// Subset: upstream's spring animations (avatars sliding in/out, the bubble rising) are
// replaced by plain transitions; avatar badges are not drawn yet (Avatar has no badges).

import SignalI18n
import SwiftUI

public struct TypingContact: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var color: String
    public init(id: String, title: String, color: String) {
        self.id = id
        self.title = title
        self.color = color
    }
}

public struct TypingBubble: View {
    public enum ConversationType: Sendable { case direct, group }
    static let maxAvatarsCount = 3

    let conversationType: ConversationType
    /// The typists in the order they started typing.
    let typingContacts: [TypingContact]
    let showContactModal: (String) -> Void
    @Environment(\.i18n) var i18n

    public init(conversationType: ConversationType, typingContacts: [TypingContact], showContactModal: @escaping (String) -> Void = { _ in }) {
        self.conversationType = conversationType
        self.typingContacts = typingContacts
        self.showContactModal = showContactModal
    }

    public var body: some View {
        if !typingContacts.isEmpty {
            HStack(alignment: .bottom, spacing: 0) {
                if conversationType == .group { avatars.padding(.trailing, 8) }
                // .module-message__container--incoming
                TypingAnimation(color: .light, width: 30)
                    .frame(height: 16)
                    .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .background(RoundedRectangle(cornerRadius: 18).fill(AxoColor.surfaceMessageIncoming))
                    .padding(.vertical, 6)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .transition(.opacity)
        }
    }

    /// `.module-message__author-avatar-container--typing`
    var avatars: some View {
        let overflow = max(typingContacts.count - Self.maxAvatarsCount, 0)
        let shown = Array(typingContacts.suffix(Self.maxAvatarsCount))
        // Visual left → right: the newest typist first, then older ones, then "+N".
        return HStack(spacing: -4) {
            ForEach(Array(shown.reversed().enumerated()), id: \.element.id) { index, contact in
                Avatar(strings: AvatarStrings(i18n: i18n), title: contact.title, size: 28, conversationType: .direct, color: contact.color,
                       onClick: { showContactModal(contact.id) })
                    .background(Circle().fill(AxoColor.surfacePrimary).padding(-3))
                    .zIndex(Double(shown.count - index))
            }
            if overflow > 0 {
                CSSText("+\(overflow)", style: LegacyType.caption(weight: 600), wrap: .nowrap, color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray75)))
                    .background(Circle().fill(AxoColor.surfacePrimary).padding(-3))
                    .accessibilityLabel(i18n("icu:TypingBubble__avatar--overflow-count", ["count": .number(Double(overflow))]))
            }
        }
        .padding(.bottom, 6)
        .frame(minWidth: 28)
    }
}
