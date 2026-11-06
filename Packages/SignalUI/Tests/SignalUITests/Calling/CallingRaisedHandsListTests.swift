// CallingRaisedHandsList stories. getDefaultConversation picks the other participants'
// avatars (kitten-N) at random per capture, so the rows are read back from each theme's DOM;
// we are "Rick Sanchez" (A100, no avatar).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct CallingRaisedHandsListTests {
    static func hands(_ id: String, theme: String) -> (hands: [CallingConversation], localHandRaised: Bool) {
        var lower = false
        let hands = StoryDOM(id, theme: theme).groups(startingWith: "module-calling-participants-list__contact").enumerated().map { i, nodes in
            let nameIndex = nodes.firstIndex { $0.cls.contains("module-calling-participants-list__name") } ?? 0
            let name = nodes[nameIndex...].first { $0.text != nil && !$0.text!.isEmpty }?.text ?? ""
            if nodes.contains(where: { $0.cls.contains("CallingRaisedHandsList__LowerMyHandLink") }) { lower = true }
            if name == "You" { return CallingConversation(id: "me", title: "Rick Sanchez", color: "A100", aci: "me") }
            let image = nodes.first { $0.cls.contains("module-Avatar__image") }?.fixture.flatMap { fixtureImage($0) }
            return CallingConversation(id: "\(i)", title: name, avatar: image, aci: "aci-\(i)")
        }
        return (hands, lower)
    }

    @Test(arguments: ["me", "me-on-another-device", "me-and-one", "one", "many"], ["light", "dark"])
    func list(story: String, theme: String) throws {
        let id = "components-callingraisedhandslist--\(story)"
        let (hands, lower) = Self.hands(id, theme: theme)
        #expect(!hands.isEmpty)
        let list = CallingRaisedHandsList(raisedHands: hands, ourAci: "me", localHandRaised: lower, onClose: {}, onLowerMyHand: {})
        try Snapshot.assertMatches(CallingRaisedHandsListOverlay(list), story: id, theme: theme)
    }

    @Test(arguments: ["button", "button-changing"], ["light", "dark"])
    func button(story: String, theme: String) throws {
        try Snapshot.assertMatches(CallingRaisedHandsListButton(syncedLocalHandRaised: false, raisedHandsCount: 1, onClick: {}),
                                   story: "components-callingraisedhandslist--\(story)", theme: theme)
    }

    @Test func labels() {
        // Several devices of one person raise one hand.
        let a = CallingConversation(id: "a", title: "A", aci: "x")
        #expect(CallingRaisedHandsList(raisedHands: [a, a, CallingConversation(id: "b", title: "B")], ourAci: nil, localHandRaised: false,
                                       onClose: {}, onLowerMyHand: {}).forDisplay.count == 2)
        #expect(CallingRaisedHandsListButton(syncedLocalHandRaised: true, raisedHandsCount: 3, onClick: {}).label == "You + 2")
        #expect(CallingRaisedHandsListButton(syncedLocalHandRaised: true, raisedHandsCount: 1, onClick: {}).label == "You")
        #expect(CallingRaisedHandsListButton(syncedLocalHandRaised: false, raisedHandsCount: 4, onClick: {}).label == "4")
    }
}
