// Port of ts/axo/fields/AxoFieldGroup.dom.tsx: several fields in one text-field container,
// divided by Separators (e.g. given + family name, username + discriminator).
//
//   AxoFieldGroup.Root(label: "Name") {
//       AxoTextField.Root(…) { AxoTextField.Input(placeholder: "Given name") }
//       AxoFieldGroup.Separator()
//       AxoTextField.Root(…) { AxoTextField.Input(placeholder: "Family name") }
//   }

import SwiftUI

public enum AxoFieldGroup {
    /// `<AxoFieldGroup.Root>`
    public struct Root<Content: View>: View {
        let label: String?
        let disabled: Bool
        let readOnly: Bool
        let content: Content

        public init(label: String? = nil, disabled: Bool = false, readOnly: Bool = false, @ViewBuilder content: () -> Content) {
            self.label = label
            self.disabled = disabled
            self.readOnly = readOnly
            self.content = content()
        }

        public var body: some View {
            AxoBaseField.Group(label: label, disabled: disabled, readOnly: readOnly) { content }
        }
    }

    /// `<AxoFieldGroup.Separator>`
    public typealias Separator = AxoBaseField.Separator
}
