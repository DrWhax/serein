// ts/components/conversation/conversation-details/AddGroupMembersModal.dom.stories.tsx. The
// candidates are 50 seeded getDefaultConversation contacts; the fixtures hold the rows the
// virtualised list renders (AddGroupMembersModalFixtures, from the captures).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct AddGroupMembersModalTests {
    static func contacts(_ rows: [(String, Int)]) -> [ContactListItemData] {
        rows.map { ContactListItemData(id: $0.0, title: $0.0, avatar: ConversationAvatarData(title: $0.0, image: fixtureImage("kitten-\($0.1)-64-64.jpg"))) }
    }

    static func modal(_ candidates: [ContactListItemData], alreadyIn: Set<String> = []) -> some View {
        PortalStage { EmptyView() } modal: {
            AddGroupMembersModal(candidateContacts: candidates, conversationIdsAlreadyInGroup: alreadyIn, groupTitle: "Tahoe Trip")
        }
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let c = "components-conversation-conversationdetails-addgroupmembersmodal--"
        let all = Self.contacts(AddGroupMembersModalFixtures.all)
        try Snapshot.assertMatches(Self.modal(all), story: c + "default", theme: theme)
        try Snapshot.assertMatches(Self.modal(Self.contacts(AddGroupMembersModalFixtures.three)), story: c + "only-3-contacts", theme: theme)
        try Snapshot.assertMatches(Self.modal([]), story: c + "no-candidate-contacts", theme: theme)
        try Snapshot.assertMatches(Self.modal(all, alreadyIn: Set(all.map(\.id))), story: c + "everyone-already-added", theme: theme)
        try Snapshot.assertMatches(Self.modal(all), story: c + "request-fails-after-1-second", theme: theme)
    }
}

/// ts/components/AddGroupMemberErrorDialog.dom.stories.tsx
@MainActor
@Suite struct AddGroupMemberErrorDialogTests {
    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        try Snapshot.assertMatches(PortalStage { EmptyView() } modal: {
            AxoBaseDialog.Host { AddGroupMemberMaximumGroupSizeErrorDialog(maximumNumberOfContacts: 123) {} }
        }, story: "components-addgroupmembererrordialog--maximum-group-size", theme: theme)
        try Snapshot.assertMatches(PortalStage { EmptyView() } modal: {
            AxoBaseDialog.Host { AddGroupMemberRecommendedMaximumGroupSizeErrorDialog(recommendedMaximumNumberOfContacts: 123) {} }
        }, story: "components-addgroupmembererrordialog--maximum-recommended-group-size", theme: theme)
    }
}
