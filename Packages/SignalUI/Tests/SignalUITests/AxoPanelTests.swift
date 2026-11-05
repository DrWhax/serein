// AxoPanel and AxoContainer stories (ts/axo/AxoPanel.dom.stories.tsx, AxoContainer.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

let panelLorem = "Lorem ipsum dolor sit amet consectetur adipisicing elit. Qui velit voluptates necessitatibus eaque tenetur molestias eum labore animi enim recusandae. Mollitia sit officiis possimus nemo debitis omnis reprehenderit provident quo!"

/// Stories `Basic` / `Back` (layout: fullscreen).
struct AxoPanelStory: View {
    let back: Bool
    var body: some View {
        AxoPanel.Root {
            AxoPanel.Header {
                AxoPanel.Label("Label")
                if back { AxoPanel.Back(onClick: {}) }
            }
            AxoPanel.Content {
                StoryText(panelLorem).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Story `AxoContainer/Basic`: three `p.mb-2.5` (the last margin stays inside the padding).
struct AxoContainerStory: View {
    static let paragraphs = [
        "Lorem ipsum dolor sit amet, consectetur adipisicing elit. Doloribus at suscipit provident minus totam, eos veritatis laudantium quidem reprehenderit blanditiis inventore et in dolorum porro unde eum voluptates, voluptatum magnam.",
        "Ipsum ad facilis atque nobis temporibus odit cum tempora voluptatum maxime quo suscipit aut ab excepturi fuga ullam reiciendis repellat repudiandae, sed nam quibusdam doloribus nulla! Incidunt dicta quisquam dolores.",
        "Alias fuga, sit et placeat debitis modi accusantium possimus eveniet vel voluptatum obcaecati ad nulla nam atque, repudiandae, in animi quidem odio recusandae! Quo, nesciunt. Rerum sapiente exercitationem officiis ullam.",
    ]
    var body: some View {
        AxoContainer.Root {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.paragraphs, id: \.self) { StoryText($0).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 10) }  // block <p> }
            }
        }
    }
}

@MainActor
@Suite struct AxoPanelTests {
    @Test(arguments: ["light", "dark"])
    func basic(theme: String) throws {
        try Snapshot.assertMatches(AxoPanelStory(back: false), story: "axo-axopanel--basic", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func back(theme: String) throws {
        try Snapshot.assertMatches(AxoPanelStory(back: true), story: "axo-axopanel--back", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func container(theme: String) throws {
        try Snapshot.assertMatches(AxoContainerStory(), story: "axo-axocontainer--basic", theme: theme)
    }
}
