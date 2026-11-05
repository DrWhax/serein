// ts/components/conversation/conversation-details/ConversationDetailsMembershipList.dom.stories.tsx.
// createMemberships(10): index i is an admin when i % 4 == 0, labelled "Task Wrangler i" when
// i % 3 == 0 (with 🟢 when i % 6 == 0), coloured ContactNameColors[i], and "you" at i == 2.
// The seeded getDefaultConversation names and kitten avatars come from the captures; index 3
// is never shown (any title sorting after "Natalie Auer" will do). Many shows only you and
// the first four of its 25 admins.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct ConversationDetailsMembershipListTests {
    static func member(_ i: Int, _ name: String, _ kitten: Int, me: Bool = false) -> GroupV2Membership {
        GroupV2Membership(id: "\(i)-\(name)", avatar: ConversationAvatarData(title: name, image: fixtureImage("kitten-\(kitten)-64-64.jpg")),
                          isMe: me, isAdmin: i % 4 == 0,
                          label: i % 3 == 0 ? ContactLabel(labelString: "Task Wrangler \(i)", labelEmoji: i % 6 == 0 ? "🟢" : nil) : nil,
                          contactNameColor: ContactNameTests.colors[i % ContactNameTests.colors.count])
    }

    static let defaults: [GroupV2Membership] = [
        member(0, "Mattie Grady", 2), member(1, "Bernadine Feil", 1), member(2, "Regan Murazik", 2, me: true), member(3, "Zelda Zz", 1),
        member(4, "Arvid Smitham", 3), member(5, "Ray Barton", 2), member(6, "Carmine Hane", 1), member(7, "Lyla Ward", 1),
        member(8, "Sienna Ernser", 2), member(9, "Natalie Auer", 3),
    ]

    static var many: [GroupV2Membership] {
        var out = [member(2, "Me", 3, me: true), member(4, "Adella Bahringer", 3), member(8, "Annabell Stoltenberg", 1),
                   member(72, "Buford Kautzer", 3), member(36, "Casper Hahn", 1)]
        for i in 0..<100 where ![2, 4, 8, 72, 36].contains(i) { out.append(member(i, "Zz \(i)", 1)) }
        return out
    }

    static func list(_ m: [GroupV2Membership], canAdd: Bool = false) -> some View {
        ConversationDetailsMembershipList(memberships: m, canAddNewMembers: canAdd).frame(width: 1168)
    }

    static let stories: [(String, AnyView)] = [
        ("few", AnyView(list(Array(defaults.dropFirst(3))))),
        ("limit", AnyView(list(Array(defaults.dropFirst(5))))),
        ("limit-1", AnyView(list(Array(defaults.dropFirst(6))))),
        ("limit-2", AnyView(list(Array(defaults.dropFirst(7))))),
        ("many", AnyView(list(many))),
        ("none", AnyView(list([]))),
        ("can-add-new-members", AnyView(list(defaults, canAdd: true))),
        ("has-group-link", AnyView(list(defaults))),
    ]

    @Test(arguments: ["light", "dark"], 0..<8)
    func story(theme: String, index: Int) throws {
        let (name, view) = Self.stories[index]
        try Snapshot.assertMatches(view, story: "components-conversation-conversationdetails-conversationdetailsmembershiplist--\(name)", theme: theme)
    }

    @Test func sorting() {
        #expect(GroupV2Membership.sorted(Self.defaults).prefix(5).map(\.avatar.title) == ["Regan Murazik", "Arvid Smitham", "Mattie Grady", "Sienna Ernser", "Bernadine Feil"])
    }
}
