// Port of ts/components/Button.dom.tsx + stylesheets/components/Button.scss: the legacy
// `.module-Button` (pre-Axo), still used by modals and many screens.
// Named `LegacyButton` because `Button` would shadow SwiftUI.Button in this module;
// upstream's `ButtonSize` / `ButtonVariant` are `LegacyButton.Size` / `.Variant`.

import SwiftUI

public struct LegacyButton: View {
    /// `ButtonSize`
    public enum Size: Sendable, Hashable, CaseIterable {
        case large, medium, small
    }

    /// `ButtonVariant` (upstream order)
    public enum Variant: String, Sendable, Hashable, CaseIterable {
        case calling = "Calling"
        case destructive = "Destructive"
        case primary = "Primary"
        case secondary = "Secondary"
        case secondaryAffirmative = "SecondaryAffirmative"
        case secondaryDestructive = "SecondaryDestructive"
        case systemMessage = "SystemMessage"

        struct Style {
            var background: AxoColor
            var pressed: AxoColor
            var label: AxoColor
            /// `[disabled]` / `--discouraged`
            var disabled: AxoColor
        }

        var style: Style {
            switch self {
            case .primary: Style(background: .fillAccent, pressed: .fillAccentPressed, label: .labelPrimaryOncolor, disabled: .labelDisabledOncolor)
            case .secondary: Style(background: .fillSecondary, pressed: .fillSecondaryPressed, label: .labelPrimary, disabled: .labelDisabledOncolor)
            case .secondaryAffirmative: Style(background: .fillSecondary, pressed: .fillSecondaryPressed, label: .labelAccent, disabled: .labelAccentDisabled)
            case .secondaryDestructive:
                Style(background: .fillSecondary, pressed: .fillSecondaryPressed, label: .labelDestructive, disabled: .labelDestructiveDisabled)
            case .destructive: Style(background: .fillDestructive, pressed: .fillDestructivePressed, label: .labelPrimaryOncolor, disabled: .labelDisabledOncolor)
            case .calling: Style(background: .fillAffirmative, pressed: .fillAffirmativePressed, label: .labelPrimaryOncolor, disabled: .labelDisabledOncolor)
            case .systemMessage: Style(background: .fillPrimary, pressed: .fillPrimaryPressed, label: .labelAccent, disabled: .labelAccentDisabled)
            }
        }

        /// `rounded-corners` (9999px) for system-message buttons and every small button.
        func capsule(_ size: Size) -> Bool { self == .systemMessage || size == .small }
    }

    let label: String?
    let size: Size
    let variant: Variant
    let disabled: Bool
    let discouraged: Bool
    let ariaLabel: String?
    let autoFocus: Bool
    let action: () -> Void
    private var focus = AxoFocusState()

    /// `children` is `label`; a button with only `aria-label` has no visible text.
    /// Per-use class overrides (e.g. `.UsernameMegaphone__buttons__button`).
    public struct Overrides: Sendable {
        public var fontWeight: Int?
        public var paddingBlock: CGFloat?
        public var background: AxoColor?
        public var paddingInline: CGFloat?
        public var radius: CGFloat?
        public var textColor: AxoColor?
        /// A fixed border-box height (the label centred in it).
        public var height: CGFloat?
        /// A fixed border-box width (`style={{ width }}`).
        public var width: CGFloat?
        /// font-size / line-height overrides (the weight stays the size's).
        public var fontSize: CGFloat?
        public var lineHeight: CGFloat?
        public init(fontWeight: Int? = nil, paddingBlock: CGFloat? = nil, background: AxoColor? = nil, paddingInline: CGFloat? = nil,
                    radius: CGFloat? = nil, textColor: AxoColor? = nil, height: CGFloat? = nil, width: CGFloat? = nil, fontSize: CGFloat? = nil,
                    lineHeight: CGFloat? = nil) {
            self.height = height
            self.width = width
            self.fontSize = fontSize
            self.lineHeight = lineHeight
            self.fontWeight = fontWeight
            self.paddingBlock = paddingBlock
            self.background = background
            self.paddingInline = paddingInline
            self.radius = radius
            self.textColor = textColor
        }
    }
    var overrides = Overrides()

    public init(_ label: String?, size: Size = .medium, variant: Variant = .primary, disabled: Bool = false, discouraged: Bool = false,
                ariaLabel: String? = nil, autoFocus: Bool = false, overrides: Overrides = Overrides(), action: @escaping () -> Void = {}) {
        self.overrides = overrides
        self.label = label
        self.size = size
        self.variant = variant
        self.disabled = disabled
        self.discouraged = discouraged
        self.ariaLabel = ariaLabel
        self.autoFocus = autoFocus
        self.action = action
    }

    var textStyle: CSSTextStyle {
        var style = baseTextStyle
        if let w = overrides.fontWeight { style.fontName = AxoFonts.interName(weight: w) }
        if let f = overrides.fontSize { style.size = f }
        if let l = overrides.lineHeight { style.lineHeight = l }
        return style
    }

    var baseTextStyle: CSSTextStyle {
        switch size {
        case .large: LegacyType.title2(weight: 700)                                    // font-title-2; font-weight: bold
        case .medium: LegacyType.body1(weight: 600)                                    // font-body-1-bold
        case .small: LegacyType.body2(weight: variant == .systemMessage ? 500 : 400)   // font-body-2
        }
    }

    var padding: EdgeInsets {
        var p = basePadding
        if let b = overrides.paddingBlock { p.top = b; p.bottom = b }
        if let i = overrides.paddingInline { p.leading = i; p.trailing = i }
        return p
    }

    var basePadding: EdgeInsets {
        switch size {
        case .large, .medium: EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        case .small:
            variant == .systemMessage ? EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12) : EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        }
    }

    public var body: some View {
        let style = variant.style
        let radius: CGFloat = overrides.radius ?? (variant.capsule(size) ? 9999 : 4)
        let shape = RoundedRectangle(cornerRadius: radius)
        SwiftUI.Button {
            if !disabled { action() }
        } label: {
            Group {
                if let label { CSSText(label, style: textStyle, alignment: .center) } else { Color.clear.frame(width: 0, height: 0) }
            }
            .cssTextColor(disabled || discouraged ? style.disabled : overrides.textColor ?? style.label)
            .padding(padding)
            .frame(width: overrides.width, height: overrides.height)
        }
        .buttonStyle(LegacyButtonStyle(background: overrides.background ?? style.background,
                                       pressed: overrides.background ?? (disabled || discouraged ? style.background : style.pressed),
                                       radius: radius))
        .disabled(disabled)
        .axoFocusRing(focus.visible(autoFocus: autoFocus), in: shape)
        .focusable(!disabled, interactions: .activate)
        .focusEffectDisabled()
        .focused(focus.$focused)
        .onChange(of: focus.focused) { _, now in if !now { focus.autoFocusConsumed = true } }
        .accessibilityLabel(ariaLabel ?? label ?? "")
    }
}

struct LegacyButtonStyle: ButtonStyle {
    let background: AxoColor
    let pressed: AxoColor
    let radius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        configuration.label
            .background { shape.fill(configuration.isPressed ? pressed : background) }
            .contentShape(shape)
    }
}
