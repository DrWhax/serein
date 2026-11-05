// AxoSwitchItem stories (ts/axo/items/AxoSwitchItem.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct AxoSwitchItemTests {
    @Test(arguments: ["light", "dark"]) func title(theme: String) throws {
        let view = AxoItem.Group { AxoSwitchItem.Root(label: "Title", checked: .constant(false)) }
        try itemsSnapshot(view, story: "axo-items-axoswitchitem--title", theme: theme)
    }

    @Test(arguments: ["light", "dark"]) func description(theme: String) throws {
        let view = AxoItem.Group { AxoSwitchItem.Root(label: "Title", description: "Description", checked: .constant(false)) }
        try itemsSnapshot(view, story: "axo-items-axoswitchitem--description", theme: theme)
    }

    @Test(arguments: ["light", "dark"]) func symbol(theme: String) throws {
        let view = AxoItem.Group { AxoSwitchItem.Root(symbol: "info-circle", label: "Title", checked: .constant(false)) }
        try itemsSnapshot(view, story: "axo-items-axoswitchitem--symbol", theme: theme)
    }

    @Test(arguments: ["light", "dark"]) func list(theme: String) throws {
        let view = AxoList.Root {
            AxoList.Body {
                AxoItem.Group {
                    AxoSwitchItem.Root(label: "Title", checked: .constant(false))
                    AxoSwitchItem.Root(label: "Title", description: "Description", checked: .constant(false))
                    AxoSwitchItem.Root(symbol: "info-circle", label: "Title", checked: .constant(false))
                }
            }
        }
        try itemsSnapshot(view, story: "axo-items-axoswitchitem--list", theme: theme)
    }
}
