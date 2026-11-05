// ts/components/conversation/ContactSpoofingReviewDialogPerson.dom.stories.tsx and
// ContactSpoofingReviewDialog.dom.stories.tsx.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct ContactSpoofingTests {
    static let mattie = ContactSpoofingPerson(title: "Mattie Grady", avatar: fixtureImage("kitten-2-64-64.jpg"))

    @Test(arguments: ["light", "dark"])
    func person(theme: String) throws {
        let c = "components-conversation-contactspoofingreviewdialogperson--"
        try Snapshot.assertMatches(ContactSpoofingReviewDialogPerson(conversation: Self.mattie, onClick: {}), story: c + "normal", theme: theme)
        try Snapshot.assertMatches(ContactSpoofingReviewDialogPerson(conversation: Self.mattie, isSignalConnection: true, onClick: {}),
                                   story: c + "signal-connection", theme: theme)
        try Snapshot.assertMatches(ContactSpoofingReviewDialogPerson(conversation: Self.mattie, oldName: "Imposter", onClick: {}),
                                   story: c + "profile-name-changed", theme: theme)
        try Snapshot.assertMatches(ContactSpoofingReviewDialogPerson(conversation: Self.mattie, sharedGroupNames: ["A", "B", "C"], onClick: {}),
                                   story: c + "with-shared-groups", theme: theme)
    }

    static func c(_ title: String, _ kitten: Int, oldName: String? = nil, connection: Bool = false) -> ContactSpoofingReviewDialog.Candidate {
        ContactSpoofingReviewDialog.Candidate(id: UUID().uuidString, conversation: ContactSpoofingPerson(title: title, avatar: fixtureImage("kitten-\(kitten)-64-64.jpg")),
                                              isSignalConnection: connection, oldName: oldName)
    }

    static func many(admin: Bool) -> ContactSpoofingReviewDialog {
        ContactSpoofingReviewDialog(kind: .multipleGroupMembersWithSameTitle(areWeAdmin: admin, addFromInviteLinkNeedsApproval: false, collisions: [
            ("Alice", [c("Alice", 1, oldName: "Alicia"), c("Alice", 2, oldName: "Alicia")]),
            ("Bob", [c("Bob", 3), c("Bob", 1), c("Bob", 2)]),
            ("Charlie", (0..<5).map { _ in c("Charlie", 1) }),
        ]))
    }

    static func one(admin: Bool) -> ContactSpoofingReviewDialog {
        ContactSpoofingReviewDialog(kind: .multipleGroupMembersWithSameTitle(areWeAdmin: admin, addFromInviteLinkNeedsApproval: false, collisions: [
            ("Alice", [c("Alice", 1, oldName: "Alicia"), c("Alice", 2, oldName: admin ? nil : "Alice", connection: true)]),
        ]))
    }

    @Test(arguments: ["light", "dark"])
    func dialog(theme: String) throws {
        func stage(_ d: some View) -> some View { PortalStage { EmptyView() } modal: { AxoBaseDialog.Host { d } } }
        let id = "components-conversation-contactspoofingreviewdialog--"
        try Snapshot.assertMatches(stage(ContactSpoofingReviewDialog(kind: .directConversationWithSameTitle(
            possiblyUnsafe: Self.c("Mattie Grady", 2), safe: Self.c("Bernadine Feil", 1, connection: true)))),
            story: id + "direct-conversations-with-same-title", theme: theme)
        try Snapshot.assertMatches(stage(Self.many(admin: false)), story: id + "not-admin-many", theme: theme)
        try Snapshot.assertMatches(stage(Self.one(admin: false)), story: id + "not-admin-one", theme: theme)
        try Snapshot.assertMatches(stage(Self.many(admin: true)), story: id + "admin-many", theme: theme)
        try Snapshot.assertMatches(stage(Self.one(admin: true)), story: id + "admin-one", theme: theme)
    }
}
