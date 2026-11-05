// AxoSelectItem stories (ts/axo/items/AxoSelectItem.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

let selectItemOptions: [AxoSelectItem.Option] = [.init(value: "1", label: "One"), .init(value: "2", label: "Two"), .init(value: "3", label: "Three")]

@MainActor
@Suite struct AxoSelectItemTests {
    @Test(arguments: ["light", "dark"]) func basic(theme: String) throws {
        let view = AxoItem.Group {
            AxoSelectItem.Root(label: "Title", placeholder: "Placeholder", value: .constant(nil), options: selectItemOptions)
        }
        try itemsSnapshot(view, story: "axo-items-axoselectitem--basic", theme: theme)
    }

    @Test(arguments: ["light", "dark"]) func description(theme: String) throws {
        let view = AxoItem.Group {
            AxoSelectItem.Root(label: "Title", description: "Description", placeholder: "Placeholder", value: .constant(nil),
                               options: selectItemOptions)
        }
        try itemsSnapshot(view, story: "axo-items-axoselectitem--description", theme: theme)
    }

    @Test(arguments: ["light", "dark"]) func icon(theme: String) throws {
        let view = AxoItem.Group {
            AxoSelectItem.Root(symbol: "settings", label: "Title", placeholder: "Placeholder", value: .constant(nil), options: selectItemOptions)
        }
        try itemsSnapshot(view, story: "axo-items-axoselectitem--icon", theme: theme)
    }
}
