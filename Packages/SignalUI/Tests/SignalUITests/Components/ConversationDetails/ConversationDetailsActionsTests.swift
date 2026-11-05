// ts/components/conversation/conversation-details/ConversationDetailsActions.dom.stories.tsx.
// createProps defaults canTerminateGroup to true, so most stories show "End group" too.
// Known tolerance 1.5%: the rows are 36.19px (the icon's line box), and the elevation-0 ring
// at the seam between the two lists lands one device row apart in Chromium's pixel snapping.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct ConversationDetailsActionsTests {
    static func actions(isGroup: Bool = true, title: String = "", lastAdmin: Bool = false, canTerminate: Bool = true, archived: Bool = false,
                        blocked: Bool = false, terminated: Bool = false, left: Bool = false) -> some View {
        ConversationDetailsActions(conversationId: "123", conversationTitle: title, cannotLeaveBecauseYouAreLastAdmin: lastAdmin,
                                   canTerminateGroup: canTerminate, isArchived: archived, isBlocked: blocked, isGroup: isGroup,
                                   isGroupTerminated: terminated, left: left)
            .frame(width: 1168)
    }

    static let stories: [(String, AnyView)] = [
        ("basic", AnyView(actions())),
        ("left-the-group", AnyView(actions(left: true))),
        ("blocked-and-left-the-group", AnyView(actions(title: "😸 Cat Snaps", blocked: true, left: true))),
        ("can-terminate-group", AnyView(actions(title: "😸 Cat Snaps"))),
        ("group-terminated", AnyView(actions(title: "😸 Cat Snaps", canTerminate: false, terminated: true))),
        ("group-terminated-archived", AnyView(actions(title: "😸 Cat Snaps", canTerminate: false, archived: true, terminated: true))),
        ("cannot-leave-because-you-are-the-last-admin", AnyView(actions(lastAdmin: true))),
        ("11", AnyView(actions(isGroup: false))),
        ("11-blocked", AnyView(actions(isGroup: false, blocked: true))),
    ]

    @Test(arguments: ["light", "dark"], 0..<9)
    func story(theme: String, index: Int) throws {
        let (name, view) = Self.stories[index]
        try Snapshot.assertMatches(view, story: "components-conversation-conversationdetails-conversationdetailsactions--\(name)", theme: theme)
    }
}

/// ts/components/DeleteMessagesConfirmationDialog.dom.stories.tsx
@MainActor
@Suite struct DeleteMessagesConfirmationDialogTests {
    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        for (name, member) in [("default", false), ("default-still-member", true)] {
            let view = PortalStage { EmptyView() } modal: {
                AxoBaseDialog.Host { DeleteMessagesConfirmationDialog(areWeMember: member, onDestroyMessages: {}, onClose: {}) }
            }
            try Snapshot.assertMatches(view, story: "components-deletemessagesconfirmationdialog--\(name)", theme: theme)
        }
    }
}
