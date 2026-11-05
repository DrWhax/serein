// Port of ts/axo/AxoButton.dom.tsx + AxoButton.css: a pill-shaped text button with an
// optional leading symbol and trailing arrow.

import SwiftUI

public enum AxoButton {
    public enum Variant: String, CaseIterable, Sendable {
        case strongSecondary = "strong-secondary", strongPrimary = "strong-primary", strongAffirmative = "strong-affirmative"
        case strongWarning = "strong-warning", strongDestructive = "strong-destructive"
        case subtlePrimary = "subtle-primary", subtleSecondary = "subtle-secondary", subtleAffirmative = "subtle-affirmative"
        case subtleWarning = "subtle-warning", subtleDestructive = "subtle-destructive"
        case elevatedSecondary = "elevated-secondary"
        case impliedSecondary = "implied-secondary", impliedPrimary = "implied-primary", impliedAffirmative = "implied-affirmative"
        case impliedDestructive = "implied-destructive"
        case messageIncomingPrimary = "message-incoming-primary", messageOutgoingPrimary = "message-outgoing-primary"

        /// Order of upstream's VariantStyles table (`_getAllVariants`).
        public static let all: [Variant] = [
            .strongSecondary, .strongPrimary, .strongAffirmative, .strongWarning, .strongDestructive,
            .subtleSecondary, .subtlePrimary, .subtleAffirmative, .subtleWarning, .subtleDestructive,
            .elevatedSecondary, .impliedSecondary, .impliedPrimary, .impliedAffirmative, .impliedDestructive,
            .messageIncomingPrimary, .messageOutgoingPrimary,
        ]

        struct Style {
            var background: AxoColor?
            var pressed: AxoColor?
            var hover: AxoColor? = nil
            var label: AxoColor
            var discouraged: AxoColor
            var elevated = false
        }

        var style: Style {
            switch self {
            case .strongSecondary: Style(background: .fillSecondary, pressed: .fillSecondaryPressed, label: .labelPrimary, discouraged: .labelDisabled)
            case .strongPrimary: Style(background: .fillAccent, pressed: .fillAccentPressed, label: .labelPrimaryOncolor, discouraged: .labelDisabledOncolor)
            case .strongAffirmative: Style(background: .fillAffirmative, pressed: .fillAffirmativePressed, label: .labelPrimaryOncolor, discouraged: .labelDisabledOncolor)
            case .strongWarning: Style(background: .fillWarningBright, pressed: .fillWarningBrightPressed, label: .labelPrimaryOnbright, discouraged: .labelDisabledOnbright)
            case .strongDestructive: Style(background: .fillDestructive, pressed: .fillDestructivePressed, label: .labelPrimaryOncolor, discouraged: .labelDisabledOncolor)
            case .subtlePrimary: Style(background: .fillAccentTint, pressed: .fillAccentTintPressed, label: .labelAccent, discouraged: .labelAccentDisabled)
            case .subtleSecondary: Style(background: .fillPrimary, pressed: .fillPrimaryPressed, label: .labelPrimary, discouraged: .labelDisabled)
            case .subtleAffirmative: Style(background: .fillAffirmativeTint, pressed: .fillAffirmativeTintPressed, label: .labelAffirmative, discouraged: .labelAffirmativeDisabled)
            case .subtleWarning: Style(background: .fillWarningTint, pressed: .fillWarningTintPressed, label: .labelWarning, discouraged: .labelWarningDisabled)
            case .subtleDestructive: Style(background: .fillDestructiveTint, pressed: .fillDestructiveTintPressed, label: .labelDestructive, discouraged: .labelDestructiveDisabled)
            case .elevatedSecondary: Style(background: .materialTertiary, pressed: .materialTertiaryPressed, label: .labelPrimary, discouraged: .labelDisabled, elevated: true)
            case .impliedSecondary: Style(background: nil, pressed: .fillPrimaryPressed, hover: .fillPrimary, label: .labelPrimary, discouraged: .labelDisabled)
            case .impliedPrimary: Style(background: nil, pressed: .fillAccentTintPressed, hover: .fillAccentTint, label: .labelAccent, discouraged: .labelAccentDisabled)
            case .impliedAffirmative: Style(background: nil, pressed: .fillAffirmativeTintPressed, hover: .fillAffirmativeTint, label: .labelAffirmative, discouraged: .labelAffirmativeDisabled)
            case .impliedDestructive: Style(background: nil, pressed: .fillDestructiveTintPressed, hover: .fillDestructiveTint, label: .labelDestructive, discouraged: .labelDestructiveDisabled)
            case .messageIncomingPrimary: Style(background: .fillOnmessageIncomingPrimary, pressed: .fillOnmessageIncomingPrimaryPressed, label: .labelPrimary, discouraged: .labelDisabled)
            case .messageOutgoingPrimary: Style(background: .fillOnmessageOutgoingPrimary, pressed: .fillOnmessageOutgoingPrimaryPressed, label: .labelPrimaryOncolor, discouraged: .labelDisabledOncolor)
            }
        }
    }
}

extension AxoButton.Variant {
    /// SpinnerVariants
    var spinnerVariant: AxoBaseSpinner.Variant {
        switch self {
        case .strongPrimary, .strongAffirmative, .strongWarning, .strongDestructive: .oncolor
        default: .default
        }
    }
}

extension AxoButton {
    public enum Size: String, CaseIterable, Sendable {
        case sm, md, lg
        var minWidth: CGFloat { self == .sm ? 48 : self == .md ? 56 : 64 }
        var padding: EdgeInsets {
            switch self {
            case .sm: EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
            case .md: EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            case .lg: EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
            }
        }
        var type: AxoType { (self == .sm ? AxoType.bodySmall : .bodyMedium).weight(500) }
    }

    public enum Width: Sendable { case fit, grow, full }

    public enum Arrow: Sendable {
        case collapse, expand, next, externalLink
        var symbol: AxoSymbol.Name {
            switch self {
            case .collapse: "chevron-up"
            case .expand: "chevron-down"
            case .next: "chevron-[end]"
            case .externalLink: "open"
            }
        }
    }

    /// `<AxoButton.Root>`
    public struct Root: View {
        let variant: Variant
        let size: Size
        let width: Width
        let symbol: AxoSymbol.Name?
        let arrow: Arrow?
        let pending: Bool
        let disabled: Bool
        let discouraged: Bool
        let label: String
        /// The label as styled runs (an `<I18n>` with components); `label` stays its plain text.
        var labelRuns: [CSSTextRun]?
        let autoFocus: Bool
        let action: () -> Void
        @State private var hovered = false
        @Environment(\.axoButtonMinWidthFit) var minWidthFit
        private var focus = AxoFocusState()

        public init(_ label: String, variant: Variant, size: Size, width: Width = .fit, symbol: AxoSymbol.Name? = nil, arrow: Arrow? = nil,
                    pending: Bool = false, disabled: Bool = false, discouraged: Bool = false, autoFocus: Bool = false,
                    labelRuns: [CSSTextRun]? = nil, action: @escaping () -> Void = {}) {
            self.autoFocus = autoFocus
            self.label = label
            self.labelRuns = labelRuns
            self.variant = variant
            self.size = size
            self.width = width
            self.symbol = symbol
            self.arrow = arrow
            self.pending = pending
            self.disabled = disabled
            self.discouraged = discouraged
            self.action = action
        }

        @ViewBuilder func text(_ type: AxoType) -> some View {
            if let labelRuns {
                CSSText(runs: labelRuns, style: CSSTextStyle(type), wrap: .truncate)
            } else {
                CSSText(label, type: type, wrap: .truncate)
            }
        }

        public var body: some View {
            let style = variant.style
            let type = size.type
            Button {
                if !pending && !disabled { action() }
            } label: {
                HStack(spacing: 4) {
                    if let symbol { AxoSymbol.InlineGlyph(symbol, size: type.size, weight: type.weight) }
                    // .axo-button-text grows (min-w-0) and the button centres its text.
                    if width == .fit {
                        text(type)
                    } else {
                        text(type).frame(maxWidth: .infinity)
                    }
                    if let arrow { AxoSymbol.InlineGlyph(arrow.symbol, size: type.size, weight: type.weight) }
                }
                .opacity(pending ? 0 : 1)
                .cssTextColor(disabled || discouraged ? style.discouraged : style.label)
                .padding(size.padding)
                .frame(minWidth: minWidthFit ? nil : size.minWidth, maxWidth: width == .fit ? nil : .infinity)
                .overlay {
                    if pending {
                        AxoBaseSpinner.Root(size: size == .sm ? 16 : 18, weight: .regular, variant: variant.spinnerVariant, value: .indeterminate, track: false)
                    }
                }
            }
            .buttonStyle(AxoButtonStyle(style: style, hovered: hovered && !disabled))
            .axoFocusRing(focus.visible(autoFocus: autoFocus), in: Capsule())
            .focusable(interactions: .activate)
            .focusEffectDisabled()
            .focused(focus.$focused)
            .onChange(of: focus.focused) { _, now in if !now { focus.autoFocusConsumed = true } }
            .layoutValue(key: AxoButtonWidthKey.self, value: width)
            .onHover { hovered = $0 }
            .accessibilityLabel(pending ? "Pending" : label)
        }
    }
}

struct AxoButtonStyle: ButtonStyle {
    let style: AxoButton.Variant.Style
    let hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        let fill: AxoColor? = configuration.isPressed ? style.pressed : hovered ? (style.hover ?? style.background) : style.background
        let shape = Capsule()
        configuration.label
            .background { if let fill { shape.fill(fill) } }
            .modifier(ElevatedModifier(on: style.elevated, shape: Capsule()))
            .contentShape(shape)
    }
}

struct ElevatedModifier<S: InsettableShape>: ViewModifier {
    let on: Bool
    let shape: S
    func body(content: Content) -> some View {
        if on { content.axoShadow(.shadowElevation1, in: shape) } else { content }
    }
}


// MARK: - <AxoButton.Group>

struct AxoButtonWidthKey: LayoutValueKey { static let defaultValue: AxoButton.Width = .fit }

extension AxoButton {
    /// `<AxoButton.Group>`: actions in one row, equal-basis (`basis-0 min-w-fit`, so `grow`
    /// buttons share the free space) and centred; when they no longer fit on one line every
    /// button takes the full width, stacked with the first at the bottom (`flex-wrap-reverse`).
    public struct Group: Layout {
        public static let gap: CGFloat = 8
        public enum Justify: Sendable { case center, end }
        /// `justify-center-safe` (AxoButton.Group) or end-aligned (dialog Actions, `ms-auto`).
        public var justify: Justify
        public init(justify: Justify = .center) { self.justify = justify }

        func fits(_ subviews: Subviews, width: CGFloat) -> Bool {
            let natural = subviews.map { $0.sizeThatFits(.unspecified).width }
            return natural.reduce(0, +) + Self.gap * CGFloat(max(0, subviews.count - 1)) <= width + 0.01
        }

        public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
                + Self.gap * CGFloat(max(0, subviews.count - 1))
            if fits(subviews, width: width) {
                return CGSize(width: width, height: subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0)
            }
            let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
            return CGSize(width: width, height: heights.reduce(0, +) + Self.gap * CGFloat(max(0, subviews.count - 1)))
        }

        public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            if fits(subviews, width: bounds.width) {
                let mins = subviews.map { $0.sizeThatFits(.unspecified).width }
                let grows = subviews.map { $0[AxoButtonWidthKey.self] != .fit }
                // Flex: basis 0, min-width = content; free space split among growers, re-freezing
                // any grower whose share is below its minimum.
                var widths = zip(mins, grows).map { $1 ? 0 : $0 }
                var frozen = grows.map { !$0 }
                let available = bounds.width - Self.gap * CGFloat(max(0, subviews.count - 1))
                while true {
                    let used = zip(widths, frozen).filter { $1 }.map(\.0).reduce(0, +)
                    let open = frozen.indices.filter { !frozen[$0] }
                    guard !open.isEmpty else { break }
                    let share = max(0, available - used) / CGFloat(open.count)
                    let violators = open.filter { share < mins[$0] }
                    if violators.isEmpty {
                        for i in open { widths[i] = share }
                        break
                    }
                    for i in violators { widths[i] = mins[i]; frozen[i] = true }
                }
                let total = widths.reduce(0, +) + Self.gap * CGFloat(max(0, subviews.count - 1))
                let free = max(0, bounds.width - total)
                var x = bounds.minX + (justify == .center ? free / 2 : free)
                let height = bounds.height
                for (i, s) in subviews.enumerated() {
                    let h = s.sizeThatFits(ProposedViewSize(width: widths[i], height: nil)).height
                    s.place(at: CGPoint(x: x, y: bounds.minY + (height - h) / 2), proposal: ProposedViewSize(width: widths[i], height: h))
                    x += widths[i] + Self.gap
                }
            } else {
                var y = bounds.maxY
                for s in subviews {
                    let h = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                    y -= h
                    s.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
                    y -= Self.gap
                }
            }
        }
    }
}

extension EnvironmentValues {
    /// In a button group (`.axo-button-group`, dialog Actions) `*:min-w-fit` replaces each
    /// button's size minimum (min-w-12/14/16) with its content width.
    @Entry var axoButtonMinWidthFit: Bool = false
}
