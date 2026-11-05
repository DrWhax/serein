// AxoFieldList stories (ts/axo/items/AxoFieldList.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

/// `GivenName` / `FamilyName`: an empty text field with a count and a clear button.
struct FieldListNameField: View {
    let placeholder: String
    @State var value = ""
    var body: some View {
        AxoTextField.Root(value: $value, maxGraphemes: 26, maxBytes: 128) {
            AxoTextField.Input(placeholder: placeholder)
            AxoTextField.Count()
            AxoTextField.Clear()
        }
    }
}

@MainActor func fieldListGivenName() -> FieldListNameField { FieldListNameField(placeholder: "First name (Required)") }
@MainActor func fieldListFamilyName() -> FieldListNameField { FieldListNameField(placeholder: "Last name (Optional)") }

@MainActor
@Suite struct AxoFieldListTests {
    static let profileText = "Your profile and changes to it will be visible to people you message, contacts and groups."

    @Test(arguments: ["light", "dark"]) func basic(theme: String) throws {
        let view = AxoFieldList.Root {
            AxoFieldList.Item { fieldListGivenName() }
            AxoFieldList.Item { fieldListFamilyName() }
        }
        try itemsSnapshot(view, story: "axo-items-axofieldlist--basic", theme: theme)
    }

    @Test(arguments: ["light", "dark"]) func title(theme: String) throws {
        let view = AxoFieldList.Root(title: "Profile") {
            AxoFieldList.Item { fieldListGivenName() }
            AxoFieldList.Item { fieldListFamilyName() }
        }
        try itemsSnapshot(view, story: "axo-items-axofieldlist--title", theme: theme)
    }

    @Test(arguments: ["light", "dark"]) func description(theme: String) throws {
        let view = AxoFieldList.Root(title: "Profile", description: Self.profileText) {
            AxoFieldList.Item { fieldListGivenName() }
            AxoFieldList.Item { fieldListFamilyName() }
        }
        try itemsSnapshot(view, story: "axo-items-axofieldlist--description", theme: theme)
    }

    @Test(arguments: ["light", "dark"]) func help(theme: String) throws {
        let view = AxoFieldList.Root(title: "Profile", footerDescription: Self.profileText) {
            AxoFieldList.Item { fieldListGivenName() }
            AxoFieldList.Item { fieldListFamilyName() }
        }
        try itemsSnapshot(view, story: "axo-items-axofieldlist--help", theme: theme)
    }

    @Test(arguments: ["light", "dark"]) func group(theme: String) throws {
        let view = AxoFieldList.Root(title: "Profile") {
            AxoFieldList.Item {
                AxoFieldGroup.Root {
                    fieldListGivenName()
                    AxoFieldGroup.Separator()
                    fieldListFamilyName()
                }
            }
        }
        try itemsSnapshot(view, story: "axo-items-axofieldlist--group", theme: theme)
    }
}
