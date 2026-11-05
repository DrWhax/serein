// Port of ts/axo/AxoCheckbox.dom.tsx (Radix Checkbox): round (20) or square (16) box
// with a check icon.

import SwiftUI

public enum AxoCheckbox {
    public enum Variant: String, CaseIterable, Sendable {
        case round, square
        var size: CGFloat { self == .round ? 20 : 16 }
        var iconSize: CGFloat { self == .round ? 14 : 12 }
    }

    /// `<AxoCheckbox.Root>`
    public struct Root: View {
        let variant: Variant
        @Binding var checked: Bool
        let disabled: Bool
        let label: String?
        @GestureState private var pressed = false

        public init(variant: Variant, checked: Binding<Bool>, disabled: Bool = false, label: String? = nil) {
            self.variant = variant
            _checked = checked
            self.disabled = disabled
            self.label = label
        }

        public var body: some View {
            let shape = AnyInsettableShape(variant == .round ? AnyInsettableShape(Circle()) : AnyInsettableShape(RoundedRectangle(cornerRadius: AxoRadius.sm)))
            let fill: AxoColor = checked ? (pressed && !disabled ? .fillAccentPressed : .fillAccent)
                : (pressed && !disabled ? .fillControlPressed : .fillControl)
            ZStack {
                if checked {
                    AxoSymbol.Icon("check", size: variant.iconSize, label: nil)
                        .cssTextColor(disabled ? .labelDisabledOncolor : .labelPrimaryOncolor)
                }
            }
            .frame(width: variant.size, height: variant.size)
            .background { shape.fill(fill) }
            .modifier(CheckboxShadow(checked: checked, disabled: disabled, shape: shape))
            .overlay { shape.strokeBorder(AxoColor.borderSecondary, lineWidth: 1) }
            .contentShape(shape)
            .gesture(DragGesture(minimumDistance: 0).updating($pressed) { _, s, _ in s = !disabled }.onEnded { _ in
                if !disabled { checked.toggle() }
            })
            .accessibilityElement()
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(checked ? "checked" : "unchecked")
            .accessibilityLabel(label ?? "")
        }
    }

    /// unchecked+enabled: inset-shadow-on-color; checked+enabled: 0 1px 1px shadow-color-elevation-1.
    struct CheckboxShadow<S: InsettableShape>: ViewModifier {
        let checked: Bool
        let disabled: Bool
        let shape: S
        @Environment(\.colorScheme) var scheme
        func body(content: Content) -> some View {
            if disabled {
                content
            } else if checked {
                content.cssBoxShadow([.init(inset: false, x: 0, y: 1, blur: 1, spread: 0, color: AxoColor.shadowColorElevation1.value(for: scheme))], in: shape)
            } else {
                content.cssBoxShadow(AxoSwitch.Root.trackShadow, in: shape)
            }
        }
    }
}

/// Type-erased InsettableShape (SwiftUI's AnyShape is not insettable).
public struct AnyInsettableShape: InsettableShape {
    let pathFn: @Sendable (CGRect) -> Path
    let insetFn: @Sendable (CGFloat) -> AnyInsettableShape

    public init<S: InsettableShape>(_ shape: S) where S.InsetShape: Sendable, S: Sendable {
        pathFn = { shape.path(in: $0) }
        insetFn = { AnyInsettableShape(shape.inset(by: $0)) }
    }

    public func path(in rect: CGRect) -> Path { pathFn(rect) }
    public func inset(by amount: CGFloat) -> AnyInsettableShape { insetFn(amount) }
}
