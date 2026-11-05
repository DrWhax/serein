// Port of ts/axo/_internal/AxoBaseSegmentedControl.dom.tsx: the shared look of segmented
// controls, toolbar toggle groups and tabs: a pill-shaped row of items, the selected one
// marked by a sliding indicator (`layoutId` → matchedGeometryEffect).

import SwiftUI

public enum ExperimentalAxoBaseSegmentedControl {
    /// Visual style variant.
    public enum Variant: String, CaseIterable, Sendable {
        case track
        case noTrack = "no-track"
    }

    /// How the control sizes itself horizontally.
    public enum RootWidth: String, CaseIterable, Sendable { case fit, full }

    /// How each item sizes itself within the control.
    public enum ItemWidth: String, CaseIterable, Sendable { case fit, equal }

    /// The selected value(s): one, several, or none.
    public enum RootValue: Sendable, Equatable {
        case none
        case single(String)
        case multiple([String])

        func contains(_ value: String) -> Bool {
            switch self {
            case .none: false
            case .single(let v): v == value
            case .multiple(let vs): vs.contains(value)
            }
        }
    }

    /// `IndicatorTransition`: spring (stiffness 422, damping 37.3, mass 1).
    public static let indicatorTransition = Animation.interpolatingSpring(mass: 1, stiffness: 422, damping: 37.3)

    struct Context {
        var value: RootValue
        var variant: Variant
        var rootWidth: RootWidth
        var itemWidth: ItemWidth
        var namespace: Namespace.ID?
    }

    /// `<AxoBaseSegmentedControl.Root>`: `flex min-w-min flex-row items-center rounded-full`
    /// (`bg-primary` for the track variant), `w-fit` or `w-full`.
    public struct Root<Content: View>: View {
        let value: RootValue
        let variant: Variant
        let width: RootWidth
        let itemWidth: ItemWidth
        let content: Content
        @Namespace private var namespace

        public init(value: RootValue, variant: Variant, width: RootWidth, itemWidth: ItemWidth, @ViewBuilder content: () -> Content) {
            self.value = value
            self.variant = variant
            self.width = width
            self.itemWidth = itemWidth
            self.content = content()
        }

        public var body: some View {
            RootLayout(width: width, itemWidth: itemWidth) { content }
                .background {
                    if variant == .track { Capsule().fill(AxoColor.fillPrimary) }
                }
                .environment(\.axoBaseSegmentedControl, Context(value: value, variant: variant, rootWidth: width, itemWidth: itemWidth,
                                                                 namespace: namespace))
        }
    }

    /// The row: items keep their content width as basis and share the free space equally
    /// (`fit`: `min-w-0 shrink grow basis-auto`), or split the width equally (`equal`:
    /// `flex-1`, with `min-w-0`). A `w-fit` root is as wide as the items' max-content widths.
    struct RootLayout: Layout {
        let width: RootWidth
        let itemWidth: ItemWidth

        func widths(_ subviews: Subviews, total: CGFloat) -> [CGFloat] {
            let n = CGFloat(max(1, subviews.count))
            switch itemWidth {
            case .equal:
                return subviews.map { _ in total / n }
            case .fit:
                let basis = subviews.map { $0.sizeThatFits(.unspecified).width }
                let free = total - basis.reduce(0, +)
                if free >= 0 { return basis.map { $0 + free / n } }
                let scaled = basis.reduce(0, +)
                return basis.map { max(0, $0 + (scaled > 0 ? free * $0 / scaled : 0)) }
            }
        }

        func totalWidth(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
            let content = subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
            switch width {
            case .full: return proposal.width ?? content
            case .fit: return min(content, proposal.width ?? content)
            }
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let total = totalWidth(proposal, subviews)
            let ws = widths(subviews, total: total)
            let height = zip(subviews, ws).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
            return CGSize(width: total, height: height)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            var x = bounds.minX
            for (s, w) in zip(subviews, widths(subviews, total: bounds.width)) {
                let h = s.sizeThatFits(ProposedViewSize(width: w, height: nil)).height
                s.place(at: CGPoint(x: x, y: bounds.midY - h / 2), proposal: ProposedViewSize(width: w, height: h))
                x += w
            }
        }
    }

    /// `<AxoBaseSegmentedControl.Item>`: `flex items-center justify-center px-3 py-1.25
    /// rounded-full type-body-medium font-medium text-primary`, with the indicator behind
    /// its content when selected.
    public struct Item<Content: View>: View {
        let value: String
        let action: () -> Void
        let content: Content
        @Environment(\.axoBaseSegmentedControl) var context
        @Environment(\.axoAnimationsDisabled) var animationsDisabled

        public init(value: String, action: @escaping () -> Void = {}, @ViewBuilder content: () -> Content) {
            self.value = value
            self.action = action
            self.content = content()
        }

        public var body: some View {
            let selected = context.value.contains(value)
            Button {
                if animationsDisabled { action() } else { withAnimation(indicatorTransition) { action() } }
            } label: {
                CSSFlex(.row, justify: .center, align: .center) { content }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .cssTextColor(.labelPrimary)
                    .background {
                        if selected { Indicator(variant: context.variant, namespace: context.namespace) }
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    /// The selected item's indicator: `absolute inset-0 rounded-full`, `bg-control
    /// shadow-elevation-1` on a track, `bg-secondary` without.
    struct Indicator: View {
        let variant: Variant
        let namespace: Namespace.ID?

        var body: some View {
            let shape = Capsule()
            Group {
                switch variant {
                case .track: shape.fill(AxoColor.fillControl).axoShadow(.shadowElevation1, in: shape)
                case .noTrack: shape.fill(AxoColor.fillSecondary)
                }
            }
            .modifier(MatchedIndicator(namespace: namespace))
            .allowsHitTesting(false)
        }
    }

    struct MatchedIndicator: ViewModifier {
        let namespace: Namespace.ID?
        func body(content: Content) -> some View {
            if let namespace { content.matchedGeometryEffect(id: "Indicator", in: namespace) } else { content }
        }
    }

    /// `<AxoBaseSegmentedControl.ItemText>`: `block truncate` (shrinks to nothing, then
    /// ellipsises), optionally capped at `maxWidth`.
    public struct ItemText: View {
        let text: String
        let maxWidth: CGFloat?

        public init(_ text: String, maxWidth: CGFloat? = nil) {
            self.text = text
            self.maxWidth = maxWidth
        }

        public var body: some View {
            CSSText(text, type: AxoType.bodyMedium.weight(500), wrap: .truncate)
                .frame(maxWidth: maxWidth)
                .flexItem(minMain: 0)
        }
    }

    /// `<AxoBaseSegmentedControl.ItemBadge>`: an `md` badge, `ms-[5px]`.
    public struct ItemBadge: View {
        let variant: AxoBadge.Variant
        let value: AxoBadge.Value
        let max: Int?
        let label: String?

        public init(variant: AxoBadge.Variant, value: AxoBadge.Value, max: Int?, label: String?) {
            self.variant = variant
            self.value = value
            self.max = max
            self.label = label
        }

        public var body: some View {
            // Inherits type-body-medium's letter-spacing (-0.039px).
            AxoBadge.Root(variant: variant, size: .md, value: value, max: max, label: label, letterSpacing: AxoType.bodyMedium.tracking * 13)
                .padding(.leading, 5)
        }
    }
}

struct AxoBaseSegmentedControlKey: EnvironmentKey {
    static let defaultValue = ExperimentalAxoBaseSegmentedControl.Context(value: .none, variant: .track, rootWidth: .fit, itemWidth: .fit,
                                                                          namespace: nil)
}

extension EnvironmentValues {
    var axoBaseSegmentedControl: ExperimentalAxoBaseSegmentedControl.Context {
        get { self[AxoBaseSegmentedControlKey.self] }
        set { self[AxoBaseSegmentedControlKey.self] = newValue }
    }
}
