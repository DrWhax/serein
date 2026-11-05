// Port of ts/axo/fields/AxoTextField.dom.tsx: a text field (variant "text") built from
// AxoBaseField parts.
//
//   AxoTextField.Root(value: $value, maxGraphemes: 200, maxBytes: 800) {
//       AxoTextField.Icon(symbol: "label")
//       AxoTextField.Input(placeholder: "Placeholder")
//       AxoTextField.Count()
//       AxoTextField.Clear()
//   }

import SwiftUI

public enum AxoTextField {
    /// `<AxoTextField.Root>`
    public struct Root: View {
        let base: AxoBaseField.Root

        public init(value: Binding<String>, maxGraphemes: Int, maxBytes: Int, disabled: Bool = false, readOnly: Bool = false,
                    @AxoBaseField.FieldPartsBuilder parts: () -> [AxoBaseField.FieldPartItem]) {
            base = AxoBaseField.Root(variant: .text, value: value, maxGraphemes: maxGraphemes, maxBytes: maxBytes, disabled: disabled,
                                     readOnly: readOnly, parts: parts)
        }

        public var body: some View { base }
    }

    public typealias InputSizing = AxoBaseField.InputSizing
    /// `<AxoTextField.Input>`
    public typealias Input = AxoBaseField.Input
    /// `<AxoTextField.TextArea>`
    public typealias TextArea = AxoBaseField.TextArea
    /// `<AxoTextField.Count>`
    public typealias Count = AxoBaseField.Count
    /// `<AxoTextField.Clear>`
    public typealias Clear = AxoBaseField.Clear
    /// `<AxoTextField.Icon>`
    public typealias Icon = AxoBaseField.Icon
    /// `<AxoTextField.Action>`
    public typealias Action = AxoBaseField.Action
    /// `<AxoTextField.LoadingIndicator>`
    public typealias LoadingIndicator = AxoBaseField.LoadingIndicator
    /// `<AxoTextField.ValidationError>`
    public typealias ValidationError = AxoBaseField.ValidationError
    /// `<AxoTextField.CustomLeadingSlot>`
    public typealias CustomLeadingSlot = AxoBaseField.CustomLeadingSlot
    /// `<AxoTextField.CustomTrailingSlot>`
    public typealias CustomTrailingSlot = AxoBaseField.CustomTrailingSlot
    /// `<AxoTextField.CustomAction>`
    public typealias CustomAction = AxoBaseField.CustomAction
}
