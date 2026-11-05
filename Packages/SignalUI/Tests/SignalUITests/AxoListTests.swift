// AxoList stories (ts/axo/items/AxoList.dom.stories.tsx, layout: fullscreen).

import SwiftUI
import Testing
@testable import SignalUI

/// `ExampleItems`: three info-circle items with a description and a trigger.
struct ListExampleItems: View {
    var body: some View {
        AxoItem.Group {
            ForEach(["First", "Second", "Third"], id: \.self) { n in
                AxoItem.Root {
                    AxoItem.Leading { AxoItem.Icon(symbol: "info-circle") }
                    AxoItem.Content {
                        AxoItem.Label("\(n) Item")
                        AxoItem.Description("Description of the \(n.lowercased()) item")
                        AxoItem.HiddenTrigger(label: "Test") {}
                    }
                }
            }
        }
    }
}

/// `bg-surface-secondary p-8`
struct ListStoryPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AxoColor.surfaceSecondary)
    }
}

@MainActor
@Suite struct AxoListTests {
    @Test(arguments: ["light", "dark"]) func basic(theme: String) throws {
        let view = ListStoryPage {
            AxoList.Root { AxoList.Body { ListExampleItems() } }
        }
        try itemsSnapshot(view, story: "axo-items-axolist--basic", theme: theme)
    }

    @Test(arguments: ["light", "dark"]) func withTitle(theme: String) throws {
        let view = ListStoryPage {
            AxoList.Root {
                AxoList.Header { AxoList.Label("List Title") }
                AxoList.Body { ListExampleItems() }
            }
        }
        try itemsSnapshot(view, story: "axo-items-axolist--with-title", theme: theme)
    }

    @Test(arguments: ["light", "dark"]) func withDescription(theme: String) throws {
        let view = ListStoryPage {
            AxoList.Root {
                AxoList.Header {
                    AxoList.Label("List Title")
                    AxoList.Description("Lorem ipsum dolor sit amet consectetur adipisicing elit.")
                }
                AxoList.Body { ListExampleItems() }
            }
        }
        try itemsSnapshot(view, story: "axo-items-axolist--with-description", theme: theme)
    }

    @Test(arguments: ["light", "dark"]) func withFooterDescription(theme: String) throws {
        let view = ListStoryPage {
            AxoList.Root {
                AxoList.Header { AxoList.Label("List Title") }
                AxoList.Body { ListExampleItems() }
                AxoList.Footer { AxoList.FooterDescription("This is some helpful text that describes the section above.") }
            }
        }
        try itemsSnapshot(view, story: "axo-items-axolist--with-footer-description", theme: theme)
    }

    @Test(arguments: ["light", "dark"]) func multipleLists(theme: String) throws {
        let view = ListStoryPage {
            AxoList.Root { AxoList.Body { ListExampleItems() } }
            AxoList.Root {
                AxoList.Header { AxoList.Label("Second Section") }
                AxoList.Body { ListExampleItems() }
                AxoList.Footer { AxoList.FooterDescription("Help text for the second section.") }
            }
            AxoList.Root {
                AxoList.Header { AxoList.Label("Third Section") }
                AxoList.Body { ListExampleItems() }
            }
        }
        try itemsSnapshot(view, story: "axo-items-axolist--multiple-lists", theme: theme)
    }
}
