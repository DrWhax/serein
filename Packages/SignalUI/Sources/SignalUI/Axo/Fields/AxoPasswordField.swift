// Port of ts/axo/fields/AxoPasswordField.dom.tsx: a text field whose value is concealed
// until the Reveal action is pressed (Root owns the revealed state, upstream's context).
//
//   AxoPasswordField.Root(value: $password, maxGraphemes: 64, maxBytes: 256) {
//       AxoPasswordField.Input(placeholder: "Password", autoComplete: .currentPassword)
//       AxoPasswordField.Reveal()
//   }

import SwiftUI

public enum AxoPasswordField {
    public enum AutoComplete: Sendable, Hashable { case currentPassword, newPassword }

    /// `<AxoPasswordField.Root>`
    public struct Root: View {
        let value: Binding<String>
        let maxGraphemes: Int
        let maxBytes: Int
        let disabled: Bool
        let parts: [AxoBaseField.FieldPartItem]
        @State private var revealed = false

        public init(value: Binding<String>, maxGraphemes: Int, maxBytes: Int, disabled: Bool = false,
                    @AxoBaseField.FieldPartsBuilder parts: () -> [AxoBaseField.FieldPartItem]) {
            self.value = value
            self.maxGraphemes = maxGraphemes
            self.maxBytes = maxBytes
            self.disabled = disabled
            self.parts = parts()
        }

        public var body: some View {
            AxoBaseField.Root(variant: .text, value: value, maxGraphemes: maxGraphemes, maxBytes: maxBytes, disabled: disabled,
                              readOnly: false, revealed: $revealed, parts: parts)
        }
    }

    /// `<AxoPasswordField.Input>`: concealed (bullets) unless revealed.
    public struct Input: AxoBaseField.FieldPart {
        let placeholder: String
        let autoComplete: AutoComplete
        let autoFocus: Bool
        public init(placeholder: String, autoComplete: AutoComplete, autoFocus: Bool = false) {
            self.placeholder = placeholder
            self.autoComplete = autoComplete
            self.autoFocus = autoFocus
        }
        public var fieldPart: AxoBaseField.FieldPartItem {
            AxoBaseField.Input(type: .password, placeholder: placeholder, autoFocus: autoFocus).fieldPart
        }
    }

    /// `<AxoPasswordField.Reveal>`: toggles between "visible" and "visible-slash".
    public struct Reveal: AxoBaseField.FieldPart {
        public init() {}
        public var fieldPart: AxoBaseField.FieldPartItem { AxoBaseField.Reveal().fieldPart }
    }
}
