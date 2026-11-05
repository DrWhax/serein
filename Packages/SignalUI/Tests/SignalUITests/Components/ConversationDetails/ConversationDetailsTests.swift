// ts/components/conversation/conversation-details/ConversationDetails.dom.stories.tsx.
// createProps makes 32 seeded members (an admin at 1, you at 2) and 13 invites. Each story's
// visible rows come from its capture (ConversationDetailsFixtures); the rest are fillers that
// sort after them. SignalConversation shows the donations row (spliced out below).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct ConversationDetailsTests {
    static func model(_ story: String, group: Bool = true, count: Int = 32, configure: (inout ConversationDetailsModel) -> Void = { _ in })
        -> ConversationDetailsModel {
        let f = ConversationDetailsFixtures.stories[story]!
        var m = ConversationDetailsModel(conversationId: "c", title: f.header.0,
                                         avatar: ConversationAvatarData(title: f.header.0, conversationType: group ? .group : .direct,
                                                                        image: f.header.1 > 0 ? fixtureImage("kitten-\(f.header.1)-64-64.jpg") : nil),
                                         isGroup: group)
        m.groupDescription = "Hello World!"
        m.hasMedia = true
        m.canHaveNicknameAndNote = true
        m.invitesCount = 13
        var members = f.members.enumerated().map { i, r in
            GroupV2Membership(id: "\(i)", avatar: ConversationAvatarData(title: r.0 == "You" ? "Me" : r.0, image: fixtureImage("kitten-\(r.1)-64-64.jpg")),
                              isMe: r.0 == "You", isAdmin: r.2)
        }
        if group { while members.count < count { members.append(GroupV2Membership(id: "f\(members.count)", avatar: ConversationAvatarData(title: "Zz \(members.count)"))) } }
        m.memberships = members
        configure(&m)
        return m
    }

    static let stories: [(String, Bool, Int, (inout ConversationDetailsModel) -> Void)] = [
        ("basic", true, 32, { _ in }),
        ("member-labels-edit-disabled", true, 32, { $0.isEditMemberLabelEnabled = false }),
        ("member-labels-cannot-be-added", true, 32, { $0.canAddLabel = false }),
        ("member-labels-not-a-member", true, 31, { $0.canAddLabel = false }),
        ("system-contact", false, 0, { $0.isInSystemContacts = true }),
        ("as-admin", true, 32, { $0.isAdmin = true }),
        ("as-last-admin", true, 32, { $0.isAdmin = true }),
        ("as-only-admin", true, 1, { $0.isAdmin = true }),
        ("group-editable", true, 32, { $0.canEditGroupInfo = true }),
        ("group-editable-edit-label-disabled", true, 32, { $0.canEditGroupInfo = true; $0.isEditMemberLabelEnabled = false }),
        ("group-editable-with-custom-disappearing-timeout", true, 32, { $0.canEditGroupInfo = true; $0.expireTimer = 3 * 86_400 }),
        ("group-links-on", true, 32, { $0.hasGroupLink = true; $0.isAdmin = true }),
        ("11", false, 0, { _ in }),
        ("in-another-call-group", true, 32, { $0.hasActiveCall = true }),
        // getFakeCallHistoryGroup: an accepted incoming video call, four calls 0 / 30 / 45 / 60 minutes ago.
        ("with-call-history-group", true, 32, {
            $0.selectedNavTab = .calls
            let now = TimelineMessageTests.now
            $0.callHistoryGroup = CallHistoryGroup(type: .video, direction: .incoming, status: .accepted, timestamp: now,
                                                   children: [0, 30, 45, 60].map { .init(callId: "\($0)", timestamp: now.addingTimeInterval(-Double($0) * 60)) })
        }),
        ("in-another-call-individual", false, 0, { $0.hasActiveCall = true }),
        ("terminated-group", true, 32, { $0.terminated = true; $0.canAddLabel = false }),
        ("terminated-group-as-admin", true, 1, { $0.terminated = true; $0.canAddLabel = false; $0.isAdmin = true }),
    ]

    @Test(arguments: ["light", "dark"], 0..<18)
    func story(theme: String, index: Int) throws {
        let (name, group, count, configure) = Self.stories[index]
        let id = "components-conversation-conversationdetails-conversationdetails--\(name)"
        let view = ConversationDetails(model: Self.model(name, group: group, count: count, configure: configure)).frame(width: 1168)
        try Snapshot.assertMatches(TimelineMessageTests.stage(view, storyHeight: try Snapshot.referenceHeight(id, theme)), story: id, theme: theme)
    }
}

/// SignalConversation with its "Donate to Signal" row spliced out of the reference.
@MainActor
@Suite struct ConversationDetailsSignalTests {
    @Test(arguments: ["light", "dark"])
    func signalConversation(theme: String) throws {
        let id = "components-conversation-conversationdetails-conversationdetails--signal-conversation-without-donations"
        let model = ConversationDetailsTests.model("signal-conversation", group: false) { $0.isSignalConversation = true; $0.canHaveNicknameAndNote = false }
        let view = ConversationDetails(model: model).frame(width: 1168)
        try Snapshot.assertMatches(TimelineMessageTests.stage(view, storyHeight: try Snapshot.referenceHeight(id, theme)), story: id, theme: theme)
    }
}
