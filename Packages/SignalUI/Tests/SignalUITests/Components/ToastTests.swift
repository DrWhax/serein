// ts/components/Toast.dom.stories.tsx

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct ToastTests {
    static let long = "Lorem ipsum dolor sit amet, consectetur adipisicing elit. Debitis deserunt cupiditate doloribus vitae perspiciatis, eos atque mollitia aliquam quae aspernatur et iure vero illo veritatis quibusdam maiores laborum. Inventore, minus."

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        for (name, text) in [("defaults", "This is a toast"), ("long", Self.long)] {
            try Snapshot.assertMatches(Toast(text, autoDismissDisabled: true).frame(width: 1168, alignment: .leading), story: "components-toast--\(name)", theme: theme)
        }
    }
}
