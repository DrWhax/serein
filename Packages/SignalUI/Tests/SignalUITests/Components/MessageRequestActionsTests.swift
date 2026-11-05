// MessageRequestActions stories (ts/components/conversation/MessageRequestActions.dom.stories.tsx):
// the seeded default conversation's first name is "Mattie".

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct MessageRequestActionsTests {
    static func view(_ type: MessageRequestModel.Kind, blocked: Bool = false, reported: Bool = false) -> some View {
        var m = MessageRequestModel(conversationId: "c", conversationType: type, conversationName: "Mattie", addedByName: "Mattie")
        m.isBlocked = blocked
        m.isReported = reported
        return MessageRequestActions(model: m)
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let c = "components-conversation-messagerequestactions--"
        for (kind, prefix) in [(MessageRequestModel.Kind.direct, "direct"), (.group, "group")] {
            try Snapshot.assertMatches(Self.view(kind), story: c + prefix, theme: theme)
            try Snapshot.assertMatches(Self.view(kind, blocked: true), story: c + prefix + "-blocked", theme: theme)
            try Snapshot.assertMatches(Self.view(kind, reported: true), story: c + prefix + "-reported", theme: theme)
            try Snapshot.assertMatches(Self.view(kind, blocked: true, reported: true), story: c + prefix + "-blocked-and-reported", theme: theme)
        }
    }

    @Test(arguments: ["light", "dark"])
    func otherBars(theme: String) throws {
        let c = "components-conversation-"
        try Snapshot.assertMatches(MandatoryProfileSharingActions(model: MessageRequestModel(conversationId: "c", conversationType: .direct,
                                                                                              conversationName: "Mattie")),
                                   story: c + "mandatoryprofilesharingactions--direct", theme: theme)
        try Snapshot.assertMatches(MandatoryProfileSharingActions(model: MessageRequestModel(conversationId: "c", conversationType: .group,
                                                                                              conversationName: "Mattie")),
                                   story: c + "mandatoryprofilesharingactions--group", theme: theme)
        try Snapshot.assertMatches(GroupV1DisabledActions {}, story: c + "groupv1disabledactions--default", theme: theme)
        try Snapshot.assertMatches(GroupV2PendingApprovalActions {}, story: c + "groupv2pendingapprovalactions--default", theme: theme)
    }
}
