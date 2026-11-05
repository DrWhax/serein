// Port of ts/axo/AxoPanel.dom.tsx: a full-size panel with a header (back button slot,
// centred label) and a scrolling content area.
//
//   <AxoPanel.Root>
//     <AxoPanel.Header> <AxoPanel.Label>…</AxoPanel.Label> <AxoPanel.Back onClick/> </AxoPanel.Header>
//     <AxoPanel.Content>…</AxoPanel.Content>
//   </AxoPanel.Root>

import SwiftUI

public enum AxoPanel {
    /// `<AxoPanel.Root>`: relative size-full pt-7 min-h-0 min-w-0 flex flex-col bg-surface-primary
    public struct Root<Content: View>: View {
        let content: Content

        public init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        public var body: some View {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.top, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(AxoColor.surfacePrimary)
        }
    }

    enum Slot: Sendable { case back, label, other }
    struct SlotKey: LayoutValueKey { static let defaultValue = Slot.other }

    /// `<AxoPanel.Header>`: h-13 shrink-0 grid items-center gap-2 px-4,
    /// grid-cols-[[back-slot]_1fr_[label-slot]_auto_[reserved-slot]_1fr]
    public struct Header<Content: View>: View {
        let content: Content

        public init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        public var body: some View {
            HeaderLayout(gap: 8) { content }
                .padding(.horizontal, 16)
                .frame(height: 52)
        }
    }

    /// Three columns `1fr auto 1fr`: the label column is as wide as the label (down to the
    /// space the side columns leave), the side columns share the rest equally.
    struct HeaderLayout: Layout {
        let gap: CGFloat

        func columns(_ width: CGFloat, _ subviews: Subviews) -> (side: CGFloat, label: CGFloat) {
            let labelIdeal = subviews.filter { $0[SlotKey.self] == .label }.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            let backMin = subviews.filter { $0[SlotKey.self] == .back }.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            let free = max(0, width - 2 * gap)
            let side = max(backMin, (free - labelIdeal) / 2)
            return (side, max(0, free - 2 * side))
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let h = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            return CGSize(width: proposal.width ?? 0, height: proposal.height ?? h)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let (side, label) = columns(bounds.width, subviews)
            for s in subviews {
                let (x, w): (CGFloat, CGFloat) = switch s[SlotKey.self] {
                case .back: (0, side)
                case .label: (side + gap, label)
                case .other: (side + gap + label + gap, side)
                }
                let size = s.sizeThatFits(ProposedViewSize(width: w, height: nil))
                s.place(at: CGPoint(x: bounds.minX + x, y: bounds.midY - size.height / 2), anchor: .topLeading,
                        proposal: ProposedViewSize(width: w, height: size.height))
            }
        }
    }

    /// `<AxoPanel.Back>`
    public struct Back: View {
        let action: () -> Void

        public init(onClick action: @escaping () -> Void) {
            self.action = action
        }

        public var body: some View {
            AxoIconButton.Root(label: "Back", tooltip: false, variant: .impliedSecondary, size: .md, symbol: "chevron-[start]", action: action)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutValue(key: SlotKey.self, value: .back)
        }
    }

    /// `<AxoPanel.Label>`: py-1.5 truncate text-center type-title-small font-semibold text-primary
    public struct Label: View {
        let text: String

        public init(_ text: String) {
            self.text = text
        }

        public var body: some View {
            CSSText(text, type: .titleSmall, wrap: .truncate, alignment: .center, color: .labelPrimary)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
                .layoutValue(key: SlotKey.self, value: .label)
        }
    }

    /// `<AxoPanel.Content>`: main min-h-0 grow, a wide-scrollbar scroll area with a top hint,
    /// around an AxoContainer.
    public struct Content<Children: View>: View {
        let children: Children

        public init(@ViewBuilder content: () -> Children) {
            children = content()
        }

        public var body: some View {
            AxoScrollArea.Root(scrollbarWidth: .wide) {
                AxoScrollArea.Hint(edge: .top)
                AxoScrollArea.Viewport {
                    AxoScrollArea.Content {
                        AxoContainer.Root { children }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}
