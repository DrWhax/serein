// Port of ts/axo/fields/AxoSearchField.dom.tsx: a rounded search field (variant "search").
//
//   AxoSearchField.Root(value: $query) {
//       AxoSearchField.Icon()
//       AxoSearchField.Input(placeholder: "Search")
//       AxoSearchField.Clear()
//   }

import SwiftUI

public enum AxoSearchField {
    /// `<AxoSearchField.Root>`; limits default to 1 KiB (UnitBytes.KILOBYTE).
    public struct Root: View {
        let base: AxoBaseField.Root

        public init(value: Binding<String>, disabled: Bool = false, maxBytes: Int = 1024, maxGraphemes: Int = 1024,
                    @AxoBaseField.FieldPartsBuilder parts: () -> [AxoBaseField.FieldPartItem]) {
            base = AxoBaseField.Root(variant: .search, value: value, maxGraphemes: maxGraphemes, maxBytes: maxBytes, disabled: disabled,
                                     parts: parts)
        }

        public var body: some View { base }
    }

    /// `<AxoSearchField.Icon>`: the search glyph.
    public struct Icon: AxoBaseField.FieldPart {
        public init() {}
        public var fieldPart: AxoBaseField.FieldPartItem { AxoBaseField.Icon(symbol: "search").fieldPart }
    }

    /// `<AxoSearchField.Input>`
    public struct Input: AxoBaseField.FieldPart {
        let placeholder: String
        let autoFocus: Bool
        public init(placeholder: String, autoFocus: Bool = false) {
            self.placeholder = placeholder
            self.autoFocus = autoFocus
        }
        public var fieldPart: AxoBaseField.FieldPartItem {
            AxoBaseField.Input(type: .search, placeholder: placeholder, autoFocus: autoFocus).fieldPart
        }
    }

    /// `<AxoSearchField.Clear>`
    public struct Clear: AxoBaseField.FieldPart {
        public init() {}
        public var fieldPart: AxoBaseField.FieldPartItem { AxoBaseField.Clear().fieldPart }
    }
}
