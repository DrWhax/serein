// Port of ts/components/CircleCheckbox.dom.tsx + stylesheets/components/CircleCheckbox.scss:
// a round checkbox (or radio) with no label. Upstream hides the native control (0×0 input)
// and paints its ::before (the ring, 1.5px; 2px for a checked radio) and ::after (the check
// mark or radio dot).

import SwiftUI

public struct CircleCheckbox: View {
    /// `Variant`
    public enum Variant: Sendable, Hashable { case normal, small }

    let variant: Variant
    let checked: Bool
    let disabled: Bool
    let isRadio: Bool
    let onChange: ((Bool) -> Void)?
    let onClick: (() -> Void)?
    private var focus = AxoFocusState()

    public init(variant: Variant = .normal, checked: Bool = false, disabled: Bool = false, isRadio: Bool = false,
                onChange: ((Bool) -> Void)? = nil, onClick: (() -> Void)? = nil) {
        self.variant = variant
        self.checked = checked
        self.disabled = disabled
        self.isRadio = isRadio
        self.onChange = onChange
        self.onClick = onClick
    }

    var size: CGFloat { variant == .small ? 18 : 20 }

    static let ultramarine = AxoColor(LegacyColor.ultramarine)

    /// Blink floors a border width of 1px or more to whole CSS pixels (1.5px paints as 1px).
    static func usedBorderWidth(_ w: CGFloat) -> CGFloat { w >= 1 ? w.rounded(.down) : w }

    /// ::before border colour and width.
    var ring: (color: AxoColor, width: CGFloat) {
        let rest = AxoColor(light: LegacyColor.gray25, dark: LegacyColor.gray65)
        let off = AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray45)
        if isRadio && checked {
            // The radio rule comes after (and, in light theme, ties with) the :disabled:checked rule.
            return (disabled ? AxoColor(light: LegacyColor.ultramarine, dark: LegacyColor.gray45) : Self.ultramarine, 2)
        }
        if checked { return (disabled ? off : Self.ultramarine, 1.5) }
        return (disabled ? off : rest, 1.5)
    }

    /// ::before background
    var fill: AxoColor? {
        if checked && disabled { return AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray45) }
        if checked && !isRadio { return Self.ultramarine }
        return nil
    }

    public var body: some View {
        let ring = self.ring
        ZStack(alignment: .topLeading) {
            Circle().fill(fill ?? AxoColor(LegacyColor.transparent))
            Circle().strokeBorder(ring.color, lineWidth: Self.usedBorderWidth(ring.width))
            if checked { mark }
        }
        .frame(width: size, height: size)
        .axoFocusRing(focus.visible(autoFocus: false), in: Circle())
        .contentShape(Circle())
        .onTapGesture { toggle() }
        .focusable(!disabled, interactions: .activate)
        .focusEffectDisabled()
        .focused(focus.$focused)
        .onKeyPress(.space) { toggle(); return .handled }
        .accessibilityElement()
        .accessibilityAddTraits(isRadio ? [.isToggle] : [.isToggle])
        .accessibilityValue(checked ? "checked" : "unchecked")
    }

    func toggle() {
        guard !disabled else { return }
        onClick?()
        if isRadio && checked { return }
        onChange?(!checked)
    }

    /// ::after
    @ViewBuilder var mark: some View {
        switch (isRadio, variant) {
        case (true, .normal):
            Circle().fill(Self.ultramarine).frame(width: 12, height: 12).offset(x: 4, y: 4)
        case (true, .small):
            Circle().fill(Self.ultramarine).frame(width: 10, height: 10).offset(x: 4, y: 4)
        case (false, .normal):
            // 14×14 at 3,3: white through the check-compact-bold mask
            LegacyIcon.Mask(.checkCompactBold, color: AxoColor(LegacyColor.white)).frame(width: 14, height: 14).offset(x: 3, y: 3)
        case (false, .small):
            // A 5×10 box (left 7, top 3, rotate(45deg)) whose white border-right/bottom are still
            // masked by the inherited check-compact-bold mask (mask-size 100%: 5×5, centred).
            LegacyIcon.Mask(.checkCompactBold, color: AxoColor(LegacyColor.white))
                .frame(width: 5, height: 10)
                .rotationEffect(.degrees(45))
                .offset(x: 7, y: 3)
        }
    }
}
