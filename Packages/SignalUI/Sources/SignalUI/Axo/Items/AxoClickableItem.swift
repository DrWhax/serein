// Port of ts/axo/items/AxoClickableItem.dom.tsx: a whole-item button with an optional
// icon, value, description, accessory and arrow.

import SwiftUI

public enum AxoClickableItem {
    public typealias Variant = AxoBaseItem.Variant
    public typealias ArrowKind = AxoBaseItem.ArrowKind

    /// `<AxoClickableItem.Root>`
    public struct Root<Accessory: View>: View {
        let variant: Variant
        let symbol: AxoSymbol.Name?
        let label: String
        /// Rich label content (`label` is then its accessible text).
        var labelView: AnyView?
        let description: String?
        let value: String?
        let accessory: Accessory?
        let arrow: ArrowKind?
        let disabled: Bool
        let tooltip: String?
        let onClick: () -> Void

        public init(variant: Variant = .secondary, symbol: AxoSymbol.Name? = nil, label: String, description: String? = nil,
                    value: String? = nil, arrow: ArrowKind? = nil, disabled: Bool = false, tooltip: String? = nil,
                    onClick: @escaping () -> Void, @ViewBuilder accessory: () -> Accessory) {
            self.variant = variant
            self.symbol = symbol
            self.label = label
            self.description = description
            self.value = value
            let a = accessory()
            self.accessory = a is EmptyView ? nil : a
            self.arrow = arrow
            self.disabled = disabled
            self.tooltip = tooltip
            self.onClick = onClick
        }

        public var body: some View {
            AxoItem.Root(variant: variant, disabled: disabled) {
                if let symbol {
                    AxoItem.Leading { AxoItem.Icon(symbol: symbol) }
                }
                AxoItem.Content {
                    if let labelView { AxoItem.Label { labelView } } else { AxoItem.Label(label) }
                    if let value { AxoItem.Value(value) }
                    if let description { AxoItem.Description(description) }
                    AxoItem.HiddenTrigger(label: label, action: onClick)
                    if let accessory { AxoItem.Accessory { accessory } }
                    if let arrow { AxoItem.Trailing { AxoItem.Arrow(kind: arrow) } }
                }
            }
            .help(tooltip ?? "")
        }
    }
}

extension AxoClickableItem.Root where Accessory == EmptyView {
    public init(variant: AxoClickableItem.Variant = .secondary, symbol: AxoSymbol.Name? = nil, label: String, description: String? = nil,
                value: String? = nil, arrow: AxoClickableItem.ArrowKind? = nil, disabled: Bool = false, tooltip: String? = nil,
                onClick: @escaping () -> Void) {
        self.init(variant: variant, symbol: symbol, label: label, description: description, value: value, arrow: arrow,
                  disabled: disabled, tooltip: tooltip, onClick: onClick, accessory: { EmptyView() })
    }
}

extension AxoClickableItem.Root where Accessory == EmptyView {
    /// A label of rich content; `accessibilityLabel` is its text.
    public init(variant: AxoClickableItem.Variant = .secondary, symbol: AxoSymbol.Name? = nil, accessibilityLabel: String,
                arrow: AxoClickableItem.ArrowKind? = nil, disabled: Bool = false, onClick: @escaping () -> Void, @ViewBuilder label: () -> some View) {
        self.init(variant: variant, symbol: symbol, label: accessibilityLabel, arrow: arrow, disabled: disabled, onClick: onClick)
        labelView = AnyView(label())
    }
}
