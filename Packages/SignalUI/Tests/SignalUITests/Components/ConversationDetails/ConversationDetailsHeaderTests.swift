// ts/components/conversation/conversation-details/ConversationDetailsHeader.dom.stories.tsx.
// OneOnOne is out of scope (it shows a donor badge). EditableNoDescription does not pass
// canEdit, so it matches BasicNoDescription. The header's 4px bottom margin collapses out of
// the story root.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct ConversationDetailsHeaderTests {
    static let description = "This is a group description. https://www.signal.org"

    static func header(_ title: String = "Some Conversation", description: String? = Self.description, canEdit: Bool = false,
                       isMe: Bool = false) -> some View {
        ConversationDetailsHeader(avatar: ConversationAvatarData(title: title, conversationType: .group, color: "A110",
                                                                 image: isMe ? nil : fixtureImage("kitten-1-64-64.jpg")),
                                  title: title, canEdit: canEdit, isGroup: true, isMe: isMe, groupDescription: description, membersCount: 0)
            .frame(width: 1168)
            .padding(.bottom, -4)
    }

    static let stories: [(String, AnyView)] = [
        ("basic", AnyView(header())),
        ("editable", AnyView(header(canEdit: true))),
        ("basic-no-description", AnyView(header("My Group", description: nil))),
        ("editable-no-description", AnyView(header("My Group", description: nil))),
        ("note-to-self", AnyView(header(isMe: true))),
    ]

    @Test(arguments: ["light", "dark"], 0..<5)
    func story(theme: String, index: Int) throws {
        let (name, view) = Self.stories[index]
        try Snapshot.assertMatches(view, story: "components-conversation-conversationdetails-conversationdetailsheader--\(name)", theme: theme)
    }
}
