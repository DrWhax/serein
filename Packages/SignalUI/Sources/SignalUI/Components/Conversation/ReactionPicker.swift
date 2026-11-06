// Port of ts/components/conversation/ReactionPicker.dom.tsx and ts/components/
// ReactionPickerPicker.dom.tsx (+ stylesheets/components/ReactionPickerPicker.scss): the
// reaction bar over a message. The preferred emoji (48px emoji drawn at 28/48 in 40px round
// buttons; the selected one on a 20% wash), then "More" (a 28px grey circle with the more
// icon) or, when the selected reaction is not a preferred one, that reaction. Hovering or
// focusing an emoji grows it to 42/48 and lifts it. The first button takes focus on open.
//
// The "More" button opens the Fun emoji picker (ported with the composer, step 5).

import SignalI18n
import SwiftUI

/// `ReactionPickerPickerStyle`
public enum ReactionPickerPickerStyle: Sendable { case picker, menu }

/// `ReactionPickerPicker`: the rounded bar (1px border, two shadows, 3px × 7px padding).
public struct ReactionPickerPicker<Content: View>: View {
    let isSomethingSelected: Bool
    let pickerStyle: ReactionPickerPickerStyle
    /// Laid into a panel (StoryViewsNRepliesModal): no background, border or shadow, and the
    /// buttons spread over the full width (`justify-content: space-between`).
    let embedded: Bool
    let content: Content

    public init(isSomethingSelected: Bool, pickerStyle: ReactionPickerPickerStyle, embedded: Bool = false, @ViewBuilder content: () -> Content) {
        self.isSomethingSelected = isSomethingSelected
        self.pickerStyle = pickerStyle
        self.embedded = embedded
        self.content = content()
    }

    static var shadow: [AxoShadowLayer] { [
        AxoShadowLayer(inset: false, x: 0, y: 1, blur: 4, spread: 0, color: LegacyColor.blackAlpha05),
        AxoShadowLayer(inset: false, x: 0, y: 10, blur: 16, spread: 0, color: LegacyColor.blackAlpha20),
    ] }

    public var body: some View {
        if embedded {
            SpaceBetweenRow { content }
                .padding(.vertical, 3)
                .padding(.horizontal, 7)
                .environment(\.reactionPickerStyle, pickerStyle)
                .environment(\.reactionPickerSomethingSelected, isSomethingSelected)
        } else {
            bar
        }
    }

    var bar: some View {
        HStack(spacing: 0) { content }
            .padding(.vertical, 3)
            .padding(.horizontal, 7)
            .padding(1)     // the border box
            .background(Capsule().fill(AxoColor(light: LegacyColor.white, dark: LegacyColor.gray75)))
            .overlay(Capsule().strokeBorder(AxoColor(light: LegacyColor.blackAlpha05, dark: LegacyColor.gray80), lineWidth: 1))
            .cssBoxShadow(Self.shadow, in: Capsule())
            .environment(\.reactionPickerStyle, pickerStyle)
            .environment(\.reactionPickerSomethingSelected, isSomethingSelected)
            .fixedSize()
    }
}

extension EnvironmentValues {
    @Entry var reactionPickerStyle: ReactionPickerPickerStyle = .picker
    @Entry var reactionPickerSomethingSelected = false
}

/// `ReactionPickerPickerEmojiButton`
public struct ReactionPickerPickerEmojiButton: View {
    let emoji: String
    let isSelected: Bool
    let title: String?
    let autoFocus: Bool
    let onClick: () -> Void
    private var focus = AxoFocusState()
    @State private var hovered = false
    @Environment(\.reactionPickerStyle) var style
    @Environment(\.reactionPickerSomethingSelected) var somethingSelected
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    public init(emoji: String, isSelected: Bool, title: String? = nil, autoFocus: Bool = false, onClick: @escaping () -> Void) {
        self.emoji = emoji
        self.isSelected = isSelected
        self.title = title
        self.autoFocus = autoFocus
        self.onClick = onClick
    }

    public var body: some View {
        let focusVisible = focus.visible(autoFocus: autoFocus)
        let big = style == .picker ? (hovered || focusVisible) : isSelected
        let scale: CGFloat = big ? 42.0 / 48 : 28.0 / 48
        // `scale(s) translateY(-16px)`: the lift is in the scaled space.
        let lift: CGFloat = style == .picker && big ? -16 * scale : 0
        let dimmed = style == .menu && somethingSelected && !isSelected
        SwiftUI.Button(action: onClick) {
            FunStaticEmoji(emoji, size: 48, snapsBaseline: false)
                .scaleEffect(scale)
                .offset(y: lift)
                .frame(width: 40, height: 40)
                .background {
                    if isSelected && style == .picker {
                        Circle().fill(AxoColor(light: LegacyColor.blackAlpha20, dark: LegacyColor.whiteAlpha20))
                    } else if style == .menu && focusVisible {
                        Circle().fill(AxoColor(light: LegacyColor.blackAlpha20, dark: LegacyColor.whiteAlpha40))
                    }
                }
                .background {
                    // outline: auto wraps the button and the lifted emoji's box (42px, 14px up).
                    if focusVisible && style == .picker {
                        ChromiumFocusOutline(shape: RoundedRectangle(cornerRadius: 14))
                            .frame(width: 42, height: 40 + 15)
                            .offset(y: -7.5)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? 0.4 : 1)
        .scaleEffect(dimmed ? 0.9 : 1)
        .animation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.4), value: big)
        .onHover { hovered = $0 }
        .focusable()
        .focusEffectDisabled()
        .focused(focus.$focused)
        .onChange(of: focus.focused) { if !focus.focused { focus.autoFocusConsumed = true } }
        .accessibilityLabel(title ?? emoji)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

public struct ReactionPicker: View {
    /// `embedded`: see `ReactionPickerPicker`.
    public func embedded(_ value: Bool = true) -> ReactionPicker {
        var copy = self
        copy.embedded = value
        return copy
    }

    let preferredReactionEmoji: [String]
    let selected: String?
    let autoFocus: Bool
    let onPick: (String) -> Void
    let onMore: () -> Void
    let onClose: (() -> Void)?
    var embedded = false
    @State private var moreHovered = false
    @Environment(\.i18n) var i18n

    /// - Parameters:
    ///   - autoFocus: the first button takes focus when the picker opens.
    ///   - onMore: opens the full emoji picker (FunEmojiPicker).
    public init(preferredReactionEmoji: [String] = ReactionEmoji.defaultPreferred, selected: String? = nil, autoFocus: Bool = true,
                onPick: @escaping (String) -> Void, onMore: @escaping () -> Void = {}, onClose: (() -> Void)? = nil) {
        self.preferredReactionEmoji = preferredReactionEmoji
        self.selected = selected
        self.autoFocus = autoFocus
        self.onPick = onPick
        self.onMore = onMore
        self.onClose = onClose
    }

    public var body: some View {
        let otherSelected = selected.map { !preferredReactionEmoji.contains($0) } ?? false
        ReactionPickerPicker(isSomethingSelected: selected != nil, pickerStyle: .picker, embedded: embedded) {
            ForEach(Array(preferredReactionEmoji.enumerated()), id: \.offset) { index, emoji in
                ReactionPickerPickerEmojiButton(emoji: emoji, isSelected: emoji == selected, autoFocus: autoFocus && index == 0) { onPick(emoji) }
            }
            if otherSelected, let selected {
                ReactionPickerPickerEmojiButton(emoji: selected, isSelected: true, title: i18n("icu:Reactions--remove")) { onPick(selected) }
            } else {
                SwiftUI.Button(action: onMore) {
                    SignalIcon("v3/more/more", size: 20, color: AxoColor(light: LegacyColor.gray45, dark: LegacyColor.gray15))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(moreHovered ? AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray45)
                                                  : AxoColor(light: LegacyColor.gray02, dark: LegacyColor.gray60)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { moreHovered = $0 }
                .padding(6)
                .accessibilityLabel(i18n("icu:Reactions--more"))
            }
        }
        .onKeyPress(.escape) {
            guard let onClose else { return .ignored }
            onClose()
            return .handled
        }
    }
}

/// A row whose items keep their size and share the free width between them
/// (`display: flex; justify-content: space-between`).
struct SpaceBetweenRow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = sizes.reduce(0) { $0 + $1.width }
        return CGSize(width: proposal.width ?? natural, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let free = max(0, bounds.width - sizes.reduce(0) { $0 + $1.width })
        let gap = subviews.count > 1 ? free / CGFloat(subviews.count - 1) : 0
        var x = bounds.minX
        for (s, size) in zip(subviews, sizes) {
            s.place(at: CGPoint(x: x, y: bounds.midY - size.height / 2), proposal: ProposedViewSize(size))
            x += size.width + gap
        }
    }
}
