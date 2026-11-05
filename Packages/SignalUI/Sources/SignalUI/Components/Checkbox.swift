// Port of ts/components/Checkbox.dom.tsx + stylesheets/components/Checkbox.scss: a native
// checkbox (or radio) with a label and an optional description. Upstream leaves the <input>
// to Chromium's form-control painting (18×18 here), reproduced by `NativeCheckbox`.

import SwiftUI

public struct Checkbox: View {
    let label: String
    let description: String?
    let checked: Bool
    let disabled: Bool
    let isRadio: Bool
    let name: String
    let onChange: (Bool) -> Void
    let onClick: (() -> Void)?

    public init(label: String, description: String? = nil, name: String, checked: Bool = false, disabled: Bool = false, isRadio: Bool = false,
                onChange: @escaping (Bool) -> Void, onClick: (() -> Void)? = nil) {
        self.label = label
        self.description = description
        self.name = name
        self.checked = checked
        self.disabled = disabled
        self.isRadio = isRadio
        self.onChange = onChange
        self.onClick = onClick
    }

    func toggle() {
        guard !disabled else { return }
        onClick?()
        if isRadio && checked { return }
        onChange(!checked)
    }

    public var body: some View {
        // .Checkbox__container: flex, items-center; .Checkbox__checkbox: 18×18, margin-inline-end 20px
        HStack(alignment: .center, spacing: 20) {
            NativeCheckbox(checked: checked, disabled: disabled, isRadio: isRadio, toggle: toggle)
            // <label>: the label, then .Checkbox__description (font-subtitle, label-secondary)
            VStack(alignment: .leading, spacing: 0) {
                CSSText(label, type: .bodyLarge)
                CSSText(description ?? "", style: LegacyType.subtitle(), color: .labelSecondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(name)
    }
}

/// Chromium's own (form-controls refresh) checkbox and radio, as painted at 18×18: a 2px-radius
/// box with a 1px border, filled with the accent colour and a stroked check when checked.
/// Colours are the UA's light / dark control palette (not design tokens).
struct NativeCheckbox: View {
    let checked: Bool
    let disabled: Bool
    let isRadio: Bool
    let toggle: () -> Void
    private var focus = AxoFocusState()

    init(checked: Bool, disabled: Bool, isRadio: Bool, toggle: @escaping () -> Void) {
        self.checked = checked
        self.disabled = disabled
        self.isRadio = isRadio
        self.toggle = toggle
    }

    static let accent = AxoColor(light: RGBA(hex: 0x0075FF), dark: RGBA(hex: 0x99C8FF))
    static let accentDisabled = AxoColor(light: RGBA(hex: 0x767676, alpha: 0.3), dark: RGBA(hex: 0x626262))
    static let background = AxoColor(light: RGBA(hex: 0xFFFFFF), dark: RGBA(hex: 0x3B3B3B))
    static let backgroundDisabled = AxoColor(light: RGBA(hex: 0xEFEFEF, alpha: 0.3), dark: RGBA(hex: 0x3B3B3B))
    static let border = AxoColor(light: RGBA(hex: 0x767676), dark: RGBA(hex: 0x858585))
    static let borderDisabled = AxoColor(light: RGBA(hex: 0x767676, alpha: 0.3), dark: RGBA(hex: 0x626262))

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: isRadio ? 9 : 2)
        ZStack {
            if checked {
                shape.fill(disabled ? Self.accentDisabled : Self.accent)
                if isRadio {
                    Circle().inset(by: 4).fill(Self.background)
                    Circle().inset(by: 5.5).fill(disabled ? Self.accentDisabled : Self.accent)
                } else {
                    CheckMark().stroke(Self.background, style: StrokeStyle(lineWidth: 18 * 0.16))
                }
            } else {
                shape.fill(disabled ? Self.backgroundDisabled : Self.background)
                shape.strokeBorder(disabled ? Self.borderDisabled : Self.border, lineWidth: 1)
            }
        }
        .frame(width: 18, height: 18)
        .axoFocusRing(focus.visible(autoFocus: false), in: shape)
        .contentShape(shape)
        .onTapGesture { toggle() }
        .focusable(!disabled, interactions: .activate)
        .focusEffectDisabled()
        .focused(focus.$focused)
        .onKeyPress(.space) { toggle(); return .handled }
    }

    /// NativeThemeBase::PaintCheckbox: (0.2w, 0.5h) → +(0.2w, 0.2h) → (0.8w, 0.2h).
    struct CheckMark: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX + r.width * 0.2, y: r.minY + r.height * 0.5))
            p.addLine(to: CGPoint(x: r.minX + r.width * 0.4, y: r.minY + r.height * 0.7))
            p.addLine(to: CGPoint(x: r.maxX - r.width * 0.2, y: r.minY + r.height * 0.2))
            return p
        }
    }
}
