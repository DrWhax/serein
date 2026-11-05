// ts/components/conversation/conversation-details/EditConversationAttributesModal.dom.stories.tsx

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct EditConversationAttributesModalTests {
    static func modal(title: String = "Bing Bong Group", image: RGBAImage? = nil, focusDescription: Bool = false,
                      state: RequestState = .inactive) -> some View {
        PortalStage { EmptyView() } modal: {
            AxoBaseDialog.Host {
                EditConversationAttributesModal(avatarImage: image, title: title, initiallyFocusDescription: focusDescription, requestState: state)
            }
        }
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let c = "components-conversation-conversationdetails-editconversationattributesmodal--"
        try Snapshot.assertMatches(Self.modal(title: ""), story: c + "no-avatar-empty-title", theme: theme)
        try Snapshot.assertMatches(Self.modal(image: fixtureImage("kitten-3-64-64.jpg")), story: c + "avatar-and-title", theme: theme)
        try Snapshot.assertMatches(Self.modal(title: "Has title", focusDescription: true), story: c + "initially-focusing-description", theme: theme)
        try Snapshot.assertMatches(Self.modal(state: .active), story: c + "request-active", theme: theme)
        try Snapshot.assertMatches(Self.modal(state: .inactiveWithError), story: c + "has-error", theme: theme)
    }
}
