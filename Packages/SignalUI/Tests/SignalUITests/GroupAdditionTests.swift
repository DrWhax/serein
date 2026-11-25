// toggleSelectedContactForGroupAddition: the hard limit, and each size dialog once.

import Testing
@testable import SignalUI

@Suite struct GroupAdditionTests {
    /// A new group (we count as one): the recommended warning on reaching it, the maximum dialog
    /// on reaching the hard limit (instead of the warning), nobody past it; removing is free.
    @Test func limitsAndOneTimeDialogs() {
        var a = GroupAddition()
        func add(_ id: String) { a.toggle(id, maxGroupSize: 5, maxRecommendedGroupSize: 3, numberOfContactsAlreadyInGroup: 1) }
        add("a")
        #expect(a.selectedConversationIds == ["a"] && a.recommendedGroupSizeModalState == .neverShown)
        add("b")                                                                    // 3 with us: recommended size
        #expect(a.recommendedGroupSizeModalState == .showing && a.maximumGroupSizeModalState == .neverShown)
        a.recommendedGroupSizeModalState = .shown
        add("c")
        #expect(a.recommendedGroupSizeModalState == .shown && a.maximumGroupSizeModalState == .neverShown)
        add("d")                                                                    // 5: the hard limit
        #expect(a.maximumGroupSizeModalState == .showing && a.selectedConversationIds == ["a", "b", "c", "d"])
        add("e")                                                                    // past it: not added
        #expect(a.selectedConversationIds == ["a", "b", "c", "d"])
        add("b")
        #expect(a.selectedConversationIds == ["a", "c", "d"])
    }

    /// Reaching both at once shows the maximum dialog only (else-if); the warning stays unseen.
    @Test func maximumWinsOverRecommended() {
        var a = GroupAddition()
        a.toggle("a", maxGroupSize: 3, maxRecommendedGroupSize: 2, numberOfContactsAlreadyInGroup: 1)
        #expect(a.recommendedGroupSizeModalState == .showing)
        var b = GroupAddition()
        b.toggle("a", maxGroupSize: 2, maxRecommendedGroupSize: 2, numberOfContactsAlreadyInGroup: 1)
        #expect(b.maximumGroupSizeModalState == .showing && b.recommendedGroupSizeModalState == .neverShown)
    }

    /// The remote config's limits, the hard one always above the recommended one.
    @Test func limitsFromRemoteConfig() {
        #expect(GroupAddition.limits(recommended: nil, hard: nil) == (151, 1001))
        #expect(GroupAddition.limits(recommended: 200, hard: 150) == (200, 201))
    }
}
