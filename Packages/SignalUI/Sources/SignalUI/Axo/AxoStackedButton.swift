// Port of ts/axo/AxoStackedButton.dom.tsx: an icon pill with a caption below it
// (`Root`), and a centred, wrapping row of them (`Row`).

import SwiftUI

public enum AxoStackedButton {
    /// `<AxoStackedButton.Root>`
    public struct Root: View {
        let symbol: AxoSymbol.Name
        let label: String
        let disabled: Bool
        let pending: Bool
        let discouraged: Bool
        let onClick: () -> Void

        public init(symbol: AxoSymbol.Name, label: String, disabled: Bool = false, pending: Bool = false, discouraged: Bool = false,
                    onClick: @escaping () -> Void = {}) {
            self.symbol = symbol
            self.label = label
            self.disabled = disabled
            self.pending = pending
            self.discouraged = discouraged
            self.onClick = onClick
        }

        public var body: some View {
            Button {
                if !disabled && !pending { onClick() }
            } label: {
                // Label is `contain-inline-size`: it never widens the button, which is as wide
                // as the pill (48 + mx-1) and wraps the caption within it.
                StackLayout {
                    Pill(symbol: symbol, pending: pending, dim: disabled || discouraged)
                    LineClampText(label, style: CSSTextStyle(AxoType.caption.weight(500)), maxLines: 2)
                        .cssTextColor(disabled ? .labelDisabled : .labelPrimary)
                }
            }
            .buttonStyle(AxoStackedButtonStyle(interactive: !(disabled || pending)))
            .accessibilityLabel(label)
            .accessibilityHint(pending ? "Pending" : "")
        }
    }

    /// `relative mx-1 px-3.75 py-2.25 rounded-full bg-primary` around an 18px icon.
    struct Pill: View {
        let symbol: AxoSymbol.Name
        let pending: Bool
        let dim: Bool
        @Environment(\.axoStackedButtonPressed) var pressed

        var body: some View {
            AxoSymbol.Icon(symbol, size: 18, label: nil)
                .opacity(pending ? 0 : 1)
                .cssTextColor(dim ? .labelDisabled : .labelPrimary)
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background(Capsule().fill(pressed ? AxoColor.fillPrimaryPressed : AxoColor.fillPrimary))
                .overlay {
                    if pending { Spinner() }
                }
                .padding(.horizontal, 4)
        }
    }

    /// `AxoStackedButton.Spinner` (internal)
    struct Spinner: View {
        var body: some View {
            AxoBaseSpinner.Root(size: 18, weight: .regular, variant: .default, value: .indeterminate, track: false)
                .accessibilityHidden(true)
        }
    }

    /// `inline-flex flex-col items-center gap-1.5`: the width is the pill's; the caption takes it.
    struct StackLayout: Layout {
        static let gap: CGFloat = 6

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard subviews.count == 2 else { return .zero }
            let pill = subviews[0].sizeThatFits(.unspecified)
            let width = min(pill.width, proposal.width ?? pill.width)
            let text = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
            return CGSize(width: width, height: pill.height + Self.gap + text.height)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            guard subviews.count == 2 else { return }
            let pill = subviews[0].sizeThatFits(.unspecified)
            subviews[0].place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: ProposedViewSize(pill))
            let text = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + pill.height + Self.gap),
                              proposal: ProposedViewSize(width: bounds.width, height: text.height))
        }
    }

    public enum RowSpacing: Sendable { case md }

    /// `<AxoStackedButton.Row>`: `flex w-full flex-wrap items-start justify-center gap-x-1
    /// gap-y-3 px-[2.5px] pt-[2.5px]`; once the buttons no longer fit on one line
    /// (`FlexWrapDetector`), every one takes the full width.
    public struct Row<Content: View>: View {
        let spacing: RowSpacing
        let content: Content

        public init(spacing: RowSpacing, @ViewBuilder content: () -> Content) {
            self.spacing = spacing
            self.content = content()
        }

        public var body: some View {
            RowLayout(columnGap: 4, rowGap: 12) { content }
                .padding(.horizontal, 2.5)
                .padding(.top, 2.5)
        }
    }

    struct RowLayout: Layout {
        let columnGap: CGFloat
        let rowGap: CGFloat

        func natural(_ subviews: Subviews) -> [CGSize] { subviews.map { $0.sizeThatFits(.unspecified) } }

        func fitsOnOneLine(_ sizes: [CGSize], width: CGFloat?) -> Bool {
            guard let width else { return true }
            return sizes.map(\.width).reduce(0, +) + columnGap * CGFloat(max(0, sizes.count - 1)) <= width + 0.01
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let sizes = natural(subviews)
            let content = sizes.map(\.width).reduce(0, +) + columnGap * CGFloat(max(0, sizes.count - 1))
            if fitsOnOneLine(sizes, width: proposal.width) {
                return CGSize(width: proposal.width ?? content, height: sizes.map(\.height).max() ?? 0)
            }
            let width = proposal.width ?? content
            let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
            return CGSize(width: width, height: heights.reduce(0, +) + rowGap * CGFloat(max(0, heights.count - 1)))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let sizes = natural(subviews)
            if fitsOnOneLine(sizes, width: bounds.width) {
                let used = sizes.map(\.width).reduce(0, +) + columnGap * CGFloat(max(0, sizes.count - 1))
                var x = bounds.minX + (bounds.width - used) / 2
                for (s, size) in zip(subviews, sizes) {
                    s.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(size))
                    x += size.width + columnGap
                }
            } else {
                var y = bounds.minY
                for s in subviews {
                    let size = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                    s.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: size.height))
                    y += size.height + rowGap
                }
            }
        }
    }
}

struct AxoStackedButtonPressedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var axoStackedButtonPressed: Bool {
        get { self[AxoStackedButtonPressedKey.self] }
        set { self[AxoStackedButtonPressedKey.self] = newValue }
    }
}

/// `group-active:bg-primary-pressed` on the pill.
struct AxoStackedButtonStyle: ButtonStyle {
    let interactive: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.axoStackedButtonPressed, interactive && configuration.isPressed)
            .contentShape(Rectangle())
    }
}
