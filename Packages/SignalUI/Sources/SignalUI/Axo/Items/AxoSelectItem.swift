// Port of ts/axo/items/AxoSelectItem.dom.tsx: an item whose accessory is a select.

import SwiftUI

public enum AxoSelectItem {
    public struct Option: Sendable, Hashable {
        public var value: String
        public var label: String
        public var disabled: Bool
        public init(value: String, label: String, disabled: Bool = false) {
            self.value = value
            self.label = label
            self.disabled = disabled
        }
    }

    /// `<AxoSelectItem.Root>`
    public struct Root: View {
        let symbol: AxoSymbol.Name?
        let label: String
        let description: String?
        let disabled: Bool
        let placeholder: String?
        let options: [Option]
        let forceStackedLayout: Bool
        @Binding var value: String?

        public init(symbol: AxoSymbol.Name? = nil, label: String, description: String? = nil, disabled: Bool = false,
                    placeholder: String?, value: Binding<String?>, options: [Option], forceStackedLayout: Bool = false) {
            self.symbol = symbol
            self.label = label
            self.description = description
            self.disabled = disabled
            self.placeholder = placeholder
            self.options = options
            self.forceStackedLayout = forceStackedLayout
            _value = value
        }

        public var body: some View {
            AxoBaseItem.Root(disabled: disabled, forceStackedLayout: forceStackedLayout) {
                if let symbol {
                    AxoBaseItem.Leading { AxoBaseItem.Icon(symbol: symbol) }
                }
                AxoBaseItem.Content {
                    AxoBaseItem.Label(label)
                    if let description { AxoBaseItem.Description(description) }
                    AxoBaseItem.Accessory {
                        AxoSelect.Root(label: label, value: $value, disabled: disabled) {
                            AxoBaseItem.DescribedBy { AxoSelect.Trigger(placeholder: placeholder) }
                            AxoSelect.Content {
                                ForEach(options, id: \.value) { option in
                                    AxoSelect.Item(value: option.value, disabled: option.disabled) { AxoSelect.ItemText(option.label) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
