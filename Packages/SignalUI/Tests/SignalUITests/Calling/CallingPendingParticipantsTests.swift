// CallingPendingParticipants stories: allRemoteParticipants ("Participant N", random kitten
// avatars per capture, read back from each theme's DOM).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct CallingPendingParticipantsTests {
    static func participants(_ id: String, theme: String, count: Int) -> [CallingParticipant] {
        let dom = StoryDOM(id, theme: theme)
        let avatars = dom.nodes.filter { $0.cls.split(separator: " ").contains("module-Avatar__contents") }
        return (0..<count).map { i in
            let image = avatars.indices.contains(i) ? dom.nodes.first { n in n.cls.contains("module-Avatar__image") && n.rect == avatars[i].rect }?.fixture : nil
            return CallingParticipant(conversation: CallingConversation(id: "p\(i)", title: "Participant \(i + 1)", avatar: image.flatMap { fixtureImage($0) },
                                                                        aci: "aci-\(i)"))
        }
    }

    @Test(arguments: [("one", 1, false), ("two", 2, false), ("many", 10, false), ("expanded-one", 1, true), ("expanded-two", 2, true),
                      ("expanded-many", 10, true)], ["light", "dark"])
    func story(_ s: (String, Int, Bool), theme: String) throws {
        let id = "components-callingpendingparticipants--\(s.0)"
        let view = CallingPendingParticipants(participants: Self.participants(id, theme: theme, count: s.1), defaultIsExpanded: s.2, approveUser: { _ in },
                                              denyUser: { _ in }, batchUserAction: { _, _ in }, showParticipant: { _ in })
        try Snapshot.assertMatches(view.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top), story: id, theme: theme)
    }
}
