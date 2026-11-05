// Port of ts/axo/items/AxoTextItem.dom.tsx: a non-interactive item of text.

import SwiftUI

public enum AxoTextItem {
    public typealias Variant = AxoBaseItem.Variant

    /// `<AxoTextItem.Root>`
    public struct Root<Trailing: View>: View {
        let variant: Variant
        let symbol: AxoSymbol.Name?
        let label: String
        /// Rich label content (`label` is then its accessible text).
        var labelView: AnyView?
        let value: String?
        let description: String?
        let trailing: Trailing?

        public init(variant: Variant = .secondary, symbol: AxoSymbol.Name? = nil, label: String, value: String? = nil,
                    description: String? = nil, @ViewBuilder trailing: () -> Trailing) {
            self.variant = variant
            self.symbol = symbol
            self.label = label
            self.value = value
            self.description = description
            let t = trailing()
            self.trailing = t is EmptyView ? nil : t
        }

        public var body: some View {
            AxoItem.Root(variant: variant) {
                if let symbol {
                    AxoItem.Leading { AxoItem.Icon(symbol: symbol) }
                }
                AxoItem.Content {
                    if let labelView { AxoItem.Label { labelView } } else { AxoItem.Label(label) }
                    if let value { AxoItem.Value(value) }
                    if let description { AxoItem.Description(description) }
                    if let trailing { AxoItem.Trailing { trailing } }
                }
            }
        }
    }
}

extension AxoTextItem.Root where Trailing == EmptyView {
    public init(variant: AxoTextItem.Variant = .secondary, symbol: AxoSymbol.Name? = nil, label: String, value: String? = nil,
                description: String? = nil) {
        self.init(variant: variant, symbol: symbol, label: label, value: value, description: description, trailing: { EmptyView() })
    }
}

extension AxoTextItem.Root where Trailing == EmptyView {
    /// A label of rich content; `accessibilityLabel` is its text.
    public init(variant: AxoTextItem.Variant = .secondary, symbol: AxoSymbol.Name? = nil, accessibilityLabel: String,
                @ViewBuilder label: () -> some View) {
        self.init(variant: variant, symbol: symbol, label: accessibilityLabel)
        labelView = AnyView(label())
    }
}
