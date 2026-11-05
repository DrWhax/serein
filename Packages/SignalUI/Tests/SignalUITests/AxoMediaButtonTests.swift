// AxoMediaButton stories (ts/axo/AxoMediaButton.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

/// `Template`: `flex gap-2` with every status (and the two downloading states).
struct AxoMediaButtonTemplate: View {
    var disabled = false
    var body: some View {
        HStack(spacing: 8) {
            AxoMediaButton.Root(status: .undownloaded, downloadedBytes: .indeterminate, totalBytes: .indeterminate, disabled: disabled)
            AxoMediaButton.Root(status: .downloading, downloadedBytes: .indeterminate, totalBytes: .indeterminate, disabled: disabled)
            AxoMediaButton.Root(status: .downloading, downloadedBytes: .count(300), totalBytes: .count(1000), disabled: disabled)
            AxoMediaButton.Root(status: .paused, downloadedBytes: .count(1000), totalBytes: .count(1000), disabled: disabled)
            AxoMediaButton.Root(status: .playing, downloadedBytes: .count(1000), totalBytes: .count(1000), disabled: disabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
@Suite struct AxoMediaButtonTests {
    @Test(arguments: ["light", "dark"])
    func statuses(theme: String) throws {
        try Snapshot.assertMatches(AxoMediaButtonTemplate(), story: "axo-axomediabutton--statuses", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func disabled(theme: String) throws {
        try Snapshot.assertMatches(AxoMediaButtonTemplate(disabled: true), story: "axo-axomediabutton--disabled", theme: theme)
    }
}
