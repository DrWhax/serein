// ts/components/UsernameEditor.dom.stories.tsx (the captures start at the icon: the root's
// mt-6 collapses into the story frame).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct UsernameEditorTests {
    static func crop(_ v: UsernameEditor) -> some View {
        TimelineMessageTests.stage(v.frame(width: 1168).padding(.top, -24))
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let cases: [(String, UsernameEditor)] = [
            ("without-username", UsernameEditor(currentUsername: nil)),
            ("with-username", UsernameEditor(currentUsername: "signaluser.12")),
            ("with-reservation", UsernameEditor(currentUsername: "reserved", reservation: ("reserved.56", nil))),
            ("username-editing-confirming", UsernameEditor(currentUsername: "signaluser.12", state: .confirming)),
            ("username-editing-username-taken", UsernameEditor(currentUsername: "signaluser.12", error: .usernameNotAvailable)),
            ("username-editing-username-wrong-characters", UsernameEditor(currentUsername: "signaluser.12", error: .checkCharacters)),
            ("username-editing-username-too-short", UsernameEditor(currentUsername: "sig", error: .notEnoughCharacters)),
        ]
        for (story, view) in cases {
            try Snapshot.assertMatches(Self.crop(view), story: "components-usernameeditor--\(story)", theme: theme)
        }
        let general = PortalStage { UsernameEditor(currentUsername: "signaluser.12", error: .general).frame(width: 1168) } modal: { EmptyView() }
        try Snapshot.assertMatches(general.axoViewport(), story: "components-usernameeditor--username-editing-general-error", theme: theme)
    }

    /// UsernameLinkEditor.dom.stories.tsx (layout: fullscreen).
    @Test(arguments: ["light", "dark"])
    func usernameLinkEditor(theme: String) throws {
        let link = "https://signal.me/#eu/n-AJkmmykrFB7j6UODGndSycxcMdp_v6ppRp9rFu5Ad39q_9Ngi_k9-TARWfT43t"
        for (story, l) in [("normal", link), ("no-link", "")] {
            let view = UsernameLinkEditor(link: l, username: "alice.12", color: .blue).frame(width: 1200)
            try Snapshot.assertMatches(TimelineMessageTests.stage(view), story: "components-usernamelinkeditor--\(story)", theme: theme)
        }
    }
}
