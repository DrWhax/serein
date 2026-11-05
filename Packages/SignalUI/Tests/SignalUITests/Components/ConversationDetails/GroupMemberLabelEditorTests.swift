// ts/components/conversation/conversation-details/GroupMemberLabelEditor.dom.stories.tsx.
// `me` is the seeded "Bernadine Feil" (kitten 2) and ourColor 160. WithBadge is out of scope
// (a donor badge on the preview's avatar).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct GroupMemberLabelEditorTests {
    static var me: MessageProps.Author {
        var a = MessageProps.Author(id: "me", title: "Bernadine Feil")
        a.avatar = fixtureImage("kitten-2-64-64.jpg")
        return a
    }

    static func editor(emoji: String? = "🐘", string: String? = "Good Memory", members: [LabelledGroupMember] = []) -> some View {
        TimelineMessageTests.stage(GroupMemberLabelEditor(me: me, ourColor: "160", existingLabelEmoji: emoji, existingLabelString: string,
                                                          membersWithLabel: members).frame(width: 1168))
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let c = "components-conversation-conversationdetails-groupmemberlabeleditor--"
        try Snapshot.assertMatches(Self.editor(emoji: nil, string: nil), story: c + "no-existing-label", theme: theme)
        for s in ["existing-label", "throws-error-on-save", "permissions-restricted-but-admin", "no-members-with-label"] {
            try Snapshot.assertMatches(Self.editor(), story: c + s, theme: theme)
        }
        try Snapshot.assertMatches(Self.editor(emoji: nil), story: c + "string-but-no-emoji", theme: theme)
    }

    static func members(_ rows: [(String, Int, Bool, String, String)]) -> [LabelledGroupMember] {
        rows.enumerated().map { i, r in
            LabelledGroupMember(id: "\(i)", avatar: ConversationAvatarData(title: r.0, image: fixtureImage("kitten-\(r.1)-64-64.jpg")), isAdmin: r.2,
                                label: ContactLabel(labelString: r.4, labelEmoji: r.3.isEmpty ? nil : r.3), contactNameColor: ContactNameTests.colors[i])
        }
    }

    @Test(arguments: ["light", "dark"])
    func membersWithLabel(theme: String) throws {
        let c = "components-conversation-conversationdetails-groupmemberlabeleditor--"
        try Snapshot.assertMatches(Self.editor(members: Self.members(GroupMemberLabelEditorFixtures.few)), story: c + "a-few-members-with-label", theme: theme)
        try Snapshot.assertMatches(Self.editor(members: Self.members(GroupMemberLabelEditorFixtures.lots)), story: c + "lots-of-members-with-label", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func permissionsError(theme: String) throws {
        let view = PortalStage { Self.editor() } modal: {
            AxoBaseDialog.Host {
                GroupMemberLabelEditorAlert(description: "Only admins can set member labels in this group.") {}
            }
        }
        try Snapshot.assertMatches(view, story: "components-conversation-conversationdetails-groupmemberlabeleditor--permissions-error", theme: theme)
    }
}
