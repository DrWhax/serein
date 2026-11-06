// ts/components/MediaEditor.dom.stories.tsx (CAPTURE_VIEWPORT=1: the editor fills the window).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct MediaEditorTests {
    static func editor(_ fixture: String, isSending: Bool = false, showViewOnceToggle: Bool = false) -> MediaEditor {
        MediaEditor(image: fixtureByURL(fixture)!, isCreatingStory: true, isSending: isSending, isHighQuality: false, showViewOnceToggle: showViewOnceToggle)
    }

    @Test(arguments: ["dark", "light"])
    func stories(theme: String) throws {
        let c = "components-mediaeditor--"
        try Snapshot.assertMatches(Self.editor("/fixtures/tina-rolf-269345-unsplash.jpg"), story: c + "extra-large", theme: theme)
        try Snapshot.assertMatches(Self.editor("/fixtures/nathan-anderson-316188-unsplash.jpg"), story: c + "large", theme: theme)
        try Snapshot.assertMatches(Self.editor("/fixtures/kitten-4-112-112.jpg"), story: c + "smol", theme: theme)
        try Snapshot.assertMatches(Self.editor("/fixtures/snow.jpg"), story: c + "portrait", theme: theme)
        try Snapshot.assertMatches(Self.editor("/fixtures/tina-rolf-269345-unsplash.jpg", showViewOnceToggle: true), story: c + "view-once", theme: theme)
        try Snapshot.assertMatches(Self.editor("/fixtures/tina-rolf-269345-unsplash.jpg", isSending: true), story: c + "sending", theme: theme)
    }
}
