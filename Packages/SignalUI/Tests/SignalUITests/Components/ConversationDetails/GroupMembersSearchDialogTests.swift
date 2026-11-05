// ts/components/conversation/conversation-details/GroupMembersSearchDialog.dom.stories.tsx.
// mockMembers(n) uses seeded getDefaultConversation names / avatars (GroupMembersSearchDialogFixtures,
// from the captures); "you" sorts under R. NoAdmins / NoSystemContacts filter everyone out.
// SearchingAndFiltering's order is Fuse's score plus each contact's random activeAt, so the
// test injects the captured order as the search function.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct GroupMembersSearchDialogTests {
    static func members(_ story: String) -> [GroupV2Membership] {
        (GroupMembersSearchDialogFixtures.rows[story] ?? []).enumerated().map { i, r in
            GroupV2Membership(id: "\(i)", avatar: ConversationAvatarData(title: r.4 ? "Rme" : r.0, image: fixtureImage("kitten-\(r.1)-64-64.jpg")),
                              isMe: r.4, isAdmin: r.2, isInSystemContacts: r.3)
        }
    }

    static func dialog(_ story: String, members: [GroupV2Membership]? = nil, add: Bool = false, invite: Bool = false, query: String = "",
                       filter: GroupMembersSearchDialog.Filter = .all, search: (([GroupV2Membership], String) -> [GroupV2Membership])? = nil) -> some View {
        PortalStage { EmptyView() } modal: {
            AxoBaseDialog.Host {
                GroupMembersSearchDialog(members: members ?? Self.members(story), canAddNewMembers: add, canInviteViaGroupLink: invite,
                                         search: search ?? GroupMembersSearchDialog.defaultSearch, initialSearchValue: query, initialFilter: filter)
            }
        }
    }

    static var stories: [(String, AnyView)] {
        let tenNoAdmins = (0..<10).map { GroupV2Membership(id: "\($0)", avatar: ConversationAvatarData(title: "Member \($0)"), isInSystemContacts: true) }
        let tenNoContacts = (0..<10).map { GroupV2Membership(id: "\($0)", avatar: ConversationAvatarData(title: "Member \($0)"), isAdmin: true) }
        let found = members("searching-and-filtering")
        return [
            ("default", AnyView(dialog("default", add: true, invite: true))),
            ("cannot-add-new-members", AnyView(dialog("cannot-add-new-members", invite: true))),
            ("can-invite-via-group-link", AnyView(dialog("can-invite-via-group-link", add: true))),
            ("no-available-actions", AnyView(dialog("no-available-actions"))),
            ("no-admins", AnyView(dialog("no-admins", members: tenNoAdmins, filter: .admins))),
            ("no-system-contacts", AnyView(dialog("no-system-contacts", members: tenNoContacts, filter: .systemContacts))),
            ("no-search-results", AnyView(dialog("no-search-results", members: tenNoAdmins,
                                                 query: "thisshouldnotmatchanythingreallyreallylongtextthatshouldoverflow"))),
            ("searching-and-filtering", AnyView(dialog("searching-and-filtering", members: found, query: "a", filter: .systemContacts,
                                                       search: { _, _ in found }))),
        ]
    }

    @Test(arguments: ["light", "dark"], 0..<8)
    func story(theme: String, index: Int) throws {
        let (name, view) = Self.stories[index]
        try Snapshot.assertMatches(view, story: "components-conversation-conversationdetails-groupmemberssearchdialog--\(name)", theme: theme)
    }

    @Test func grouping() {
        let sections = GroupMembersSearchDialog.groupByFirstInitial(Self.members("default"))
        #expect(sections.first?.initial == "A")
        #expect(sections.first?.items.map(\.avatar.title).prefix(3) == ["Arvid Smitham", "Arielle Kozey", "Adelia Christiansen"])
    }
}
