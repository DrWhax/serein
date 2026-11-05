// ts/components/ForwardMessagesModal.dom.stories.tsx: 100 seeded getDefaultConversation()
// candidates, sorted by title; the visible rows' titles and avatars read off the capture.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct ForwardMessagesModalTests {
    static func candidate(_ title: String, _ kitten: Int) -> SearchableConversation {
        SearchableConversation(listItem: ContactListItemData(id: title, title: title,
                                                             avatar: ConversationAvatarData(title: title, image: fixtureImage("kitten-\(kitten)-64-64.jpg"))))
    }

    static let candidates = [("Abe Crooks", 2), ("Adah Morar", 3), ("Adalberto Skiles", 1), ("Adelia Christiansen", 3), ("Adella Bahringer", 3),
                             ("Alize Walter", 1), ("Allan Glover", 2), ("Amaya Lang", 1)].map { candidate($0.0, $0.1) }

    static func stage(_ view: ForwardMessagesModal) -> some View {
        PortalStage { EmptyView() } modal: { view }
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        var announcement = Self.candidate("Jodie Hartmann", 3)
        announcement.announcementsOnly = true
        let stories: [(String, [MessageForwardDraft], [SearchableConversation])] = [
            ("modal", [], Self.candidates),
            ("with-text", [MessageForwardDraft(messageBody: "Hello world")], Self.candidates),
            ("a-sticker", [MessageForwardDraft(isSticker: true)], Self.candidates),
            ("with-a-contact", [MessageForwardDraft(hasContact: true)], Self.candidates),
            ("link-preview", [MessageForwardDraft(messageBody: "signal.org")], Self.candidates),
            ("media-attachments", [MessageForwardDraft(attachmentCount: 4)], Self.candidates),
            ("announcement-only-groups-non-admin", [], [announcement]),
        ]
        for (name, drafts, candidates) in stories {
            try Snapshot.assertMatches(Self.stage(ForwardMessagesModal(drafts: drafts, candidateConversations: candidates)),
                                       story: "components-forwardmessagemodal--\(name)", theme: theme)
        }
    }
}
