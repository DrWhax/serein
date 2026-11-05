// ConversationHero stories (ts/components/conversation/ConversationHero.dom.stories.tsx) in the
// stories' 480px column. Names are the seeded casual / getDefaultConversation values; the
// avatar's 18px overhang is above the captured story root.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct ConversationHeroTests {
    static let rashad = ConversationAvatarData(title: "Rashad Gleichner", image: fixtureImage("kitten-2-64-64.jpg"))
    static func groupAvatar(_ title: String) -> ConversationAvatarData {
        ConversationAvatarData(title: title, conversationType: .group, image: fixtureImage("kitten-2-64-64.jpg"))
    }
    static let longDescription = "This is anextremelylargewordinaverylargegroupdescriptionandagroup for all the rock climbers of NYC. We really like to climb rocks and these NYC people climb any rock. No rock is too small or too big to be climbed. We will ascend upon all rocks, and not just in NYC, in the whole world. We are just getting started, NYC is just the beginning, watch out rocks in the galaxy. Kuiper belt I'm looking at you. We will put on a space suit and climb all your rocks. No rock is near nor far for the rock climbers of NYC."

    static func direct(_ groups: [String] = [], title: String = "Rashad Gleichner", profileName: Bool = true, nickname: Bool = false,
                       contacts: Bool = false, accepted: Bool = true, stories: HasStories? = nil) -> ConversationHero {
        ConversationHero(conversationType: .direct, title: title, avatar: rashad, hasStories: stories, acceptedMessageRequest: accepted,
                         hasProfileName: profileName, hasNickname: nickname, isInSystemContacts: contacts, sharedGroupNames: groups)
    }

    static func group(_ title: String, members: [HeroMember], description: String? = nil, verified: Bool = false, accepted: Bool = true) -> ConversationHero {
        ConversationHero(conversationType: .group, title: title, avatar: groupAvatar(title), acceptedMessageRequest: accepted,
                         isGroupNameVerified: verified, groupDescription: description, memberships: members)
    }

    static let withMe = [HeroMember(isMe: true, titleShort: "Me"), HeroMember(titleShort: "Florida"), HeroMember(titleShort: "Natalie")]
    static let withoutMe = [HeroMember(titleShort: "Lora"), HeroMember(titleShort: "Florida"), HeroMember(titleShort: "Natalie")]

    static var stories: [(String, AnyView)] {
        [
            ("direct-five-other-groups", AnyView(direct(["Quis perferendis a", "Inventore eaque", "Dicta voluptatibus", "x", "y"]))),
            ("direct-four-other-groups", AnyView(direct(["Cumque quo", "Iure in", "Recusandae dolorum est", "x"]))),
            ("direct-three-other-groups", AnyView(direct(["Qui rem", "Omnis vitae", "Qui quasi error"]))),
            ("direct-two-other-groups", AnyView(direct(["Voluptas et", "Sit est"]))),
            ("direct-one-other-group", AnyView(direct(["Porro fugit"]))),
            ("direct-no-groups", AnyView(direct())),
            ("direct-no-profile-name", AnyView(direct(title: "123-555-1234", profileName: false))),
            ("direct-in-system-contacts", AnyView(direct(contacts: true))),
            ("direct-with-nickname", AnyView(direct(nickname: true))),
            ("direct-message-request", AnyView(direct(accepted: false))),
            ("direct-read-stories", AnyView(direct(stories: .read))),
            ("direct-unread-stories", AnyView(direct(stories: .unread))),
            ("group", AnyView(group("This is the title that never ends", members: withMe))),
            ("group-long-title", AnyView(group("This is the title that never ends", members: withMe))),
            ("group-long-group-description", AnyView(group("Group title", members: withMe, description: longDescription))),
            ("group-message-request", AnyView(group("Group title", members: withoutMe, description: "Quia ut ut doloremque dicta quo et sapiente quisquam et.",
                                                    accepted: false))),
            ("group-verified-name", AnyView(group("Group title", members: withMe, verified: true))),
            ("note-to-self", AnyView(ConversationHero(conversationType: .direct, title: "Me", avatar: ConversationAvatarData(title: "Me", color: "A130", noteToSelf: true),
                                                      isMe: true))),
            ("signal-conversation", AnyView(ConversationHero(conversationType: .direct, title: "Signal",
                                                             avatar: ConversationAvatarData(title: "Signal", image: BundledImage.named("profile-avatar")),
                                                             isSignalConversation: true))),
        ]
    }

    @Test(arguments: ["light", "dark"], 0..<19)
    func story(theme: String, index: Int) throws {
        let (name, view) = Self.stories[index]
        try Snapshot.assertMatches(view.frame(width: 480, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading),
                                   story: "components-conversation-conversationhero--\(name)", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func groupMemberNames(theme: String) throws {
        func m(_ names: [String?], me: Bool) -> [HeroMember] {
            (me ? [HeroMember(isMe: true, titleShort: "Me")] : []) + names.map { HeroMember(titleShort: $0) }
        }
        func hero(_ members: [HeroMember], invites: Int = 0) -> some View {
            ConversationHero(conversationType: .group, title: "Group Chat", avatar: ConversationAvatarData(title: "Group Chat", conversationType: .group),
                             acceptedMessageRequest: false, memberships: members, invitesCount: invites)
        }
        let body = CSSTextStyle(AxoType.bodyLarge)
        let sections: [(String, [(String, [HeroMember], Int)])] = [
            ("When user is NOT in the group", [
                ("0 members", m([], me: false), 0), ("1 member", m(["Rashad"], me: false), 0), ("2 members", m(["Lora", "Florida"], me: false), 0),
                ("2 members + 2 invited", m(["Natalie", "Chandler"], me: false), 2), ("3 members", m(["Oda", "Thea", "Henri"], me: false), 0),
                ("5 members", m(["Marcus", "Reymundo", "Gabriella", "a", "b"], me: false), 0),
                ("5 members + 2 invited", m(["Cristina", "Jordane", "Faye", "a", "b"], me: false), 2),
            ]),
            ("When user is in the group", [
                ("Just me (1 member)", m([], me: true), 0), ("Just me (1 member) + 1 invited", m([], me: true), 1),
                ("Me + 1 other (2 members)", m(["Ricky"], me: true), 0), ("Me + 2 others (3 members)", m(["Leatha", "Jerry"], me: true), 0),
                ("Me + 3 others (4 members)", m(["Rita", "Lacey", "Kirstin"], me: true), 0),
                ("Me + 4 others (5 members)", m(["Justyn", "Tad", "Aaron", "x"], me: true), 0),
            ]),
            ("Edge Cases", [
                ("Unknown Contact in Small Group", m([nil], me: true), 0),
                ("Unknown Hidden Under \"others\"", m(["Leo", "Karli", nil, nil, nil, "Lilyan", "a", "b", "c", "d"], me: false), 0),
            ]),
        ]
        let view = VStack(alignment: .leading, spacing: 40) {
            ForEach(sections.indices, id: \.self) { s in
                VStack(alignment: .leading, spacing: 0) {
                    CSSText(sections[s].0, style: body).frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 40) {
                        ForEach(sections[s].1.indices, id: \.self) { i in
                            let item = sections[s].1[i]
                            VStack(alignment: .leading, spacing: 0) {
                                CSSText(item.0, style: body).frame(maxWidth: .infinity, alignment: .leading)
                                hero(item.1, invites: item.2)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 480, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        try Snapshot.assertMatches(view, story: "components-conversation-conversationhero--group-member-names", theme: theme)
    }
}
