// Port of ts/axo/chatList/_AxoBaseChatItem.dom.tsx (+ _AxoBaseChatItem.css): the parts
// shared by AxoChatItem and AxoChatItemCompact — a clickable row (AriaClickable: a hidden
// trigger button covers it) with a curved-2xl inner box that fills on hover, the avatar,
// and the unread / mention badges.

import SwiftUI

public enum AxoBaseChatItem {
    public static let badgeMax = 999

    enum Role: Sendable { case content, trigger }
    struct RoleKey: LayoutValueKey { static let defaultValue = Role.content }

    /// `<AxoBaseChatItem.Root compact>`
    struct Root<Content: View>: View {
        let compact: Bool
        let content: Content
        @State private var hovered = false
        @State private var pressed = false

        var body: some View {
            // Full: px-2.5 py-0.5 around an inner flex items-center gap-3 px-3.5 py-2.5.
            // Compact: flex justify-center py-0.5 around a w-fit inner px-2.5 py-2.
            let outer = compact ? EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0) : EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10)
            let inner = compact ? EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10) : EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
            let bg: AxoColor? = pressed ? .fillPrimaryPressed : hovered ? .fillPrimary : nil
            ItemLayout(outer: outer, inner: inner, fit: compact) { content }
                .background {
                    if let bg {
                        SuperellipseRect.curved(16).fill(bg).padding(outer).modifier(FitInner(compact: compact, inner: inner))
                    }
                }
                .onHover { hovered = $0 }
                .environment(\.axoChatItemBackground, bg)
                .environment(\.axoChatItemPressed, $pressed)
                .accessibilityElement(children: .combine)
        }
    }

    /// The compact inner box hugs the 40pt avatar (60 × 56), centred.
    struct FitInner: ViewModifier {
        let compact: Bool
        let inner: EdgeInsets
        func body(content: Content) -> some View {
            if compact {
                content.frame(width: 40 + inner.leading + inner.trailing).frame(maxWidth: .infinity)
            } else {
                content
            }
        }
    }

    /// Lays out the inner flex row (gap-3, items-center; the content grows) inside the paddings;
    /// the hidden trigger covers the whole item.
    struct ItemLayout: Layout {
        let outer: EdgeInsets
        let inner: EdgeInsets
        let fit: Bool

        var hpad: CGFloat { outer.leading + outer.trailing + inner.leading + inner.trailing }
        var vpad: CGFloat { outer.top + outer.bottom + inner.top + inner.bottom }

        func row(_ subviews: Subviews) -> [LayoutSubview] { subviews.filter { $0[RoleKey.self] == .content } }

        func sizes(_ width: CGFloat?, _ subviews: Subviews) -> [CGSize] {
            let items = row(subviews)
            let gaps = 12 * CGFloat(max(0, items.count - 1))
            let fixed = items.map { $0[FlexGrowKey.self] ? CGSize.zero : $0.sizeThatFits(.unspecified) }
            let used = fixed.map(\.width).reduce(0, +) + gaps
            let free = width.map { max(0, $0 - hpad - used) }
            return zip(items, fixed).map { s, f in
                s[FlexGrowKey.self] ? s.sizeThatFits(ProposedViewSize(width: free, height: nil)) : f
            }
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let sz = sizes(proposal.width, subviews)
            let rowWidth = sz.map(\.width).reduce(0, +) + 12 * CGFloat(max(0, sz.count - 1))
            let width = fit ? (proposal.width ?? rowWidth + hpad) : (proposal.width ?? rowWidth + hpad)
            return CGSize(width: width, height: (sz.map(\.height).max() ?? 0) + vpad)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let sz = sizes(bounds.width, subviews)
            let rowWidth = sz.map(\.width).reduce(0, +) + 12 * CGFloat(max(0, sz.count - 1))
            let innerHeight = bounds.height - vpad
            var x = bounds.minX + outer.leading + inner.leading
            if fit { x = bounds.minX + (bounds.width - rowWidth) / 2 }
            let y0 = bounds.minY + outer.top + inner.top
            for (s, size) in zip(row(subviews), sz) {
                s.place(at: CGPoint(x: x, y: y0 + (innerHeight - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + 12
            }
            for s in subviews where s[RoleKey.self] == .trigger {
                s.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            }
        }
    }

    struct FlexGrowKey: LayoutValueKey { static let defaultValue = false }

    /// `<AxoBaseChatItem.Avatar>`: relative shrink-0; the first child (the avatar) sizes it,
    /// the others (compact badges, absolutely positioned) are laid over its top edge.
    struct Avatar<Content: View>: View {
        let content: Content
        var body: some View {
            AvatarLayout { content }
        }
    }

    struct AvatarLayout: Layout {
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            subviews.first?.sizeThatFits(.unspecified) ?? .zero
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            for (i, s) in subviews.enumerated() {
                let p = i == 0 ? ProposedViewSize(bounds.size) : ProposedViewSize(width: bounds.width, height: nil)
                s.place(at: bounds.origin, proposal: p)
            }
        }
    }

    /// `<AxoBaseChatItem.IconAvatar>`
    struct IconAvatar: View {
        let size: AxoAvatar.Size
        let symbol: AxoSymbol.Name
        var body: some View {
            AxoAvatar.Root(size: size) {
                AxoAvatar.Content(label: nil) { AxoAvatar.Icon(symbol: symbol) }
            }
        }
    }

    /// `<AxoBaseChatItem.Badges>`: a mention badge and/or the unread count (or dot).
    struct Badges: View {
        let unreadCount: Int
        let markedUnread: Bool
        let mentioned: Bool
        @Environment(\.axoChatListCompact) var compact
        @Environment(\.axoChatItemBackground) var itemBackground

        var unreadValue: AxoBadge.Value? {
            if unreadCount > 0 { return .count(unreadCount) }
            if markedUnread { return .unread }
            return nil
        }

        func badge(_ value: AxoBadge.Value) -> some View {
            AxoBadge.Root(variant: .primary, size: .md, value: value, max: AxoBaseChatItem.badgeMax, label: nil)
                .modifier(CompactRing(on: compact, itemBackground: itemBackground))
        }

        var body: some View {
            if unreadCount == 0 && !markedUnread && !mentioned {
                EmptyView()
            } else if compact {
                // absolute -inset-x-1.25 -top-px flex justify-end (justify-between with a mention)
                HStack(spacing: 0) {
                    if mentioned { badge(.mention) }
                    Spacer(minLength: 0)
                    if let unreadValue { badge(unreadValue) }
                }
                .padding(.horizontal, -5)
                .offset(y: -1)
            } else {
                // mt-px flex gap-1 self-start ps-2.5
                HStack(spacing: 4) {
                    if mentioned { badge(.mention) }
                    if let unreadValue { badge(unreadValue) }
                }
                .padding(.leading, 10)
                .padding(.top, 1)
            }
        }
    }

    /// Compact badges: `shadow-[0_0_0_3px_var(--axo-chat-item-bg,transparent),0_0_0_3px_surface-secondary]`.
    struct CompactRing: ViewModifier {
        let on: Bool
        let itemBackground: AxoColor?
        @Environment(\.colorScheme) var scheme
        func body(content: Content) -> some View {
            if on {
                let ring = { (c: AxoColor) in AxoShadowLayer(inset: false, x: 0, y: 0, blur: 0, spread: 3, color: c.value(for: scheme)) }
                content.cssBoxShadow([ring(itemBackground ?? AxoColor(RGBA(0, 0, 0, 0))), ring(.surfaceSecondary)], in: Capsule())
            } else {
                content
            }
        }
    }

    /// `<AxoBaseChatItem.HiddenTrigger>`: a transparent button over the whole item.
    struct HiddenTrigger: View {
        let label: String
        let action: () -> Void
        @Environment(\.axoChatItemPressed) var pressed

        var body: some View {
            Button(action: action) { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(TriggerStyle(pressed: pressed))
                .accessibilityLabel(label)
                .layoutValue(key: RoleKey.self, value: .trigger)
        }

        struct TriggerStyle: ButtonStyle {
            let pressed: Binding<Bool>?
            func makeBody(configuration: Configuration) -> some View {
                configuration.label.onChange(of: configuration.isPressed) { _, v in pressed?.wrappedValue = v }
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var axoChatItemBackground: AxoColor? = nil
    @Entry var axoChatItemPressed: Binding<Bool>? = nil
}
