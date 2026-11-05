// AxoFieldGroup, AxoPasswordField and AxoSearchField stories (ts/axo/fields/*.dom.stories.tsx).

import EncodePNG
import Foundation
import SwiftUI
import Testing
@testable import SignalUI

struct AxoFieldGroupBasicStory: View {
    @State var givenName = ""
    @State var familyName = ""
    var body: some View {
        AxoFieldGroup.Root(label: "Name") {
            AxoTextField.Root(value: $givenName, maxGraphemes: 200, maxBytes: 800) { AxoTextField.Input(placeholder: "Given name") }
            AxoFieldGroup.Separator()
            AxoTextField.Root(value: $familyName, maxGraphemes: 200, maxBytes: 800) { AxoTextField.Input(placeholder: "Family name") }
        }
    }
}

struct AxoFieldGroupFitStory: View {
    @State var nickname = ""
    @State var discriminator = ""
    var body: some View {
        AxoFieldGroup.Root(label: "Username") {
            AxoTextField.Root(value: $nickname, maxGraphemes: 200, maxBytes: 800) { AxoTextField.Input(placeholder: "Username") }
            AxoFieldGroup.Separator()
            AxoTextField.Root(value: $discriminator, maxGraphemes: 200, maxBytes: 800) {
                AxoTextField.Input(placeholder: "00", sizing: .fit, tabularNums: true)
            }
        }
    }
}

struct AxoFieldGroupKitchenSinkStory: View {
    @State var givenName = ""
    @State var familyName = ""
    var body: some View {
        AxoFieldGroup.Root(label: "Name") {
            AxoTextField.Root(value: $givenName, maxGraphemes: 16, maxBytes: 64) {
                AxoTextField.Icon(symbol: "person")
                AxoTextField.Input(placeholder: "Given name")
                AxoTextField.Count()
                AxoTextField.Clear()
                AxoTextField.LoadingIndicator(pending: false)
            }
            AxoFieldGroup.Separator()
            AxoTextField.Root(value: $familyName, maxGraphemes: 16, maxBytes: 64) {
                AxoTextField.Icon(symbol: "group")
                AxoTextField.Input(placeholder: "Family name")
                AxoTextField.Count()
                AxoTextField.Clear()
                AxoTextField.LoadingIndicator(pending: false)
            }
        }
    }
}

struct AxoPasswordFieldBasicStory: View {
    @State var value = ""
    var body: some View {
        AxoPasswordField.Root(value: $value, maxGraphemes: 64, maxBytes: 64) {
            AxoPasswordField.Input(placeholder: "Password", autoComplete: .currentPassword)
            AxoPasswordField.Reveal()
        }
    }
}

struct AxoSearchFieldBasicStory: View {
    @State var value = ""
    var body: some View {
        AxoSearchField.Root(value: $value) {
            AxoSearchField.Icon()
            AxoSearchField.Input(placeholder: "Search")
            AxoSearchField.Clear()
        }
    }
}

@MainActor
@Suite struct AxoFieldGroupTests {
    @Test(arguments: ["light", "dark"])
    func fieldGroup(theme: String) throws {
        try Snapshot.assertMatches(AxoFieldGroupBasicStory(), story: "axo-fields-axofieldgroup--basic", theme: theme)
        try Snapshot.assertMatches(AxoFieldGroupFitStory(), story: "axo-fields-axofieldgroup--fit", theme: theme)
        try Snapshot.assertMatches(AxoFieldGroupKitchenSinkStory(), story: "axo-fields-axofieldgroup--kitchen-sink", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func passwordField(theme: String) throws {
        try Snapshot.assertMatches(AxoPasswordFieldBasicStory(), story: "axo-fields-axopasswordfield--basic", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func searchField(theme: String) throws {
        try Snapshot.assertMatches(AxoSearchFieldBasicStory(), story: "axo-fields-axosearchfield--basic", theme: theme)
    }
}

/// Dev aid: with FIELDS_DUMP=<dir> set, writes every fields story's rendering to <dir>.
@MainActor
@Suite struct FieldsDump {
    @Test func dump() throws {
        guard let dir = ProcessInfo.processInfo.environment["FIELDS_DUMP"] else { return }
        let views: [(String, AnyView)] = AxoTextFieldTests.stories.map { ("axo-fields-axotextfield--\($0.0)", $0.1) } + [
            ("axo-fields-axofieldgroup--basic", AnyView(AxoFieldGroupBasicStory())),
            ("axo-fields-axofieldgroup--fit", AnyView(AxoFieldGroupFitStory())),
            ("axo-fields-axofieldgroup--kitchen-sink", AnyView(AxoFieldGroupKitchenSinkStory())),
            ("axo-fields-axopasswordfield--basic", AnyView(AxoPasswordFieldBasicStory())),
            ("axo-fields-axosearchfield--basic", AnyView(AxoSearchFieldBasicStory())),
            ("axo-controls-axoradiogroup--default", AnyView(AxoRadioGroupDefaultStory())),
        ]
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (id, view) in views {
            for theme in ["light", "dark"] {
                let (info, _) = try Snapshot.reference(id, theme)
                let image = try Snapshot.render(view, info: info)
                try Data(PNGEncoder.encode(image)).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(id).\(theme).png"))
            }
        }
    }
}
