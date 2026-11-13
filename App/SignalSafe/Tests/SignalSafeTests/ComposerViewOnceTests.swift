// The composer's view-once toggle applies only to a lone photo or video that is not a reply
// (upstream isViewOnceEligible).

import Testing
@testable import SignalSafe

@MainActor @Suite struct ComposerViewOnceTests {
    @Test func eligibility() {
        #expect(SignalSession.isViewOnceEligible(["image/jpeg"], quoting: nil))
        #expect(SignalSession.isViewOnceEligible(["video/mp4"], quoting: nil))
        #expect(!SignalSession.isViewOnceEligible(["image/jpeg"], quoting: "m1"))
        #expect(!SignalSession.isViewOnceEligible(["image/jpeg", "image/png"], quoting: nil))
        #expect(!SignalSession.isViewOnceEligible(["application/pdf"], quoting: nil))
        #expect(!SignalSession.isViewOnceEligible([], quoting: nil))
    }
}
