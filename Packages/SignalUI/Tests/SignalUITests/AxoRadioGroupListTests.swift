// AxoRadioGroupList stories (ts/axo/items/AxoRadioGroupList.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct AxoRadioGroupListTests {
    @Test(arguments: ["light", "dark"]) func basic(theme: String) throws {
        let view = AxoRadioGroupList.Root(value: .constant("1")) {
            AxoRadioGroupList.Item(value: "1") { AxoRadioGroupList.Label("One") }
            AxoRadioGroupList.Item(value: "2") { AxoRadioGroupList.Label("Two") }
            AxoRadioGroupList.Item(value: "3") { AxoRadioGroupList.Label("Three") }
        }
        try itemsSnapshot(view, story: "axo-items-axoradiogrouplist--basic", theme: theme)
    }

    @Test(arguments: ["light", "dark"]) func descriptions(theme: String) throws {
        let d = "Lorem ipsum dolor, sit amet consectetur adipisicing elit."
        let view = AxoRadioGroupList.Root(value: .constant("1")) {
            AxoRadioGroupList.Item(value: "1") { AxoRadioGroupList.Label("One"); AxoRadioGroupList.Description(d) }
            AxoRadioGroupList.Item(value: "2") { AxoRadioGroupList.Label("Two"); AxoRadioGroupList.Description(d) }
            AxoRadioGroupList.Item(value: "3") { AxoRadioGroupList.Label("Three"); AxoRadioGroupList.Description(d) }
        }
        try itemsSnapshot(view, story: "axo-items-axoradiogrouplist--descriptions", theme: theme)
    }
}
