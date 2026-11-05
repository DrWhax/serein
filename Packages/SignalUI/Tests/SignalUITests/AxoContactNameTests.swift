// AxoContactName stories (ts/axo/AxoContactName.dom.stories.tsx, layout: centered).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct AxoContactNameTests {
    /// `<span dir="auto">Jamie</span>&nbsp;<SystemContactEmblem />` in body text; the emblem's
    /// line-height-1 box sits on the text baseline (3px below the 20px line's top).
    @Test(arguments: ["light", "dark"]) func systemContactEmblem(theme: String) throws {
        let style = CSSTextStyle(.bodyLarge)
        let nbsp = CSSTextLayout.make("\u{00A0}x", style, wrap: .nowrap, maxWidth: nil).width - CSSTextLayout.make("x", style, wrap: .nowrap, maxWidth: nil).width
        let view = HStack(alignment: .top, spacing: 0) {
            AxoBaseItem.Text("Jamie", type: .bodyLarge, wrap: .nowrap)
            AxoContactName.SystemContactEmblem().padding(.top, 3).padding(.leading, nbsp)
        }
        .padding(.leading, 0.75)
        try itemsSnapshot(view, story: "axo-axocontactname--system-contact-emblem", theme: theme)
    }
}
