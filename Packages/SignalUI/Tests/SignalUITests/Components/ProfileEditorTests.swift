// ts/components/ProfileEditor.dom.stories.tsx (names, about and colour as the capture drew
// them from `casual` and getRandomColor).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct ProfileEditorTests {
    static let about = "Quis perferendis a sit inventore eaque totam dicta."

    static func editor(first: String = "Kristian", family: String? = "Wunsch", about: String? = about, emoji: String? = nil, avatar: RGBAImage? = nil,
                       username: String? = nil, corrupted: Bool = false, state: UsernameEditState = .editing) -> some View {
        ProfileEditor(aboutEmoji: emoji, aboutText: about, color: "A140", avatar: avatar, firstName: first, familyName: family, username: username,
                      usernameCorrupted: corrupted, usernameLink: "https://signal.me/#eu/testtest", editState: .constant(.none),
                      usernameEditState: .constant(state))
            .frame(width: 1168)
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let s = "components-profileeditor--"
        let cases: [(String, AnyView)] = [
            ("full-set", AnyView(Self.editor(first: "Abelardo", family: "Pfannerstill", about: "Live. Laugh. Love", emoji: "🙏",
                                             avatar: fixtureImage("kitten-3-64-64.jpg")))),
            ("with-full-name", AnyView(Self.editor(family: "Zulauf"))),
            ("with-custom-about", AnyView(Self.editor(about: "Live. Laugh. Love", emoji: "🙏"))),
            ("with-username", AnyView(Self.editor(username: "signaluser.123"))),
            ("deleting-username", AnyView(Self.editor(username: "signaluser.123", state: .deleting))),
            ("corrupted", AnyView(Self.editor(username: "signaluser.123", corrupted: true))),
        ]
        for (story, view) in cases {
            try Snapshot.assertMatches(TimelineMessageTests.stage(view), story: s + story, theme: theme)
        }
        let confirming = PortalStage { TimelineMessageTests.stage(Self.editor(username: "signaluser.123", state: .confirmingDelete)) } modal: { EmptyView() }
        try Snapshot.assertMatches(confirming.axoViewport(), story: s + "confirming-delete", theme: theme)
    }
}
