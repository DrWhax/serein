// ts/components/conversation/conversation-details/PendingInvites.dom.stories.tsx (Basic;
// WithBadges is out of scope). The seeded names and avatars come from the capture; the Invites
// tab only shows its count (4 by us + 8 by others).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct PendingInvitesTests {
    func m(_ name: String, _ kitten: Int) -> PendingMember {
        PendingMember(id: name, avatar: ConversationAvatarData(title: name, image: fixtureImage("kitten-\(kitten)-64-64.jpg")))
    }

    @Test(arguments: ["light", "dark"])
    func basic(theme: String) throws {
        let requests = [m("Ole Boyle", 1), m("Chyna Kshlerin", 3), m("Pierce Ondricka", 3), m("Armani Schaden", 1), m("Destini Murazik", 1)]
        let byUs = (0..<4).map { m("Invitee \($0)", 1) }
        let others = [(inviter: m("Inviter", 2), invitees: (0..<8).map { m("Other \($0)", 1) })]
        let view = PendingInvites(groupTitle: "Eveniet illum quidem", areWeAdmin: true, pendingApprovalMemberships: requests,
                                  invitedByUs: byUs, invitedByOthers: others)
            .frame(width: 1168)
        try Snapshot.assertMatches(view, story: "components-conversation-conversationdetails-pendinginvites--basic", theme: theme)
    }
}
