// Port of ts/axo/AxoIconButton.dom.tsx: round icon-only button (with tooltip).

import SwiftUI

public enum AxoIconButton {
    public enum Variant: String, CaseIterable, Sendable {
        case strongSecondary = "strong-secondary", strongPrimary = "strong-primary", strongAffirmative = "strong-affirmative"
        case strongWarning = "strong-warning", strongDestructive = "strong-destructive"
        case subtleSecondary = "subtle-secondary", subtlePrimary = "subtle-primary", subtleAffirmative = "subtle-affirmative"
        case subtleWarning = "subtle-warning", subtleDestructive = "subtle-destructive"
        case impliedSecondary = "implied-secondary", materialSubtle = "material-subtle", materialStrong = "material-strong"
        case elevatedSecondary = "elevated-secondary"

        /// Order of upstream's Variants table (`_getAllVariants`).
        public static let all: [Variant] = [
            .strongSecondary, .strongPrimary, .strongAffirmative, .strongWarning, .strongDestructive,
            .subtleSecondary, .subtlePrimary, .subtleAffirmative, .subtleWarning, .subtleDestructive,
            .impliedSecondary, .materialSubtle, .materialStrong, .elevatedSecondary,
        ]

        enum Pressed { case none, inverted, primary }

        struct Style {
            var background: AxoColor?
            var active: AxoColor?
            var hover: AxoColor? = nil
            var label: AxoColor
            var disabled: AxoColor
            var pressedStyle: Pressed = .none
            var elevated = false
        }

        var style: Style {
            switch self {
            case .strongSecondary: Style(background: .fillSecondary, active: .fillSecondaryPressed, label: .labelPrimary, disabled: .labelDisabled, pressedStyle: .inverted)
            case .strongPrimary: Style(background: .fillAccent, active: .fillAccentPressed, label: .labelPrimaryOncolor, disabled: .labelDisabledOncolor)
            case .strongAffirmative: Style(background: .fillAffirmative, active: .fillAffirmativePressed, label: .labelPrimaryOncolor, disabled: .labelDisabledOncolor)
            case .strongWarning: Style(background: .fillWarningBright, active: .fillWarningBrightPressed, label: .labelPrimaryOnbright, disabled: .labelDisabledOnbright)
            case .strongDestructive: Style(background: .fillDestructive, active: .fillDestructivePressed, label: .labelPrimaryOncolor, disabled: .labelDisabledOncolor)
            case .subtleSecondary: Style(background: .fillPrimary, active: .fillPrimaryPressed, label: .labelPrimary, disabled: .labelDisabled, pressedStyle: .inverted)
            case .subtlePrimary: Style(background: .fillAccentTint, active: .fillAccentTintPressed, label: .labelAccent, disabled: .labelAccentDisabled)
            case .subtleAffirmative: Style(background: .fillAffirmativeTint, active: .fillAffirmativeTintPressed, label: .labelAffirmative, disabled: .labelAffirmativeDisabled)
            case .subtleWarning: Style(background: .fillWarningTint, active: .fillWarningTintPressed, label: .labelWarning, disabled: .labelWarningDisabled)
            case .subtleDestructive: Style(background: .fillDestructiveTint, active: .fillDestructiveTintPressed, label: .labelDestructive, disabled: .labelDestructiveDisabled)
            case .impliedSecondary: Style(background: nil, active: .fillPrimaryPressed, hover: .fillPrimary, label: .labelPrimary, disabled: .labelDisabled, pressedStyle: .primary)
            case .materialSubtle: Style(background: .materialSecondary, active: .materialTertiaryPressed, label: .labelPrimary, disabled: .labelDisabled, pressedStyle: .inverted)
            case .materialStrong: Style(background: .materialPrimary, active: .materialQuaternaryPressed, label: .labelPrimary, disabled: .labelDisabled)
            case .elevatedSecondary: Style(background: .materialTertiary, active: .materialTertiaryPressed, label: .labelPrimary, disabled: .labelDisabled, elevated: true)
            }
        }

        var spinnerVariant: AxoBaseSpinner.Variant {
            switch self {
            case .strongPrimary, .strongAffirmative, .strongWarning, .strongDestructive: .oncolor
            default: .default
            }
        }
    }

    public enum Size: String, CaseIterable, Sendable {
        case sm, md, lg
        var padding: CGFloat { self == .sm ? 5 : self == .md ? 6 : 8 }
        var iconSize: CGFloat { self == .sm ? 18 : 20 }
        var spinnerSize: CGFloat { self == .sm ? 16 : 18 }
    }

    /// `<AxoIconButton.Root>`
    public struct Root: View {
        let label: String
        let tooltip: Bool
        let variant: Variant
        let size: Size
        let symbol: AxoSymbol.Name
        let pending: Bool
        let pressed: Bool?
        let disabled: Bool
        let autoFocus: Bool
        let action: () -> Void
        @State private var hovered = false
        private var focus = AxoFocusState()

        public init(label: String, tooltip: Bool = true, variant: Variant, size: Size, symbol: AxoSymbol.Name, pending: Bool = false,
                    pressed: Bool? = nil, disabled: Bool = false, autoFocus: Bool = false, action: @escaping () -> Void = {}) {
            self.autoFocus = autoFocus
            self.label = label
            self.tooltip = tooltip
            self.variant = variant
            self.size = size
            self.symbol = symbol
            self.pending = pending
            self.pressed = pressed
            self.disabled = disabled
            self.action = action
        }

        public var body: some View {
            let style = variant.style
            let isDisabled = pending || disabled
            let on = pressed == true
            let focusVisible = focus.visible(autoFocus: autoFocus)
            var label: AxoColor = isDisabled ? style.disabled : style.label
            var fill = style.background
            var active = style.active
            if on {
                switch style.pressedStyle {
                case .inverted:
                    fill = .fillInverted; active = .fillInvertedPressed
                    label = isDisabled ? .labelDisabledInverted : .labelPrimaryInverted
                case .primary:
                    fill = .fillAccent; active = .fillAccentPressed
                    label = isDisabled ? .labelDisabledOncolor : .labelPrimaryOncolor
                case .none: break
                }
            }
            return Button {
                if !isDisabled { action() }
            } label: {
                AxoSymbol.Icon(symbol, size: size.iconSize, label: nil)
                    .opacity(pending ? 0 : 1)
                    .cssTextColor(label)
                    .padding(size.padding)
                    .overlay {
                        if pending {
                            AxoBaseSpinner.Root(size: size.spinnerSize, weight: .regular, variant: variant.spinnerVariant, value: .indeterminate, track: false)
                        }
                    }
            }
            .buttonStyle(AxoIconButtonStyle(fill: (focusVisible && variant == .impliedSecondary && !on) ? .fillPrimary : fill,
                                            active: isDisabled ? nil : active,
                                            hover: (!isDisabled && !on) ? style.hover : nil, hovered: hovered, elevated: style.elevated))
            .axoFocusRing(focusVisible, in: Circle())
            .focusable(interactions: .activate)
            .focusEffectDisabled()
            .focused(focus.$focused)
            .onChange(of: focus.focused) { _, now in if !now { focus.autoFocusConsumed = true } }
            .onHover { hovered = $0 }
            .help(tooltip ? self.label : "")
            .accessibilityLabel(pending ? "Pending" : self.label)
            .accessibilityAddTraits(pressed == true ? .isSelected : [])
        }
    }
}

struct AxoIconButtonStyle: ButtonStyle {
    let fill: AxoColor?
    let active: AxoColor?
    let hover: AxoColor?
    let hovered: Bool
    let elevated: Bool

    func makeBody(configuration: Configuration) -> some View {
        let color = configuration.isPressed ? (active ?? fill) : hovered ? (hover ?? fill) : fill
        configuration.label
            .background { if let color { Circle().fill(color) } }
            .modifier(ElevatedModifier(on: elevated, shape: Circle()))
            .contentShape(Circle())
    }
}
